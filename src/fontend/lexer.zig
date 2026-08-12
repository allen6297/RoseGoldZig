//! RoseGold lexer.
//! Targets Zig 0.16.0.
//!
//! Layout rules implemented here:
//!   * INDENT is emitted only when the previous line's last significant token
//!     was `:`. This is what lets colon-blocks nest inside braced `for` bodies
//!     without the brace body itself producing a spurious INDENT.
//!   * DEDENT is emitted whenever indentation drops below the current level.
//!   * NEWLINE is suppressed inside `(` and `[` (line continuations) but stays
//!     significant inside `{`, so newline-separated brace bodies (enum members,
//!     match arms) keep their separators. INDENT/DEDENT are only produced at
//!     bracket depth 0, so brace bodies never indent.
//!   * `##` runs to end of line; `##/ ... /##` is a block comment. A lone `#`
//!     is an error (comments require `##`).

const std = @import("std");

pub const TokenKind = enum {
    // literals
    identifier,
    int_literal,
    float_literal,
    string_literal,

    // keywords
    kw_import,
    kw_class,
    kw_struct,
    kw_extends,
    kw_uses,
    kw_func,
    kw_var,
    kw_const,
    kw_enum,
    kw_if,
    kw_elif,
    kw_else,
    kw_match,
    kw_for,
    kw_in,
    kw_while,
    kw_break,
    kw_continue,
    kw_return,
    kw_pass,
    kw_nil,
    kw_pub,
    kw_private,
    kw_static,
    kw_true,
    kw_false,
    kw_and,
    kw_or,
    kw_not,
    kw_signal,

    // punctuation
    colon,
    comma,
    dot,
    arrow,
    arrow_equals,
    underscore,
    l_paren,
    r_paren,
    l_brace,
    r_brace,
    l_bracket,
    r_bracket,
    question,

    // operators
    plus,
    minus,
    star,
    slash,
    percent,
    assign,
    eq,
    bang_eq,
    lt,
    lt_eq,
    gt,
    gt_eq,

    // layout
    newline,
    indent,
    dedent,
    eof,

    invalid,
};

const keywords = std.StaticStringMap(TokenKind).initComptime(.{
    .{ "import", .kw_import },
    .{ "class", .kw_class },
    .{ "struct", .kw_struct },
    .{ "extends", .kw_extends },
    .{ "uses", .kw_uses },
    .{ "func", .kw_func },
    .{ "var", .kw_var },
    .{ "const", .kw_const },
    .{ "enum", .kw_enum },
    .{ "if", .kw_if },
    .{ "elif", .kw_elif },
    .{ "else", .kw_else },
    .{ "match", .kw_match },
    .{ "for", .kw_for },
    .{ "in", .kw_in },
    .{ "while", .kw_while },
    .{ "break", .kw_break },
    .{ "continue", .kw_continue },
    .{ "return", .kw_return },
    .{ "pass", .kw_pass },
    .{ "nil", .kw_nil },
    .{ "pub", .kw_pub },
    .{ "private", .kw_private },
    .{ "static", .kw_static },
    .{ "true", .kw_true },
    .{ "false", .kw_false },
    .{ "and", .kw_and },
    .{ "or", .kw_or },
    .{ "not", .kw_not },
    .{ "signal", .kw_signal },
});

/// Byte offsets plus line/col, threaded through every token so the parser and
/// analyzer can report errors without re-scanning the source.
pub const Span = struct {
    start: u32,
    end: u32,
    line: u32,
    col: u32,
};

pub const Token = struct {
    kind: TokenKind,
    span: Span,
    text: []const u8,
};

pub const Diagnostic = struct {
    message: []const u8,
    line: u32,
    col: u32,
};

pub const Result = struct {
    tokens: std.ArrayList(Token),
    diagnostics: std.ArrayList(Diagnostic),

    pub fn deinit(self: *Result, gpa: std.mem.Allocator) void {
        self.tokens.deinit(gpa);
        self.diagnostics.deinit(gpa);
    }
};

