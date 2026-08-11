//! RoseGold semantic analyzer.
//! Targets Zig 0.16.0.
//!
//! A combined name-resolution and type-checking pass over the parser's AST.
//! It builds lexical scopes (module, class, function, block) and checks:
//!   * duplicate declarations within the same scope
//!   * references to undefined names
//!   * unknown types in annotations
//!   * type compatibility: variable initializers, `return` values, operator
//!     operands, `if`/`while` conditions, assignments, and call arguments/arity
//!
//! Types are inferred bottom-up for every expression. `unknown` (unresolved)
//! and `any` are compatible with everything, so an earlier error never
//! cascades into a storm of follow-on complaints. A method sees its class's
//! fields and other methods by bare name; module and class members are
//! registered before any body is analyzed, so declarations may refer to one
//! another regardless of order.
//!
//! Not yet done (future work): member-access result types (`x.field` needs the
//! type of `x`), element-typed lists/maps, and inheritance-aware assignability.
//!
//! Diagnostics are self-contained — messages are formatted into the returned
//! arena — so an `Analysis` may outlive the `Tree` it was built from.

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
const BinaryOp = parser.BinaryOp;
const Span = lexer.Span;
const Diagnostic = lexer.Diagnostic;

const Error = std.mem.Allocator.Error;

// --- types -------------------------------------------------------------------

const FuncSig = struct {
    params: []const Type,
    ret: Type,
};

/// An inferred type. `unknown` marks something we couldn't determine (usually
/// downstream of another error) and `any` is an explicit escape hatch; both are
/// compatible with everything so they suppress cascading diagnostics. Lists and
/// maps are opaque for now (element types are not tracked).
const Type = union(enum) {
    unknown,
    any,
    int,
    float,
    str,
    bool,
    void,
    list,
    map,
    named: []const u8,
    func: *const FuncSig,
};

fn tagOf(t: Type) std.meta.Tag(Type) {
    return std.meta.activeTag(t);
}

fn isAnyish(t: Type) bool {
    return switch (tagOf(t)) {
        .any, .unknown => true,
        else => false,
    };
}

fn isNumeric(t: Type) bool {
    return switch (tagOf(t)) {
        .int, .float => true,
        else => false,
    };
}

fn isBoolish(t: Type) bool {
    return switch (tagOf(t)) {
        .bool, .any, .unknown => true,
        else => false,
    };
}

/// Whether a value of type `from` may be used where `to` is expected.
fn assignable(from: Type, to: Type) bool {
    if (isAnyish(from) or isAnyish(to)) return true;
    return switch (from) {
        .int => tagOf(to) == .int or tagOf(to) == .float, // int widens to float
        .float => tagOf(to) == .float,
        .str => tagOf(to) == .str,
        .bool => tagOf(to) == .bool,
        .void => tagOf(to) == .void,
        .list => tagOf(to) == .list,
        .map => tagOf(to) == .map,
        .func => tagOf(to) == .func,
        .named => |n| tagOf(to) == .named and std.mem.eql(u8, n, to.named),
        .any, .unknown => true,
    };
}

fn typeName(t: Type) []const u8 {
    return switch (t) {
        .unknown => "unknown",
        .any => "any",
        .int => "int",
        .float => "float",
        .str => "str",
        .bool => "bool",
        .void => "void",
        .list => "list",
        .map => "map",
        .named => |n| n,
        .func => "function",
    };
}

fn numericResult(lt: Type, rt: Type) Type {
    if (tagOf(lt) == .float or tagOf(rt) == .float) return .float;
    return .int;
}

fn opSymbol(op: BinaryOp) []const u8 {
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

const builtin_types = [_][]const u8{ "int", "float", "str", "bool", "void", "any", "list", "map" };

fn isBuiltinType(name: []const u8) bool {
    for (builtin_types) |t| {
        if (std.mem.eql(u8, t, name)) return true;
    }
    return false;
}

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
    ty: Type,
    span: Span,
};

