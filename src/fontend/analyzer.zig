//! RoseGold semantic analyzer.
//! Targets Zig 0.16.0.
//!
//! A name-resolution pass over the parser's AST. It builds lexical scopes
//! (module, class, function, block) and checks:
//!   * duplicate declarations within the same scope (top-level names, params,
//!     locals, class members, enum members)
//!   * references to undefined names in expressions
//!   * unknown types in annotations (parameters, return types, variables)
//!
//! Names are resolved through the enclosing scope chain, so a method sees its
//! class's fields and other methods by bare name, and any body sees module
//! globals. Type checking proper (type inference / compatibility) and member
//! resolution (`x.field`, which needs the type of `x`) are future work.
//!
//! Diagnostics are self-contained: their messages are formatted into the
//! returned arena, so an `Analysis` may outlive the `Tree` it was built from.

const std = @import("std");
const parser = @import("parser.zig");
const lexer = @import("lexer.zig");

const Module = parser.Module;
const Decl = parser.Decl;
const Stmt = parser.Stmt;
const Expr = parser.Expr;
const Pattern = parser.Pattern;
const TypeRef = parser.TypeRef;
const VarDecl = parser.VarDecl;
const Span = lexer.Span;
const Diagnostic = lexer.Diagnostic;

const Error = std.mem.Allocator.Error;

// --- symbols and scopes ------------------------------------------------------

const SymbolKind = enum {
    import,
    variable,
    constant,
    function,
    class,
    enum_type,
    parameter,
    field,
    method,
    binding,
};

const Symbol = struct {
    kind: SymbolKind,
    span: Span,
};

const Scope = struct {
    parent: ?*Scope,
    symbols: std.StringHashMapUnmanaged(Symbol) = .{},
};

const builtin_types = [_][]const u8{ "int", "float", "str", "bool", "void", "any" };

fn isBuiltinType(name: []const u8) bool {
    for (builtin_types) |t| {
        if (std.mem.eql(u8, t, name)) return true;
    }
    return false;
}

// --- result ------------------------------------------------------------------

pub const Analysis = struct {
    arena: std.heap.ArenaAllocator,
    diagnostics: []const Diagnostic,

    pub fn deinit(self: *Analysis) void {
        self.arena.deinit();
    }
};

pub fn analyze(gpa: std.mem.Allocator, module: Module) Error!Analysis {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;

    const module_scope = try alloc.create(Scope);
    module_scope.* = .{ .parent = null };

    var analyzer = Analyzer{
        .arena = alloc,
        .diagnostics = &diagnostics,
        .current = module_scope,
        .module_scope = module_scope,
    };
    try analyzer.run(module);

    const diags = try diagnostics.toOwnedSlice(alloc);
    return .{ .arena = arena, .diagnostics = diags };
}

// --- analyzer ----------------------------------------------------------------

