//! A small Language Server for RoseGold, spoken over stdio (`RoseGold_Zig lsp`).
//!
//! It reuses the real front end: every open document is parsed and analyzed
//! (`parser.parse` + `analyzer.analyzeModule`) and the resulting diagnostics are
//! published to the editor, so errors match the CLI's `check` exactly. It also
//! answers hover, go-to-definition, and document-symbol requests using a
//! lightweight declaration scan over the buffer.
//!
//! Cross-file analysis: a document with `import`s is analyzed through the module
//! loader, with every open (unsaved) buffer overlaid on disk — so imported names
//! and types are resolved and diagnostics reflect live edits across files. A
//! document with no imports (or an untitled buffer) is analyzed standalone.
//! Positions are treated as UTF-8 byte offsets within a line (correct for ASCII
//! source).

const std = @import("std");
const Io = std.Io;
const parser = @import("parser.zig");
const analyzer = @import("analyzer.zig");
const loader = @import("loader.zig");
const formatter = @import("formatter.zig");
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
/// `kind`: 1 = Text, 2 = Read, 3 = Write.
const DocumentHighlight = struct { range: Range, kind: u32 };
/// `kind`: "region" (a colon-block body) or "comment" (a run of `##` lines).
const FoldingRange = struct { startLine: u32, endLine: u32, kind: []const u8 };

// rename / workspace-edit wire types
const TextEdit = struct { range: Range, newText: []const u8 };
const OptVersionedDocId = struct { uri: []const u8, version: ?i64 = null };
const TextDocumentEdit = struct { textDocument: OptVersionedDocId, edits: []const TextEdit };
const WorkspaceEdit = struct { documentChanges: []const TextDocumentEdit };
const PrepareRename = struct { range: Range, placeholder: []const u8 };
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
    /// Leading-whitespace width of the header line (0 ⇒ top-level).
    indent: u32 = 0,
    /// Whether the declaration is `pub` (part of the module's export surface).
    is_pub: bool = false,

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

    /// The LSP CompletionItemKind number for this declaration.
    fn completionKind(self: Decl) u32 {
        return switch (self.kind) {
            .func => 3, // Function
            .class => 7, // Class
            .struct_ => 22, // Struct
            .enum_ => 13, // Enum
            .signal => 23, // Event
            .const_ => 21, // Constant
            .var_ => 6, // Variable
        };
    }
};

const CompletionItem = struct {
    label: []const u8,
    kind: u32,
    detail: ?[]const u8 = null,
};

// signatureHelp wire types
const SigParam = struct { label: []const u8 };
const SignatureInfo = struct {
    label: []const u8,
    parameters: []const SigParam,
    documentation: ?[]const u8 = null,
};
const SignatureHelpResult = struct {
    signatures: []const SignatureInfo,
    activeSignature: u32 = 0,
    activeParameter: u32,
};

/// An intermediate signature (label + parameter labels + optional docs) before
/// it's shaped into the LSP response.
const Signature = struct { label: []const u8, params: []const []const u8, doc: ?[]const u8 = null };

/// A found call the cursor sits inside: the callee name, an optional receiver
/// (`recv.callee(…)`), and the 0-based index of the argument being typed.
const CallContext = struct { callee: []const u8, receiver: ?[]const u8, active: u32 };

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
        const indent = i;
        var rest = l[i..];
        var col = i;
        // Skip optional visibility and `static` modifiers, noting `pub`.
        var is_pub = false;
        inline for (.{ "pub ", "private ", "static " }) |kw| {
            if (std.mem.startsWith(u8, rest, kw)) {
                if (kw[0] == 'p' and kw[1] == 'u') is_pub = true;
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
            .indent = @intCast(indent),
            .is_pub = is_pub,
        });
    }
    return out.toOwnedSlice(alloc);
}

// --- folding -----------------------------------------------------------------

const LineInfo = struct { indent: u32, blank: bool, colon: bool, comment: bool };

/// Classify one source line for folding: its indent, whether it's blank, whether
/// its code (past any trailing `## comment`) ends with `:`, and whether it's a
/// whole-line comment.
fn classifyLine(l: []const u8) LineInfo {
    var i: usize = 0;
    while (i < l.len and (l[i] == ' ' or l[i] == '\t')) i += 1;
    const trimmed = l[i..];
    const comment = std.mem.startsWith(u8, trimmed, "##");
    const hash = std.mem.indexOf(u8, l, "##");
    const code = std.mem.trimEnd(u8, if (hash) |h| l[0..h] else l, " \t");
    return .{
        .indent = @intCast(i),
        .blank = trimmed.len == 0,
        .colon = code.len > 0 and code[code.len - 1] == ':',
        .comment = comment,
    };
}

/// Folding ranges for a document: each colon-block body (header line through its
/// last more-indented line, skipping trailing blanks) and each run of 2+
/// consecutive whole-line comments.
fn computeFoldingRanges(a: std.mem.Allocator, text: []const u8, out: *std.ArrayList(FoldingRange)) !void {
    var lines: std.ArrayList(LineInfo) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| try lines.append(a, classifyLine(std.mem.trimEnd(u8, raw, "\r")));
    const n = lines.items.len;

    // Colon-block bodies (by indentation).
    for (lines.items, 0..) |hdr, i| {
        if (hdr.blank or !hdr.colon) continue;
        var last: usize = i;
        var k = i + 1;
        while (k < n) : (k += 1) {
            if (lines.items[k].blank) continue;
            if (lines.items[k].indent > hdr.indent) last = k else break;
        }
        if (last > i) try out.append(a, .{ .startLine = @intCast(i), .endLine = @intCast(last), .kind = "region" });
    }

    // Runs of consecutive whole-line comments.
    var i: usize = 0;
    while (i < n) {
        if (lines.items[i].comment) {
            var j = i;
            while (j + 1 < n and lines.items[j + 1].comment) j += 1;
            if (j > i) try out.append(a, .{ .startLine = @intCast(i), .endLine = @intCast(j), .kind = "comment" });
            i = j + 1;
        } else i += 1;
    }
}

// --- scope resolution --------------------------------------------------------
//
// Makes references/rename/highlight scope-aware: a local (a parameter or a local
// binding) resolves to the byte span of the function/lambda that declares it, so
// it isn't conflated with a same-named local elsewhere or a module global. A name
// not declared by any enclosing scope is treated as a module global (searched
// workspace-wide). Block sub-scopes are merged into their function (whole-body
// granularity), so this is precise across functions but conservative about
// shadowing *within* one function.

const Scope = struct { start: u32, end: u32, names: std.StringHashMapUnmanaged(void) = .{} };
const Bounds = struct { start: usize, end: usize };
const ScopeResult = union(enum) { local: Bounds, global };

/// Names bound directly by `body`'s statements (var/const, destructure, for
/// bindings, catch), recursing into control-flow sub-blocks but not lambdas.
fn addBodyNames(a: std.mem.Allocator, body: []const parser.Stmt, names: *std.StringHashMapUnmanaged(void)) std.mem.Allocator.Error!void {
    for (body) |s| switch (s) {
        .var_decl => |v| try names.put(a, v.name, {}),
        .destructure => |d| for (d.names) |n| try names.put(a, n, {}),
        .for_stmt => |f| {
            try names.put(a, f.binding, {});
            if (f.value_binding) |vb| try names.put(a, vb, {});
            try addBodyNames(a, f.body, names);
        },
        .while_stmt => |w| try addBodyNames(a, w.body, names),
        .if_stmt => |i| {
            try addBodyNames(a, i.then_body, names);
            for (i.elifs) |e| try addBodyNames(a, e.body, names);
            if (i.else_body) |eb| try addBodyNames(a, eb, names);
        },
        .try_catch => |t| {
            try addBodyNames(a, t.body, names);
            try names.put(a, t.catch_name, {});
            try addBodyNames(a, t.handler, names);
        },
        else => {},
    };
}

/// Record a function/lambda scope (its params + body-local names) and recurse to
/// register any lambdas nested in its body as their own scopes.
fn addFuncScope(a: std.mem.Allocator, span: lexer.Span, params: []const parser.Param, body: []const parser.Stmt, scopes: *std.ArrayList(Scope)) std.mem.Allocator.Error!void {
    var scope = Scope{ .start = span.start, .end = span.end };
    for (params) |p| try scope.names.put(a, p.name, {});
    try addBodyNames(a, body, &scope.names);
    try scopes.append(a, scope);
    try findLambdasInStmts(a, body, scopes);
}

