//! A canonical source formatter: re-prints a parsed module in a consistent
//! style (4-space indentation, one space around binary operators, one blank line
//! between top-level declarations). It walks the AST, so precedence-required
//! parentheses are re-inserted but **comments are not preserved** (the AST does
//! not retain them). The CLI therefore prints to stdout rather than rewriting a
//! file in place.

const std = @import("std");
const parser = @import("parser.zig");
const lexer = @import("lexer.zig");

const Decl = parser.Decl;
const Stmt = parser.Stmt;
const Expr = parser.Expr;
const TypeRef = parser.TypeRef;
const Param = parser.Param;
const Pattern = parser.Pattern;
const Visibility = parser.Visibility;
const BinaryOp = parser.BinaryOp;

const Error = std.mem.Allocator.Error;

/// Format `module` into canonical source. `comments` (in source order, from the
/// parse tree) are re-emitted, interleaved by their original line. The caller
/// owns the returned bytes.
pub fn format(gpa: std.mem.Allocator, module: parser.Module, comments: []const lexer.Comment) Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var f = Formatter{ .gpa = gpa, .buf = &buf, .comments = comments };
    try f.module(module);
    try f.emitCommentsBefore(std.math.maxInt(u32)); // flush any trailing comments
    return buf.toOwnedSlice(gpa);
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

fn stmtLine(s: Stmt) u32 {
    return switch (s) {
        .var_decl => |x| x.span.line,
        .return_stmt => |x| x.span.line,
        .if_stmt => |x| x.span.line,
        .while_stmt => |x| x.span.line,
        .for_stmt => |x| x.span.line,
        .assign => |x| x.span.line,
        .expr_stmt => |e| parser.exprSpan(e.*).line,
        .pass => |sp| sp.line,
        .break_stmt => |sp| sp.line,
        .continue_stmt => |sp| sp.line,
    };
}

fn binPrec(op: BinaryOp) u8 {
    return switch (op) {
        .logical_or => 1,
        .logical_and => 2,
        .eq, .ne, .lt, .le, .gt, .ge => 3,
        .add, .sub => 4,
        .mul, .div, .mod => 5,
    };
}

fn opStr(op: BinaryOp) []const u8 {
    return switch (op) {
        .add => "+",
        .sub => "-",
        .mul => "*",
        .div => "/",
        .mod => "%",
        .eq => "==",
        .ne => "!=",
        .lt => "<",
        .le => "<=",
        .gt => ">",
        .ge => ">=",
        .logical_and => "and",
        .logical_or => "or",
    };
}

fn visPrefix(v: Visibility) []const u8 {
    return switch (v) {
        .public => "pub ",
        .private => "private ",
        .default => "",
    };
}