const Analyzer = struct {
    arena: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
    current: *Scope,
    module_scope: *Scope,

    fn report(self: *Analyzer, span: Span, comptime fmt: []const u8, args: anytype) Error!void {
        const msg = try std.fmt.allocPrint(self.arena, fmt, args);
        try self.diagnostics.append(self.arena, .{
            .message = msg,
            .line = span.line,
            .col = span.col,
        });
    }

    fn newScope(self: *Analyzer, parent: *Scope) Error!*Scope {
        const s = try self.arena.create(Scope);
        s.* = .{ .parent = parent };
        return s;
    }

    fn declareIn(self: *Analyzer, scope: *Scope, name: []const u8, kind: SymbolKind, span: Span) Error!void {
        const gop = try scope.symbols.getOrPut(self.arena, name);
        if (gop.found_existing) {
            try self.report(span, "'{s}' is already declared", .{name});
        } else {
            gop.value_ptr.* = .{ .kind = kind, .span = span };
        }
    }

    fn resolve(self: *Analyzer, name: []const u8) ?Symbol {
        var scope: ?*Scope = self.current;
        while (scope) |s| : (scope = s.parent) {
            if (s.symbols.get(name)) |sym| return sym;
        }
        return null;
    }

    fn checkType(self: *Analyzer, t: TypeRef) Error!void {
        if (isBuiltinType(t.name)) return;
        if (self.module_scope.symbols.get(t.name)) |sym| {
            if (sym.kind == .class or sym.kind == .enum_type) return;
        }
        try self.report(t.span, "unknown type '{s}'", .{t.name});
    }

    // --- declarations --------------------------------------------------------

    fn run(self: *Analyzer, module: Module) Error!void {
        // Phase 1: register every top-level name so declarations may reference
        // one another regardless of order.
        for (module.decls) |decl| try self.declareTopLevel(decl);
        // Phase 2: analyze the bodies.
        for (module.decls) |decl| try self.analyzeDecl(decl);
    }

    fn declareTopLevel(self: *Analyzer, decl: Decl) Error!void {
        switch (decl) {
            .import => |x| try self.declareIn(self.module_scope, x.name, .import, x.span),
            .var_decl => |x| try self.declareIn(self.module_scope, x.name, if (x.is_const) .constant else .variable, x.span),
            .func => |x| try self.declareIn(self.module_scope, x.name, .function, x.span),
            .class => |x| try self.declareIn(self.module_scope, x.name, .class, x.span),
            .enum_decl => |x| try self.declareIn(self.module_scope, x.name, .enum_type, x.span),
        }
    }

    fn analyzeDecl(self: *Analyzer, decl: Decl) Error!void {
        switch (decl) {
            .import => {},
            .var_decl => |x| try self.analyzeVarDeclBody(x),
            .func => |x| try self.analyzeFunc(x),
            .class => |x| try self.analyzeClass(x),
            .enum_decl => |x| try self.analyzeEnum(x),
        }
    }

    /// Check a variable's type annotation and initializer. Does not declare the
    /// name — the caller decides whether/where it is bound.
    fn analyzeVarDeclBody(self: *Analyzer, x: VarDecl) Error!void {
        if (x.type) |t| try self.checkType(t);
        if (x.value) |v| try self.analyzeExpr(v.*);
    }

    fn analyzeFunc(self: *Analyzer, f: Decl.Func) Error!void {
        const fn_scope = try self.newScope(self.current);
        for (f.params) |p| {
            try self.checkType(p.type);
            try self.declareIn(fn_scope, p.name, .parameter, p.span);
        }
        if (f.return_type) |rt| try self.checkType(rt);

        const saved = self.current;
        self.current = fn_scope;
        defer self.current = saved;
        try self.analyzeStmts(f.body);
    }

    fn analyzeClass(self: *Analyzer, c: Decl.Class) Error!void {
        const class_scope = try self.newScope(self.module_scope);

        // Phase 1: register members so methods can see fields and each other.
        for (c.members) |m| switch (m) {
            .var_decl => |x| try self.declareIn(class_scope, x.name, .field, x.span),
            .func => |x| try self.declareIn(class_scope, x.name, .method, x.span),
            else => {},
        };

        // Phase 2: analyze member bodies with the class scope in the chain.
        const saved = self.current;
        self.current = class_scope;
        defer self.current = saved;
        for (c.members) |m| switch (m) {
            .var_decl => |x| try self.analyzeVarDeclBody(x),
            .func => |x| try self.analyzeFunc(x),
            else => {},
        };
    }

    fn analyzeEnum(self: *Analyzer, e: Decl.Enum) Error!void {
        var seen: std.StringHashMapUnmanaged(void) = .{};
        for (e.members) |m| {
            const gop = try seen.getOrPut(self.arena, m.name);
            if (gop.found_existing) {
                try self.report(m.span, "duplicate enum member '{s}'", .{m.name});
            }
            if (m.value) |v| try self.analyzeExpr(v.*);
        }
    }

    // --- statements ----------------------------------------------------------

    fn analyzeStmts(self: *Analyzer, stmts: []const Stmt) Error!void {
        for (stmts) |s| try self.analyzeStmt(s);
    }

    /// Analyze a nested block (if/while/for body) in a fresh child scope.
    fn analyzeChildBlock(self: *Analyzer, stmts: []const Stmt) Error!void {
        const child = try self.newScope(self.current);
        const saved = self.current;
        self.current = child;
        defer self.current = saved;
        try self.analyzeStmts(stmts);
    }

    fn analyzeStmt(self: *Analyzer, stmt: Stmt) Error!void {
        switch (stmt) {
            .var_decl => |x| {
                // Resolve the initializer before binding the name, so `var x = x`
                // refers to an outer `x` rather than itself.
                try self.analyzeVarDeclBody(x);
                try self.declareIn(self.current, x.name, if (x.is_const) .constant else .variable, x.span);
            },
            .return_stmt => |x| {
                if (x.value) |v| try self.analyzeExpr(v.*);
            },
            .if_stmt => |x| {
                try self.analyzeExpr(x.cond.*);
                try self.analyzeChildBlock(x.then_body);
                for (x.elifs) |e| {
                    try self.analyzeExpr(e.cond.*);
                    try self.analyzeChildBlock(e.body);
                }
                if (x.else_body) |eb| try self.analyzeChildBlock(eb);
            },
            .while_stmt => |x| {
                try self.analyzeExpr(x.cond.*);
                try self.analyzeChildBlock(x.body);
            },
            .for_stmt => |x| {
                try self.analyzeExpr(x.iter.*);
                const child = try self.newScope(self.current);
                try self.declareIn(child, x.binding, .binding, x.span);
                const saved = self.current;
                self.current = child;
                defer self.current = saved;
                try self.analyzeStmts(x.body);
            },
            .assign => |x| {
                try self.analyzeExpr(x.target.*);
                try self.analyzeExpr(x.value.*);
            },
            .expr_stmt => |e| try self.analyzeExpr(e.*),
            .pass => {},
        }
    }

    // --- expressions ---------------------------------------------------------

    fn analyzeExpr(self: *Analyzer, e: Expr) Error!void {
        switch (e) {
            .int_literal, .float_literal, .string_literal, .bool_literal => {},
            .identifier => |id| {
                if (self.resolve(id.name) == null) {
                    try self.report(id.span, "undefined name '{s}'", .{id.name});
                }
            },
            .unary => |u| try self.analyzeExpr(u.operand.*),
            .binary => |b| {
                try self.analyzeExpr(b.lhs.*);
                try self.analyzeExpr(b.rhs.*);
            },
            .call => |c| {
                try self.analyzeExpr(c.callee.*);
                for (c.args) |arg| try self.analyzeExpr(arg.*);
            },
            .index => |i| {
                try self.analyzeExpr(i.object.*);
                try self.analyzeExpr(i.index.*);
            },
            // Only the object is resolvable without type information; the member
            // name is checked once type checking exists.
            .member => |m| try self.analyzeExpr(m.object.*),
            .array => |a| {
                for (a.elements) |el| try self.analyzeExpr(el.*);
            },
            .map => |m| {
                for (m.entries) |entry| {
                    try self.analyzeExpr(entry.key.*);
                    try self.analyzeExpr(entry.value.*);
                }
            },
            .match => |m| {
                try self.analyzeExpr(m.subject.*);
                for (m.arms) |arm| {
                    const child = try self.newScope(self.current);
                    switch (arm.pattern) {
                        .binding => |b| try self.declareIn(child, b.name, .binding, b.span),
                        else => {},
                    }
                    const saved = self.current;
                    self.current = child;
                    defer self.current = saved;
                    try self.analyzeExpr(arm.body.*);
                }
            },
        }
    }
};