fn findLambdasInStmts(a: std.mem.Allocator, body: []const parser.Stmt, scopes: *std.ArrayList(Scope)) std.mem.Allocator.Error!void {
    for (body) |s| switch (s) {
        .var_decl => |v| if (v.value) |e| try findLambdasInExpr(a, e, scopes),
        .destructure => |d| try findLambdasInExpr(a, d.value, scopes),
        .return_stmt => |r| if (r.value) |e| try findLambdasInExpr(a, e, scopes),
        .if_stmt => |i| {
            try findLambdasInExpr(a, i.cond, scopes);
            try findLambdasInStmts(a, i.then_body, scopes);
            for (i.elifs) |e| {
                try findLambdasInExpr(a, e.cond, scopes);
                try findLambdasInStmts(a, e.body, scopes);
            }
            if (i.else_body) |eb| try findLambdasInStmts(a, eb, scopes);
        },
        .while_stmt => |w| {
            try findLambdasInExpr(a, w.cond, scopes);
            try findLambdasInStmts(a, w.body, scopes);
        },
        .for_stmt => |f| {
            try findLambdasInExpr(a, f.iter, scopes);
            try findLambdasInStmts(a, f.body, scopes);
        },
        .assign => |x| {
            try findLambdasInExpr(a, x.target, scopes);
            try findLambdasInExpr(a, x.value, scopes);
        },
        .expr_stmt => |e| try findLambdasInExpr(a, e, scopes),
        .try_catch => |t| {
            try findLambdasInStmts(a, t.body, scopes);
            try findLambdasInStmts(a, t.handler, scopes);
        },
        .raise => |r| try findLambdasInExpr(a, r.value, scopes),
        else => {},
    };
}

fn findLambdasInExpr(a: std.mem.Allocator, e: *const parser.Expr, scopes: *std.ArrayList(Scope)) std.mem.Allocator.Error!void {
    switch (e.*) {
        .lambda => |l| try addFuncScope(a, l.span, l.params, l.body, scopes),
        .unary => |u| try findLambdasInExpr(a, u.operand, scopes),
        .binary => |b| {
            try findLambdasInExpr(a, b.lhs, scopes);
            try findLambdasInExpr(a, b.rhs, scopes);
        },
        .call => |c| {
            try findLambdasInExpr(a, c.callee, scopes);
            for (c.args) |arg| try findLambdasInExpr(a, arg.value, scopes);
        },
        .index => |ix| {
            try findLambdasInExpr(a, ix.object, scopes);
            try findLambdasInExpr(a, ix.index, scopes);
        },
        .slice => |s| {
            try findLambdasInExpr(a, s.object, scopes);
            if (s.start) |st| try findLambdasInExpr(a, st, scopes);
            if (s.end) |en| try findLambdasInExpr(a, en, scopes);
        },
        .member => |m| try findLambdasInExpr(a, m.object, scopes),
        .array => |arr| for (arr.elements) |el| try findLambdasInExpr(a, el, scopes),
        .map => |mp| for (mp.entries) |en| {
            try findLambdasInExpr(a, en.key, scopes);
            try findLambdasInExpr(a, en.value, scopes);
        },
        .match => |mt| {
            try findLambdasInExpr(a, mt.subject, scopes);
            for (mt.arms) |arm| try findLambdasInExpr(a, arm.body, scopes);
        },
        .range => |rg| {
            try findLambdasInExpr(a, rg.start, scopes);
            try findLambdasInExpr(a, rg.end, scopes);
        },
        .tuple => |t| for (t.elements) |el| try findLambdasInExpr(a, el, scopes),
        .interpolation => |ip| for (ip.parts) |part| {
            if (part == .expr) try findLambdasInExpr(a, part.expr, scopes);
        },
        else => {}, // literals, identifier, member name
    }
}

fn collectScopesInDecl(a: std.mem.Allocator, d: parser.Decl, scopes: *std.ArrayList(Scope)) std.mem.Allocator.Error!void {
    switch (d) {
        .func => |f| try addFuncScope(a, f.span, f.params, f.body, scopes),
        .class => |c| for (c.members) |m| try collectScopesInDecl(a, m, scopes),
        .struct_decl => |s| for (s.members) |m| try collectScopesInDecl(a, m, scopes),
        .var_decl => |v| if (v.value) |e| try findLambdasInExpr(a, e, scopes), // a lambda in a const/var initializer
        else => {},
    }
}

/// Every function/method/lambda scope in the module.
fn collectScopes(a: std.mem.Allocator, module: parser.Module, scopes: *std.ArrayList(Scope)) std.mem.Allocator.Error!void {
    for (module.decls) |d| try collectScopesInDecl(a, d, scopes);
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

/// If the cursor is completing a member access — `receiver.partial` — return the
/// `receiver` identifier; otherwise null. `partial` may be empty (just after `.`).
fn receiverBeforeCursor(text: []const u8, offset: usize) ?[]const u8 {
    var o = offset;
    while (o > 0 and isIdentChar(text[o - 1])) o -= 1; // over the partial being typed
    if (o == 0 or text[o - 1] != '.') return null;
    const dot = o - 1;
    var s = dot;
    while (s > 0 and isIdentChar(text[s - 1])) s -= 1;
    if (s == dot) return null; // a '.' with no identifier before it
    return text[s..dot];
}

/// If `text` imports a module bound to the leaf name `leaf`, return its file path
/// relative to the importer (`a.b.c` → `a/b/c.rg`), else null.
fn importRelPath(a: std.mem.Allocator, text: []const u8, leaf: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const l = std.mem.trimStart(u8, std.mem.trimEnd(u8, raw, "\r"), " \t");
        const kw = "import ";
        if (!std.mem.startsWith(u8, l, kw)) continue;
        const rest = std.mem.trimStart(u8, l[kw.len..], " \t");
        var n: usize = 0;
        while (n < rest.len and (isIdentChar(rest[n]) or rest[n] == '.')) n += 1;
        const dotted = rest[0..n];
        if (dotted.len == 0) continue;
        const last_dot = std.mem.lastIndexOfScalar(u8, dotted, '.');
        const this_leaf = if (last_dot) |ld| dotted[ld + 1 ..] else dotted;
        if (!std.mem.eql(u8, this_leaf, leaf)) continue;
        var buf: std.ArrayList(u8) = .empty;
        for (dotted) |c| buf.append(a, if (c == '.') '/' else c) catch return null;
        buf.appendSlice(a, ".rg") catch return null;
        return buf.toOwnedSlice(a) catch null;
    }
    return null;
}

/// If `offset` sits inside a call's argument list, return the callee (and any
/// `receiver.`) and which argument (0-based) is being typed. Scans backward
/// through balanced brackets; naive about strings/comments.
fn callContext(text: []const u8, offset: usize) ?CallContext {
    var depth: usize = 0;
    var active: u32 = 0;
    var open: ?usize = null;
    var i = offset;
    while (i > 0) {
        i -= 1;
        switch (text[i]) {
            ')', ']', '}' => depth += 1,
            '(', '[', '{' => {
                if (depth > 0) {
                    depth -= 1;
                } else {
                    if (text[i] == '(') open = i; // '[' or '{' ⇒ not a call
                    break;
                }
            },
            ',' => if (depth == 0) {
                active += 1;
            },
            else => {},
        }
    }
    const p = open orelse return null;
    var j = p;
    while (j > 0 and (text[j - 1] == ' ' or text[j - 1] == '\t')) j -= 1;
    const e = j;
    while (j > 0 and isIdentChar(text[j - 1])) j -= 1;
    if (j == e) return null; // '(' not preceded by a name: a grouping, not a call
    const callee = text[j..e];
    var receiver: ?[]const u8 = null;
    if (j > 0 and text[j - 1] == '.') {
        var rs = j - 1;
        const re = rs;
        while (rs > 0 and isIdentChar(text[rs - 1])) rs -= 1;
        if (rs < re) receiver = text[rs..re];
    }
    return .{ .callee = callee, .receiver = receiver, .active = active };
}