const Formatter = struct {
    gpa: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    indent: u32 = 0,
    comments: []const lexer.Comment = &.{},
    ci: usize = 0,

    /// Emit any pending comments that appear before `line`, at the current
    /// indent, advancing the cursor.
    fn emitCommentsBefore(self: *Formatter, line: u32) Error!void {
        while (self.ci < self.comments.len and self.comments[self.ci].line < line) : (self.ci += 1) {
            try self.pad();
            try self.w(self.comments[self.ci].text);
            try self.nl();
        }
    }

    fn w(self: *Formatter, s: []const u8) Error!void {
        try self.buf.appendSlice(self.gpa, s);
    }

    fn nl(self: *Formatter) Error!void {
        try self.buf.append(self.gpa, '\n');
    }

    fn pad(self: *Formatter) Error!void {
        var i: u32 = 0;
        while (i < self.indent) : (i += 1) try self.w("    ");
    }

    // --- declarations --------------------------------------------------------

    fn module(self: *Formatter, m: parser.Module) Error!void {
        for (m.decls, 0..) |d, i| {
            if (i > 0) try self.nl(); // blank line between top-level declarations
            try self.decl(d);
        }
    }

    fn decl(self: *Formatter, d: Decl) Error!void {
        try self.emitCommentsBefore(declLine(d));
        switch (d) {
            .import => |im| {
                try self.pad();
                try self.w("import ");
                for (im.path, 0..) |seg, i| {
                    if (i > 0) try self.w(".");
                    try self.w(seg);
                }
                try self.nl();
            },
            .var_decl => |v| try self.varDecl(v),
            .func => |f| try self.func(f),
            .class => |c| try self.aggregate("class", c.name, c.visibility, c.extends, c.uses, c.members),
            .struct_decl => |s| try self.aggregate("struct", s.name, s.visibility, null, &.{}, s.members),
            .enum_decl => |e| try self.enumDecl(e),
            .signal => |s| {
                try self.pad();
                try self.w(visPrefix(s.visibility));
                try self.w("signal ");
                try self.w(s.name);
                if (s.params.len > 0) try self.params(s.params);
                try self.nl();
            },
        }
    }

    fn varDecl(self: *Formatter, v: parser.VarDecl) Error!void {
        try self.pad();
        try self.w(visPrefix(v.visibility));
        if (v.is_static) try self.w("static ");
        try self.w(if (v.is_const) "const " else "var ");
        try self.w(v.name);
        if (v.type) |t| {
            try self.w(": ");
            try self.typeRef(t);
        }
        if (v.value) |val| {
            try self.w(" = ");
            try self.expr(val.*);
        }
        try self.nl();
    }

    fn func(self: *Formatter, f: Decl.Func) Error!void {
        try self.pad();
        try self.w(visPrefix(f.visibility));
        if (f.is_static) try self.w("static ");
        try self.w("func ");
        try self.w(f.name);
        try self.params(f.params);
        if (f.return_type) |rt| {
            try self.w(" -> ");
            try self.typeRef(rt);
        }
        try self.w(":");
        try self.nl();
        try self.block(f.body);
    }

    fn aggregate(self: *Formatter, kw: []const u8, name: []const u8, vis: Visibility, extends: ?TypeRef, uses: []const TypeRef, members: []const Decl) Error!void {
        try self.pad();
        try self.w(visPrefix(vis));
        try self.w(kw);
        try self.w(" ");
        try self.w(name);
        if (extends) |base| {
            try self.w(" extends ");
            try self.typeRef(base);
        }
        if (uses.len > 0) {
            try self.w(" uses ");
            for (uses, 0..) |t, i| {
                if (i > 0) try self.w(", ");
                try self.typeRef(t);
            }
        }
        try self.w(":");
        try self.nl();
        self.indent += 1;
        var prev_field = false;
        for (members, 0..) |m, i| {
            const is_field = m == .var_decl;
            // Keep consecutive fields together; otherwise separate with a blank line.
            if (i > 0 and !(is_field and prev_field)) try self.nl();
            try self.decl(m);
            prev_field = is_field;
        }
        self.indent -= 1;
    }

    fn enumDecl(self: *Formatter, e: Decl.Enum) Error!void {
        try self.pad();
        try self.w(visPrefix(e.visibility));
        try self.w("enum ");
        try self.w(e.name);
        try self.w(" { ");
        for (e.members, 0..) |mem, i| {
            if (i > 0) try self.w(", ");
            try self.w(mem.name);
            if (mem.value) |val| {
                try self.w(" = ");
                try self.expr(val.*);
            }
        }
        try self.w(" }");
        try self.nl();
    }

    fn params(self: *Formatter, ps: []const Param) Error!void {
        try self.w("(");
        for (ps, 0..) |p, i| {
            if (i > 0) try self.w(", ");
            try self.w(p.name);
            if (p.type) |t| {
                try self.w(": ");
                try self.typeRef(t);
            }
        }
        try self.w(")");
    }

    fn typeRef(self: *Formatter, t: TypeRef) Error!void {
        if (t.optional) try self.w("?");
        if (t.module) |m| {
            try self.w(m);
            try self.w(".");
        }
        try self.w(t.name);
        if (t.args.len > 0) {
            try self.w("<");
            for (t.args, 0..) |a, i| {
                if (i > 0) try self.w(", ");
                try self.typeRef(a);
            }
            try self.w(">");
        }
    }

    // --- statements ----------------------------------------------------------

    fn block(self: *Formatter, stmts: []const Stmt) Error!void {
        self.indent += 1;
        for (stmts) |s| try self.stmt(s);
        self.indent -= 1;
    }

    fn stmt(self: *Formatter, s: Stmt) Error!void {
        try self.emitCommentsBefore(stmtLine(s));
        switch (s) {
            .var_decl => |v| try self.varDecl(v),
            .return_stmt => |r| {
                try self.pad();
                try self.w("return");
                if (r.value) |v| {
                    try self.w(" ");
                    try self.expr(v.*);
                }
                try self.nl();
            },
            .if_stmt => |x| {
                try self.pad();
                try self.w("if ");
                try self.expr(x.cond.*);
                try self.w(":");
                try self.nl();
                try self.block(x.then_body);
                for (x.elifs) |e| {
                    try self.pad();
                    try self.w("elif ");
                    try self.expr(e.cond.*);
                    try self.w(":");
                    try self.nl();
                    try self.block(e.body);
                }
                if (x.else_body) |eb| {
                    try self.pad();
                    try self.w("else:");
                    try self.nl();
                    try self.block(eb);
                }
            },
            .while_stmt => |x| {
                try self.pad();
                try self.w("while ");
                try self.expr(x.cond.*);
                try self.w(":");
                try self.nl();
                try self.block(x.body);
            },
            .for_stmt => |x| {
                try self.pad();
                try self.w("for ");
                try self.w(x.binding);
                if (x.value_binding) |vb| {
                    try self.w(", ");
                    try self.w(vb);
                }
                try self.w(" in ");
                try self.expr(x.iter.*);
                try self.w(":");
                try self.nl();
                try self.block(x.body);
            },
            .assign => |x| {
                try self.pad();
                try self.expr(x.target.*);
                try self.w(" = ");
                try self.expr(x.value.*);
                try self.nl();
            },
            .expr_stmt => |e| {
                try self.pad();
                try self.expr(e.*);
                try self.nl();
            },
            .pass => try self.keywordLine("pass"),
            .break_stmt => try self.keywordLine("break"),
            .continue_stmt => try self.keywordLine("continue"),
        }
    }

    fn keywordLine(self: *Formatter, kw: []const u8) Error!void {
        try self.pad();
        try self.w(kw);
        try self.nl();
    }

    // --- expressions ---------------------------------------------------------

    fn expr(self: *Formatter, e: Expr) Error!void {
        try self.exprPrec(e, 0);
    }

    /// Print `e`, wrapping it in parentheses if it is a binary expression whose
    /// precedence is below `min_prec`.
    fn exprPrec(self: *Formatter, e: Expr, min_prec: u8) Error!void {
        switch (e) {
            .binary => |b| {
                const p = binPrec(b.op);
                const wrap = p < min_prec;
                if (wrap) try self.w("(");
                try self.exprPrec(b.lhs.*, p);
                try self.w(" ");
                try self.w(opStr(b.op));
                try self.w(" ");
                try self.exprPrec(b.rhs.*, p + 1);
                if (wrap) try self.w(")");
            },
            else => try self.primary(e),
        }
    }

    fn primary(self: *Formatter, e: Expr) Error!void {
        switch (e) {
            .int_literal, .float_literal, .string_literal => |lit| try self.w(lit.text),
            .bool_literal => |b| try self.w(if (b.value) "true" else "false"),
            .nil_literal => try self.w("nil"),
            .identifier => |id| try self.w(id.name),
            .unary => |u| {
                switch (u.op) {
                    .neg => try self.w("-"),
                    .not => try self.w("not "),
                }
                try self.operand(u.operand.*);
            },
            .call => |c| {
                try self.callee(c.callee.*);
                try self.w("(");
                for (c.args, 0..) |arg, i| {
                    if (i > 0) try self.w(", ");
                    try self.expr(arg.*);
                }
                try self.w(")");
            },
            .index => |idx| {
                try self.callee(idx.object.*);
                try self.w("[");
                try self.expr(idx.index.*);
                try self.w("]");
            },
            .member => |m| {
                try self.callee(m.object.*);
                try self.w(".");
                try self.w(m.name);
            },
            .array => |a| {
                try self.w("[");
                for (a.elements, 0..) |el, i| {
                    if (i > 0) try self.w(", ");
                    try self.expr(el.*);
                }
                try self.w("]");
            },
            .map => |m| {
                if (m.entries.len == 0) {
                    try self.w("{}");
                    return;
                }
                try self.w("{");
                for (m.entries, 0..) |entry, i| {
                    if (i > 0) try self.w(", ");
                    try self.expr(entry.key.*);
                    try self.w(": ");
                    try self.expr(entry.value.*);
                }
                try self.w("}");
            },
            .match => |m| try self.matchExpr(m),
            .lambda => |lam| try self.lambda(lam),
            .range => |r| {
                try self.exprPrec(r.start.*, 0);
                try self.w("..");
                try self.exprPrec(r.end.*, 0);
            },
            .interpolation => |x| {
                try self.w("\"");
                for (x.parts) |p| switch (p) {
                    .literal => |lit| try self.w(lit), // raw (still escaped)
                    .expr => |sub| {
                        try self.w("${");
                        try self.expr(sub.*);
                        try self.w("}");
                    },
                };
                try self.w("\"");
            },
            .binary => try self.exprPrec(e, 0), // reached only via a wrapped call
        }
    }

    /// An operand of a unary operator: wrap a binary in parentheses.
    fn operand(self: *Formatter, e: Expr) Error!void {
        if (e == .binary) {
            try self.w("(");
            try self.expr(e);
            try self.w(")");
        } else try self.primary(e);
    }

    /// A callee/object position: wrap anything that isn't a simple postfix chain.
    fn callee(self: *Formatter, e: Expr) Error!void {
        switch (e) {
            .identifier, .call, .index, .member => try self.primary(e),
            else => {
                try self.w("(");
                try self.expr(e);
                try self.w(")");
            },
        }
    }

    fn matchExpr(self: *Formatter, m: Expr.Match) Error!void {
        try self.w("match ");
        try self.expr(m.subject.*);
        try self.w(" {");
        try self.nl();
        self.indent += 1;
        for (m.arms) |arm| {
            try self.pad();
            try self.pattern(arm.pattern);
            try self.w(": ");
            try self.expr(arm.body.*);
            try self.nl();
        }
        self.indent -= 1;
        try self.pad();
        try self.w("}");
    }

    fn pattern(self: *Formatter, p: Pattern) Error!void {
        switch (p) {
            .wildcard => try self.w("_"),
            .int_literal, .float_literal, .string_literal => |lit| try self.w(lit.text),
            .bool_literal => |b| try self.w(if (b.value) "true" else "false"),
            .binding => |id| try self.w(id.name),
            .enum_case => |ec| {
                try self.w(ec.enum_name);
                try self.w(".");
                try self.w(ec.case);
            },
        }
    }

    fn lambda(self: *Formatter, lam: *const Expr.Lambda) Error!void {
        try self.w("func");
        try self.params(lam.params);
        try self.w(":");
        // Single-expression body prints inline; a block form uses an indented block.
        if (lam.body.len == 1 and lam.body[0] == .return_stmt and lam.body[0].return_stmt.value != null) {
            try self.w(" ");
            try self.expr(lam.body[0].return_stmt.value.?.*);
        } else {
            try self.nl();
            try self.block(lam.body);
        }
    }
};