// --- tests -------------------------------------------------------------------

const testing = std.testing;

/// Parse and analyze `src`, returning the analysis. The parse tree is freed
/// before returning; analyzer diagnostics are self-contained, so this is safe.
fn analyzeSource(gpa: std.mem.Allocator, src: []const u8) !Analysis {
    var tree = try parser.parse(gpa, src);
    defer tree.deinit();
    return analyze(gpa, tree.module);
}

test "a well-formed program has no diagnostics" {
    const src =
        \\const LIMIT: int = 10
        \\
        \\pub func clamp(value: int) -> int:
        \\    if value > LIMIT:
        \\        return LIMIT
        \\    return value
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();

    try testing.expectEqual(@as(usize, 0), analysis.diagnostics.len);
}

test "undefined name is reported with its name" {
    var analysis = try analyzeSource(testing.allocator, "const x: int = y");
    defer analysis.deinit();

    try testing.expectEqual(@as(usize, 1), analysis.diagnostics.len);
    try testing.expect(std.mem.indexOf(u8, analysis.diagnostics[0].message, "y") != null);
}

test "duplicate top-level declaration is reported" {
    var analysis = try analyzeSource(testing.allocator, "const a: int = 1\nconst a: int = 2");
    defer analysis.deinit();

    try testing.expectEqual(@as(usize, 1), analysis.diagnostics.len);
    try testing.expect(std.mem.indexOf(u8, analysis.diagnostics[0].message, "already declared") != null);
}

