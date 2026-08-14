//! A small Language Server for RoseGold, spoken over stdio (`RoseGold_Zig lsp`).
//!
//! It reuses the real front end: every open document is parsed and analyzed
//! (`parser.parse` + `analyzer.analyzeModule`) and the resulting diagnostics are
//! published to the editor, so errors match the CLI's `check` exactly. It also
//! answers hover, go-to-definition, and document-symbol requests using a
//! lightweight declaration scan over the buffer.
//!
//! Scope (v1): each document is analyzed **standalone** (imports are not resolved
//! across files), so cross-module member checks are deferred — single-file
//! programs get fully accurate diagnostics. Positions are treated as UTF-8 byte
//! offsets within a line (correct for ASCII source).

const std = @import("std");
const Io = std.Io;
const parser = @import("parser.zig");
const analyzer = @import("analyzer.zig");
const lexer = @import("lexer.zig");

// --- LSP wire types (serialized to JSON by std.json) -------------------------

const Pos = struct { line: u32, character: u32 };
const Range = struct { start: Pos, end: Pos };
const LspDiag = struct {
    range: Range,
    severity: u32 = 1, // 1 = Error
    source: []const u8 = "rosegold",
    message: []const u8,
};
const Location = struct { uri: []const u8, range: Range };
const SymbolInformation = struct {
    name: []const u8,
    kind: u32,
    location: Location,
};

// --- declaration scan --------------------------------------------------------

const DeclKind = enum { func, class, struct_, enum_, signal, const_, var_ };

const Decl = struct {
    kind: DeclKind,
    name: []const u8,
    /// 0-based line and byte-column of the declared name.
    line: u32,
    character: u32,

    /// The LSP SymbolKind number for this declaration.
    fn symbolKind(self: Decl) u32 {
        return switch (self.kind) {
            .func => 12, // Function
            .class => 5, // Class
            .struct_ => 23, // Struct
            .enum_ => 10, // Enum
            .signal => 24, // Event
            .const_ => 14, // Constant
            .var_ => 13, // Variable
        };
    }
};

fn isIdentChar(c: u8) bool {
    return c == '_' or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9');
}