/// An open bracket awaiting its match, kept on the lexer's bracket stack. The
/// opener's location is recorded so an unclosed bracket can be reported where it
/// was opened rather than at EOF.
const OpenBracket = struct {
    opener: u8,
    line: u32,
    col: u32,
};

pub const Lexer = struct {
    gpa: std.mem.Allocator,
    src: []const u8,
    pos: u32 = 0,
    line: u32 = 1,
    line_start: u32 = 0,

    indents: std.ArrayList(u32) = .empty,
    /// Stack of the brackets currently open ('(', '[', '{'). Its depth gates
    /// layout (INDENT/DEDENT only at depth 0), its top decides NEWLINE handling
    /// (see `newlineSuppressed`), and any entries left at EOF are reported as
    /// unclosed brackets.
    brackets: std.ArrayList(OpenBracket) = .empty,
    last_significant: ?TokenKind = null,
    line_has_token: bool = false,

    tokens: std.ArrayList(Token) = .empty,
    diagnostics: std.ArrayList(Diagnostic) = .empty,

    fn col(self: *Lexer) u32 {
        return self.pos - self.line_start + 1;
    }

    fn peek(self: *Lexer) u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else 0;
    }

    fn peekAt(self: *Lexer, offset: u32) u8 {
        const i = self.pos + offset;
        return if (i < self.src.len) self.src[i] else 0;
    }

    fn atEnd(self: *Lexer) bool {
        return self.pos >= self.src.len;
    }

    fn pushBracket(self: *Lexer, opener: u8, opener_col: u32) !void {
        try self.brackets.append(self.gpa, .{
            .opener = opener,
            .line = self.line,
            .col = opener_col,
        });
    }

    fn popBracket(self: *Lexer) void {
        if (self.brackets.items.len > 0) _ = self.brackets.pop();
    }

    fn bracketDepth(self: *Lexer) usize {
        return self.brackets.items.len;
    }

    /// Newlines are line continuations inside `(`/`[`, but real separators
    /// inside `{` (and at top level), so brace bodies keep their item breaks.
    fn newlineSuppressed(self: *Lexer) bool {
        if (self.brackets.items.len == 0) return false;
        const opener = self.brackets.items[self.brackets.items.len - 1].opener;
        return opener == '(' or opener == '[';
    }

    fn err(self: *Lexer, message: []const u8) !void {
        try self.diagnostics.append(self.gpa, .{
            .message = message,
            .line = self.line,
            .col = self.col(),
        });
    }

    fn emit(self: *Lexer, kind: TokenKind, start: u32, start_col: u32) !void {
        try self.tokens.append(self.gpa, .{
            .kind = kind,
            .span = .{
                .start = start,
                .end = self.pos,
                .line = self.line,
                .col = start_col,
            },
            .text = self.src[start..self.pos],
        });
        if (kind != .newline and kind != .indent and kind != .dedent) {
            self.last_significant = kind;
            self.line_has_token = true;
        }
    }

    /// Emit a zero-width layout token (INDENT / DEDENT / NEWLINE at EOF).
    fn emitLayout(self: *Lexer, kind: TokenKind) !void {
        try self.tokens.append(self.gpa, .{
            .kind = kind,
            .span = .{
                .start = self.pos,
                .end = self.pos,
                .line = self.line,
                .col = self.col(),
            },
            .text = "",
        });
    }

    fn currentIndent(self: *Lexer) u32 {
        return self.indents.items[self.indents.items.len - 1];
    }

    /// Consume leading whitespace on a fresh line and emit INDENT / DEDENT.
    /// Blank lines and comment-only lines produce no layout tokens at all.
    fn handleLineStart(self: *Lexer) !void {
        var width: u32 = 0;
        var reported_tab = false;
        while (!self.atEnd()) {
            switch (self.peek()) {
                ' ' => {
                    width += 1;
                    self.pos += 1;
                },
                '\t' => {
                    // Tabs are disallowed, but recover by counting each as one
                    // column so the block still registers as indented (avoiding a
                    // bogus "expected an indented block" on the next check), and
                    // report only once per line instead of once per tab.
                    if (!reported_tab) {
                        try self.err("tabs are not allowed for indentation; use spaces");
                        reported_tab = true;
                    }
                    width += 1;
                    self.pos += 1;
                },
                else => break,
            }
        }

        // Blank line, or a line containing only a comment: no layout change.
        if (self.atEnd()) return;
        if (self.peek() == '\n' or self.peek() == '\r') return;
        if (self.peek() == '#') return;

        if (self.last_significant == .colon) {
            if (width > self.currentIndent()) {
                try self.indents.append(self.gpa, width);
                try self.emitLayout(.indent);
            } else {
                try self.err("expected an indented block after ':'");
            }
            return;
        }

        while (width < self.currentIndent()) {
            _ = self.indents.pop();
            try self.emitLayout(.dedent);
        }

        if (width > self.currentIndent()) {
            try self.err("unexpected indentation");
            try self.indents.append(self.gpa, width);
        }
    }

    fn skipBlockComment(self: *Lexer) !void {
        const open_line = self.line;
        self.pos += 3; // consume "##/"
        while (!self.atEnd()) {
            if (self.peek() == '/' and self.peekAt(1) == '#' and self.peekAt(2) == '#') {
                self.pos += 3;
                return;
            }
            if (self.peek() == '\n') {
                self.line += 1;
                self.pos += 1;
                self.line_start = self.pos;
            } else {
                self.pos += 1;
            }
        }
        try self.diagnostics.append(self.gpa, .{
            .message = "unterminated block comment",
            .line = open_line,
            .col = 1,
        });
    }

    fn skipLineComment(self: *Lexer) void {
        while (!self.atEnd() and self.peek() != '\n') self.pos += 1;
    }

    fn lexNumber(self: *Lexer) !void {
        const start = self.pos;
        const start_col = self.col();
        while (std.ascii.isDigit(self.peek())) self.pos += 1;

        // A '.' is only part of the number if a digit follows, so `1.foo`
        // still lexes as int, dot, identifier.
        if (self.peek() == '.' and std.ascii.isDigit(self.peekAt(1))) {
            self.pos += 1;
            while (std.ascii.isDigit(self.peek())) self.pos += 1;
            try self.emit(.float_literal, start, start_col);
            return;
        }
        try self.emit(.int_literal, start, start_col);
    }

    fn lexString(self: *Lexer) !void {
        const start = self.pos;
        const start_col = self.col();
        self.pos += 1; // opening quote

        while (!self.atEnd() and self.peek() != '"') {
            if (self.peek() == '\\') {
                self.pos += 1;
                if (!self.atEnd()) self.pos += 1;
                continue;
            }
            if (self.peek() == '\n') {
                try self.err("unterminated string literal");
                try self.emit(.invalid, start, start_col);
                return;
            }
            self.pos += 1;
        }

        if (self.atEnd()) {
            try self.err("unterminated string literal");
            try self.emit(.invalid, start, start_col);
            return;
        }

        self.pos += 1; // closing quote
        try self.emit(.string_literal, start, start_col);
    }

    fn lexIdentifier(self: *Lexer) !void {
        const start = self.pos;
        const start_col = self.col();
        while (std.ascii.isAlphanumeric(self.peek()) or self.peek() == '_') {
            self.pos += 1;
        }
        const text = self.src[start..self.pos];

        if (std.mem.eql(u8, text, "_")) {
            try self.emit(.underscore, start, start_col);
            return;
        }
        try self.emit(keywords.get(text) orelse .identifier, start, start_col);
    }

    fn lexOperator(self: *Lexer) !void {
        const start = self.pos;
        const start_col = self.col();
        const c = self.peek();
        self.pos += 1;

        const kind: TokenKind = switch (c) {
            ':' => .colon,
            ',' => .comma,
            '.' => .dot,
            '?' => .question,
            '+' => .plus,
            '*' => .star,
            '/' => .slash,
            '%' => .percent,
            '(' => blk: {
                try self.pushBracket('(', start_col);
                break :blk .l_paren;
            },
            ')' => blk: {
                self.popBracket();
                break :blk .r_paren;
            },
            '[' => blk: {
                try self.pushBracket('[', start_col);
                break :blk .l_bracket;
            },
            ']' => blk: {
                self.popBracket();
                break :blk .r_bracket;
            },
            '{' => blk: {
                try self.pushBracket('{', start_col);
                break :blk .l_brace;
            },
            '}' => blk: {
                self.popBracket();
                break :blk .r_brace;
            },
            '-' => blk: {
                if (self.peek() == '>') {
                    self.pos += 1;
                    break :blk .arrow;
                }
                break :blk .minus;
            },
            '=' => blk: {
                if (self.peek() == '=') {
                    self.pos += 1;
                    break :blk .eq;
                }
                if (self.peek() == '>') {
                    self.pos += 1;
                    break :blk .arrow_equals;
                }
                break :blk .assign;
            },
            '!' => blk: {
                if (self.peek() == '=') {
                    self.pos += 1;
                    break :blk .bang_eq;
                }
                break :blk .invalid;
            },
            '<' => blk: {
                if (self.peek() == '=') {
                    self.pos += 1;
                    break :blk .lt_eq;
                }
                break :blk .lt;
            },
            '>' => blk: {
                if (self.peek() == '=') {
                    self.pos += 1;
                    break :blk .gt_eq;
                }
                break :blk .gt;
            },
            else => blk: {
                try self.err("unexpected character");
                break :blk .invalid;
            },
        };

        try self.emit(kind, start, start_col);
    }

    pub fn run(self: *Lexer) !Result {
        try self.indents.append(self.gpa, 0);

        var fresh_line = true;
        while (!self.atEnd()) {
            // Layout is only processed at the true start of a physical line that
            // sits at bracket depth 0. The `pos == line_start` guard matters when a
            // multi-line `(`/`[`/`{` closes mid-line (e.g. `]` followed by more
            // tokens on the same line): `fresh_line` is still set from the
            // suppressed newline, but we are no longer at the line start and must
            // not re-run indentation for what is really a line continuation.
            if (fresh_line and self.bracketDepth() == 0 and self.pos == self.line_start) {
                try self.handleLineStart();
                fresh_line = false;
                if (self.atEnd()) break;
            }

            const c = self.peek();
            switch (c) {
                ' ', '\r', '\t' => self.pos += 1,

                '\n' => {
                    const start = self.pos;
                    const start_col = self.col();
                    self.pos += 1;
                    // `line_has_token` suppresses NEWLINE on blank / comment-only
                    // lines; `newlineSuppressed` suppresses it inside `(`/`[`.
                    // `last_significant` is deliberately left intact so the next
                    // line's handleLineStart can still see a trailing `:` and open
                    // an indented block.
                    if (!self.newlineSuppressed() and self.line_has_token) {
                        try self.emit(.newline, start, start_col);
                    }
                    self.line_has_token = false;
                    self.line += 1;
                    self.line_start = self.pos;
                    fresh_line = true;
                },

                '#' => {
                    if (self.peekAt(1) == '#') {
                        if (self.peekAt(2) == '/') {
                            try self.skipBlockComment();
                        } else {
                            self.skipLineComment();
                        }
                    } else {
                        // A lone '#' is not a comment (comments start with '##').
                        // Flag it once and skip the rest of the line to recover,
                        // treating it as the malformed comment it most likely is.
                        try self.err("unexpected '#'; comments start with '##'");
                        self.skipLineComment();
                    }
                },

                '"' => try self.lexString(),

                else => {
                    if (std.ascii.isDigit(c)) {
                        try self.lexNumber();
                    } else if (std.ascii.isAlphabetic(c) or c == '_') {
                        try self.lexIdentifier();
                    } else {
                        try self.lexOperator();
                    }
                },
            }
        }

        // Anything still on the bracket stack was never closed. Report each at
        // the location it was opened (outermost first, i.e. source order).
        for (self.brackets.items) |open| {
            const message = switch (open.opener) {
                '(' => "unclosed '('",
                '[' => "unclosed '['",
                '{' => "unclosed '{'",
                else => "unclosed bracket",
            };
            try self.diagnostics.append(self.gpa, .{
                .message = message,
                .line = open.line,
                .col = open.col,
            });
        }

        // A source that does not end in a newline still needs its final logical
        // line terminated. Synthesize one, using the same rule as a real newline:
        // skip it inside a `(`/`[` continuation or when the last line was blank,
        // so a newline-terminated file is not given a doubled NEWLINE.
        if (!self.newlineSuppressed() and self.line_has_token) {
            try self.emitLayout(.newline);
        }

        // Close any open blocks, then EOF.
        while (self.indents.items.len > 1) {
            _ = self.indents.pop();
            try self.emitLayout(.dedent);
        }
        try self.emitLayout(.eof);

        self.indents.deinit(self.gpa);
        self.brackets.deinit(self.gpa);
        return .{ .tokens = self.tokens, .diagnostics = self.diagnostics };
    }
};