// --- tests -------------------------------------------------------------------

const testing = std.testing;

fn fmt(gpa: std.mem.Allocator, src: []const u8) ![]u8 {
    var tree = try parser.parse(gpa, src);
    defer tree.deinit();
    return format(gpa, tree.module, tree.comments);
}

test "formats a function canonically" {
    const gpa = testing.allocator;
    const out = try fmt(gpa, "func  add(a:int,b:int)->int:\n        return a+b*2");
    defer gpa.free(out);
    try testing.expectEqualStrings("func add(a: int, b: int) -> int:\n    return a + b * 2\n", out);
}

test "re-adds precedence-required parentheses" {
    const gpa = testing.allocator;
    const out = try fmt(gpa, "func main():\n    print((a + b) * c)");
    defer gpa.free(out);
    try testing.expectEqualStrings("func main():\n    print((a + b) * c)\n", out);
}

test "formats a class with fields grouped and methods spaced" {
    const gpa = testing.allocator;
    const out = try fmt(gpa, "class Point extends Base:\n  var x:int=0\n  var y:int=0\n  func sum()->int:\n    return x+y");
    defer gpa.free(out);
    const want =
        "class Point extends Base:\n" ++
        "    var x: int = 0\n" ++
        "    var y: int = 0\n\n" ++
        "    func sum() -> int:\n" ++
        "        return x + y\n";
    try testing.expectEqualStrings(want, out);
}