const Scope = struct {
    parent: ?*Scope,
    symbols: std.StringHashMapUnmanaged(Symbol) = .{},
};

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
    current_ret: ?Type = null,

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

    fn declareIn(self: *Analyzer, scope: *Scope, name: []const u8, kind: SymbolKind, ty: Type, span: Span) Error!void {
        const gop = try scope.symbols.getOrPut(self.arena, name);
        if (gop.found_existing) {
            try self.report(span, "'{s}' is already declared", .{name});
        } else {
            gop.value_ptr.* = .{ .kind = kind, .ty = ty, .span = span };
        }
    }

    fn resolve(self: *Analyzer, name: []const u8) ?Symbol {
        var scope: ?*Scope = self.current;
        while (scope) |s| : (scope = s.parent) {
            if (s.symbols.get(name)) |sym| return sym;
        }
        return null;
    }

    /// Report a reference to an unknown type in an annotation.
    fn checkType(self: *Analyzer, t: TypeRef) Error!void {
        if (isBuiltinType(t.name)) return;
        if (self.module_scope.symbols.get(t.name)) |sym| {
            if (sym.kind == .class or sym.kind == .enum_type) return;
        }
        try self.report(t.span, "unknown type '{s}'", .{t.name});
    }

    /// Map a type annotation to an inferred type (without reporting; use
    /// `checkType` for the existence error).
    fn annotationType(self: *Analyzer, t: TypeRef) Type {
        const n = t.name;
        if (std.mem.eql(u8, n, "int")) return .int;
        if (std.mem.eql(u8, n, "float")) return .float;
        if (std.mem.eql(u8, n, "str")) return .str;
        if (std.mem.eql(u8, n, "bool")) return .bool;
        if (std.mem.eql(u8, n, "void")) return .void;
        if (std.mem.eql(u8, n, "any")) return .any;
        if (std.mem.eql(u8, n, "list")) return .list;
        if (std.mem.eql(u8, n, "map")) return .map;
        if (self.module_scope.symbols.get(n)) |sym| {
            if (sym.kind == .class or sym.kind == .enum_type) return .{ .named = n };
        }
        return .unknown;
    }

    fn funcSig(self: *Analyzer, f: Decl.Func) Error!*const FuncSig {
        const params = try self.arena.alloc(Type, f.params.len);
        for (f.params, 0..) |p, i| params[i] = self.annotationType(p.type);
        const ret: Type = if (f.return_type) |rt| self.annotationType(rt) else .any;
        const sig = try self.arena.create(FuncSig);
        sig.* = .{ .params = params, .ret = ret };
        return sig;
    }

    // --- declarations --------------------------------------------------------

    fn run(self: *Analyzer, module: Module) Error!void {
        // Phase 1a: register every top-level name (so declarations may reference
        // one another regardless of order).
        for (module.decls) |decl| try self.registerTopLevel(decl);
        // Phase 1b: fill in function signatures now that all type names exist.
        for (module.decls) |decl| switch (decl) {
            .func => |f| {
                if (self.module_scope.symbols.getPtr(f.name)) |sym| {
                    sym.ty = .{ .func = try self.funcSig(f) };
                }
            },
            else => {},
        };
        // Phase 2: analyze bodies.
        for (module.decls) |decl| try self.analyzeDecl(decl);
    }

    fn registerTopLevel(self: *Analyzer, decl: Decl) Error!void {
        switch (decl) {
            .import => |x| try self.declareIn(self.module_scope, x.name, .import, .unknown, x.span),
            .var_decl => |x| {
                const ty: Type = if (x.type) |ann| self.annotationType(ann) else .unknown;
                try self.declareIn(self.module_scope, x.name, if (x.is_const) .constant else .variable, ty, x.span);
            },
            .func => |x| try self.declareIn(self.module_scope, x.name, .function, .unknown, x.span),
            .class => |x| try self.declareIn(self.module_scope, x.name, .class, .unknown, x.span),
            .enum_decl => |x| try self.declareIn(self.module_scope, x.name, .enum_type, .unknown, x.span),
        }
    }

    fn analyzeDecl(self: *Analyzer, decl: Decl) Error!void {
        switch (decl) {
            .import => {},
            .var_decl => |x| {
                const ty = try self.checkVarDecl(x);
                if (self.module_scope.symbols.getPtr(x.name)) |sym| sym.ty = ty;
            },
            .func => |x| try self.analyzeFunc(x),
            .class => |x| try self.analyzeClass(x),
            .enum_decl => |x| try self.analyzeEnum(x),
        }
    }

    /// Check a variable's annotation and initializer, returning the type the
    /// name should be bound to. Does not declare the name.
    fn checkVarDecl(self: *Analyzer, x: VarDecl) Error!Type {
        var declared: ?Type = null;
        if (x.type) |ann| {
            try self.checkType(ann);
            declared = self.annotationType(ann);
        }
        var value_ty: ?Type = null;
        if (x.value) |v| value_ty = try self.typeOf(v.*);

        if (declared) |dt| {
            if (value_ty) |vt| {
                if (!assignable(vt, dt)) {
                    try self.report(parser.exprSpan(x.value.?.*), "cannot assign {s} to {s}", .{ typeName(vt), typeName(dt) });
                }
            }
            return dt;
        }
        return value_ty orelse .unknown;
    }

    fn analyzeFunc(self: *Analyzer, f: Decl.Func) Error!void {
        const fn_scope = try self.newScope(self.current);
        for (f.params) |p| {
            try self.checkType(p.type);
            try self.declareIn(fn_scope, p.name, .parameter, self.annotationType(p.type), p.span);
        }
        if (f.return_type) |rt| try self.checkType(rt);

        const saved_scope = self.current;
        const saved_ret = self.current_ret;
        self.current = fn_scope;
        self.current_ret = if (f.return_type) |rt| self.annotationType(rt) else null;
        defer {
            self.current = saved_scope;
            self.current_ret = saved_ret;
        }
        try self.analyzeStmts(f.body);
    }

    fn analyzeClass(self: *Analyzer, c: Decl.Class) Error!void {
        const class_scope = try self.newScope(self.module_scope);

        // Register members first so methods can see fields and each other.
        for (c.members) |m| switch (m) {
            .var_decl => |x| {
                const ty: Type = if (x.type) |ann| self.annotationType(ann) else .unknown;
                try self.declareIn(class_scope, x.name, .field, ty, x.span);
            },
            .func => |x| try self.declareIn(class_scope, x.name, .method, .{ .func = try self.funcSig(x) }, x.span),
            else => {},
        };

        const saved = self.current;
        self.current = class_scope;
        defer self.current = saved;
        for (c.members) |m| switch (m) {
            .var_decl => |x| {
                const ty = try self.checkVarDecl(x);
                if (class_scope.symbols.getPtr(x.name)) |sym| sym.ty = ty;
            },
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
            if (m.value) |v| _ = try self.typeOf(v.*);
        }
    }

    // --- statements ----------------------------------------------------------

    fn analyzeStmts(self: *Analyzer, stmts: []const Stmt) Error!void {
        for (stmts) |s| try self.analyzeStmt(s);
    }

    fn analyzeChildBlock(self: *Analyzer, stmts: []const Stmt) Error!void {
        const child = try self.newScope(self.current);
        const saved = self.current;
        self.current = child;
        defer self.current = saved;
        try self.analyzeStmts(stmts);
    }

    fn checkCondition(self: *Analyzer, cond: *const Expr) Error!void {
        const ct = try self.typeOf(cond.*);
        if (!isBoolish(ct)) {
            try self.report(parser.exprSpan(cond.*), "condition must be bool, got {s}", .{typeName(ct)});
        }
    }

    fn analyzeStmt(self: *Analyzer, stmt: Stmt) Error!void {
        switch (stmt) {
            .var_decl => |x| {
                // Resolve the initializer before binding the name so `var x = x`
                // refers to an outer `x`.
                const ty = try self.checkVarDecl(x);
                try self.declareIn(self.current, x.name, if (x.is_const) .constant else .variable, ty, x.span);
            },
            .return_stmt => |x| try self.checkReturn(x),
            .if_stmt => |x| {
                try self.checkCondition(x.cond);
                try self.analyzeChildBlock(x.then_body);
                for (x.elifs) |e| {
                    try self.checkCondition(e.cond);
                    try self.analyzeChildBlock(e.body);
                }
                if (x.else_body) |eb| try self.analyzeChildBlock(eb);
            },
            .while_stmt => |x| {
                try self.checkCondition(x.cond);
                try self.analyzeChildBlock(x.body);
            },
            .for_stmt => |x| {
                _ = try self.typeOf(x.iter.*);
                const child = try self.newScope(self.current);
                try self.declareIn(child, x.binding, .binding, .unknown, x.span);
                const saved = self.current;
                self.current = child;
                defer self.current = saved;
                try self.analyzeStmts(x.body);
            },
            .assign => |x| {
                const tt = try self.typeOf(x.target.*);
                const vt = try self.typeOf(x.value.*);
                if (!assignable(vt, tt)) {
                    try self.report(x.span, "cannot assign {s} to {s}", .{ typeName(vt), typeName(tt) });
                }
            },
            .expr_stmt => |e| _ = try self.typeOf(e.*),
            .pass => {},
        }
    }

    fn checkReturn(self: *Analyzer, r: Stmt.Return) Error!void {
        const ret = self.current_ret orelse {
            // Function has no declared return type: don't constrain returns.
            if (r.value) |v| _ = try self.typeOf(v.*);
            return;
        };
        if (r.value) |v| {
            const vt = try self.typeOf(v.*);
            if (tagOf(ret) == .void) {
                try self.report(r.span, "returning a value from a function declared to return void", .{});
            } else if (!assignable(vt, ret)) {
                try self.report(r.span, "cannot return {s} from a function returning {s}", .{ typeName(vt), typeName(ret) });
            }
        } else if (!isAnyish(ret) and tagOf(ret) != .void) {
            try self.report(r.span, "expected a return value of type {s}", .{typeName(ret)});
        }
    }

    // --- expressions ---------------------------------------------------------

    fn typeOf(self: *Analyzer, e: Expr) Error!Type {
        return switch (e) {
            .int_literal => .int,
            .float_literal => .float,
            .string_literal => .str,
            .bool_literal => .bool,
            .identifier => |id| blk: {
                if (self.resolve(id.name)) |sym| break :blk sym.ty;
                try self.report(id.span, "undefined name '{s}'", .{id.name});
                break :blk .unknown;
            },
            .unary => |u| try self.typeUnary(u),
            .binary => |b| try self.typeBinary(b),
            .call => |c| try self.typeCall(c),
            .index => |i| try self.typeIndex(i),
            .member => |m| blk: {
                _ = try self.typeOf(m.object.*);
                break :blk .unknown; // member types await real type checking
            },
            .array => |a| blk: {
                for (a.elements) |el| _ = try self.typeOf(el.*);
                break :blk .list;
            },
            .map => |m| blk: {
                for (m.entries) |entry| {
                    _ = try self.typeOf(entry.key.*);
                    _ = try self.typeOf(entry.value.*);
                }
                break :blk .map;
            },
            .match => |m| try self.typeMatch(m),
        };
    }

    fn typeUnary(self: *Analyzer, u: Expr.Unary) Error!Type {
        const ot = try self.typeOf(u.operand.*);
        switch (u.op) {
            .neg => {
                if (!isAnyish(ot) and !isNumeric(ot)) {
                    try self.report(u.span, "unary '-' requires a number, got {s}", .{typeName(ot)});
                    return .unknown;
                }
                return ot;
            },
            .not => {
                if (!isBoolish(ot)) {
                    try self.report(u.span, "'not' requires a bool, got {s}", .{typeName(ot)});
                }
                return .bool;
            },
        }
    }

    fn typeBinary(self: *Analyzer, b: Expr.Binary) Error!Type {
        const lt = try self.typeOf(b.lhs.*);
        const rt = try self.typeOf(b.rhs.*);
        switch (b.op) {
            .add => {
                if (isAnyish(lt) or isAnyish(rt)) return .unknown;
                if (tagOf(lt) == .str and tagOf(rt) == .str) return .str;
                if (isNumeric(lt) and isNumeric(rt)) return numericResult(lt, rt);
                try self.reportOperator(b.span, b.op, lt, rt);
                return .unknown;
            },
            .sub, .mul, .div, .mod => {
                if (isAnyish(lt) or isAnyish(rt)) return .unknown;
                if (isNumeric(lt) and isNumeric(rt)) return numericResult(lt, rt);
                try self.reportOperator(b.span, b.op, lt, rt);
                return .unknown;
            },
            .eq, .ne => {
                if (!(isAnyish(lt) or isAnyish(rt) or assignable(lt, rt) or assignable(rt, lt))) {
                    try self.report(b.span, "cannot compare {s} and {s}", .{ typeName(lt), typeName(rt) });
                }
                return .bool;
            },
            .lt, .le, .gt, .ge => {
                const ok = isAnyish(lt) or isAnyish(rt) or
                    (isNumeric(lt) and isNumeric(rt)) or
                    (tagOf(lt) == .str and tagOf(rt) == .str);
                if (!ok) {
                    try self.report(b.span, "cannot order {s} and {s}", .{ typeName(lt), typeName(rt) });
                }
                return .bool;
            },
            .logical_and, .logical_or => {
                if (!isBoolish(lt) or !isBoolish(rt)) {
                    try self.report(b.span, "'{s}' requires bool operands, got {s} and {s}", .{ opSymbol(b.op), typeName(lt), typeName(rt) });
                }
                return .bool;
            },
        }
    }

    fn reportOperator(self: *Analyzer, span: Span, op: BinaryOp, lt: Type, rt: Type) Error!void {
        try self.report(span, "operator '{s}' cannot be applied to {s} and {s}", .{ opSymbol(op), typeName(lt), typeName(rt) });
    }

    fn typeCall(self: *Analyzer, c: Expr.Call) Error!Type {
        const ct = try self.typeOf(c.callee.*);
        switch (ct) {
            .func => |sig| {
                if (c.args.len != sig.params.len) {
                    try self.report(c.span, "expected {d} argument(s), got {d}", .{ sig.params.len, c.args.len });
                }
                for (c.args, 0..) |arg, i| {
                    const at = try self.typeOf(arg.*);
                    if (i < sig.params.len and !assignable(at, sig.params[i])) {
                        try self.report(parser.exprSpan(arg.*), "argument {d}: cannot pass {s} where {s} is expected", .{ i + 1, typeName(at), typeName(sig.params[i]) });
                    }
                }
                return sig.ret;
            },
            .any, .unknown => {
                for (c.args) |arg| _ = try self.typeOf(arg.*);
                return .unknown;
            },
            else => {
                for (c.args) |arg| _ = try self.typeOf(arg.*);
                try self.report(c.span, "{s} is not callable", .{typeName(ct)});
                return .unknown;
            },
        }
    }

    fn typeIndex(self: *Analyzer, i: Expr.Index) Error!Type {
        const ot = try self.typeOf(i.object.*);
        _ = try self.typeOf(i.index.*);
        return switch (tagOf(ot)) {
            .list, .map, .str, .any, .unknown => .unknown, // element types not tracked yet
            else => blk: {
                try self.report(i.span, "{s} is not indexable", .{typeName(ot)});
                break :blk .unknown;
            },
        };
    }

    fn typeMatch(self: *Analyzer, m: Expr.Match) Error!Type {
        _ = try self.typeOf(m.subject.*);
        for (m.arms) |arm| {
            const child = try self.newScope(self.current);
            switch (arm.pattern) {
                .binding => |b| try self.declareIn(child, b.name, .binding, .unknown, b.span),
                else => {},
            }
            const saved = self.current;
            self.current = child;
            defer self.current = saved;
            _ = try self.typeOf(arm.body.*);
        }
        return .unknown; // arm types are not unified yet
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

fn expectMessageContains(analysis: Analysis, needle: []const u8) !void {
    try testing.expectEqual(@as(usize, 1), analysis.diagnostics.len);
    try testing.expect(std.mem.indexOf(u8, analysis.diagnostics[0].message, needle) != null);
}

// name resolution

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
    try expectMessageContains(analysis, "y");
}