/// Build a `Signature` for the function whose name starts at `name_offset` by
/// reading its `(…)` header straight from the source (so types and defaults show
/// as written), splitting the parameters on top-level commas.
fn signatureFromSource(a: std.mem.Allocator, text: []const u8, name_offset: usize, doc: ?[]const u8) ?Signature {
    var i = name_offset;
    while (i < text.len and text[i] != '(' and text[i] != '\n') i += 1;
    if (i >= text.len or text[i] != '(') return null;
    const open = i;
    var depth: usize = 0;
    var j = open;
    var closed = false;
    while (j < text.len) : (j += 1) {
        switch (text[j]) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => {
                depth -= 1;
                if (depth == 0) {
                    closed = true;
                    break;
                }
            },
            else => {},
        }
    }
    if (!closed) return null;
    const inner = text[open + 1 .. j];
    var params: std.ArrayList([]const u8) = .empty;
    var d: usize = 0;
    var start: usize = 0;
    var k: usize = 0;
    while (k < inner.len) : (k += 1) {
        switch (inner[k]) {
            '(', '[', '{' => d += 1,
            ')', ']', '}' => {
                if (d > 0) d -= 1;
            },
            ',' => if (d == 0) {
                params.append(a, std.mem.trim(u8, inner[start..k], " \t")) catch return null;
                start = k + 1;
            },
            else => {},
        }
    }
    const last = std.mem.trim(u8, inner[start..], " \t");
    if (last.len > 0 or params.items.len > 0) params.append(a, last) catch return null;
    return .{
        .label = text[name_offset .. j + 1], // `name(params…)`
        .params = params.toOwnedSlice(a) catch return null,
        .doc = doc,
    };
}

/// A signature for a top-level or member `func` named `name` declared in `text`.
fn findDocSignature(a: std.mem.Allocator, text: []const u8, name: []const u8) ?Signature {
    const decls = scanDecls(a, text) catch return null;
    for (decls) |d| {
        if (d.kind == .func and std.mem.eql(u8, d.name, name)) {
            const off = offsetAt(text, d.line, d.character) orelse continue;
            if (signatureFromSource(a, text, off, null)) |s| return s;
        }
    }
    return null;
}

/// A signature for a `pub` top-level `func` named `name` in `text` (an imported
/// module's export surface).
fn findPubDocSignature(a: std.mem.Allocator, text: []const u8, name: []const u8) ?Signature {
    const decls = scanDecls(a, text) catch return null;
    for (decls) |d| {
        if (d.kind == .func and d.is_pub and d.indent == 0 and std.mem.eql(u8, d.name, name)) {
            const off = offsetAt(text, d.line, d.character) orelse continue;
            if (signatureFromSource(a, text, off, null)) |s| return s;
        }
    }
    return null;
}

/// A signature for a stdlib builtin, or null.
fn builtinSignature(a: std.mem.Allocator, name: []const u8) ?Signature {
    for (BUILTIN_SIGS) |b| {
        if (!std.mem.eql(u8, b.n, name)) continue;
        var label: std.ArrayList(u8) = .empty;
        label.appendSlice(a, name) catch return null;
        label.append(a, '(') catch return null;
        for (b.params, 0..) |pp, idx| {
            if (idx > 0) label.appendSlice(a, ", ") catch return null;
            label.appendSlice(a, pp) catch return null;
        }
        label.append(a, ')') catch return null;
        return .{ .label = label.toOwnedSlice(a) catch return null, .params = b.params, .doc = builtinDoc(name) };
    }
    return null;
}

const IdentBounds = struct { start: usize, end: usize };

/// The byte bounds of the identifier surrounding `offset` (the cursor may sit
/// just past its end), or null if there's no identifier there.
fn identBoundsAt(text: []const u8, offset: usize) ?IdentBounds {
    var o = offset;
    if (o > 0 and (o >= text.len or !isIdentChar(text[o])) and isIdentChar(text[o - 1])) o -= 1;
    if (o >= text.len or !isIdentChar(text[o])) return null;
    var s = o;
    while (s > 0 and isIdentChar(text[s - 1])) s -= 1;
    var e = o;
    while (e < text.len and isIdentChar(text[e])) e += 1;
    return .{ .start = s, .end = e };
}

/// The identifier surrounding `offset`, or null if there's none.
fn identAt(text: []const u8, offset: usize) ?[]const u8 {
    const b = identBoundsAt(text, offset) orelse return null;
    return text[b.start..b.end];
}

fn isKeyword(name: []const u8) bool {
    for (KEYWORDS) |k| {
        if (std.mem.eql(u8, k, name)) return true;
    }
    return false;
}

/// Whether `name` is usable as a new identifier for rename (a valid, non-keyword
/// identifier).
fn isValidIdent(name: []const u8) bool {
    if (name.len == 0 or !isIdentStart(name[0])) return false;
    for (name) |c| {
        if (!isIdentChar(c)) return false;
    }
    return !isKeyword(name);
}

// --- builtin documentation ---------------------------------------------------

const BuiltinDoc = struct { n: []const u8, d: []const u8 };