test "line comments are preserved and re-indented" {
    const gpa = testing.allocator;
    const src =
        \\## a header
        \\func main():
        \\    ## inside the body
        \\    print(1)
    ;
    const out = try fmt(gpa, src);
    defer gpa.free(out);
    const want =
        "## a header\n" ++
        "func main():\n" ++
        "    ## inside the body\n" ++
        "    print(1)\n";
    try testing.expectEqualStrings(want, out);
}

test "formats ranges and an index/value for" {
    const gpa = testing.allocator;
    const out = try fmt(gpa, "func main():\n    for i,x in 0..n:\n        print(i)");
    defer gpa.free(out);
    try testing.expectEqualStrings("func main():\n    for i, x in 0..n:\n        print(i)\n", out);
}

test "formats an interpolated string, spacing holes" {
    const gpa = testing.allocator;
    const out = try fmt(gpa, "func main():\n    print(\"hi ${name}, ${a+b} left\")");
    defer gpa.free(out);
    try testing.expectEqualStrings("func main():\n    print(\"hi ${name}, ${a + b} left\")\n", out);
}

test "formatting is idempotent" {
    const gpa = testing.allocator;
    const src =
        \\import a.b
        \\
        \\enum Color { RED, GREEN, BLUE }
        \\
        \\func main():
        \\    var f = func(n): n * 2
        \\    var xs: list<int> = [1, 2, 3]
        \\    for x in xs:
        \\        print(f(x))
        \\
    ;
    const once = try fmt(gpa, src);
    defer gpa.free(once);
    const twice = try fmt(gpa, once);
    defer gpa.free(twice);
    try testing.expectEqualStrings(once, twice);
}