pub fn tokenize(gpa: std.mem.Allocator, src: []const u8) !Result {
    var lexer = Lexer{ .gpa = gpa, .src = src };
    return lexer.run();
}

// ---------------------------------------------------------------------------

const sample =
\\import graphics
\\
\\const VERSION: str = "0.1"
\\
\\enum Status {
\\    OK
\\    NOT_FOUND
\\}
\\
\\##/
\\Describes an HTTP status code.
\\/##
\\pub func describe(code: int) -> str:
\\    ## match is an expression
\\    return match code {
\\        200: "ok"
\\        404: "not found"
\\        _: "unknown"
\\    }
\\
\\pub class Player extends Entity uses Damageable:
\\    var health: int = 100
\\
\\    pub func take_damage(amount: int) -> bool:
\\        for effect in active_effects {
\\            effect.tick()
\\        }
\\        if health <= 0:
\\            return true
\\        else:
\\            return false
\\
;

pub fn main() !void {
    const gpa = std.heap.page_allocator;

    var result = try tokenize(gpa, sample);
    defer result.deinit(gpa);

    for (result.tokens.items) |tok| {
        if (tok.text.len == 0) {
            std.debug.print("{d:>3}:{d:<3} {s}\n", .{ tok.span.line, tok.span.col, @tagName(tok.kind) });
        } else {
            std.debug.print("{d:>3}:{d:<3} {s:<16} {s}\n", .{ tok.span.line, tok.span.col, @tagName(tok.kind), tok.text });
        }
    }

    for (result.diagnostics.items) |d| {
        std.debug.print("error {d}:{d}: {s}\n", .{ d.line, d.col, d.message });
    }
}