test "duplicate top-level declaration is reported" {
    var analysis = try analyzeSource(testing.allocator, "const a: int = 1\nconst a: int = 2");
    defer analysis.deinit();
    try expectMessageContains(analysis, "already declared");
}

test "duplicate parameter is reported" {
    var analysis = try analyzeSource(testing.allocator, "func f(a: int, a: int):\n    pass");
    defer analysis.deinit();
    try expectMessageContains(analysis, "already declared");
}

test "unknown type in an annotation is reported" {
    var analysis = try analyzeSource(testing.allocator, "func f(x: Widget):\n    pass");
    defer analysis.deinit();
    try expectMessageContains(analysis, "Widget");
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
    const src =
        \\func f(cond: bool):
        \\    if cond:
        \\        var inner: int = 1
        \\    return inner
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try expectMessageContains(analysis, "inner");
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
        try testing.expect(std.mem.indexOf(u8, d.message, "'it'") == null);
        try testing.expect(std.mem.indexOf(u8, d.message, "'n'") == null);
    }
}

test "duplicate enum member is reported" {
    var analysis = try analyzeSource(testing.allocator, "enum E { A, B, A }");
    defer analysis.deinit();
    try expectMessageContains(analysis, "A");
}

// type checking

test "initializer type mismatch is reported" {
    var analysis = try analyzeSource(testing.allocator, "const x: int = \"hi\"");
    defer analysis.deinit();
    try expectMessageContains(analysis, "cannot assign str to int");
}

