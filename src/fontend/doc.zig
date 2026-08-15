//! `rosegold doc`: generate Markdown API documentation from a source file's
//! `##` doc comments. For each top-level declaration (and each `pub` member of a
//! class/struct) it emits the canonical signature — via `formatter.signature`,
//! so types/defaults render exactly as `fmt` would — followed by the `##` comment
//! block written directly above it. The leading comment block at the top of the
//! file (when it doesn't abut the first declaration) becomes the module preamble.
//!
//! Pure over the parse tree; the CLI (`main.zig`) reads the file, parses it, and
//! writes the result to stdout.

const std = @import("std");
const parser = @import("parser.zig");
const lexer = @import("lexer.zig");
const formatter = @import("formatter.zig");

const Decl = parser.Decl;
const Comment = lexer.Comment;
const Error = std.mem.Allocator.Error;

/// Render Markdown for `module`. `title` heads the document (usually the module /
/// file name). `comments` are the parse tree's `##` comments, in source order.
pub fn generate(gpa: std.mem.Allocator, title: []const u8, module: parser.Module, comments: []const Comment) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.print(gpa, "# {s}\n\n", .{title});

    // A module preamble: the comment run at the very top of the file, unless it
    // serves as the first declaration's own doc block (i.e. abuts it).
    if (comments.len > 0) {
        const top = runStartingAt(comments, 0);
        const first_doc: ?[]const Comment = if (module.decls.len > 0) docRunBefore(comments, declLine(module.decls[0])) else null;
        const is_first_doc = first_doc != null and first_doc.?.len > 0 and first_doc.?.ptr == comments.ptr;
        if (!is_first_doc) try emitDoc(gpa, &out, top);
    }

    for (module.decls) |d| {
        if (d == .import) continue;
        try emitDecl(gpa, &out, d, comments, 2);
        // A class/struct documents its members one heading level deeper.
        const members: []const Decl = switch (d) {
            .class => |c| c.members,
            .struct_decl => |s| s.members,
            else => &.{},
        };
        for (members) |m| {
            if (m == .var_decl or m == .func) try emitDecl(gpa, &out, m, comments, 3);
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Emit one declaration: a `level`-deep heading holding its canonical signature,
/// then its doc-comment block (if any).
fn emitDecl(gpa: std.mem.Allocator, out: *std.ArrayList(u8), d: Decl, comments: []const Comment, level: u8) Error!void {
    const sig = try formatter.signature(gpa, d);
    defer gpa.free(sig);
    var h: usize = 0;
    while (h < level) : (h += 1) try out.append(gpa, '#');
    try out.print(gpa, " `{s}`\n\n", .{sig});
    try emitDoc(gpa, out, docRunBefore(comments, declLine(d)));
}

/// Emit a comment block as a Markdown paragraph, stripping each line's `##`
/// prefix. Empty blocks emit nothing.
fn emitDoc(gpa: std.mem.Allocator, out: *std.ArrayList(u8), block: []const Comment) Error!void {
    if (block.len == 0) return;
    for (block) |c| {
        try out.appendSlice(gpa, stripPrefix(c.text));
        try out.append(gpa, '\n');
    }
    try out.append(gpa, '\n');
}

/// Strip a comment's leading `##` and one optional following space, leaving the
/// text (`## Sum of a list.` -> `Sum of a list.`, a bare `##` -> ``).
fn stripPrefix(text: []const u8) []const u8 {
    var s = text;
    if (std.mem.startsWith(u8, s, "##")) s = s[2..];
    if (s.len > 0 and s[0] == ' ') s = s[1..];
    return s;
}

/// The maximal run of comments with consecutive lines ending exactly at
/// `line - 1` — the doc block written directly above a declaration on `line`.
/// Empty if no comment sits on `line - 1`.
fn docRunBefore(comments: []const Comment, line: u32) []const Comment {
    var end: usize = 0;
    var found = false;
    for (comments, 0..) |c, i| {
        if (c.line + 1 == line) {
            end = i;
            found = true;
        }
    }
    if (!found) return comments[0..0];
    var start = end;
    while (start > 0 and comments[start - 1].line + 1 == comments[start].line) start -= 1;
    return comments[start .. end + 1];
}

/// The run of consecutive-line comments beginning at index `from`.
fn runStartingAt(comments: []const Comment, from: usize) []const Comment {
    var end = from;
    while (end + 1 < comments.len and comments[end].line + 1 == comments[end + 1].line) end += 1;
    return comments[from .. end + 1];
}

fn declLine(d: Decl) u32 {
    return switch (d) {
        .import => |x| x.span.line,
        .var_decl => |x| x.span.line,
        .func => |x| x.span.line,
        .class => |x| x.span.line,
        .struct_decl => |x| x.span.line,
        .enum_decl => |x| x.span.line,
        .signal => |x| x.span.line,
    };
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;

fn expectDoc(src: []const u8, title: []const u8, expected: []const u8) !void {
    const gpa = testing.allocator;
    var tree = try parser.parse(gpa, src);
    defer tree.deinit();
    try testing.expectEqual(@as(usize, 0), tree.diagnostics.len);
    const md = try generate(gpa, title, tree.module, tree.comments);
    defer gpa.free(md);
    try testing.expectEqualStrings(expected, md);
}

test "doc: a function's signature and doc comment" {
    try expectDoc(
        "## Sum two ints.\npub func add(a: int, b: int) -> int:\n    return a + b\n",
        "demo",
        "# demo\n\n## `pub func add(a: int, b: int) -> int`\n\nSum two ints.\n\n",
    );
}

test "doc: a module preamble precedes the declarations" {
    try expectDoc(
        "## A tiny module.\n## Two lines of intro.\n\n## The answer.\nconst N: int = 42\n",
        "mod",
        "# mod\n\nA tiny module.\nTwo lines of intro.\n\n## `const N: int = 42`\n\nThe answer.\n\n",
    );
}

test "doc: a class documents its pub members one level deeper" {
    try expectDoc(
        "## A 2D point.\npub struct Point:\n    var x: int = 0\n    ## Move right by dx.\n    pub func shift(dx: int):\n        x = x + dx\n",
        "geo",
        "# geo\n\n## `pub struct Point`\n\nA 2D point.\n\n### `var x: int = 0`\n\n### `pub func shift(dx: int)`\n\nMove right by dx.\n\n",
    );
}

test "doc: imports are skipped and undocumented decls still list their signature" {
    try expectDoc(
        "import std.lists\n\nfunc helper():\n    pass\n",
        "x",
        "# x\n\n## `func helper()`\n\n",
    );
}
