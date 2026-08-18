//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

/// The bytecode VM, including the embedding surface (`Session`, host
/// functions, value marshalling, bytecode serialization) that a host program
/// like Strata uses. See docs/vm-api.md.
pub const vm = @import("fontend/vm.zig");

/// The parser. An embedder needs it to turn source into the `Module` that
/// `Session.load` compiles.
pub const parser = @import("fontend/parser.zig");

/// This is a documentation comment to explain the `printAnotherMessage` function below.
///
/// Accepting an `Io.Writer` instance is a handy way to write reusable code.
pub fn printAnotherMessage(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("Run `zig build test` to run the tests.\n", .{});
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}