const BUILTINS = [_]BuiltinDoc{
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

/// Keywords offered by completion (declarations, control flow, modifiers, literals).
const KEYWORDS = [_][]const u8{
    "func",   "class",  "struct", "enum",     "signal", "const", "var",   "import",
    "pub",    "private", "static", "extends", "uses",   "if",    "elif",  "else",
    "while",  "for",    "in",     "break",    "continue", "return", "pass", "match",
    "raise",  "try",    "catch",  "and",      "or",     "not",   "true",  "false",
    "nil",
};

const TYPES = [_][]const u8{ "int", "float", "str", "bool", "void", "any", "list", "map" };

/// Parameter names for the stdlib builtins, for signature help.
const BuiltinSig = struct { n: []const u8, params: []const []const u8 };
const BUILTIN_SIGS = [_]BuiltinSig{
    .{ .n = "print", .params = &.{"values…"} },
    .{ .n = "echo", .params = &.{"values…"} },
    .{ .n = "len", .params = &.{"x"} },
    .{ .n = "range", .params = &.{"n"} },
    .{ .n = "str", .params = &.{"x"} },
    .{ .n = "int", .params = &.{"x"} },
    .{ .n = "float", .params = &.{"x"} },
    .{ .n = "push", .params = &.{ "list", "x" } },
    .{ .n = "pop", .params = &.{"list"} },
    .{ .n = "keys", .params = &.{"map"} },
    .{ .n = "values", .params = &.{"map"} },
    .{ .n = "has", .params = &.{ "map", "key" } },
    .{ .n = "connect", .params = &.{ "signal", "handler" } },
    .{ .n = "emit", .params = &.{ "signal", "args…" } },
    .{ .n = "abs", .params = &.{"x"} },
    .{ .n = "min", .params = &.{ "a", "b" } },
    .{ .n = "max", .params = &.{ "a", "b" } },
    .{ .n = "upper", .params = &.{"s"} },
    .{ .n = "lower", .params = &.{"s"} },
    .{ .n = "split", .params = &.{ "s", "sep" } },
    .{ .n = "join", .params = &.{ "list", "sep" } },
    .{ .n = "contains", .params = &.{ "haystack", "needle" } },
    .{ .n = "sort", .params = &.{"list"} },
    .{ .n = "reverse", .params = &.{"list"} },
    .{ .n = "trim", .params = &.{"s"} },
    .{ .n = "starts_with", .params = &.{ "s", "prefix" } },
    .{ .n = "ends_with", .params = &.{ "s", "suffix" } },
    .{ .n = "find", .params = &.{ "haystack", "needle" } },
    .{ .n = "replace", .params = &.{ "s", "from", "to" } },
    .{ .n = "map", .params = &.{ "list", "f" } },
    .{ .n = "filter", .params = &.{ "list", "pred" } },
    .{ .n = "reduce", .params = &.{ "list", "f", "init" } },
    .{ .n = "sqrt", .params = &.{"x"} },
    .{ .n = "pow", .params = &.{ "base", "exp" } },
    .{ .n = "floor", .params = &.{"x"} },
    .{ .n = "ceil", .params = &.{"x"} },
    .{ .n = "round", .params = &.{"x"} },
};

fn builtinDoc(name: []const u8) ?[]const u8 {
    for (BUILTINS) |e| {
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
    io: Io,
    out: *Io.Writer,
    in: *Io.Reader,
    /// uri → document text, both owned by `gpa`.
    docs: std.StringHashMapUnmanaged([]const u8) = .{},
    /// Module search roots (workspace folders + configured import paths), each a
    /// `gpa`-owned filesystem path; imports not found relative to the importer are
    /// looked up here, in order.
    roots: std.ArrayListUnmanaged([]const u8) = .empty,
    shutting_down: bool = false,

    fn deinit(self: *Server) void {
        var it = self.docs.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.*);
        }
        self.docs.deinit(self.gpa);
        for (self.roots.items) |r| self.gpa.free(r);
        self.roots.deinit(self.gpa);
    }

    /// Add `path` as a search root (owned copy), skipping duplicates and empties.
    fn addRoot(self: *Server, path: []const u8) !void {
        if (path.len == 0) return;
        for (self.roots.items) |r| {
            if (std.mem.eql(u8, r, path)) return;
        }
        try self.roots.append(self.gpa, try self.gpa.dupe(u8, path));
    }

    /// Add a search root given as a `file://` URI, if it decodes to a path.
    fn addRootUri(self: *Server, uri: []const u8) !void {
        const p = uriToPath(self.gpa, uri) orelse return;
        defer self.gpa.free(p);
        try self.addRoot(p);
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
                try self.onInitialize(id.?, params);
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
            } else if (std.mem.eql(u8, method, "textDocument/completion")) {
                try self.onCompletion(id.?, params);
            } else if (std.mem.eql(u8, method, "textDocument/signatureHelp")) {
                try self.onSignatureHelp(id.?, params);
            } else if (std.mem.eql(u8, method, "textDocument/references")) {
                try self.onReferences(id.?, params);
            } else if (std.mem.eql(u8, method, "textDocument/documentHighlight")) {
                try self.onDocumentHighlight(id.?, params);
            } else if (std.mem.eql(u8, method, "textDocument/foldingRange")) {
                try self.onFoldingRange(id.?, params);
            } else if (std.mem.eql(u8, method, "textDocument/formatting")) {
                try self.onFormatting(id.?, params);
            } else if (std.mem.eql(u8, method, "textDocument/prepareRename")) {
                try self.onPrepareRename(id.?, params);
            } else if (std.mem.eql(u8, method, "textDocument/rename")) {
                try self.onRename(id.?, params);
            } else if (id) |rid| {
                // Any other request: reply with null so the client isn't left waiting.
                try self.respond(rid, @as(?u8, null));
            }
        }
    }

    /// Capture the workspace's module search roots from the `initialize` request
    /// (workspace folders, the legacy `rootUri`, and an optional
    /// `initializationOptions.importPaths` array of paths or `file://` URIs), then
    /// reply with capabilities.
    fn onInitialize(self: *Server, id: std.json.Value, params: ?std.json.Value) !void {
        if (params) |p| {
            if (objGet(p, "workspaceFolders")) |wf| {
                if (wf == .array) {
                    for (wf.array.items) |folder| {
                        if (strField(folder, "uri")) |u| try self.addRootUri(u);
                    }
                }
            }
            if (strField(p, "rootUri")) |u| try self.addRootUri(u);
            if (objGet(p, "initializationOptions")) |opts| {
                if (objGet(opts, "importPaths")) |ip| {
                    if (ip == .array) {
                        for (ip.array.items) |v| {
                            if (v != .string) continue;
                            if (std.mem.startsWith(u8, v.string, "file://")) {
                                try self.addRootUri(v.string);
                            } else {
                                try self.addRoot(v.string);
                            }
                        }
                    }
                }
            }
        }
        try self.respond(id, initializeResult());
    }

    fn initializeResult() struct {
        capabilities: struct {
            textDocumentSync: u32,
            hoverProvider: bool,
            definitionProvider: bool,
            documentSymbolProvider: bool,
            referencesProvider: bool,
            documentHighlightProvider: bool,
            foldingRangeProvider: bool,
            documentFormattingProvider: bool,
            completionProvider: struct { triggerCharacters: []const []const u8 },
            signatureHelpProvider: struct { triggerCharacters: []const []const u8 },
            renameProvider: struct { prepareProvider: bool },
        },
        serverInfo: struct { name: []const u8, version: []const u8 },
    } {
        return .{
            .capabilities = .{
                .textDocumentSync = 1, // full document sync
                .hoverProvider = true,
                .definitionProvider = true,
                .documentSymbolProvider = true,
                .referencesProvider = true,
                .documentHighlightProvider = true,
                .foldingRangeProvider = true,
                .documentFormattingProvider = true,
                .completionProvider = .{ .triggerCharacters = &.{"."} },
                .signatureHelpProvider = .{ .triggerCharacters = &.{ "(", "," } },
                .renameProvider = .{ .prepareProvider = true },
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

    /// Map a front-end diagnostic and append it with a `gpa`-owned message, so it
    /// outlives the parse tree / analysis arena it came from.
    fn appendDiag(self: *Server, diags: *std.ArrayList(LspDiag), text: []const u8, d: lexer.Diagnostic) !void {
        var m = mapDiag(text, d);
        m.message = try self.gpa.dupe(u8, m.message);
        try diags.append(self.gpa, m);
    }

    fn publishDiagnostics(self: *Server, uri: []const u8, text: []const u8) !void {
        var diags: std.ArrayList(LspDiag) = .empty;
        defer {
            for (diags.items) |d| self.gpa.free(d.message);
            diags.deinit(self.gpa);
        }

        var tree = try parser.parse(self.gpa, text);
        defer tree.deinit();
        // A broken parse: report its errors and stop (analysis over it is noise).
        if (tree.diagnostics.len > 0) {
            for (tree.diagnostics) |d| try self.appendDiag(&diags, text, d);
            try self.notify("textDocument/publishDiagnostics", .{ .uri = uri, .diagnostics = diags.items });
            return;
        }

        // Cross-file when the document imports and lives on disk; else standalone.
        const path = uriToPath(self.gpa, uri);
        defer if (path) |p| self.gpa.free(p);
        if (path != null and hasImports(tree.module)) {
            self.diagnoseCrossFile(path.?, &diags) catch |e| switch (e) {
                error.OutOfMemory => return e,
                // Any loader/analyze trouble: fall back to a standalone pass.
                else => try self.diagnoseStandalone(tree.module, text, &diags),
            };
        } else {
            try self.diagnoseStandalone(tree.module, text, &diags);
        }
        try self.notify("textDocument/publishDiagnostics", .{ .uri = uri, .diagnostics = diags.items });
    }

    fn diagnoseStandalone(self: *Server, module: parser.Module, text: []const u8, diags: *std.ArrayList(LspDiag)) !void {
        var analysis = try analyzer.analyzeModule(self.gpa, module, &.{});
        defer analysis.deinit();
        for (analysis.diagnostics) |d| try self.appendDiag(diags, text, d);
    }

    /// Analyze `entry_path` through the module loader, overlaying every open
    /// buffer on disk, and collect the entry document's own diagnostics (import
    /// resolution errors plus its analysis, with imported modules resolved).
    fn diagnoseCrossFile(self: *Server, entry_path: []const u8, diags: *std.ArrayList(LspDiag)) !void {
        // Overlay every open document so unsaved edits (here and in imported
        // files) are what gets analyzed.
        var overlays: std.ArrayList(loader.Overlay) = .empty;
        defer overlays.deinit(self.gpa);
        var paths: std.ArrayList([]u8) = .empty;
        defer {
            for (paths.items) |p| self.gpa.free(p);
            paths.deinit(self.gpa);
        }
        var it = self.docs.iterator();
        while (it.next()) |e| {
            const p = uriToPath(self.gpa, e.key_ptr.*) orelse continue;
            try paths.append(self.gpa, p);
            try overlays.append(self.gpa, .{ .path = p, .src = e.value_ptr.* });
        }

        var graph = try loader.loadWithOverlay(self.gpa, self.io, entry_path, self.roots.items, overlays.items);
        defer graph.deinit();
        if (graph.units.len == 0) return;
        const entry = graph.units[graph.units.len - 1]; // dependency order: entry last

        // Load/resolution errors attributed to the entry file (e.g. missing import).
        for (graph.diagnostics) |ld| {
            if (std.mem.eql(u8, ld.path, entry.path)) try self.appendDiag(diags, entry.src, ld.diag);
        }

        // Analyze every module in dependency order, handing each the exports of the
        // modules it imports. Keep all analyses alive: a dependent's exports point
        // into its dependency's analysis arena.
        const analyses = try self.gpa.alloc(analyzer.Analysis, graph.units.len);
        var built: usize = 0;
        defer {
            for (analyses[0..built]) |*a| a.deinit();
            self.gpa.free(analyses);
        }
        const exports = try self.gpa.alloc(*const analyzer.ModuleExports, graph.units.len);
        defer self.gpa.free(exports);

        for (graph.units, 0..) |unit, i| {
            const imports = try self.gpa.alloc(analyzer.ModuleImport, unit.imports.len);
            defer self.gpa.free(imports);
            for (unit.imports, 0..) |imp, j| {
                imports[j] = .{ .name = imp.name, .exports = exports[imp.module_index] };
            }
            analyses[i] = try analyzer.analyzeModule(self.gpa, unit.module, imports);
            built = i + 1;
            exports[i] = analyses[i].exports;
        }
        // Only the entry document's analysis belongs under this uri.
        for (analyses[graph.units.len - 1].diagnostics) |d| try self.appendDiag(diags, entry.src, d);
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

    /// Offer completions: after `receiver.` the exported members of the imported
    /// module `receiver`; otherwise keywords, built-in types, stdlib builtins, and
    /// the document's own declarations. The client filters the list by the prefix
    /// already typed. Everything is built in a scratch arena and serialized before
    /// it's freed.
    fn onCompletion(self: *Server, id: std.json.Value, params: ?std.json.Value) !void {
        const p = params orelse return self.respond(id, &[_]CompletionItem{});
        const uri = self.uriOf(params) orelse return self.respond(id, &[_]CompletionItem{});
        const text = self.docs.get(uri) orelse return self.respond(id, &[_]CompletionItem{});
        const pos = objGet(p, "position") orelse return self.respond(id, &[_]CompletionItem{});
        const line = intField(pos, "line") orelse return self.respond(id, &[_]CompletionItem{});
        const character = intField(pos, "character") orelse return self.respond(id, &[_]CompletionItem{});
        const off = offsetAt(text, @intCast(line), @intCast(character)) orelse return self.respond(id, &[_]CompletionItem{});

        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();

        var items: std.ArrayList(CompletionItem) = .empty;
        if (receiverBeforeCursor(text, off)) |receiver| {
            try self.moduleMemberCompletions(a, uri, text, receiver, &items);
        } else {
            try plainCompletions(a, text, &items);
        }
        try self.respond(id, items.items);
    }

    /// Keywords, built-in types, stdlib builtins, and this document's declarations.
    fn plainCompletions(a: std.mem.Allocator, text: []const u8, items: *std.ArrayList(CompletionItem)) !void {
        for (KEYWORDS) |kw| try items.append(a, .{ .label = kw, .kind = 14 }); // Keyword
        for (TYPES) |t| try items.append(a, .{ .label = t, .kind = 25 }); // TypeParameter
        for (BUILTINS) |b| try items.append(a, .{ .label = b.n, .kind = 3, .detail = b.d }); // Function
        const decls = try scanDecls(a, text);
        for (decls) |d| {
            try items.append(a, .{ .label = d.name, .kind = d.completionKind(), .detail = declKindWord(d.kind) });
        }
    }

    /// The `pub` top-level declarations of the module imported under the leaf name
    /// `receiver`, read from an open buffer or disk (empty if it can't be resolved).
    fn moduleMemberCompletions(self: *Server, a: std.mem.Allocator, uri: []const u8, text: []const u8, receiver: []const u8, items: *std.ArrayList(CompletionItem)) !void {
        const rel = importRelPath(a, text, receiver) orelse return;
        const src = self.readModuleSource(a, uri, rel) orelse return;
        const decls = try scanDecls(a, src);
        for (decls) |d| {
            if (d.indent == 0 and d.is_pub) {
                try items.append(a, .{ .label = d.name, .kind = d.completionKind(), .detail = declKindWord(d.kind) });
            }
        }
    }

    /// Read the source of a module at `rel` (a `a/b.rg` relative path), looked up
    /// against the document's directory then the search roots, preferring an open
    /// buffer over disk.
    fn readModuleSource(self: *Server, a: std.mem.Allocator, uri: []const u8, rel: []const u8) ?[]const u8 {
        const doc_path = uriToPath(a, uri) orelse return null;
        const doc_dir = std.fs.path.dirname(doc_path) orelse ".";

        // Candidate directories: the document's own dir, then each search root.
        var dirs: std.ArrayList([]const u8) = .empty;
        dirs.append(a, doc_dir) catch return null;
        for (self.roots.items) |r| dirs.append(a, r) catch return null;

        for (dirs.items) |dir| {
            const cand = std.fs.path.join(a, &.{ dir, rel }) catch continue;
            // Prefer an open buffer at this path.
            var it = self.docs.iterator();
            while (it.next()) |e| {
                const p = uriToPath(a, e.key_ptr.*) orelse continue;
                if (std.mem.eql(u8, p, cand)) return e.value_ptr.*;
            }
            // Otherwise read from disk.
            if (Io.Dir.cwd().readFileAlloc(self.io, cand, a, .limited(16 << 20))) |src| {
                return src;
            } else |_| {}
        }
        return null;
    }

    /// Signature help for the call the cursor is inside: the callee's parameters
    /// with the active one marked. Resolves stdlib builtins, this document's
    /// functions/methods, and `mod.func` against the imported module.
    fn onSignatureHelp(self: *Server, id: std.json.Value, params: ?std.json.Value) !void {
        const p = params orelse return self.respond(id, @as(?u8, null));
        const uri = self.uriOf(params) orelse return self.respond(id, @as(?u8, null));
        const text = self.docs.get(uri) orelse return self.respond(id, @as(?u8, null));
        const pos = objGet(p, "position") orelse return self.respond(id, @as(?u8, null));
        const line = intField(pos, "line") orelse return self.respond(id, @as(?u8, null));
        const character = intField(pos, "character") orelse return self.respond(id, @as(?u8, null));
        const off = offsetAt(text, @intCast(line), @intCast(character)) orelse return self.respond(id, @as(?u8, null));

        const ctx = callContext(text, off) orelse return self.respond(id, @as(?u8, null));

        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();

        var sig: ?Signature = null;
        if (ctx.receiver) |receiver| {
            // `mod.func(…)`: the imported module's exported function.
            if (importRelPath(a, text, receiver)) |rel| {
                if (self.readModuleSource(a, uri, rel)) |src| {
                    sig = findPubDocSignature(a, src, ctx.callee);
                }
            }
            // Fallback (e.g. a method call on a value): any func named that here.
            if (sig == null) sig = findDocSignature(a, text, ctx.callee);
        } else {
            sig = builtinSignature(a, ctx.callee) orelse findDocSignature(a, text, ctx.callee);
        }
        const s = sig orelse return self.respond(id, @as(?u8, null));

        const sparams = a.alloc(SigParam, s.params.len) catch return self.respond(id, @as(?u8, null));
        for (s.params, 0..) |pl, idx| sparams[idx] = .{ .label = pl };
        var active = ctx.active;
        if (s.params.len > 0 and active >= s.params.len) active = @intCast(s.params.len - 1);

        const result = SignatureHelpResult{
            .signatures = &.{.{ .label = s.label, .parameters = sparams, .documentation = s.doc }},
            .activeParameter = active,
        };
        try self.respond(id, result);
    }

    fn onFoldingRange(self: *Server, id: std.json.Value, params: ?std.json.Value) !void {
        const empty = &[_]FoldingRange{};
        const uri = self.uriOf(params) orelse return self.respond(id, empty);
        const text = self.docs.get(uri) orelse return self.respond(id, empty);
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        var out: std.ArrayList(FoldingRange) = .empty;
        computeFoldingRanges(arena_state.allocator(), text, &out) catch return self.respond(id, empty);
        try self.respond(id, out.items);
    }

    /// Reformat the whole document through the compiler's formatter, returned as a
    /// single full-document `TextEdit`. A file that doesn't parse (or is already
    /// canonical) yields no edits.
    fn onFormatting(self: *Server, id: std.json.Value, params: ?std.json.Value) !void {
        const empty = &[_]TextEdit{};
        const uri = self.uriOf(params) orelse return self.respond(id, empty);
        const text = self.docs.get(uri) orelse return self.respond(id, empty);

        var tree = parser.parse(self.gpa, text) catch return self.respond(id, empty);
        defer tree.deinit();
        if (tree.diagnostics.len > 0) return self.respond(id, empty); // don't reformat a broken file

        const formatted = formatter.format(self.gpa, tree.module, tree.comments) catch return self.respond(id, empty);
        defer self.gpa.free(formatted);
        if (std.mem.eql(u8, formatted, text)) return self.respond(id, empty); // already canonical

        const edit = TextEdit{
            .range = .{ .start = .{ .line = 0, .character = 0 }, .end = offsetToPos(text, text.len) },
            .newText = formatted,
        };
        try self.respond(id, &[_]TextEdit{edit});
    }

    /// Highlight every occurrence of the identifier under the cursor within the
    /// current document (the same-file, single-buffer cousin of references).
    /// Declaration sites are marked Write, other occurrences Read.
    fn onDocumentHighlight(self: *Server, id: std.json.Value, params: ?std.json.Value) !void {
        const empty = &[_]DocumentHighlight{};
        const p = params orelse return self.respond(id, empty);
        const uri = self.uriOf(params) orelse return self.respond(id, empty);
        const text = self.docs.get(uri) orelse return self.respond(id, empty);
        const pos = objGet(p, "position") orelse return self.respond(id, empty);
        const line = intField(pos, "line") orelse return self.respond(id, empty);
        const character = intField(pos, "character") orelse return self.respond(id, empty);
        const off = offsetAt(text, @intCast(line), @intCast(character)) orelse return self.respond(id, empty);
        const target = identAt(text, off) orelse return self.respond(id, empty);

        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();

        var offs: std.ArrayList(usize) = .empty;
        collectRefs(a, text, target, &offs) catch return self.respond(id, empty);
        const decls: []const usize = declNameOffsets(a, text) catch &.{};
        // If it's a local, confine highlights to its scope.
        const lb: ?Bounds = switch (self.resolveTargetScope(a, text, target, off)) {
            .local => |b| b,
            .global => null,
        };

        var hls: std.ArrayList(DocumentHighlight) = .empty;
        for (offs.items) |o| {
            if (!inBounds(o, lb)) continue;
            const ps = offsetToPos(text, o);
            const kind: u32 = if (std.mem.indexOfScalar(usize, decls, o) != null) 3 else 2; // Write / Read
            hls.append(a, .{
                .range = .{
                    .start = ps,
                    .end = .{ .line = ps.line, .character = ps.character + @as(u32, @intCast(target.len)) },
                },
                .kind = kind,
            }) catch {};
        }
        try self.respond(id, hls.items);
    }

    /// Find every reference to the identifier under the cursor across the
    /// workspace — all open buffers plus the `.rg` files under the document's
    /// directory and the search roots. Name-based (whole-word, skipping comments
    /// and string text but not `${…}` holes); not scope-aware.
    fn onReferences(self: *Server, id: std.json.Value, params: ?std.json.Value) !void {
        const empty = &[_]Location{};
        const p = params orelse return self.respond(id, empty);
        const uri = self.uriOf(params) orelse return self.respond(id, empty);
        const text = self.docs.get(uri) orelse return self.respond(id, empty);
        const pos = objGet(p, "position") orelse return self.respond(id, empty);
        const line = intField(pos, "line") orelse return self.respond(id, empty);
        const character = intField(pos, "character") orelse return self.respond(id, empty);
        const off = offsetAt(text, @intCast(line), @intCast(character)) orelse return self.respond(id, empty);
        const target = identAt(text, off) orelse return self.respond(id, empty);

        var include_decl = true;
        if (objGet(p, "context")) |ctx| {
            if (objGet(ctx, "includeDeclaration")) |v| {
                if (v == .bool) include_decl = v.bool;
            }
        }

        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();

        var locs: std.ArrayList(Location) = .empty;
        switch (self.resolveTargetScope(a, text, target, off)) {
            // A local: search only its scope within the current document.
            .local => |lb| appendFileRefs(a, uri, text, target, include_decl, lb, &locs),
            // A module global: search the whole workspace.
            .global => {
                var files: std.StringHashMapUnmanaged([]const u8) = .{};
                self.gatherWorkspaceFiles(a, uri, &files);
                var fit = files.iterator();
                while (fit.next()) |e| {
                    const file_uri = pathToUri(a, e.key_ptr.*) orelse continue;
                    appendFileRefs(a, file_uri, e.value_ptr.*, target, include_decl, null, &locs);
                }
            },
        }
        try self.respond(id, locs.items);
    }

    /// Populate `files` (path → source) with every candidate `.rg` file for a
    /// workspace-wide query: all open buffers (they win over disk), then the files
    /// walked from the document's directory and the search roots.
    fn gatherWorkspaceFiles(self: *Server, a: std.mem.Allocator, uri: []const u8, files: *std.StringHashMapUnmanaged([]const u8)) void {
        var it = self.docs.iterator();
        while (it.next()) |e| {
            const path = uriToPath(a, e.key_ptr.*) orelse continue;
            files.put(a, path, e.value_ptr.*) catch {};
        }
        var budget: usize = 4000; // cap files walked, guarding pathological trees
        if (uriToPath(a, uri)) |dp| {
            if (std.fs.path.dirname(dp)) |dir| self.walkRgFiles(a, dir, files, &budget);
        }
        for (self.roots.items) |r| self.walkRgFiles(a, r, files, &budget);
    }

    /// Validate a rename request: reply with the identifier's range + placeholder,
    /// or null when the cursor isn't on a renameable identifier (e.g. a keyword).
    fn onPrepareRename(self: *Server, id: std.json.Value, params: ?std.json.Value) !void {
        const p = params orelse return self.respond(id, @as(?u8, null));
        const uri = self.uriOf(params) orelse return self.respond(id, @as(?u8, null));
        const text = self.docs.get(uri) orelse return self.respond(id, @as(?u8, null));
        const pos = objGet(p, "position") orelse return self.respond(id, @as(?u8, null));
        const line = intField(pos, "line") orelse return self.respond(id, @as(?u8, null));
        const character = intField(pos, "character") orelse return self.respond(id, @as(?u8, null));
        const off = offsetAt(text, @intCast(line), @intCast(character)) orelse return self.respond(id, @as(?u8, null));
        const b = identBoundsAt(text, off) orelse return self.respond(id, @as(?u8, null));
        const name = text[b.start..b.end];
        if (isKeyword(name)) return self.respond(id, @as(?u8, null));
        try self.respond(id, PrepareRename{
            .range = .{ .start = offsetToPos(text, b.start), .end = offsetToPos(text, b.end) },
            .placeholder = name,
        });
    }

    /// Rename the identifier under the cursor to `newName` everywhere in the
    /// workspace: the same whole-word search as find-references, emitted as a
    /// WorkspaceEdit (one TextDocumentEdit per file). Name-based, not scope-aware.
    fn onRename(self: *Server, id: std.json.Value, params: ?std.json.Value) !void {
        const p = params orelse return self.respond(id, @as(?u8, null));
        const uri = self.uriOf(params) orelse return self.respond(id, @as(?u8, null));
        const text = self.docs.get(uri) orelse return self.respond(id, @as(?u8, null));
        const new_name = strField(p, "newName") orelse return self.respond(id, @as(?u8, null));
        const pos = objGet(p, "position") orelse return self.respond(id, @as(?u8, null));
        const line = intField(pos, "line") orelse return self.respond(id, @as(?u8, null));
        const character = intField(pos, "character") orelse return self.respond(id, @as(?u8, null));
        const off = offsetAt(text, @intCast(line), @intCast(character)) orelse return self.respond(id, @as(?u8, null));
        const target = identAt(text, off) orelse return self.respond(id, @as(?u8, null));
        if (isKeyword(target) or !isValidIdent(new_name)) return self.respond(id, @as(?u8, null));

        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();

        var changes: std.ArrayList(TextDocumentEdit) = .empty;
        switch (self.resolveTargetScope(a, text, target, off)) {
            // A local: edit only its scope within the current document.
            .local => |lb| appendFileEdits(a, uri, text, target, new_name, lb, &changes),
            // A module global: edit across the whole workspace.
            .global => {
                var files: std.StringHashMapUnmanaged([]const u8) = .{};
                self.gatherWorkspaceFiles(a, uri, &files);
                var fit = files.iterator();
                while (fit.next()) |e| {
                    const file_uri = pathToUri(a, e.key_ptr.*) orelse continue;
                    appendFileEdits(a, file_uri, e.value_ptr.*, target, new_name, null, &changes);
                }
            },
        }
        try self.respond(id, WorkspaceEdit{ .documentChanges = changes.items });
    }

    /// Add every `.rg` file under `dir_abs` (recursively) to `files`, reading from
    /// disk unless the path is already present (an open buffer). Best-effort: any
    /// error skips the directory. `budget` bounds the number of files added.
    fn walkRgFiles(self: *Server, a: std.mem.Allocator, dir_abs: []const u8, files: *std.StringHashMapUnmanaged([]const u8), budget: *usize) void {
        var dir = Io.Dir.openDirAbsolute(self.io, dir_abs, .{ .iterate = true }) catch return;
        defer dir.close(self.io);
        var walker = dir.walk(a) catch return;
        defer walker.deinit();
        while (walker.next(self.io) catch null) |entry| {
            if (budget.* == 0) return;
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".rg")) continue;
            // Skip generated/vendored trees.
            if (std.mem.indexOf(u8, entry.path, ".zig-cache") != null) continue;
            if (std.mem.indexOf(u8, entry.path, "zig-out") != null) continue;
            if (std.mem.indexOf(u8, entry.path, "node_modules") != null) continue;
            const abs = std.fs.path.join(a, &.{ dir_abs, entry.path }) catch continue;
            if (files.contains(abs)) continue;
            const src = Io.Dir.cwd().readFileAlloc(self.io, abs, a, .limited(16 << 20)) catch continue;
            files.put(a, abs, src) catch continue;
            budget.* -= 1;
        }
    }

    // --- request helpers ---

    fn uriOf(self: *Server, params: ?std.json.Value) ?[]const u8 {
        _ = self;
        const p = params orelse return null;
        const td = objGet(p, "textDocument") orelse return null;
        return strField(td, "uri");
    }

    /// Classify the identifier `target` at byte `offset` in `text`: a local
    /// (bound to the byte span of the innermost enclosing scope that declares it)
    /// or a module global (workspace-wide). Falls back to global if the document
    /// doesn't parse.
    fn resolveTargetScope(self: *Server, a: std.mem.Allocator, text: []const u8, target: []const u8, offset: usize) ScopeResult {
        var tree = parser.parse(self.gpa, text) catch return .global;
        defer tree.deinit();
        if (tree.diagnostics.len > 0) return .global;

        var scopes: std.ArrayList(Scope) = .empty;
        collectScopes(a, tree.module, &scopes) catch return .global;

        var best: ?Bounds = null;
        var best_width: usize = std.math.maxInt(usize);
        for (scopes.items) |s| {
            const start: usize = s.start;
            const end: usize = s.end;
            if (offset >= start and offset < end and s.names.contains(target)) {
                if (end - start < best_width) {
                    best_width = end - start;
                    best = .{ .start = start, .end = end };
                }
            }
        }
        if (best) |b| return .{ .local = b };
        return .global;
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

fn hasImports(module: parser.Module) bool {
    for (module.decls) |d| {
        if (d == .import) return true;
    }
    return false;
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn isUnreservedUriChar(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or
        c == '-' or c == '.' or c == '_' or c == '~';
}

/// Convert a filesystem path to a `file://` URI, percent-encoding as needed.
fn pathToUri(a: std.mem.Allocator, path: []const u8) ?[]u8 {
    var buf: std.ArrayList(u8) = .empty;
    buf.appendSlice(a, "file://") catch return null;
    const hex = "0123456789ABCDEF";
    for (path) |c| {
        if (isUnreservedUriChar(c) or c == '/') {
            buf.append(a, c) catch return null;
        } else {
            buf.append(a, '%') catch return null;
            buf.append(a, hex[c >> 4]) catch return null;
            buf.append(a, hex[c & 0xF]) catch return null;
        }
    }
    return buf.toOwnedSlice(a) catch null;
}

/// The 0-based (line, byte-column) position of `offset` in `text`.
fn offsetToPos(text: []const u8, offset: usize) Pos {
    var line: u32 = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < offset and i < text.len) : (i += 1) {
        if (text[i] == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }
    return .{ .line = line, .character = @intCast(offset - line_start) };
}

/// Collect the byte offset of every whole-word occurrence of `target` in `text`,
/// skipping `##` comments and string literals but *including* identifiers inside
/// `${…}` interpolation holes (which are real references).
fn collectRefs(a: std.mem.Allocator, text: []const u8, target: []const u8, out: *std.ArrayList(usize)) !void {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '#' and i + 1 < text.len and text[i + 1] == '#') {
            while (i < text.len and text[i] != '\n') i += 1;
            continue;
        }
        if (c == '"') {
            i += 1;
            while (i < text.len and text[i] != '"') {
                if (text[i] == '\\') {
                    i += 2;
                    continue;
                }
                if (text[i] == '$' and i + 1 < text.len and text[i + 1] == '{') {
                    i += 2;
                    var depth: usize = 1;
                    while (i < text.len and depth > 0) {
                        const h = text[i];
                        if (h == '{') {
                            depth += 1;
                            i += 1;
                        } else if (h == '}') {
                            depth -= 1;
                            i += 1;
                        } else if (isIdentStart(h)) {
                            const s = i;
                            while (i < text.len and isIdentChar(text[i])) i += 1;
                            if (std.mem.eql(u8, text[s..i], target)) try out.append(a, s);
                        } else i += 1;
                    }
                    continue;
                }
                i += 1;
            }
            if (i < text.len) i += 1; // past the closing quote
            continue;
        }
        if (isIdentStart(c) and (i == 0 or !isIdentChar(text[i - 1]))) {
            const s = i;
            while (i < text.len and isIdentChar(text[i])) i += 1;
            if (std.mem.eql(u8, text[s..i], target)) try out.append(a, s);
            continue;
        }
        i += 1;
    }
}

/// Byte offsets of the *names* of every declaration in `text` (to optionally
/// exclude declarations from references).
fn declNameOffsets(a: std.mem.Allocator, text: []const u8) ![]usize {
    const decls = try scanDecls(a, text);
    var offs: std.ArrayList(usize) = .empty;
    for (decls) |d| {
        if (offsetAt(text, d.line, d.character)) |o| try offs.append(a, o);
    }
    return offs.toOwnedSlice(a);
}

fn inBounds(o: usize, lb: ?Bounds) bool {
    if (lb) |b| return o >= b.start and o < b.end;
    return true;
}

/// Append a `Location` for each occurrence of `target` in `src`, optionally
/// bounded to a byte range (a local's scope) and optionally excluding
/// declaration sites.
fn appendFileRefs(a: std.mem.Allocator, file_uri: []const u8, src: []const u8, target: []const u8, include_decl: bool, lb: ?Bounds, locs: *std.ArrayList(Location)) void {
    var offs: std.ArrayList(usize) = .empty;
    collectRefs(a, src, target, &offs) catch return;
    const decl_offs: ?[]usize = if (include_decl) null else (declNameOffsets(a, src) catch null);
    for (offs.items) |o| {
        if (!inBounds(o, lb)) continue;
        if (decl_offs) |ds| {
            if (std.mem.indexOfScalar(usize, ds, o) != null) continue;
        }
        const ps = offsetToPos(src, o);
        locs.append(a, .{
            .uri = file_uri,
            .range = .{ .start = ps, .end = .{ .line = ps.line, .character = ps.character + @as(u32, @intCast(target.len)) } },
        }) catch {};
    }
}

/// Append a `TextDocumentEdit` renaming every occurrence of `target` in `src` to
/// `new_name`, optionally bounded to a local's scope. No entry if there are none.
fn appendFileEdits(a: std.mem.Allocator, file_uri: []const u8, src: []const u8, target: []const u8, new_name: []const u8, lb: ?Bounds, changes: *std.ArrayList(TextDocumentEdit)) void {
    var offs: std.ArrayList(usize) = .empty;
    collectRefs(a, src, target, &offs) catch return;
    var edits: std.ArrayList(TextEdit) = .empty;
    for (offs.items) |o| {
        if (!inBounds(o, lb)) continue;
        const ps = offsetToPos(src, o);
        edits.append(a, .{
            .range = .{ .start = ps, .end = .{ .line = ps.line, .character = ps.character + @as(u32, @intCast(target.len)) } },
            .newText = new_name,
        }) catch {};
    }
    if (edits.items.len > 0) changes.append(a, .{ .textDocument = .{ .uri = file_uri }, .edits = edits.items }) catch {};
}

/// Convert a `file://` URI to a filesystem path (percent-decoded), or null for a
/// non-file URI. The returned slice is owned by `gpa`.
fn uriToPath(gpa: std.mem.Allocator, uri: []const u8) ?[]u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return null;
    const enc = uri[prefix.len..];
    const buf = gpa.alloc(u8, enc.len) catch return null;
    defer gpa.free(buf);
    var n: usize = 0;
    var i: usize = 0;
    while (i < enc.len) {
        if (enc[i] == '%' and i + 2 < enc.len) {
            const hi = hexVal(enc[i + 1]);
            const lo = hexVal(enc[i + 2]);
            if (hi != null and lo != null) {
                buf[n] = hi.? * 16 + lo.?;
                n += 1;
                i += 3;
                continue;
            }
        }
        buf[n] = enc[i];
        n += 1;
        i += 1;
    }
    return gpa.dupe(u8, buf[0..n]) catch null;
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

    var server = Server{ .gpa = gpa, .io = io, .out = out, .in = &reader.interface };
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

test "uriToPath strips file:// and percent-decodes" {
    const gpa = testing.allocator;
    const p1 = uriToPath(gpa, "file:///Users/x/app.rg").?;
    defer gpa.free(p1);
    try testing.expectEqualStrings("/Users/x/app.rg", p1);

    const p2 = uriToPath(gpa, "file:///a/My%20Code/app.rg").?;
    defer gpa.free(p2);
    try testing.expectEqualStrings("/a/My Code/app.rg", p2);

    try testing.expect(uriToPath(gpa, "untitled:Untitled-1") == null);
}

test "resolveTargetScope separates locals from module globals" {
    var server = Server{ .gpa = testing.allocator, .io = undefined, .out = undefined, .in = undefined };
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "const G = 1\n\nfunc f(n: int) -> int:\n    var x = n\n    return x + G\n";

    const x_off = std.mem.indexOf(u8, text, "var x").? + 4; // the local `x`
    try testing.expect(server.resolveTargetScope(a, text, "x", x_off) != .global);
    const n_off = std.mem.indexOf(u8, text, "f(n").? + 2; // the parameter `n`
    try testing.expect(server.resolveTargetScope(a, text, "n", n_off) != .global);
    const g_off = std.mem.indexOf(u8, text, "G = 1").?; // the module global `G`
    try testing.expect(server.resolveTargetScope(a, text, "G", g_off) == .global);
}

test "computeFoldingRanges folds colon blocks and comment runs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text =
        "## a\n" ++ // 0  comment
        "## b\n" ++ // 1  comment  → comment run 0..1
        "func main():\n" ++ // 2  header
        "    var x = 1\n" ++ // 3  body
        "    if x:\n" ++ // 4  nested header
        "        print(x)\n" ++ // 5  nested body
        "\n" ++ // 6  blank
        "    var y = 2\n"; // 7  still main's body
    var out: std.ArrayList(FoldingRange) = .empty;
    try computeFoldingRanges(a, text, &out);

    var main_ok = false;
    var if_ok = false;
    var comment_ok = false;
    for (out.items) |f| {
        if (f.startLine == 2 and f.endLine == 7 and std.mem.eql(u8, f.kind, "region")) main_ok = true;
        if (f.startLine == 4 and f.endLine == 5 and std.mem.eql(u8, f.kind, "region")) if_ok = true;
        if (f.startLine == 0 and f.endLine == 1 and std.mem.eql(u8, f.kind, "comment")) comment_ok = true;
    }
    try testing.expect(main_ok and if_ok and comment_ok);
    try testing.expectEqual(@as(usize, 3), out.items.len);
}

test "isValidIdent / isKeyword gate rename targets" {
    try testing.expect(isValidIdent("foo"));
    try testing.expect(isValidIdent("_x1"));
    try testing.expect(!isValidIdent("func")); // keyword
    try testing.expect(!isValidIdent("1bad")); // starts with a digit
    try testing.expect(!isValidIdent("a b")); // has a space
    try testing.expect(!isValidIdent("")); // empty
    try testing.expect(isKeyword("class"));
    try testing.expect(!isKeyword("classy"));
}

test "identBoundsAt returns the identifier's byte range" {
    const src = "  foo.bar";
    const b = identBoundsAt(src, 3).?; // inside "foo"
    try testing.expectEqual(@as(usize, 2), b.start);
    try testing.expectEqual(@as(usize, 5), b.end);
    try testing.expectEqualStrings("foo", src[b.start..b.end]);
    try testing.expect(identBoundsAt(src, 0) == null); // whitespace
}

test "collectRefs finds whole-word refs, skipping comments and string text" {
    const a = testing.allocator;
    const text = "foo\nfoobar\n## foo comment\nx = \"foo\"\ny = \"${foo}\"\n";
    var offs: std.ArrayList(usize) = .empty;
    defer offs.deinit(a);
    try collectRefs(a, text, "foo", &offs);
    // A bare `foo` and the one inside a `${…}` hole; not `foobar`, the comment, or string text.
    try testing.expectEqual(@as(usize, 2), offs.items.len);
    try testing.expectEqual(@as(usize, 0), offs.items[0]);
}

test "offsetToPos maps a byte offset to line/character" {
    const text = "ab\ncde\nf";
    const p = offsetToPos(text, 4); // 'd' on line 1
    try testing.expectEqual(@as(u32, 1), p.line);
    try testing.expectEqual(@as(u32, 1), p.character);
}

test "pathToUri percent-encodes and prefixes file://" {
    const a = testing.allocator;
    const u = pathToUri(a, "/a/My Code/x.rg").?;
    defer a.free(u);
    try testing.expectEqualStrings("file:///a/My%20Code/x.rg", u);
}

test "callContext finds the enclosing call and active argument" {
    const src = "    r = add(1, x)";
    const at_x = std.mem.indexOfScalar(u8, src, 'x').?;
    const c = callContext(src, at_x).?;
    try testing.expectEqualStrings("add", c.callee);
    try testing.expect(c.receiver == null);
    try testing.expectEqual(@as(u32, 1), c.active);

    const at_1 = std.mem.indexOfScalar(u8, src, '1').?;
    try testing.expectEqual(@as(u32, 0), callContext(src, at_1 + 1).?.active);

    const c2 = callContext("mod.f(a", 7).?;
    try testing.expectEqualStrings("f", c2.callee);
    try testing.expectEqualStrings("mod", c2.receiver.?);

    try testing.expect(callContext("hello", 5) == null); // not in a call
}

test "signatureFromSource reads types and defaults from the header" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const text = "func add(a: int, b: int = 5) -> int:\n    return a";
    const off = std.mem.indexOf(u8, text, "add").?;
    const s = signatureFromSource(arena.allocator(), text, off, null).?;
    try testing.expectEqualStrings("add(a: int, b: int = 5)", s.label);
    try testing.expectEqual(@as(usize, 2), s.params.len);
    try testing.expectEqualStrings("a: int", s.params[0]);
    try testing.expectEqualStrings("b: int = 5", s.params[1]);
}

