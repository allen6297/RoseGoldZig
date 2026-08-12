//! Aggregates every front-end unit test into one test target. Referencing each
//! module here pulls its `test` blocks into the compilation.

test {
    _ = @import("lexer.zig");
    _ = @import("parser.zig");
    _ = @import("analyzer.zig");
    _ = @import("interpreter.zig");
    _ = @import("loader.zig");
}