fn isIdentStart(c: u8) bool {
    return c == '_' or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

/// Match a keyword at the start of `s`, returning its kind and the byte length
/// consumed (keyword + following whitespace), or null.
fn matchKeyword(s: []const u8) ?struct { kind: DeclKind, len: usize } {
    const words = [_]struct { w: []const u8, k: DeclKind }{
        .{ .w = "func", .k = .func },
        .{ .w = "class", .k = .class },
        .{ .w = "struct", .k = .struct_ },
        .{ .w = "enum", .k = .enum_ },
        .{ .w = "signal", .k = .signal },
        .{ .w = "const", .k = .const_ },
        .{ .w = "var", .k = .var_ },
    };
    for (words) |e| {
        if (s.len > e.w.len and std.mem.startsWith(u8, s, e.w) and s[e.w.len] == ' ') {
            var i = e.w.len;
            while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
            return .{ .kind = e.k, .len = i };
        }
    }
    return null;
}

/// Find every top-level or member declaration by a line scan (funcs, classes,
/// structs, enums, signals, consts/vars). Deliberately grammar-free — enough for
/// navigation and the symbol outline.
fn scanDecls(alloc: std.mem.Allocator, text: []const u8) ![]Decl {
    var out: std.ArrayList(Decl) = .empty;
    var line: u32 = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| : (line += 1) {
        const l = std.mem.trimEnd(u8, raw, "\r");
        var i: usize = 0;
        while (i < l.len and (l[i] == ' ' or l[i] == '\t')) i += 1;
        var rest = l[i..];
        var col = i;
        // Skip optional visibility and `static` modifiers.
        inline for (.{ "pub ", "private ", "static " }) |kw| {
            if (std.mem.startsWith(u8, rest, kw)) {
                rest = rest[kw.len..];
                col += kw.len;
            }
        }
        const m = matchKeyword(rest) orelse continue;
        const after = rest[m.len..];
        col += m.len;
        if (after.len == 0 or !isIdentStart(after[0])) continue;
        var n: usize = 0;
        while (n < after.len and isIdentChar(after[n])) n += 1;
        try out.append(alloc, .{
            .kind = m.kind,
            .name = after[0..n],
            .line = line,
            .character = @intCast(col),
        });
    }
    return out.toOwnedSlice(alloc);
}

// --- position helpers --------------------------------------------------------

/// The byte offset of a 0-based (line, character) position, or null if the line
/// is out of range. `character` is clamped to the line's length.
fn offsetAt(text: []const u8, line: u32, character: u32) ?usize {
    var cur: u32 = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (cur < line) {
        if (i >= text.len) return null;
        if (text[i] == '\n') {
            cur += 1;
            start = i + 1;
        }
        i += 1;
    }
    // `start` is the beginning of the target line; find its end.
    var end = start;
    while (end < text.len and text[end] != '\n') end += 1;
    const off = start + character;
    return @min(off, end);
}

/// The identifier surrounding `offset` (the cursor may sit just past its end),
/// or null if there's no identifier there.
fn identAt(text: []const u8, offset: usize) ?[]const u8 {
    var o = offset;
    if (o > 0 and (o >= text.len or !isIdentChar(text[o])) and isIdentChar(text[o - 1])) o -= 1;
    if (o >= text.len or !isIdentChar(text[o])) return null;
    var s = o;
    while (s > 0 and isIdentChar(text[s - 1])) s -= 1;
    var e = o;
    while (e < text.len and isIdentChar(text[e])) e += 1;
    return text[s..e];
}

// --- builtin documentation ---------------------------------------------------

fn builtinDoc(name: []const u8) ?[]const u8 {
    const docs = [_]struct { n: []const u8, d: []const u8 }{
        .{ .n = "print", .d = "print(values…) — write the values, space-separated, and a newline." },
        .{ .n = "echo", .d = "echo(values…) — alias of print." },
        .{ .n = "len", .d = "len(x) → int — length of a list, map, or string." },
        .{ .n = "range", .d = "range(n) → list<int> — the ints 0 … n-1." },
        .{ .n = "str", .d = "str(x) → str — the string form of any value." },
        .{ .n = "int", .d = "int(x) → int — convert a number/bool/string to int." },
        .{ .n = "float", .d = "float(x) → float — convert to float." },
        .{ .n = "push", .d = "push(list, x) — append x to the list." },
        .{ .n = "pop", .d = "pop(list<T>) → T — remove and return the last element." },
        .{ .n = "keys", .d = "keys(map<K,V>) → list<K> — the map's keys." },
        .{ .n = "values", .d = "values(map<K,V>) → list<V> — the map's values." },
        .{ .n = "has", .d = "has(map, key) → bool — whether the key is present." },
        .{ .n = "connect", .d = "connect(signal, handler) — register a signal handler." },
        .{ .n = "emit", .d = "emit(signal, args…) — fire a signal's handlers in order." },
        .{ .n = "abs", .d = "abs(x) — absolute value." },
        .{ .n = "min", .d = "min(a, b) — the smaller of two numbers." },
        .{ .n = "max", .d = "max(a, b) — the larger of two numbers." },
        .{ .n = "upper", .d = "upper(s) → str — uppercase." },
        .{ .n = "lower", .d = "lower(s) → str — lowercase." },
        .{ .n = "split", .d = "split(s, sep) → list<str>." },
        .{ .n = "join", .d = "join(list<str>, sep) → str." },
        .{ .n = "contains", .d = "contains(haystack, needle) → bool." },
        .{ .n = "sort", .d = "sort(list) → list — a sorted copy." },
        .{ .n = "reverse", .d = "reverse(list) → list — a reversed copy." },
        .{ .n = "trim", .d = "trim(s) → str — strip surrounding whitespace." },
        .{ .n = "starts_with", .d = "starts_with(s, prefix) → bool." },
        .{ .n = "ends_with", .d = "ends_with(s, suffix) → bool." },
        .{ .n = "find", .d = "find(haystack, needle) → int — index, or -1 if absent." },
        .{ .n = "replace", .d = "replace(s, from, to) → str." },
        .{ .n = "map", .d = "map(list, f) → list — apply f to each element." },
        .{ .n = "filter", .d = "filter(list, pred) → list." },
        .{ .n = "reduce", .d = "reduce(list, f, init) — fold left." },
        .{ .n = "sqrt", .d = "sqrt(x) → float — square root." },
        .{ .n = "pow", .d = "pow(base, exp) → float." },
        .{ .n = "floor", .d = "floor(x) → int." },
        .{ .n = "ceil", .d = "ceil(x) → int." },
        .{ .n = "round", .d = "round(x) → int." },
    };
    for (docs) |e| {
        if (std.mem.eql(u8, e.n, name)) return e.d;
    }
    return null;
}

fn declKindWord(k: DeclKind) []const u8 {
    return switch (k) {
        .func => "function",
        .class => "class",
        .struct_ => "struct",
        .enum_ => "enum",
        .signal => "signal",
        .const_ => "const",
        .var_ => "var",
    };
}

// --- server ------------------------------------------------------------------

const Server = struct {
    gpa: std.mem.Allocator,
    out: *Io.Writer,
    in: *Io.Reader,
    /// uri → document text, both owned by `gpa`.
    docs: std.StringHashMapUnmanaged([]const u8) = .{},
    shutting_down: bool = false,

    fn deinit(self: *Server) void {
        var it = self.docs.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.*);
        }
        self.docs.deinit(self.gpa);
    }

    /// Store (or replace) a document's text, taking ownership of a fresh copy.
    fn putDoc(self: *Server, uri: []const u8, text: []const u8) !void {
        const text_copy = try self.gpa.dupe(u8, text);
        const gop = try self.docs.getOrPut(self.gpa, uri);
        if (gop.found_existing) {
            self.gpa.free(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = try self.gpa.dupe(u8, uri);
        }
        gop.value_ptr.* = text_copy;
    }

    fn removeDoc(self: *Server, uri: []const u8) void {
        if (self.docs.fetchRemove(uri)) |kv| {
            self.gpa.free(kv.key);
            self.gpa.free(kv.value);
        }
    }

    // --- framing ---

    /// Read one message's JSON body (or null at EOF). Returned slice is owned by
    /// the caller.
    fn readMessage(self: *Server) !?[]u8 {
        var content_length: ?usize = null;
        while (true) {
            const maybe = self.in.takeDelimiter('\n') catch return null;
            const line = maybe orelse return null;
            const trimmed = std.mem.trimEnd(u8, line, "\r");
            if (trimmed.len == 0) break; // end of headers
            const prefix = "Content-Length:";
            if (std.mem.startsWith(u8, trimmed, prefix)) {
                const v = std.mem.trim(u8, trimmed[prefix.len..], " \t");
                content_length = std.fmt.parseInt(usize, v, 10) catch null;
            }
        }
        const n = content_length orelse return error.BadHeader;
        const body = try self.gpa.alloc(u8, n);
        errdefer self.gpa.free(body);
        try self.in.readSliceAll(body);
        return body;
    }

    /// Serialize `payload` and write it with an LSP header frame.
    fn send(self: *Server, payload: anytype) !void {
        const body = try std.json.Stringify.valueAlloc(self.gpa, payload, .{});
        defer self.gpa.free(body);
        try self.out.print("Content-Length: {d}\r\n\r\n", .{body.len});
        try self.out.writeAll(body);
        try self.out.flush();
    }

    fn respond(self: *Server, id: std.json.Value, result: anytype) !void {
        try self.send(.{ .jsonrpc = "2.0", .id = id, .result = result });
    }

    fn notify(self: *Server, method: []const u8, params: anytype) !void {
        try self.send(.{ .jsonrpc = "2.0", .method = method, .params = params });
    }

    // --- dispatch ---

    fn run(self: *Server) !void {
        while (true) {
            const body = (try self.readMessage()) orelse break;
            defer self.gpa.free(body);

            var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, body, .{}) catch continue;
            defer parsed.deinit();
            const root = parsed.value;
            if (root != .object) continue;
            const obj = root.object;

            const method = if (obj.get("method")) |m| (if (m == .string) m.string else continue) else continue;
            const id = obj.get("id"); // present for requests, absent for notifications
            const params = obj.get("params");

            if (std.mem.eql(u8, method, "initialize")) {
                try self.respond(id.?, initializeResult());
            } else if (std.mem.eql(u8, method, "shutdown")) {
                self.shutting_down = true;
                try self.respond(id.?, @as(?u8, null));
            } else if (std.mem.eql(u8, method, "exit")) {
                break;
            } else if (std.mem.eql(u8, method, "textDocument/didOpen")) {
                try self.onDidOpen(params);
            } else if (std.mem.eql(u8, method, "textDocument/didChange")) {
                try self.onDidChange(params);
            } else if (std.mem.eql(u8, method, "textDocument/didSave")) {
                try self.onDidSave(params);
            } else if (std.mem.eql(u8, method, "textDocument/didClose")) {
                self.onDidClose(params);
            } else if (std.mem.eql(u8, method, "textDocument/hover")) {
                try self.onHover(id.?, params);
            } else if (std.mem.eql(u8, method, "textDocument/definition")) {
                try self.onDefinition(id.?, params);
            } else if (std.mem.eql(u8, method, "textDocument/documentSymbol")) {
                try self.onDocumentSymbol(id.?, params);
            } else if (id) |rid| {
                // Any other request: reply with null so the client isn't left waiting.
                try self.respond(rid, @as(?u8, null));
            }
        }
    }

    fn initializeResult() struct {
        capabilities: struct {
            textDocumentSync: u32,
            hoverProvider: bool,
            definitionProvider: bool,
            documentSymbolProvider: bool,
        },
        serverInfo: struct { name: []const u8, version: []const u8 },
    } {
        return .{
            .capabilities = .{
                .textDocumentSync = 1, // full document sync
                .hoverProvider = true,
                .definitionProvider = true,
                .documentSymbolProvider = true,
            },
            .serverInfo = .{ .name = "rosegold-lsp", .version = "0.1.0" },
        };
    }

    // --- text-sync handlers ---

    fn onDidOpen(self: *Server, params: ?std.json.Value) !void {
        const p = params orelse return;
        const td = objGet(p, "textDocument") orelse return;
        const uri = strField(td, "uri") orelse return;
        const text = strField(td, "text") orelse return;
        try self.putDoc(uri, text);
        try self.publishDiagnostics(uri, text);
    }

    fn onDidChange(self: *Server, params: ?std.json.Value) !void {
        const p = params orelse return;
        const td = objGet(p, "textDocument") orelse return;
        const uri = strField(td, "uri") orelse return;
        // Full sync: the last content change holds the whole document.
        const changes = objGet(p, "contentChanges") orelse return;
        if (changes != .array or changes.array.items.len == 0) return;
        const last = changes.array.items[changes.array.items.len - 1];
        const text = strField(last, "text") orelse return;
        try self.putDoc(uri, text);
        try self.publishDiagnostics(uri, text);
    }

    fn onDidSave(self: *Server, params: ?std.json.Value) !void {
        const p = params orelse return;
        const td = objGet(p, "textDocument") orelse return;
        const uri = strField(td, "uri") orelse return;
        const text = self.docs.get(uri) orelse return;
        try self.publishDiagnostics(uri, text);
    }

    fn onDidClose(self: *Server, params: ?std.json.Value) void {
        const p = params orelse return;
        const td = objGet(p, "textDocument") orelse return;
        const uri = strField(td, "uri") orelse return;
        self.removeDoc(uri);
    }

    // --- diagnostics ---

    fn publishDiagnostics(self: *Server, uri: []const u8, text: []const u8) !void {
        var diags: std.ArrayList(LspDiag) = .empty;
        defer diags.deinit(self.gpa);

        var tree = try parser.parse(self.gpa, text);
        defer tree.deinit();
        for (tree.diagnostics) |d| try diags.append(self.gpa, mapDiag(text, d));

        // Only analyze once it parses cleanly (analysis over a broken tree is noise).
        if (tree.diagnostics.len == 0) {
            var analysis = try analyzer.analyzeModule(self.gpa, tree.module, &.{});
            defer analysis.deinit();
            for (analysis.diagnostics) |d| try diags.append(self.gpa, mapDiag(text, d));
            // Serialize while the analysis arena (which owns the messages) is alive.
            try self.notify("textDocument/publishDiagnostics", .{ .uri = uri, .diagnostics = diags.items });
            return;
        }
        try self.notify("textDocument/publishDiagnostics", .{ .uri = uri, .diagnostics = diags.items });
    }

    // --- language features ---

    fn onHover(self: *Server, id: std.json.Value, params: ?std.json.Value) !void {
        const word = self.wordAtParams(params) orelse return self.respond(id, @as(?u8, null));
        var value: ?[]const u8 = null;
        var buf: ?[]u8 = null;
        defer if (buf) |b| self.gpa.free(b);

        if (builtinDoc(word)) |doc| {
            value = doc;
        } else if (self.findDecl(params, word)) |d| {
            buf = try std.fmt.allocPrint(self.gpa, "{s} {s}", .{ declKindWord(d.kind), d.name });
            value = buf;
        }
        if (value) |v| {
            try self.respond(id, .{ .contents = .{ .kind = "plaintext", .value = v } });
        } else {
            try self.respond(id, @as(?u8, null));
        }
    }

    fn onDefinition(self: *Server, id: std.json.Value, params: ?std.json.Value) !void {
        const word = self.wordAtParams(params) orelse return self.respond(id, @as(?u8, null));
        const uri = self.uriOf(params) orelse return self.respond(id, @as(?u8, null));
        if (self.findDecl(params, word)) |d| {
            const loc = Location{
                .uri = uri,
                .range = .{
                    .start = .{ .line = d.line, .character = d.character },
                    .end = .{ .line = d.line, .character = d.character + @as(u32, @intCast(d.name.len)) },
                },
            };
            try self.respond(id, loc);
        } else {
            try self.respond(id, @as(?u8, null));
        }
    }

    fn onDocumentSymbol(self: *Server, id: std.json.Value, params: ?std.json.Value) !void {
        const uri = self.uriOf(params) orelse return self.respond(id, @as(?u8, null));
        const text = self.docs.get(uri) orelse return self.respond(id, @as(?u8, null));
        const decls = try scanDecls(self.gpa, text);
        defer self.gpa.free(decls);

        var syms: std.ArrayList(SymbolInformation) = .empty;
        defer syms.deinit(self.gpa);
        for (decls) |d| {
            try syms.append(self.gpa, .{
                .name = d.name,
                .kind = d.symbolKind(),
                .location = .{
                    .uri = uri,
                    .range = .{
                        .start = .{ .line = d.line, .character = d.character },
                        .end = .{ .line = d.line, .character = d.character + @as(u32, @intCast(d.name.len)) },
                    },
                },
            });
        }
        try self.respond(id, syms.items);
    }

    // --- request helpers ---

    fn uriOf(self: *Server, params: ?std.json.Value) ?[]const u8 {
        _ = self;
        const p = params orelse return null;
        const td = objGet(p, "textDocument") orelse return null;
        return strField(td, "uri");
    }

    /// The identifier under the request's position, using the stored document.
    fn wordAtParams(self: *Server, params: ?std.json.Value) ?[]const u8 {
        const p = params orelse return null;
        const uri = self.uriOf(params) orelse return null;
        const text = self.docs.get(uri) orelse return null;
        const pos = objGet(p, "position") orelse return null;
        const line = intField(pos, "line") orelse return null;
        const character = intField(pos, "character") orelse return null;
        const off = offsetAt(text, @intCast(line), @intCast(character)) orelse return null;
        return identAt(text, off);
    }

    /// The first declaration named `word` in the request's document.
    fn findDecl(self: *Server, params: ?std.json.Value, word: []const u8) ?Decl {
        const uri = self.uriOf(params) orelse return null;
        const text = self.docs.get(uri) orelse return null;
        const decls = scanDecls(self.gpa, text) catch return null;
        defer self.gpa.free(decls);
        for (decls) |d| {
            if (std.mem.eql(u8, d.name, word)) return d;
        }
        return null;
    }
};