test "keywords and identifiers" {
    const gpa = std.testing.allocator;
    var result = try tokenize(gpa, "var health: int = 100\n");
    defer result.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.len);
    try std.testing.expectEqual(TokenKind.kw_var, result.tokens.items[0].kind);
    try std.testing.expectEqual(TokenKind.identifier, result.tokens.items[1].kind);
    try std.testing.expectEqual(TokenKind.colon, result.tokens.items[2].kind);
}

test "colon opens an indented block" {
    const gpa = std.testing.allocator;
    var result = try tokenize(gpa, "if x:\n    pass\n");
    defer result.deinit(gpa);

    var saw_indent = false;
    var saw_dedent = false;
    for (result.tokens.items) |tok| {
        if (tok.kind == .indent) saw_indent = true;
        if (tok.kind == .dedent) saw_dedent = true;
    }
    try std.testing.expect(saw_indent);
    try std.testing.expect(saw_dedent);
}

test "colon block emits exact indent/dedent sequence" {
    const gpa = std.testing.allocator;
    // if x:
    //     a
    //     b
    // c
    var result = try tokenize(gpa, "if x:\n    a\n    b\nc\n");
    defer result.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.len);

    const expected = [_]TokenKind{
        .kw_if,      .identifier, .colon,   .newline,
        .indent,     .identifier, .newline, .identifier,
        .newline,    .dedent,     .identifier,
        .newline,    .eof,
    };
    try std.testing.expectEqual(expected.len, result.tokens.items.len);
    for (expected, result.tokens.items) |kind, tok| {
        try std.testing.expectEqual(kind, tok.kind);
    }
}