test "builtinSignature builds a label from the parameter table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = builtinSignature(arena.allocator(), "reduce").?;
    try testing.expectEqualStrings("reduce(list, f, init)", s.label);
    try testing.expectEqual(@as(usize, 3), s.params.len);
    try testing.expect(builtinSignature(arena.allocator(), "nope") == null);
}

test "receiverBeforeCursor detects member-access context" {
    const src = "    mathlib.sq";
    try testing.expectEqualStrings("mathlib", receiverBeforeCursor(src, src.len).?);
    const dot = std.mem.indexOfScalar(u8, src, '.').? + 1; // right after '.'
    try testing.expectEqualStrings("mathlib", receiverBeforeCursor(src, dot).?);
    try testing.expect(receiverBeforeCursor("hello", 5) == null); // no dot
}

test "importRelPath maps an import's leaf name to a file path" {
    const a = testing.allocator;
    const text = "import util.strutil\n\nfunc main():\n    pass";
    const rel = importRelPath(a, text, "strutil").?;
    defer a.free(rel);
    try testing.expectEqualStrings("util/strutil.rg", rel);
    try testing.expect(importRelPath(a, text, "nope") == null);
}

test "plainCompletions offers keywords, builtins, and declarations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var items: std.ArrayList(CompletionItem) = .empty;
    try Server.plainCompletions(arena.allocator(), "func helper():\n    pass", &items);
    var has_kw = false;
    var has_builtin = false;
    var has_decl = false;
    for (items.items) |it| {
        if (std.mem.eql(u8, it.label, "func")) has_kw = true;
        if (std.mem.eql(u8, it.label, "print")) has_builtin = true;
        if (std.mem.eql(u8, it.label, "helper")) has_decl = true;
    }
    try testing.expect(has_kw and has_builtin and has_decl);
}

test "addRoot dedups and addRootUri decodes file URIs" {
    var server = Server{ .gpa = testing.allocator, .io = undefined, .out = undefined, .in = undefined };
    defer server.deinit();
    try server.addRoot("/a");
    try server.addRoot("/a"); // duplicate: ignored
    try server.addRoot(""); // empty: ignored
    try server.addRoot("/b");
    try server.addRootUri("file:///c/d");
    try server.addRootUri("untitled:x"); // not a file URI: ignored
    try testing.expectEqual(@as(usize, 3), server.roots.items.len);
    try testing.expectEqualStrings("/a", server.roots.items[0]);
    try testing.expectEqualStrings("/b", server.roots.items[1]);
    try testing.expectEqualStrings("/c/d", server.roots.items[2]);
}

test "hasImports detects import declarations" {
    var t1 = try parser.parse(testing.allocator, "func main():\n    pass");
    defer t1.deinit();
    try testing.expect(!hasImports(t1.module));

    var t2 = try parser.parse(testing.allocator, "import foo\n\nfunc main():\n    pass");
    defer t2.deinit();
    try testing.expect(hasImports(t2.module));
}
