//! RoseGold CLI. Reads a `.rg` file and runs the full front end
//! (lex -> parse -> analyze -> interpret), reporting diagnostics with source
//! context. Usage:
//!
//!   rosegold [run|check] <file.rg>
//!
//!   run     parse, analyze, and execute (the default)
//!   check   parse and analyze only, then report any problems

const std = @import("std");
const Io = std.Io;
const Parser = @import("fontend/parser.zig");
const Loader = @import("fontend/loader.zig");
const Analyzer = @import("fontend/analyzer.zig");
const Interpreter = @import("fontend/interpreter.zig");

const usage =
    \\Usage: rosegold [run|check|repl] [<file.rg>]
    \\
    \\  run     parse, analyze, and execute the program (the default)
    \\  check   parse and analyze only, then report any problems
    \\  repl    start an interactive session (also the default with no file)
    \\
;

const Mode = enum { run, check };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var out_buf: [4096]u8 = undefined;
    var out_fw: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &out_fw.interface;

    var err_buf: [4096]u8 = undefined;
    var err_fw: Io.File.Writer = .init(.stderr(), io, &err_buf);
    const err = &err_fw.interface;

    const code: u8 = handle(arena, io, out, err, args) catch |e| blk: {
        err.print("error: {s}\n", .{@errorName(e)}) catch {};
        break :blk 1;
    };

    out.flush() catch {};
    err.flush() catch {};
    if (code != 0) std.process.exit(code);
}

fn handle(
    arena: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    err: *Io.Writer,
    args: []const [:0]const u8,
) !u8 {
    // With no arguments, or an explicit `repl`, start an interactive session.
    if (args.len <= 1 or std.mem.eql(u8, args[1], "repl")) {
        return repl(arena, io, out, err);
    }

    // Parse arguments: an optional subcommand followed by a file path.
    var mode: Mode = .run;
    var arg_index: usize = 1;
    if (std.mem.eql(u8, args[1], "run")) {
        mode = .run;
        arg_index = 2;
    } else if (std.mem.eql(u8, args[1], "check")) {
        mode = .check;
        arg_index = 2;
    }
    if (arg_index >= args.len) {
        try err.writeAll(usage);
        return 1;
    }
    const path = args[arg_index];

    // Load the entry file and everything it imports (lex + parse each), in
    // dependency order. Missing files, cycles, and parse errors surface here.
    const graph = try Loader.load(arena, io, path);
    if (graph.diagnostics.len > 0) {
        for (graph.diagnostics) |ld| {
            try render(err, "error", ld.path, ld.src, ld.diag.message, ld.diag.line, ld.diag.col);
        }
        try err.print("{d} error(s)\n", .{graph.diagnostics.len});
        return 1;
    }

    // Analyze every module in dependency order, giving each module the exports
    // of the modules it imports.
    const exports = try arena.alloc(*const Analyzer.ModuleExports, graph.units.len);
    var error_count: usize = 0;
    for (graph.units, 0..) |unit, i| {
        const imports = try arena.alloc(Analyzer.ModuleImport, unit.imports.len);
        for (unit.imports, 0..) |imp, j| {
            imports[j] = .{ .name = imp.name, .exports = exports[imp.module_index] };
        }
        const analysis = try Analyzer.analyzeModule(arena, unit.module, imports);
        exports[i] = analysis.exports;
        for (analysis.diagnostics) |d| {
            try render(err, "error", unit.path, unit.src, d.message, d.line, d.col);
        }
        error_count += analysis.diagnostics.len;
    }
    if (error_count > 0) {
        try err.print("{d} error(s)\n", .{error_count});
        return 1;
    }

    if (mode == .check) {
        try out.print("{s}: no problems found\n", .{path});
        return 0;
    }

    // Execute: hand the whole module set to the interpreter in dependency order.
    const modules = try arena.alloc(Interpreter.ProgramModule, graph.units.len);
    for (graph.units, 0..) |unit, i| {
        const imps = try arena.alloc(Interpreter.ModuleImport, unit.imports.len);
        for (unit.imports, 0..) |imp, j| {
            imps[j] = .{ .name = imp.name, .module_index = imp.module_index };
        }
        modules[i] = .{ .module = unit.module, .imports = imps };
    }
    const result = try Interpreter.runProgram(arena, modules);
    try out.writeAll(result.output);
    if (result.runtime_error) |re| {
        // Runtime errors carry a line/col but not their module; attribute them to
        // the entry file, which is correct for the common single-file case.
        const entry = graph.units[graph.units.len - 1];
        try render(err, "runtime error", entry.path, entry.src, re.message, re.line, re.col);
        return 1;
    }
    return 0;
}

// --- REPL --------------------------------------------------------------------