test "nested colon blocks indent and dedent to baseline" {
    const gpa = std.testing.allocator;
    // if a:
    //     if b:
    //         x
    var result = try tokenize(gpa, "if a:\n    if b:\n        x\n");
    defer result.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.len);

    var indents: usize = 0;
    var dedents: usize = 0;
    for (result.tokens.items) |tok| {
        if (tok.kind == .indent) indents += 1;
        if (tok.kind == .dedent) dedents += 1;
    }
    // Two blocks open, and both must close by EOF.
    try std.testing.expectEqual(@as(usize, 2), indents);
    try std.testing.expectEqual(@as(usize, 2), dedents);
}

test "braced body produces no indent" {
    const gpa = std.testing.allocator;
    var result = try tokenize(gpa, "for x in y {\n    tick()\n}\n");
    defer result.deinit(gpa);

    for (result.tokens.items) |tok| {
        try std.testing.expect(tok.kind != .indent);
    }
}

test "brace body keeps newlines as separators" {
    const gpa = std.testing.allocator;
    // enum E {
    //     A
    //     B
    // }
    var result = try tokenize(gpa, "enum E {\n    A\n    B\n}\n");
    defer result.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.len);

    const expected = [_]TokenKind{
        .kw_enum,    .identifier, .l_brace, .newline,
        .identifier, .newline,    .identifier, .newline,
        .r_brace,    .newline,    .eof,
    };
    try std.testing.expectEqual(expected.len, result.tokens.items.len);
    for (expected, result.tokens.items) |kind, tok| {
        try std.testing.expectEqual(kind, tok.kind);
    }
    // A brace body must not produce layout tokens.
    for (result.tokens.items) |tok| {
        try std.testing.expect(tok.kind != .indent and tok.kind != .dedent);
    }
}

