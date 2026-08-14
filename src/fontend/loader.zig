//! Module loader. Given an entry `.rg` file, reads and parses it and every
//! module it transitively imports, producing the modules in dependency order
//! (imports before the modules that import them) so later passes can process a
//! module knowing its dependencies are already done.
//!
//! A dotted import `import a.b` resolves to the file `a/b.rg`, looked up first
//! relative to the directory of the importing file and then, if not found there,
//! against each caller-supplied search root in order (so shared libraries can
//! live in a common directory). Paths are normalized lexically so the same file
//! reached two ways loads once. Circular imports and missing files are reported
//! against the import that triggered them; a program with any such error still
//! returns a graph (with the parts that loaded), so the caller can report every
//! problem at once.

const std = @import("std");
const Io = std.Io;
const parser = @import("parser.zig");
const lexer = @import("lexer.zig");

const Diagnostic = lexer.Diagnostic;
const Error = std.mem.Allocator.Error || error{ParseError};

/// One resolved import edge: the bound (leaf) name and the index of the imported
/// module in the graph's `units`. That index is always lower than the importing
/// module's, since dependencies are finalized first.
pub const Import = struct { name: []const u8, module_index: usize };

/// A single loaded module: its canonical path and source (kept for diagnostics),
/// the parsed AST, and its resolved imports.
pub const Unit = struct {
    path: []const u8,
    src: []const u8,
    module: parser.Module,
    imports: []const Import,
};

/// A diagnostic paired with the file it belongs to, so the CLI can render it
/// with the correct source and path.
pub const LocatedDiag = struct { path: []const u8, src: []const u8, diag: Diagnostic };

pub const Graph = struct {
    arena: std.heap.ArenaAllocator,
    /// The parsed trees, kept alive because `units[*].module` borrows them.
    trees: []const *parser.Tree,
    /// Modules in dependency order; the last entry is the root that was loaded.
    units: []const Unit,
    /// Load- and parse-time errors across every file (empty on success).
    diagnostics: []const LocatedDiag,

    pub fn deinit(self: *Graph) void {
        for (self.trees) |t| t.deinit();
        self.arena.deinit();
    }
};

pub fn load(gpa: std.mem.Allocator, io: Io, entry_path: []const u8) Error!Graph {
    return loadWithPaths(gpa, io, entry_path, &.{});
}

/// Like `load`, but imports not found relative to the importer are then looked
/// up against each directory in `roots`, in order. Roots are normalized
/// lexically; the importer-relative lookup always takes precedence.
pub fn loadWithPaths(gpa: std.mem.Allocator, io: Io, entry_path: []const u8, roots: []const []const u8) Error!Graph {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    const clean_roots = try alloc.alloc([]const u8, roots.len);
    for (roots, 0..) |r, i| clean_roots[i] = try cleanPath(alloc, r);

    var loader = Loader{ .gpa = gpa, .arena = alloc, .io = io, .roots = clean_roots };
    const entry = try cleanPath(alloc, entry_path);
    switch (try loader.visit(entry)) {
        .missing => {
            const msg = try std.fmt.allocPrint(alloc, "cannot read '{s}'", .{entry});
            try loader.diags.append(alloc, .{ .path = entry, .src = "", .diag = .{ .message = msg, .line = 0, .col = 0 } });
        },
        .cycle, .index => {},
    }

    const trees = try loader.trees.toOwnedSlice(alloc);
    const units = try loader.units.toOwnedSlice(alloc);
    const diags = try loader.diags.toOwnedSlice(alloc);
    return .{ .arena = arena, .trees = trees, .units = units, .diagnostics = diags };
}

// --- loader ------------------------------------------------------------------

const State = union(enum) { loading, done: usize };

/// The outcome of resolving one module by path.
const Visited = union(enum) { index: usize, missing, cycle };