test "duplicate parameter is reported" {
    var analysis = try analyzeSource(testing.allocator, "func f(a: int, a: int):\n    pass");
    defer analysis.deinit();

    try testing.expectEqual(@as(usize, 1), analysis.diagnostics.len);
    try testing.expect(std.mem.indexOf(u8, analysis.diagnostics[0].message, "already declared") != null);
}

test "unknown type in an annotation is reported" {
    var analysis = try analyzeSource(testing.allocator, "func f(x: Widget):\n    pass");
    defer analysis.deinit();

    try testing.expectEqual(@as(usize, 1), analysis.diagnostics.len);
    try testing.expect(std.mem.indexOf(u8, analysis.diagnostics[0].message, "Widget") != null);
}

test "a declared class is a valid type" {
    const src =
        \\class Widget:
        \\    var size: int = 0
        \\
        \\func make(w: Widget):
        \\    pass
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();

    try testing.expectEqual(@as(usize, 0), analysis.diagnostics.len);
}

test "a method sees its class fields by bare name" {
    const src =
        \\class Counter:
        \\    var count: int = 0
        \\
        \\    func bump() -> int:
        \\        return count
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();

    try testing.expectEqual(@as(usize, 0), analysis.diagnostics.len);
}

test "a local does not leak out of its block" {
    // `inner` is declared inside the if-body and referenced after it.
    const src =
        \\func f(cond: bool):
        \\    if cond:
        \\        var inner: int = 1
        \\    return inner
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();

    try testing.expectEqual(@as(usize, 1), analysis.diagnostics.len);
    try testing.expect(std.mem.indexOf(u8, analysis.diagnostics[0].message, "inner") != null);
}

test "functions may reference each other regardless of order" {
    const src =
        \\func a() -> int:
        \\    return b()
        \\
        \\func b() -> int:
        \\    return a()
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();

    try testing.expectEqual(@as(usize, 0), analysis.diagnostics.len);
}

test "for binding and match binding are in scope in their bodies" {
    const src =
        \\func run(items: any):
        \\    for it in items {
        \\        echo(it)
        \\    }
        \\
        \\func classify(x: int) -> str:
        \\    return match x {
        \\        n: describe(n)
        \\    }
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();

    // `echo` and `describe` are undefined; `it` and `n` must resolve.
    try testing.expectEqual(@as(usize, 2), analysis.diagnostics.len);
    for (analysis.diagnostics) |d| {
        try testing.expect(std.mem.indexOf(u8, d.message, "it") == null);
        try testing.expect(std.mem.indexOf(u8, d.message, "'n'") == null);
    }
}

test "duplicate enum member is reported" {
    var analysis = try analyzeSource(testing.allocator, "enum E { A, B, A }");
    defer analysis.deinit();

    try testing.expectEqual(@as(usize, 1), analysis.diagnostics.len);
    try testing.expect(std.mem.indexOf(u8, analysis.diagnostics[0].message, "A") != null);
}