test "paren body suppresses newlines" {
    const gpa = std.testing.allocator;
    // foo(
    //     a
    //     b
    // )
    var result = try tokenize(gpa, "foo(\n    a\n    b\n)\n");
    defer result.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.len);

    const expected = [_]TokenKind{
        .identifier, .l_paren, .identifier, .identifier,
        .r_paren,    .newline, .eof,
    };
    try std.testing.expectEqual(expected.len, result.tokens.items.len);
    for (expected, result.tokens.items) |kind, tok| {
        try std.testing.expectEqual(kind, tok.kind);
    }
}

test "innermost bracket decides newline handling" {
    const gpa = std.testing.allocator;
    // The `{` is nested inside a `(`, but the innermost bracket wins: newlines
    // inside the braces stay significant. A newline directly after `{` is a
    // redundant leading separator (the parser skips it), just like the ones
    // after each item.
    var result = try tokenize(gpa, "f({\n    a\n    b\n})\n");
    defer result.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.len);

    const expected = [_]TokenKind{
        .identifier, .l_paren,  .l_brace, .newline,
        .identifier, .newline,  .identifier, .newline,
        .r_brace,    .r_paren,  .newline, .eof,
    };
    try std.testing.expectEqual(expected.len, result.tokens.items.len);
    for (expected, result.tokens.items) |kind, tok| {
        try std.testing.expectEqual(kind, tok.kind);
    }
}

test "bracket closing mid-line does not trigger layout" {
    const gpa = std.testing.allocator;
    // The `]` closes the multi-line list and `+ y` continues the same logical
    // line. Layout must not run for that continuation — before the guard, the
    // ` + y` after `]` was mis-read as indentation.
    var result = try tokenize(gpa, "x = [\n    1\n] + y\n");
    defer result.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.len);

    const expected = [_]TokenKind{
        .identifier, .assign, .l_bracket, .int_literal,
        .r_bracket,  .plus,   .identifier, .newline,
        .eof,
    };
    try std.testing.expectEqual(expected.len, result.tokens.items.len);
    for (expected, result.tokens.items) |kind, tok| {
        try std.testing.expectEqual(kind, tok.kind);
    }
    // No layout tokens at all: it is one continued logical line.
    for (result.tokens.items) |tok| {
        try std.testing.expect(tok.kind != .indent and tok.kind != .dedent);
    }
}