const Loader = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    roots: []const []const u8 = &.{},
    states: std.StringHashMapUnmanaged(State) = .{},
    units: std.ArrayList(Unit) = .empty,
    trees: std.ArrayList(*parser.Tree) = .empty,
    diags: std.ArrayList(LocatedDiag) = .empty,

    /// Load the module at `path` (canonical), recursively loading its imports,
    /// and return its index. Returns `.missing` if the file cannot be read and
    /// `.cycle` if it is already on the load stack.
    fn visit(self: *Loader, path: []const u8) Error!Visited {
        if (self.states.get(path)) |st| {
            return switch (st) {
                .loading => .cycle,
                .done => |idx| .{ .index = idx },
            };
        }
        try self.states.put(self.arena, path, .loading);

        const src = Io.Dir.cwd().readFileAlloc(self.io, path, self.arena, .limited(16 << 20)) catch {
            // Not loadable: forget it so a second import of the same path is
            // reported at its own site too.
            _ = self.states.remove(path);
            return .missing;
        };

        const tree = try self.arena.create(parser.Tree);
        tree.* = try parser.parse(self.gpa, src);
        try self.trees.append(self.arena, tree);
        for (tree.diagnostics) |d| {
            try self.diags.append(self.arena, .{ .path = path, .src = src, .diag = d });
        }

        // Resolve imports relative to this file's directory, then search roots.
        var imports: std.ArrayList(Import) = .empty;
        const base_dir = std.fs.path.dirname(path) orelse ".";
        for (tree.module.decls) |decl| {
            if (decl != .import) continue;
            const imp = decl.import;
            const rel = try importRelPath(self.arena, imp.path);
            switch (try self.resolveImport(base_dir, rel)) {
                .index => |idx| try imports.append(self.arena, .{ .name = imp.name, .module_index = idx }),
                .missing => try self.reportImport(path, src, imp, "cannot find module"),
                .cycle => try self.reportImport(path, src, imp, "circular import of module"),
            }
        }

        const idx = self.units.items.len;
        try self.units.append(self.arena, .{
            .path = path,
            .src = src,
            .module = tree.module,
            .imports = try imports.toOwnedSlice(self.arena),
        });
        try self.states.put(self.arena, path, .{ .done = idx });
        return .{ .index = idx };
    }

    /// Resolve an import's relative path against the importer's directory first,
    /// then each search root in order. The importer-relative lookup wins when
    /// present; only a `.missing` result falls through to the next candidate (a
    /// cycle is a real resolution and stops the search). Returns `.missing` if no
    /// candidate exists.
    fn resolveImport(self: *Loader, base_dir: []const u8, rel: []const u8) Error!Visited {
        const first = try cleanJoin(self.arena, base_dir, rel);
        switch (try self.visit(first)) {
            .missing => {},
            else => |v| return v,
        }
        for (self.roots) |root| {
            const cand = try cleanJoin(self.arena, root, rel);
            switch (try self.visit(cand)) {
                .missing => {},
                else => |v| return v,
            }
        }
        return .missing;
    }

    fn reportImport(self: *Loader, path: []const u8, src: []const u8, imp: parser.Decl.Import, comptime what: []const u8) Error!void {
        const dotted = try joinDots(self.arena, imp.path);
        const msg = try std.fmt.allocPrint(self.arena, what ++ " '{s}'", .{dotted});
        try self.diags.append(self.arena, .{
            .path = path,
            .src = src,
            .diag = .{ .message = msg, .line = imp.span.line, .col = imp.span.col },
        });
    }
};

// --- path helpers ------------------------------------------------------------

/// A dotted import path to a relative file path: `{a, b}` -> `a/b.rg`.
fn importRelPath(alloc: std.mem.Allocator, segments: []const []const u8) Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (segments, 0..) |seg, i| {
        if (i > 0) try buf.append(alloc, '/');
        try buf.appendSlice(alloc, seg);
    }
    try buf.appendSlice(alloc, ".rg");
    return try buf.toOwnedSlice(alloc);
}

/// A dotted import path in its `a.b` form, for messages.
fn joinDots(alloc: std.mem.Allocator, segments: []const []const u8) Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (segments, 0..) |seg, i| {
        if (i > 0) try buf.append(alloc, '.');
        try buf.appendSlice(alloc, seg);
    }
    return try buf.toOwnedSlice(alloc);
}