/// An interactive read-eval-print loop. Definitions and values persist across
/// entries. An entry spanning an indented block or unclosed brackets keeps
/// reading (a blank line ends an indented block).
fn repl(arena: std.mem.Allocator, io: Io, out: *Io.Writer, err: *Io.Writer) !u8 {
    const checker = try Analyzer.replCheckerInit(arena);
    const session = try Interpreter.replInit(arena);

    try out.writeAll("RoseGold REPL. Enter a definition or expression; a blank line ends a block; Ctrl-D exits.\n");

    var in_buf: [64 * 1024]u8 = undefined;
    var reader: Io.File.Reader = .init(.stdin(), io, &in_buf);
    const in = &reader.interface;

    var entry: std.ArrayList(u8) = .empty;
    var in_block = false;
    while (true) {
        try out.writeAll(if (in_block) "... " else "rg> ");
        try out.flush();

        const maybe_line = in.takeDelimiter('\n') catch |e| {
            try err.print("\ninput error: {s}\n", .{@errorName(e)});
            break;
        };
        const line = maybe_line orelse break; // EOF (Ctrl-D)

        try entry.appendSlice(arena, line);
        try entry.append(arena, '\n');

        // Keep reading while brackets are unbalanced, or an indented block is
        // open (a `:` line opens one; a blank line closes it).
        if (bracketDepth(entry.items) > 0) {
            in_block = true;
            continue;
        }
        const trimmed = std.mem.trimEnd(u8, line, " \t\r");
        if (trimmed.len > 0 and trimmed[trimmed.len - 1] == ':') {
            in_block = true;
            continue;
        }
        if (in_block and trimmed.len != 0) continue;
        in_block = false;

        if (std.mem.trim(u8, entry.items, " \t\r\n").len == 0) {
            entry.clearRetainingCapacity();
            continue;
        }
        // The parsed AST borrows its source, so give each entry its own copy that
        // outlives the reused scratch buffer (function values persist).
        const src = try arena.dupe(u8, entry.items);
        entry.clearRetainingCapacity();
        try runReplEntry(arena, out, err, checker, session, src);
    }
    try out.writeAll("\n");
    return 0;
}

fn runReplEntry(arena: std.mem.Allocator, out: *Io.Writer, err: *Io.Writer, checker: *Analyzer.ReplChecker, session: *Interpreter.Repl, src: []const u8) !void {
    // Never deinit the chunk: function values borrow its AST for the session.
    const chunk = try Parser.parseRepl(arena, src);
    if (chunk.diagnostics.len > 0) {
        for (chunk.diagnostics) |d| {
            try render(err, "error", "<repl>", src, d.message, d.line, d.col);
        }
        try err.flush();
        return;
    }
    // Type-check the entry; on a static error, report it and don't execute
    // (like `check`). Redefine the entry cleanly to continue.
    const diags = try checker.check(chunk.items);
    if (diags.len > 0) {
        for (diags) |d| {
            try render(err, "error", "<repl>", src, d.message, d.line, d.col);
        }
        try err.flush();
        return;
    }
    const outcome = try session.run(chunk.items);
    try out.writeAll(outcome.output);
    try out.flush();
    if (outcome.runtime_error) |re| {
        try render(err, "runtime error", "<repl>", src, re.message, re.line, re.col);
        try err.flush();
    }
}

/// Net count of open brackets in `s` (naive: ignores strings/comments, which is
/// good enough to decide whether a REPL entry needs another line).
fn bracketDepth(s: []const u8) i32 {
    var depth: i32 = 0;
    for (s) |c| switch (c) {
        '(', '[', '{' => depth += 1,
        ')', ']', '}' => depth -= 1,
        else => {},
    };
    return depth;
}

// --- diagnostic rendering ----------------------------------------------------

/// Render one diagnostic in the style:
///
///   error: <message>
///     --> <path>:<line>:<col>
///      |
///    N | <source line>
///      |     ^
fn render(
    w: *Io.Writer,
    label: []const u8,
    path: []const u8,
    src: []const u8,
    message: []const u8,
    line: u32,
    col: u32,
) !void {
    var num_buf: [20]u8 = undefined;
    const num = std.fmt.bufPrint(&num_buf, "{d}", .{line}) catch "?";

    try w.print("{s}: {s}\n", .{ label, message });
    try w.print("  --> {s}:{d}:{d}\n", .{ path, line, col });
    try writeSpaces(w, num.len);
    try w.writeAll(" |\n");
    try w.print("{s} | {s}\n", .{ num, lineText(src, line) });
    try writeSpaces(w, num.len);
    try w.writeAll(" | ");
    if (col > 0) try writeSpaces(w, col - 1);
    try w.writeAll("^\n\n");
}

fn writeSpaces(w: *Io.Writer, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) try w.writeByte(' ');
}

/// The 1-based `line`-th line of `src`, without its trailing newline (or CR).
fn lineText(src: []const u8, line: u32) []const u8 {
    var current: u32 = 1;
    var start: usize = 0;
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        if (src[i] == '\n') {
            if (current == line) return trimCr(src[start..i]);
            current += 1;
            start = i + 1;
        }
    }
    if (current == line) return trimCr(src[start..]);
    return "";
}

fn trimCr(s: []const u8) []const u8 {
    return if (s.len > 0 and s[s.len - 1] == '\r') s[0 .. s.len - 1] else s;
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    try std.testing.fuzz({}, testOne, .{});
}

fn testOne(context: void, smith: *std.testing.Smith) !void {
    _ = context;
    // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!

    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    while (!smith.eos()) switch (smith.value(enum { add_data, dup_data })) {
        .add_data => {
            const slice = try list.addManyAsSlice(gpa, smith.value(u4));
            smith.bytes(slice);
        },
        .dup_data => {
            if (list.items.len == 0) continue;
            if (list.items.len > std.math.maxInt(u32)) return error.SkipZigTest;
            const len = smith.valueRangeAtMost(u32, 1, @min(32, list.items.len));
            const off = smith.valueRangeAtMost(u32, 0, @intCast(list.items.len - len));
            try list.appendSlice(gpa, list.items[off..][0..len]);
            try std.testing.expectEqualSlices(
                u8,
                list.items[off..][0..len],
                list.items[list.items.len - len ..],
            );
        },
    };
}