// --- JSON navigation helpers -------------------------------------------------

fn objGet(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn strField(v: std.json.Value, key: []const u8) ?[]const u8 {
    const f = objGet(v, key) orelse return null;
    return if (f == .string) f.string else null;
}

fn intField(v: std.json.Value, key: []const u8) ?i64 {
    const f = objGet(v, key) orelse return null;
    return if (f == .integer) f.integer else null;
}

/// Map a front-end diagnostic (1-based line/col) to an LSP diagnostic (0-based),
/// extending the range over the identifier at that spot when there is one.
fn mapDiag(text: []const u8, d: lexer.Diagnostic) LspDiag {
    const line0: u32 = if (d.line > 0) d.line - 1 else 0;
    const char0: u32 = if (d.col > 0) d.col - 1 else 0;
    var end_char = char0 + 1;
    if (offsetAt(text, line0, char0)) |off| {
        if (identAt(text, off)) |word| end_char = char0 + @as(u32, @intCast(word.len));
    }
    return .{
        .range = .{
            .start = .{ .line = line0, .character = char0 },
            .end = .{ .line = line0, .character = end_char },
        },
        .message = d.message,
    };
}

// --- entry point -------------------------------------------------------------

pub fn run(gpa: std.mem.Allocator, io: Io, out: *Io.Writer) !u8 {
    var in_buf: [64 * 1024]u8 = undefined;
    var reader: Io.File.Reader = .init(.stdin(), io, &in_buf);

    var server = Server{ .gpa = gpa, .out = out, .in = &reader.interface };
    defer server.deinit();
    try server.run();
    return 0;
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;

test "scanDecls finds top-level and member declarations" {
    const src =
        \\const N = 3
        \\
        \\func add(a, b):
        \\    return a + b
        \\
        \\class Box:
        \\    var w = 0
        \\    func area() -> int:
        \\        return w
    ;
    const decls = try scanDecls(testing.allocator, src);
    defer testing.allocator.free(decls);
    try testing.expectEqual(@as(usize, 5), decls.len);
    try testing.expectEqualStrings("N", decls[0].name);
    try testing.expect(decls[0].kind == .const_);
    try testing.expectEqualStrings("add", decls[1].name);
    try testing.expect(decls[1].kind == .func);
    try testing.expectEqualStrings("Box", decls[2].name);
    try testing.expect(decls[2].kind == .class);
    try testing.expectEqualStrings("area", decls[4].name);
    try testing.expect(decls[4].kind == .func);
    try testing.expectEqual(@as(u32, 7), decls[4].line); // 0-based: the `func area` line
    try testing.expectEqualStrings("w", decls[3].name); // the class field
}

test "offsetAt and identAt locate the word under a cursor" {
    const src = "func add(a, b):\n    return a + b";
    // "add" starts at line 0, char 5.
    const off = offsetAt(src, 0, 6).?; // inside "add"
    try testing.expectEqualStrings("add", identAt(src, off).?);
    // "return" begins after the 4-space indent on line 1
    const off2 = offsetAt(src, 1, 6).?; // inside "return"
    try testing.expectEqualStrings("return", identAt(src, off2).?);
    // indentation whitespace (not adjacent to an identifier) has no word
    try testing.expect(identAt(src, offsetAt(src, 1, 0).?) == null);
}

test "builtinDoc returns docs for known builtins only" {
    try testing.expect(builtinDoc("map") != null);
    try testing.expect(builtinDoc("reduce") != null);
    try testing.expect(builtinDoc("not_a_builtin") == null);
}