fn cleanJoin(alloc: std.mem.Allocator, base: []const u8, rel: []const u8) Error![]const u8 {
    if (std.mem.eql(u8, base, ".")) return cleanPath(alloc, rel);
    const joined = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ base, rel });
    defer alloc.free(joined); // intermediate; cleanPath copies into a fresh buffer
    return cleanPath(alloc, joined);
}

/// Normalize a path lexically (drop `.`, collapse `..`, dedupe separators) so
/// the same file always keys the same. Purely textual; no filesystem access.
fn cleanPath(alloc: std.mem.Allocator, p: []const u8) Error![]const u8 {
    const absolute = p.len > 0 and p[0] == '/';
    var segs: std.ArrayList([]const u8) = .empty;
    defer segs.deinit(alloc); // scratch; the result is built into its own buffer
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (segs.items.len > 0 and !std.mem.eql(u8, segs.items[segs.items.len - 1], "..")) {
                _ = segs.pop();
            } else if (!absolute) {
                try segs.append(alloc, seg);
            }
            continue;
        }
        try segs.append(alloc, seg);
    }
    var buf: std.ArrayList(u8) = .empty;
    if (absolute) try buf.append(alloc, '/');
    for (segs.items, 0..) |seg, i| {
        if (i > 0) try buf.append(alloc, '/');
        try buf.appendSlice(alloc, seg);
    }
    if (buf.items.len == 0) try buf.appendSlice(alloc, ".");
    return try buf.toOwnedSlice(alloc);
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;

test "cleanPath normalizes . and .." {
    const a = testing.allocator;
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "examples/app.rg", .want = "examples/app.rg" },
        .{ .in = "examples/./app.rg", .want = "examples/app.rg" },
        .{ .in = "examples/lib/../app.rg", .want = "examples/app.rg" },
        .{ .in = "./app.rg", .want = "app.rg" },
        .{ .in = "a//b.rg", .want = "a/b.rg" },
        .{ .in = "/abs/x.rg", .want = "/abs/x.rg" },
    };
    for (cases) |c| {
        const got = try cleanPath(a, c.in);
        defer a.free(got);
        try testing.expectEqualStrings(c.want, got);
    }
}

test "cleanJoin resolves a dotted import against a base dir" {
    const a = testing.allocator;
    const rel = try importRelPath(a, &.{ "lib", "math" });
    defer a.free(rel);
    try testing.expectEqualStrings("lib/math.rg", rel);

    const joined = try cleanJoin(a, "examples/sub", rel);
    defer a.free(joined);
    try testing.expectEqualStrings("examples/sub/lib/math.rg", joined);

    const dotted = try joinDots(a, &.{ "lib", "math" });
    defer a.free(dotted);
    try testing.expectEqualStrings("lib.math", dotted);
}

test "loadWithPaths resolves an import from a search root" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // A library under lib/, and an app importing it by leaf name — the library
    // is NOT next to the app, so it's only reachable via a search root.
    try tmp.dir.createDirPath(io, "lib");
    try tmp.dir.writeFile(io, .{ .sub_path = "lib/greet.rg", .data =
        \\pub func hi() -> str:
        \\    return "hi"
        \\
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "app.rg", .data =
        \\import greet
        \\
        \\func main():
        \\    print(greet.hi())
        \\
    });

    const app_path = try tmp.dir.realPathFileAlloc(io, "app.rg", gpa);
    defer gpa.free(app_path);
    const lib_root = try tmp.dir.realPathFileAlloc(io, "lib", gpa);
    defer gpa.free(lib_root);

    // Without the root, the bare `import greet` can't be resolved.
    {
        var g = try loadWithPaths(gpa, io, app_path, &.{});
        defer g.deinit();
        try testing.expectEqual(@as(usize, 1), g.diagnostics.len);
    }
    // With the root, it resolves: two modules, no diagnostics, `greet` bound.
    {
        var g = try loadWithPaths(gpa, io, app_path, &.{lib_root});
        defer g.deinit();
        try testing.expectEqual(@as(usize, 0), g.diagnostics.len);
        try testing.expectEqual(@as(usize, 2), g.units.len);
        const app = g.units[g.units.len - 1]; // the entry is last
        try testing.expectEqual(@as(usize, 1), app.imports.len);
        try testing.expectEqualStrings("greet", app.imports[0].name);
    }
}