test "block comment spans lines" {
    const gpa = std.testing.allocator;
    var result = try tokenize(gpa, "##/\nhidden\n/##\nvar x = 1\n");
    defer result.deinit(gpa);

    try std.testing.expectEqual(TokenKind.kw_var, result.tokens.items[0].kind);
}

test "file without trailing newline is still terminated" {
    const gpa = std.testing.allocator;
    var result = try tokenize(gpa, "var x = 1");
    defer result.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.len);

    const expected = [_]TokenKind{
        .kw_var, .identifier, .assign, .int_literal, .newline, .eof,
    };
    try std.testing.expectEqual(expected.len, result.tokens.items.len);
    for (expected, result.tokens.items) |kind, tok| {
        try std.testing.expectEqual(kind, tok.kind);
    }
}

test "trailing newline is not doubled" {
    const gpa = std.testing.allocator;
    var result = try tokenize(gpa, "var x = 1\n");
    defer result.deinit(gpa);

    var newlines: usize = 0;
    for (result.tokens.items) |tok| {
        if (tok.kind == .newline) newlines += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), newlines);
}

test "unterminated block closes with newline then dedent at eof" {
    const gpa = std.testing.allocator;
    // No trailing newline: the final line is terminated, then the open block
    // is closed, before EOF.
    var result = try tokenize(gpa, "if x:\n    pass");
    defer result.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.len);

    const expected = [_]TokenKind{
        .kw_if,  .identifier, .colon,   .newline,
        .indent, .kw_pass,    .newline, .dedent,
        .eof,
    };
    try std.testing.expectEqual(expected.len, result.tokens.items.len);
    for (expected, result.tokens.items) |kind, tok| {
        try std.testing.expectEqual(kind, tok.kind);
    }
}

test "unclosed bracket is diagnosed at the opener" {
    const gpa = std.testing.allocator;
    // foo(  <- '(' opens at line 1, col 4, and is never closed.
    var result = try tokenize(gpa, "foo(\n    a\n");
    defer result.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), result.diagnostics.items.len);
    const d = result.diagnostics.items[0];
    try std.testing.expectEqual(@as(u32, 1), d.line);
    try std.testing.expectEqual(@as(u32, 4), d.col);
}

test "each unclosed bracket is diagnosed" {
    const gpa = std.testing.allocator;
    var result = try tokenize(gpa, "a([\n");
    defer result.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), result.diagnostics.items.len);
    // Reported outermost first: '(' at col 2, then '[' at col 3.
    try std.testing.expectEqual(@as(u32, 2), result.diagnostics.items[0].col);
    try std.testing.expectEqual(@as(u32, 3), result.diagnostics.items[1].col);
}

test "balanced brackets produce no diagnostic" {
    const gpa = std.testing.allocator;
    var result = try tokenize(gpa, "f([1], {2})\n");
    defer result.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.len);
}

test "tabs in indentation report once per line" {
    const gpa = std.testing.allocator;
    // Three tabs after a colon: a single tab diagnostic (not one per tab).
    var result = try tokenize(gpa, "if x:\n\t\t\tpass\n");
    defer result.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), result.diagnostics.items.len);
    try std.testing.expectEqualStrings(
        "tabs are not allowed for indentation; use spaces",
        result.diagnostics.items[0].message,
    );
    try std.testing.expectEqual(@as(u32, 2), result.diagnostics.items[0].line);
    try std.testing.expectEqual(@as(u32, 1), result.diagnostics.items[0].col);
}

test "single tab after colon opens a block without cascade" {
    const gpa = std.testing.allocator;
    var result = try tokenize(gpa, "if x:\n\tpass\n");
    defer result.deinit(gpa);

    // Only the tab diagnostic — the tab counts as width, so there is no spurious
    // "expected an indented block after ':'".
    try std.testing.expectEqual(@as(usize, 1), result.diagnostics.items.len);

    var saw_indent = false;
    var saw_dedent = false;
    for (result.tokens.items) |tok| {
        if (tok.kind == .indent) saw_indent = true;
        if (tok.kind == .dedent) saw_dedent = true;
    }
    try std.testing.expect(saw_indent);
    try std.testing.expect(saw_dedent);
}

