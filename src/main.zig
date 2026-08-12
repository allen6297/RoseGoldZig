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
const Analyzer = @import("fontend/analyzer.zig");
const Interpreter = @import("fontend/interpreter.zig");

const Diagnostic = @import("fontend/lexer.zig").Diagnostic;

const usage =
    \\Usage: rosegold [run|check] <file.rg>
    \\
    \\  run     parse, analyze, and execute the program (the default)
    \\  check   parse and analyze only, then report any problems
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
    // Parse arguments: an optional subcommand followed by a file path.
    var mode: Mode = .run;
    var arg_index: usize = 1;
    if (args.len > 1) {
        if (std.mem.eql(u8, args[1], "run")) {
            mode = .run;
            arg_index = 2;
        } else if (std.mem.eql(u8, args[1], "check")) {
            mode = .check;
            arg_index = 2;
        }
    }
    if (arg_index >= args.len) {
        try err.writeAll(usage);
        return 1;
    }
    const path = args[arg_index];

    const src = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 << 20)) catch |e| {
        try err.print("error: could not read '{s}': {s}\n", .{ path, @errorName(e) });
        return 1;
    };

    // Parse (which also lexes). Lexer + parser diagnostics come out together.
    const tree = try Parser.parse(arena, src);
    if (tree.diagnostics.len > 0) {
        try renderAll(err, path, src, tree.diagnostics);
        return 1;
    }

    // Analyze: name resolution and type checking.
    const analysis = try Analyzer.analyze(arena, tree.module);
    if (analysis.diagnostics.len > 0) {
        try renderAll(err, path, src, analysis.diagnostics);
        return 1;
    }

    if (mode == .check) {
        try out.print("{s}: no problems found\n", .{path});
        return 0;
    }

    // Execute.
    const result = try Interpreter.run(arena, tree.module);
    try out.writeAll(result.output);
    if (result.runtime_error) |re| {
        try render(err, "runtime error", path, src, re.message, re.line, re.col);
        return 1;
    }
    return 0;
}

// --- diagnostic rendering ----------------------------------------------------

fn renderAll(w: *Io.Writer, path: []const u8, src: []const u8, diagnostics: []const Diagnostic) !void {
    for (diagnostics) |d| {
        try render(w, "error", path, src, d.message, d.line, d.col);
    }
    try w.print("{d} error(s)\n", .{diagnostics.len});
}

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