test "int widens to float on assignment" {
    var analysis = try analyzeSource(testing.allocator, "const x: float = 3");
    defer analysis.deinit();
    try testing.expectEqual(@as(usize, 0), analysis.diagnostics.len);
}

test "float does not narrow to int" {
    var analysis = try analyzeSource(testing.allocator, "const x: int = 3.5");
    defer analysis.deinit();
    try expectMessageContains(analysis, "cannot assign float to int");
}

test "return type mismatch is reported" {
    var analysis = try analyzeSource(testing.allocator, "func f() -> int:\n    return \"no\"");
    defer analysis.deinit();
    try expectMessageContains(analysis, "cannot return str");
}

test "non-bool condition is reported" {
    var analysis = try analyzeSource(testing.allocator, "func f():\n    if 5:\n        pass");
    defer analysis.deinit();
    try expectMessageContains(analysis, "condition must be bool");
}

test "arithmetic on non-numbers is reported" {
    var analysis = try analyzeSource(testing.allocator, "const x: int = true + 1");
    defer analysis.deinit();
    try expectMessageContains(analysis, "'+'");
}

test "logical operator requires bool operands" {
    var analysis = try analyzeSource(testing.allocator, "const b: bool = 1 and 2");
    defer analysis.deinit();
    try expectMessageContains(analysis, "bool operands");
}

test "not on a non-bool is reported" {
    var analysis = try analyzeSource(testing.allocator, "const b: bool = not 5");
    defer analysis.deinit();
    try expectMessageContains(analysis, "'not' requires a bool");
}

test "call arity mismatch is reported" {
    const src =
        \\func g(a: int):
        \\    pass
        \\
        \\func h():
        \\    g()
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try expectMessageContains(analysis, "expected 1 argument");
}

test "call argument type mismatch is reported" {
    const src =
        \\func g(a: int):
        \\    pass
        \\
        \\func h():
        \\    g("x")
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try expectMessageContains(analysis, "argument 1");
}

test "calling a non-function is reported" {
    const src =
        \\const x: int = 1
        \\
        \\func h():
        \\    x()
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try expectMessageContains(analysis, "not callable");
}

test "a well-typed call has no diagnostics" {
    const src =
        \\func g(a: int) -> int:
        \\    return a
        \\
        \\func h() -> int:
        \\    return g(3)
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try testing.expectEqual(@as(usize, 0), analysis.diagnostics.len);
}