test "lone hash is flagged and the line recovers" {
    const gpa = std.testing.allocator;
    var result = try tokenize(gpa, "x = 1 # oops\n");
    defer result.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), result.diagnostics.items.len);
    try std.testing.expectEqualStrings(
        "unexpected '#'; comments start with '##'",
        result.diagnostics.items[0].message,
    );
    try std.testing.expectEqual(@as(u32, 7), result.diagnostics.items[0].col);

    // The rest of the line is skipped, so no stray tokens leak from `# oops`.
    const expected = [_]TokenKind{
        .identifier, .assign, .int_literal, .newline, .eof,
    };
    try std.testing.expectEqual(expected.len, result.tokens.items.len);
    for (expected, result.tokens.items) |kind, tok| {
        try std.testing.expectEqual(kind, tok.kind);
    }
}

test "double hash is a valid line comment" {
    const gpa = std.testing.allocator;
    var result = try tokenize(gpa, "x = 1 ## fine\n");
    defer result.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.len);
    const expected = [_]TokenKind{
        .identifier, .assign, .int_literal, .newline, .eof,
    };
    try std.testing.expectEqual(expected.len, result.tokens.items.len);
    for (expected, result.tokens.items) |kind, tok| {
        try std.testing.expectEqual(kind, tok.kind);
    }
}

test "logical keywords lex as keywords" {
    const gpa = std.testing.allocator;
    var result = try tokenize(gpa, "a and b or not c\n");
    defer result.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.len);
    const expected = [_]TokenKind{
        .identifier, .kw_and, .identifier, .kw_or,
        .kw_not,     .identifier, .newline, .eof,
    };
    try std.testing.expectEqual(expected.len, result.tokens.items.len);
    for (expected, result.tokens.items) |kind, tok| {
        try std.testing.expectEqual(kind, tok.kind);
    }
}

test "nil keyword and ? token" {
    const gpa = std.testing.allocator;
    var result = try tokenize(gpa, "var x: ?int = nil\n");
    defer result.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.len);
    const kinds = [_]TokenKind{ .kw_var, .identifier, .colon, .question, .identifier, .assign, .kw_nil, .newline, .eof };
    try std.testing.expectEqual(kinds.len, result.tokens.items.len);
    for (kinds, result.tokens.items) |k, tok| try std.testing.expectEqual(k, tok.kind);
}

test "break and continue are keywords" {
    const gpa = std.testing.allocator;
    var result = try tokenize(gpa, "break\ncontinue\n");
    defer result.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.len);
    try std.testing.expectEqual(TokenKind.kw_break, result.tokens.items[0].kind);
    try std.testing.expectEqual(TokenKind.kw_continue, result.tokens.items[2].kind);
}

test "signal is a keyword" {
    const gpa = std.testing.allocator;
    var result = try tokenize(gpa, "signal health_changed\n");
    defer result.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.len);
    try std.testing.expectEqual(TokenKind.kw_signal, result.tokens.items[0].kind);
    try std.testing.expectEqual(TokenKind.identifier, result.tokens.items[1].kind);
}

test "struct is a keyword" {
    const gpa = std.testing.allocator;
    var result = try tokenize(gpa, "struct Point\n");
    defer result.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.len);
    try std.testing.expectEqual(TokenKind.kw_struct, result.tokens.items[0].kind);
    try std.testing.expectEqual(TokenKind.identifier, result.tokens.items[1].kind);
}

test "empty source is just eof" {
    const gpa = std.testing.allocator;
    var result = try tokenize(gpa, "");
    defer result.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.len);
    try std.testing.expectEqual(@as(usize, 1), result.tokens.items.len);
    try std.testing.expectEqual(TokenKind.eof, result.tokens.items[0].kind);
}