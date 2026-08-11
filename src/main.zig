const std = @import("std");
const Io = std.Io;
const Lexer = @import("fontend/lexer.zig");
const Parser = @import("fontend/parser.zig");
const Analyzer = @import("fontend/analyzer.zig");

const RoseGold_Zig = @import("RoseGold_Zig");

pub fn main(init: std.process.Init) !void {
    // Prints to stderr, unbuffered, ignoring potential errors.
    //std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    // This is appropriate for anything that lives as long as the process.
    const arena: std.mem.Allocator = init.arena.allocator();

    // Accessing command line arguments:
    const args = try init.minimal.args.toSlice(arena);
    for (args) |arg| {
        std.log.info("arg: {s}", .{arg});
    }

    // In order to do I/O operations need an `Io` instance.
    const io = init.io;

    try Lexer.main();
    // Stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    try RoseGold_Zig.printAnotherMessage(stdout_writer);

    try parserDemo(arena, stdout_writer);
    try analyzerDemo(arena, stdout_writer);

    try stdout_writer.flush(); // Don't forget to flush!
}

/// Runs the semantic analyzer over a small program with two deliberate mistakes
/// — a type mismatch and an undefined reference — to show name resolution and
/// type checking catching them.
fn analyzerDemo(gpa: std.mem.Allocator, out: *Io.Writer) !void {
    var tree = try Parser.parse(gpa, analyzer_demo_source);
    defer tree.deinit();
    var analysis = try Analyzer.analyze(gpa, tree.module);
    defer analysis.deinit();

    try out.print("\n== analyzer demo ==\n", .{});
    try out.print("diagnostics: {d}\n", .{analysis.diagnostics.len});
    for (analysis.diagnostics) |diag| {
        try out.print("  {d}:{d} {s}\n", .{ diag.line, diag.col, diag.message });
    }
}

const analyzer_demo_source =
    \\const LIMIT: int = 10
    \\
    \\pub func clamp(value: int) -> int:
    \\    if value > LIMIT:
    \\        return "too big"
    \\    return valve
;

/// A small program exercising the whole front end: it lexes and parses
/// `demo_source`, then prints a summary of the top-level declarations and any
/// diagnostics.
fn parserDemo(gpa: std.mem.Allocator, out: *Io.Writer) !void {
    var tree = try Parser.parse(gpa, demo_source);
    defer tree.deinit();

    try out.print("\n== parser demo ==\n", .{});
    try out.print("module: {d} declaration(s)\n", .{tree.module.decls.len});
    for (tree.module.decls) |decl| {
        const kind = @tagName(std.meta.activeTag(decl));
        switch (decl) {
            .import => |x| try out.print("  {s:<10} {s}\n", .{ kind, x.name }),
            .var_decl => |x| try out.print("  {s:<10} {s}\n", .{ kind, x.name }),
            .func => |x| try out.print("  {s:<10} {s} ({d} param(s))\n", .{ kind, x.name, x.params.len }),
            .class => |x| try out.print("  {s:<10} {s} ({d} member(s))\n", .{ kind, x.name, x.members.len }),
            .enum_decl => |x| try out.print("  {s:<10} {s} ({d} member(s))\n", .{ kind, x.name, x.members.len }),
        }
    }

    try out.print("diagnostics: {d}\n", .{tree.diagnostics.len});
    for (tree.diagnostics) |diag| {
        try out.print("  {d}:{d} {s}\n", .{ diag.line, diag.col, diag.message });
    }
}

const demo_source =
    \\import graphics
    \\
    \\const VERSION: str = "0.1"
    \\
    \\enum Status {
    \\    OK
    \\    NOT_FOUND
    \\}
    \\
    \\pub func describe(code: int) -> str:
    \\    return match code {
    \\        200: "ok"
    \\        _: "unknown"
    \\    }
    \\
    \\pub class Player extends Entity uses Damageable:
    \\    var health: int = 100
    \\
    \\    pub func take_damage(amount: int) -> bool:
    \\        if health <= 0:
    \\            return true
    \\        else:
    \\            return false
;

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
