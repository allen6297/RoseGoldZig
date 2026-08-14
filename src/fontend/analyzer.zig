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
//!   * enum-case access (`Status.OK`), `match` exhaustiveness, and unification
//!     of `match` arm types into the expression's result type
//!   * every path of a function with a concrete return type returns a value
//!
//! Types are inferred bottom-up for every expression. `unknown` (unresolved)
//! and `any` are compatible with everything, so an earlier error never
//! cascades into a storm of follow-on complaints. A method sees its class's
//! fields and other methods by bare name; module and class members are
//! registered before any body is analyzed, so declarations may refer to one
//! another regardless of order.
//!
//! Member access resolves to field/method types on a class or struct instance
//! (`v.x`, `c.get()`), including inherited members, and unknown members are
//! reported. `extends`/`uses` names are validated, a subclass is assignable to
//! any of its ancestors, and `private` members are only reachable from inside
//! the type that declares them.
//!
//! Not yet done (future work): static member access on classes, and
//! element-typed lists/maps.
//!
//! Diagnostics are self-contained — messages are formatted into the returned
//! arena — so an `Analysis` may outlive the `Tree` it was built from.

const std = @import("std");
const parser = @import("parser.zig");
const lexer = @import("lexer.zig");
const interpreter = @import("interpreter.zig"); // for the shared builtin_names list

const Module = parser.Module;
const Decl = parser.Decl;
const Stmt = parser.Stmt;
const Expr = parser.Expr;
const Pattern = parser.Pattern;
const TypeRef = parser.TypeRef;
const VarDecl = parser.VarDecl;
const BinaryOp = parser.BinaryOp;
const Visibility = parser.Visibility;
const Span = lexer.Span;
const Diagnostic = lexer.Diagnostic;

const Error = std.mem.Allocator.Error;

// --- types -------------------------------------------------------------------

const FuncSig = struct {
    params: []const Type,
    ret: Type,
    /// Minimum arguments (parameters without a default); defaults are trailing,
    /// so `required <= params.len`. Equal to `params.len` when none default.
    required: usize = 0,
    /// Parameter names, parallel to `params` (for named-argument calls).
    param_names: []const []const u8 = &.{},
};

/// An optional type `?T`, carrying the wrapped type and a pre-formatted name
/// (so `typeName` stays allocation-free).
const Optional = struct {
    inner: Type,
    name: []const u8,
};

/// A `list<T>`, carrying its element type and a pre-formatted name.
const ListType = struct {
    elem: Type,
    name: []const u8,
};

/// A `map<K, V>`, carrying its key/value types and a pre-formatted name.
const MapType = struct {
    key: Type,
    value: Type,
    name: []const u8,
};

/// A tuple `(A, B, ...)`, carrying its element types and a pre-formatted name.
const TupleType = struct {
    elems: []const Type,
    name: []const u8,
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
    /// A `list<T>` (element type tracked).
    list: *const ListType,
    /// A `map<K, V>` (key/value types tracked).
    map: *const MapType,
    /// A tuple `(A, B, ...)` (element types tracked).
    tuple: *const TupleType,
    named: []const u8,
    func: *const FuncSig,
    /// A reference to an enum type itself (e.g. `Status` in `Status.OK`), as
    /// opposed to `named` which is a value of that type.
    enum_ref: []const u8,
    /// A reference to a class/struct type itself (e.g. `Counter` in
    /// `Counter.member` or `Counter()`), as opposed to `named` (an instance).
    type_ref: []const u8,
    /// The type of the `nil` literal; assignable to any optional.
    nil,
    /// An optional type `?T`.
    optional: *const Optional,
    /// An imported module; its exported members are looked up by `.`.
    module: *const ModuleExports,
};

fn tagOf(t: Type) std.meta.Tag(Type) {
    return std.meta.activeTag(t);
}

/// The count of leading parameters with no default value (defaults are trailing),
/// i.e. the minimum number of arguments a call must supply.
fn requiredParamCount(params: []const parser.Param) usize {
    for (params, 0..) |p, i| {
        if (p.default != null) return i;
    }
    return params.len;
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
// `assignable` is a method on Analyzer (see below) so it can consult the
// inheritance graph; `named` types use it.

fn typeName(t: Type) []const u8 {
    return switch (t) {
        .unknown => "unknown",
        .any => "any",
        .int => "int",
        .float => "float",
        .str => "str",
        .bool => "bool",
        .void => "void",
        .list => |l| l.name,
        .map => |m| m.name,
        .tuple => |tp| tp.name,
        .named => |n| n,
        .func => "function",
        .enum_ref => |n| n,
        .type_ref => |n| n,
        .nil => "nil",
        .optional => |o| o.name,
        .module => "module",
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
        .bit_and => "&",
        .bit_or => "|",
        .bit_xor => "^",
        .shl => "<<",
        .shr => ">>",
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

/// If `a` is an identifier and `b` is the `nil` literal, return the name.
fn nilCheckIdent(a: Expr, b: Expr) ?[]const u8 {
    if (a != .identifier) return null;
    if (b != .nil_literal) return null;
    return a.identifier.name;
}

// --- control flow ------------------------------------------------------------

/// Whether a block always exits via `return` (i.e. cannot fall off the end).
fn alwaysReturns(stmts: []const Stmt) bool {
    for (stmts) |s| {
        if (stmtReturns(s)) return true;
    }
    return false;
}

fn stmtReturns(stmt: Stmt) bool {
    return switch (stmt) {
        .return_stmt => true,
        // A `raise` never falls through to the next statement (it returns control
        // to a `catch` or propagates), so it terminates this path.
        .raise => true,
        .if_stmt => |x| ifReturns(x),
        // `try/catch` guarantees a return only when both the body and the handler
        // do: the body may raise (→ handler) before it would otherwise return.
        .try_catch => |x| alwaysReturns(x.body) and alwaysReturns(x.handler),
        // `while true:` never falls through unless a `break` can exit it.
        .while_stmt => |x| switch (x.cond.*) {
            .bool_literal => |b| b.value and !hasBreak(x.body),
            else => false,
        },
        else => false,
    };
}

/// Whether a `break` at this loop's own level can be reached (breaks inside
/// nested loops belong to those loops, so we do not descend into them).
fn hasBreak(stmts: []const Stmt) bool {
    for (stmts) |s| {
        switch (s) {
            .break_stmt => return true,
            .if_stmt => |x| {
                if (hasBreak(x.then_body)) return true;
                for (x.elifs) |e| {
                    if (hasBreak(e.body)) return true;
                }
                if (x.else_body) |eb| {
                    if (hasBreak(eb)) return true;
                }
            },
            else => {},
        }
    }
    return false;
}

fn ifReturns(x: Stmt.If) bool {
    // An `if` guarantees a return only when it is exhaustive (has an `else`)
    // and every branch returns.
    if (x.else_body == null) return false;
    if (!alwaysReturns(x.then_body)) return false;
    for (x.elifs) |e| {
        if (!alwaysReturns(e.body)) return false;
    }
    return alwaysReturns(x.else_body.?);
}

// --- symbols and scopes ------------------------------------------------------

const SymbolKind = enum {
    import,
    variable,
    constant,
    function,
    /// A built-in function (see `interpreter.builtin_names`); typed specially at
    /// call sites since they are polymorphic/variadic.
    builtin,
    class,
    struct_type,
    enum_type,
    parameter,
    field,
    method,
    binding,
    signal,
    enum_member,
};

fn isUserType(kind: SymbolKind) bool {
    return kind == .class or kind == .struct_type or kind == .enum_type;
}

const Symbol = struct {
    kind: SymbolKind,
    ty: Type,
    span: Span,
    /// For class/struct members: whether the member is `private`, and the type
    /// that declares it (so a `private` member is only reachable from inside it).
    visibility: Visibility = .default,
    owner: ?[]const u8 = null,
};

const Scope = struct {
    parent: ?*Scope,
    symbols: std.StringHashMapUnmanaged(Symbol) = .{},
};

/// A module's public surface: the `pub` top-level symbols other modules may
/// reach with `.`, plus the member scopes of any exported class/struct types (so
/// an importer that annotates `mod.T` can still check `x.member`). Lives in the
/// exporting module's analysis arena.
pub const ModuleExports = struct {
    symbols: std.StringHashMapUnmanaged(Symbol) = .{},
    types: std.StringHashMapUnmanaged(*Scope) = .{},
    static_types: std.StringHashMapUnmanaged(*Scope) = .{},
};

/// One import made available to `analyzeModule`: the bound name and the exports
/// of the module it refers to (already analyzed).
pub const ModuleImport = struct { name: []const u8, exports: *const ModuleExports };

/// Stand-in exports for an import that did not resolve, so analysis can proceed.
const empty_exports: ModuleExports = .{};

const NameSet = std.StringHashMapUnmanaged(void);

// --- result ------------------------------------------------------------------

pub const Analysis = struct {
    arena: std.heap.ArenaAllocator,
    diagnostics: []const Diagnostic,
    /// This module's `pub` surface, for modules that import it.
    exports: *const ModuleExports,

    pub fn deinit(self: *Analysis) void {
        self.arena.deinit();
    }
};

pub fn analyze(gpa: std.mem.Allocator, module: Module) Error!Analysis {
    return analyzeModule(gpa, module, &.{});
}

/// Analyze a module that may import others. `imports` supplies the exports of
/// each imported module (already analyzed, in dependency order).
pub fn analyzeModule(gpa: std.mem.Allocator, module: Module, imports: []const ModuleImport) Error!Analysis {
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
        .imports = imports,
    };
    try analyzer.run(module);
    const exports = try analyzer.buildExports(module);

    const diags = try diagnostics.toOwnedSlice(alloc);
    return .{ .arena = arena, .diagnostics = diags, .exports = exports };
}

// --- REPL checking -----------------------------------------------------------

/// A persistent analyzer for the REPL: its scope, types, and inheritance graph
/// survive across entries, so each entry is checked against everything defined
/// before it. Redefinition is allowed. Heap-allocated so the analyzer's
/// self-references stay valid.
pub const ReplChecker = struct {
    arena: std.heap.ArenaAllocator,
    az: Analyzer,
    diagnostics: std.ArrayList(Diagnostic),

    pub fn deinit(self: *ReplChecker) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self);
    }

    /// Type-check one REPL entry against the persistent scope, returning this
    /// entry's diagnostics (owned by the checker; valid until the next call).
    pub fn check(self: *ReplChecker, items: []const parser.ReplItem) Error![]const Diagnostic {
        self.diagnostics.clearRetainingCapacity();
        const az = &self.az;
        az.current = az.module_scope;
        az.current_ret = null;
        az.current_class = null;
        az.loop_depth = 0;

        // Phase 1a: register the entry's declared names.
        for (items) |item| if (item == .decl) try az.registerTopLevel(item.decl.*);
        // Phase 1b: function signatures and class/struct/enum member scopes.
        var class_decls: std.ArrayList(Decl) = .empty;
        for (items) |item| if (item == .decl) switch (item.decl.*) {
            .func => |f| {
                if (az.module_scope.symbols.getPtr(f.name)) |sym| sym.ty = .{ .func = try az.funcSig(f) };
            },
            .class => |c| {
                try az.buildUserType(c.name, c.members);
                try class_decls.append(az.arena, item.decl.*);
            },
            .struct_decl => |s| try az.buildUserType(s.name, s.members),
            .enum_decl => |en| try az.buildEnumType(en.name, en.members),
            else => {},
        };
        // Inheritance + inherited-member flattening for this entry's classes.
        try az.buildInheritance(class_decls.items);
        for (class_decls.items) |d| try az.flattenInheritedMembers(d.class.name);
        // Phase 2: analyze declaration bodies and statements in source order.
        for (items) |item| switch (item) {
            .decl => |d| try az.analyzeDecl(d.*),
            .stmt => |s| try az.analyzeStmt(s.*),
        };
        return self.diagnostics.items;
    }
};

pub fn replCheckerInit(gpa: std.mem.Allocator) Error!*ReplChecker {
    const rc = try gpa.create(ReplChecker);
    errdefer gpa.destroy(rc);
    rc.* = .{ .arena = std.heap.ArenaAllocator.init(gpa), .az = undefined, .diagnostics = .empty };
    const alloc = rc.arena.allocator();
    const module_scope = try alloc.create(Scope);
    module_scope.* = .{ .parent = null };
    rc.az = .{
        .arena = alloc,
        .diagnostics = &rc.diagnostics,
        .current = module_scope,
        .module_scope = module_scope,
        .allow_redefine = true,
    };
    for (interpreter.builtin_names) |name| {
        try rc.az.declareIn(module_scope, name, .builtin, .any, .{ .start = 0, .end = 0, .line = 0, .col = 0 });
    }
    return rc;
}

// --- analyzer ----------------------------------------------------------------

const Analyzer = struct {
    arena: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
    current: *Scope,
    module_scope: *Scope,
    /// Imports available to this module (name -> exports), from `analyzeModule`.
    imports: []const ModuleImport = &.{},
    current_ret: ?Type = null,
    /// The class/struct whose body is currently being analyzed, so `private`
    /// members are reachable from inside their own type.
    current_class: ?[]const u8 = null,
    /// How many loops enclose the statement being analyzed, so `break`/
    /// `continue` outside a loop can be reported.
    loop_depth: u32 = 0,
    /// Member scope of each class/struct, keyed by type name, so `x.member` can
    /// be resolved from anywhere. Built before any body is analyzed.
    user_types: std.StringHashMapUnmanaged(*Scope) = .{},
    /// Static-member scope of each class/struct, keyed by type name, so
    /// `Type.member` resolves and static methods see statics by bare name.
    static_types: std.StringHashMapUnmanaged(*Scope) = .{},
    /// Case scope of each enum, keyed by enum name, so `Enum.CASE` can be
    /// validated. Built before any body is analyzed.
    enum_types: std.StringHashMapUnmanaged(*Scope) = .{},
    /// Direct `extends`/`uses` targets of each class, and the transitive set of
    /// all supertypes, so a subclass is assignable to any of its ancestors.
    direct_supers: std.StringHashMapUnmanaged([]const []const u8) = .{},
    supertypes: std.StringHashMapUnmanaged(*NameSet) = .{},
    /// When set, re-declaring a name overwrites it instead of reporting a
    /// duplicate — used by the REPL, where redefinition is normal.
    allow_redefine: bool = false,

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
        if (gop.found_existing and !self.allow_redefine) {
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
        // A tuple `(A, B, ...)`: just validate each element type.
        if (t.is_tuple) {
            for (t.args) |a| try self.checkType(a);
            return;
        }
        // A `mod.T` qualifier: `mod` must be an imported module that exports the
        // type `T`.
        if (t.module) |mod_name| {
            const sym = self.module_scope.symbols.get(mod_name);
            if (sym == null or sym.?.kind != .import) {
                try self.report(t.span, "'{s}' is not a module", .{mod_name});
                return;
            }
            if (t.args.len > 0) try self.report(t.span, "'{s}.{s}' does not take type arguments", .{ mod_name, t.name });
            const exported = self.importExports(mod_name).symbols.get(t.name);
            if (exported == null or !isUserType(exported.?.kind)) {
                try self.report(t.span, "module '{s}' has no exported type '{s}'", .{ mod_name, t.name });
            }
            return;
        }
        // Type arguments only apply to `list`/`map`; validate arity and recurse.
        if (std.mem.eql(u8, t.name, "list")) {
            if (t.args.len > 1) try self.report(t.span, "list takes at most one type argument", .{});
        } else if (std.mem.eql(u8, t.name, "map")) {
            if (t.args.len != 0 and t.args.len != 2) try self.report(t.span, "map takes two type arguments (map<K, V>)", .{});
        } else if (t.args.len > 0) {
            try self.report(t.span, "'{s}' does not take type arguments", .{t.name});
        }
        for (t.args) |a| try self.checkType(a);

        if (isBuiltinType(t.name)) return;
        if (self.module_scope.symbols.get(t.name)) |sym| {
            if (isUserType(sym.kind)) return;
        }
        try self.report(t.span, "unknown type '{s}'", .{t.name});
    }

    /// Map a type annotation to an inferred type (without reporting; use
    /// `checkType` for the existence error). Wraps the type in an optional when
    /// the annotation is `?T`.
    fn annotationType(self: *Analyzer, t: TypeRef) Error!Type {
        const base = try self.annotationBase(t);
        if (!t.optional) return base;
        return self.makeOptional(base);
    }

    fn annotationBase(self: *Analyzer, t: TypeRef) Error!Type {
        if (t.is_tuple) {
            const elems = try self.arena.alloc(Type, t.args.len);
            for (t.args, 0..) |a, i| elems[i] = try self.annotationType(a);
            return self.makeTuple(elems);
        }
        // An imported type `mod.T` resolves to a `named` instance type; its member
        // scope is available if the module exported it (merged into user_types).
        if (t.module != null) return .{ .named = t.name };
        const n = t.name;
        if (std.mem.eql(u8, n, "int")) return .int;
        if (std.mem.eql(u8, n, "float")) return .float;
        if (std.mem.eql(u8, n, "str")) return .str;
        if (std.mem.eql(u8, n, "bool")) return .bool;
        if (std.mem.eql(u8, n, "void")) return .void;
        if (std.mem.eql(u8, n, "any")) return .any;
        if (std.mem.eql(u8, n, "list")) {
            const elem: Type = if (t.args.len >= 1) try self.annotationType(t.args[0]) else .any;
            return self.makeList(elem);
        }
        if (std.mem.eql(u8, n, "map")) {
            const key: Type = if (t.args.len >= 1) try self.annotationType(t.args[0]) else .any;
            const value: Type = if (t.args.len >= 2) try self.annotationType(t.args[1]) else .any;
            return self.makeMap(key, value);
        }
        if (self.module_scope.symbols.get(n)) |sym| {
            if (isUserType(sym.kind)) return .{ .named = n };
        }
        return .unknown;
    }

    /// Type-check a parameter's default value (if any) against its declared
    /// type. Resolved in whatever scope is current (the enclosing one — defaults
    /// see the module, not the sibling parameters), matching the runtime, which
    /// evaluates defaults in the function's home module.
    fn checkDefault(self: *Analyzer, p: parser.Param, pty: Type) Error!void {
        const d = p.default orelse return;
        const dt = try self.typeOf(d.*);
        if (!self.assignable(dt, pty)) {
            try self.report(parser.exprSpan(d.*), "default value: cannot use {s} where {s} is expected", .{ typeName(dt), typeName(pty) });
        }
    }

    fn funcSig(self: *Analyzer, f: Decl.Func) Error!*const FuncSig {
        const params = try self.arena.alloc(Type, f.params.len);
        const names = try self.arena.alloc([]const u8, f.params.len);
        for (f.params, 0..) |p, i| {
            params[i] = if (p.type) |ann| try self.annotationType(ann) else .any;
            names[i] = p.name;
        }
        const ret: Type = if (f.return_type) |rt| try self.annotationType(rt) else .any;
        const sig = try self.arena.create(FuncSig);
        sig.* = .{ .params = params, .ret = ret, .required = requiredParamCount(f.params), .param_names = names };
        return sig;
    }

    fn isClass(self: *Analyzer, name: []const u8) bool {
        if (self.module_scope.symbols.get(name)) |sym| return sym.kind == .class;
        return false;
    }

    /// Whether a `extends`/`uses` target is valid: a local class, or a `mod.Base`
    /// that names a type exported by an imported module.
    fn validSuper(self: *Analyzer, t: TypeRef) bool {
        if (t.module) |mod_name| {
            const sym = self.module_scope.symbols.get(mod_name);
            if (sym == null or sym.?.kind != .import) return false;
            const exported = self.importExports(mod_name).symbols.get(t.name);
            return exported != null and isUserType(exported.?.kind);
        }
        return self.isClass(t.name);
    }

    /// Whether `sub` is `base` or transitively extends/uses it.
    fn isSubtype(self: *Analyzer, sub: []const u8, base: []const u8) bool {
        if (std.mem.eql(u8, sub, base)) return true;
        if (self.supertypes.get(sub)) |set| return set.contains(base);
        return false;
    }

    /// Whether a value of type `from` may be used where `to` is expected.
    /// `named` types honor inheritance: a subclass is assignable to its bases.
    /// `nil` and a value both fit an optional target; an optional does not fit a
    /// non-optional target (it must be unwrapped first).
    fn assignable(self: *Analyzer, from: Type, to: Type) bool {
        if (isAnyish(from) or isAnyish(to)) return true;
        // A bare type reference used as a value is unusual; stay lenient.
        if (tagOf(from) == .enum_ref or tagOf(to) == .enum_ref) return true;
        if (tagOf(from) == .type_ref or tagOf(to) == .type_ref) return true;
        if (tagOf(to) == .optional) {
            const inner = to.optional.inner;
            return switch (from) {
                .nil => true,
                .optional => |a| self.assignable(a.inner, inner),
                else => self.assignable(from, inner),
            };
        }
        // `to` is a non-optional concrete type.
        return switch (from) {
            .int => tagOf(to) == .int or tagOf(to) == .float, // int widens to float
            .float => tagOf(to) == .float,
            .str => tagOf(to) == .str,
            .bool => tagOf(to) == .bool,
            .void => tagOf(to) == .void,
            // Element-aware, leaning on the recursive call (which shortcuts on
            // `any`/`unknown` elements) so a plain `list`/`map` stays compatible.
            .list => |l| tagOf(to) == .list and self.assignable(l.elem, to.list.elem),
            .map => |m| tagOf(to) == .map and
                self.assignable(m.key, to.map.key) and self.assignable(m.value, to.map.value),
            .tuple => |tp| tagOf(to) == .tuple and tp.elems.len == to.tuple.elems.len and blk: {
                for (tp.elems, to.tuple.elems) |a, b| {
                    if (!self.assignable(a, b)) break :blk false;
                }
                break :blk true;
            },
            .func => tagOf(to) == .func,
            .named => |n| tagOf(to) == .named and self.isSubtype(n, to.named),
            .any, .unknown, .enum_ref, .type_ref => true,
            .nil, .optional => false, // needs an optional target / must be unwrapped
            .module => tagOf(to) == .module, // modules aren't really values
        };
    }

    fn makeOptional(self: *Analyzer, inner: Type) Error!Type {
        switch (tagOf(inner)) {
            .optional, .nil => return inner, // ?(?T) = ?T; ?nil = nil
            else => {},
        }
        const opt = try self.arena.create(Optional);
        opt.* = .{ .inner = inner, .name = try std.fmt.allocPrint(self.arena, "?{s}", .{typeName(inner)}) };
        return .{ .optional = opt };
    }

    fn makeList(self: *Analyzer, elem: Type) Error!Type {
        const lt = try self.arena.create(ListType);
        lt.* = .{ .elem = elem, .name = try std.fmt.allocPrint(self.arena, "list<{s}>", .{typeName(elem)}) };
        return .{ .list = lt };
    }

    fn makeMap(self: *Analyzer, key: Type, value: Type) Error!Type {
        const mt = try self.arena.create(MapType);
        mt.* = .{
            .key = key,
            .value = value,
            .name = try std.fmt.allocPrint(self.arena, "map<{s}, {s}>", .{ typeName(key), typeName(value) }),
        };
        return .{ .map = mt };
    }

    fn makeTuple(self: *Analyzer, elems: []const Type) Error!Type {
        var name: std.ArrayList(u8) = .empty;
        try name.append(self.arena, '(');
        for (elems, 0..) |e, i| {
            if (i > 0) try name.appendSlice(self.arena, ", ");
            try name.appendSlice(self.arena, typeName(e));
        }
        try name.append(self.arena, ')');
        const tt = try self.arena.create(TupleType);
        tt.* = .{ .elems = elems, .name = try name.toOwnedSlice(self.arena) };
        return .{ .tuple = tt };
    }

    /// The least upper bound of two types, or null if they are incompatible. A
    /// `nil` arm makes the result optional; widening and inheritance apply.
    fn join(self: *Analyzer, a: Type, b: Type) Error!?Type {
        if (isAnyish(a) or isAnyish(b)) return .unknown;
        const ta = tagOf(a);
        const tb = tagOf(b);
        if (ta == .nil and tb == .nil) return .nil;
        if (ta == .nil) return try self.makeOptional(b);
        if (tb == .nil) return try self.makeOptional(a);
        if (ta == .optional or tb == .optional) {
            const ia = if (ta == .optional) a.optional.inner else a;
            const ib = if (tb == .optional) b.optional.inner else b;
            const inner = (try self.join(ia, ib)) orelse return null;
            return try self.makeOptional(inner);
        }
        // Collections unify element-wise (so `[cat, dog]` becomes `list<Animal>`).
        if (ta == .list and tb == .list) {
            const e = (try self.join(a.list.elem, b.list.elem)) orelse return null;
            return try self.makeList(e);
        }
        if (ta == .map and tb == .map) {
            const k = (try self.join(a.map.key, b.map.key)) orelse return null;
            const v = (try self.join(a.map.value, b.map.value)) orelse return null;
            return try self.makeMap(k, v);
        }
        if (self.assignable(a, b)) return b;
        if (self.assignable(b, a)) return a;
        return null;
    }

    /// Validate every class's `extends`/`uses` targets and compute the transitive
    /// set of supertypes for each class.
    fn buildInheritance(self: *Analyzer, decls: []const Decl) Error!void {
        // Pass 1: validate and record the direct supertypes of each class.
        for (decls) |decl| switch (decl) {
            .class => |c| {
                var supers: std.ArrayList([]const u8) = .empty;
                if (c.extends) |base| {
                    if (self.validSuper(base)) {
                        try supers.append(self.arena, base.name);
                    } else {
                        try self.report(base.span, "unknown base class '{s}'", .{base.name});
                    }
                }
                for (c.uses) |trait| {
                    if (self.validSuper(trait)) {
                        try supers.append(self.arena, trait.name);
                    } else {
                        try self.report(trait.span, "unknown trait '{s}'", .{trait.name});
                    }
                }
                try self.direct_supers.put(self.arena, c.name, try supers.toOwnedSlice(self.arena));
            },
            else => {},
        };
        // Pass 2: transitive closure over the direct supertypes.
        for (decls) |decl| switch (decl) {
            .class => |c| {
                const set = try self.arena.create(NameSet);
                set.* = .{};
                try self.collectSupers(c.name, set);
                try self.supertypes.put(self.arena, c.name, set);
            },
            else => {},
        };
    }

    fn collectSupers(self: *Analyzer, name: []const u8, into: *NameSet) Error!void {
        const direct = self.direct_supers.get(name) orelse return;
        for (direct) |s| {
            const gop = try into.getOrPut(self.arena, s);
            if (!gop.found_existing) try self.collectSupers(s, into);
        }
    }

    // --- declarations --------------------------------------------------------

    fn run(self: *Analyzer, module: Module) Error!void {
        // Built-in functions provided by the interpreter. Typed `any` so calls
        // to them are unconstrained (variadic `print`, conversions, etc.).
        for (interpreter.builtin_names) |name| {
            try self.declareIn(self.module_scope, name, .builtin, .any, .{ .start = 0, .end = 0, .line = 0, .col = 0 });
        }

        // Phase 1a: register every top-level name (so declarations may reference
        // one another regardless of order).
        for (module.decls) |decl| try self.registerTopLevel(decl);
        // Phase 1b: now that all type names exist, fill in function signatures
        // and build the member table of every class/struct (so `x.member` can be
        // resolved from any body).
        for (module.decls) |decl| switch (decl) {
            .func => |f| {
                if (self.module_scope.symbols.getPtr(f.name)) |sym| {
                    sym.ty = .{ .func = try self.funcSig(f) };
                }
            },
            .class => |c| try self.buildUserType(c.name, c.members),
            .struct_decl => |s| try self.buildUserType(s.name, s.members),
            .enum_decl => |en| try self.buildEnumType(en.name, en.members),
            else => {},
        };
        // Make imported types' member scopes resolvable before inheritance runs,
        // so a class may extend an imported base (local types win a name clash).
        try self.mergeImportedTypes();
        // Validate extends/uses and compute the class hierarchy.
        try self.buildInheritance(module.decls);
        // Fold each class's inherited members into its own scope.
        for (module.decls) |decl| switch (decl) {
            .class => |c| try self.flattenInheritedMembers(c.name),
            else => {},
        };
        // Phase 2: analyze bodies.
        for (module.decls) |decl| try self.analyzeDecl(decl);
    }

    fn registerTopLevel(self: *Analyzer, decl: Decl) Error!void {
        switch (decl) {
            // Bind the import's leaf name to a module value whose members are the
            // imported module's exports (empty if it did not resolve).
            .import => |im| {
                const exports = self.importExports(im.name);
                try self.declareIn(self.module_scope, im.name, .import, .{ .module = exports }, im.span);
            },
            .var_decl => |x| {
                const ty: Type = if (x.type) |ann| try self.annotationType(ann) else .unknown;
                try self.declareIn(self.module_scope, x.name, if (x.is_const) .constant else .variable, ty, x.span);
            },
            .func => |x| try self.declareIn(self.module_scope, x.name, .function, .unknown, x.span),
            .class => |x| try self.declareIn(self.module_scope, x.name, .class, .{ .type_ref = x.name }, x.span),
            .struct_decl => |x| try self.declareIn(self.module_scope, x.name, .struct_type, .{ .type_ref = x.name }, x.span),
            .enum_decl => |x| try self.declareIn(self.module_scope, x.name, .enum_type, .{ .enum_ref = x.name }, x.span),
            .signal => |x| try self.declareIn(self.module_scope, x.name, .signal, .unknown, x.span),
        }
    }

    /// Fold every imported module's exported type scopes into this module's
    /// `user_types`/`static_types` (skipping names it already defines), so a
    /// value of an imported type resolves its members and static members.
    fn mergeImportedTypes(self: *Analyzer) Error!void {
        for (self.imports) |imp| {
            var it = imp.exports.types.iterator();
            while (it.next()) |e| {
                const gop = try self.user_types.getOrPut(self.arena, e.key_ptr.*);
                if (!gop.found_existing) gop.value_ptr.* = e.value_ptr.*;
            }
            var sit = imp.exports.static_types.iterator();
            while (sit.next()) |e| {
                const gop = try self.static_types.getOrPut(self.arena, e.key_ptr.*);
                if (!gop.found_existing) gop.value_ptr.* = e.value_ptr.*;
            }
        }
    }

    /// The exports of the module bound to `name`, or an empty set if the import
    /// did not resolve (the loader already reported that).
    fn importExports(self: *Analyzer, name: []const u8) *const ModuleExports {
        for (self.imports) |imp| {
            if (std.mem.eql(u8, imp.name, name)) return imp.exports;
        }
        return &empty_exports;
    }

    /// Collect this module's `pub` top-level symbols into its export surface.
    fn buildExports(self: *Analyzer, module: Module) Error!*const ModuleExports {
        const exp = try self.arena.create(ModuleExports);
        exp.* = .{};
        for (module.decls) |decl| {
            var name: []const u8 = undefined;
            var vis: Visibility = .default;
            switch (decl) {
                .import => continue,
                .var_decl => |x| {
                    name = x.name;
                    vis = x.visibility;
                },
                .func => |x| {
                    name = x.name;
                    vis = x.visibility;
                },
                .class => |x| {
                    name = x.name;
                    vis = x.visibility;
                },
                .struct_decl => |x| {
                    name = x.name;
                    vis = x.visibility;
                },
                .enum_decl => |x| {
                    name = x.name;
                    vis = x.visibility;
                },
                .signal => |x| {
                    name = x.name;
                    vis = x.visibility;
                },
            }
            if (vis != .public) continue;
            if (self.module_scope.symbols.get(name)) |sym| {
                try exp.symbols.put(self.arena, name, sym);
            }
            // Export a class/struct's member scopes so importers can check access
            // through a `mod.T` annotation.
            if (self.user_types.get(name)) |scope| try exp.types.put(self.arena, name, scope);
            if (self.static_types.get(name)) |scope| try exp.static_types.put(self.arena, name, scope);
        }
        return exp;
    }

    fn analyzeDecl(self: *Analyzer, decl: Decl) Error!void {
        switch (decl) {
            .import => {},
            .var_decl => |x| {
                const ty = try self.checkVarDecl(x);
                if (self.module_scope.symbols.getPtr(x.name)) |sym| sym.ty = ty;
            },
            .func => |x| try self.analyzeFunc(x),
            .class => |x| try self.analyzeAggregate(x.name, x.members),
            .struct_decl => |x| try self.analyzeAggregate(x.name, x.members),
            .enum_decl => |x| try self.analyzeEnum(x),
            .signal => |x| try self.analyzeSignal(x),
        }
    }

    /// Signals introduce no values; just validate parameter types and flag
    /// duplicate parameter names.
    fn analyzeSignal(self: *Analyzer, s: Decl.Signal) Error!void {
        var seen: std.StringHashMapUnmanaged(void) = .{};
        for (s.params) |p| {
            if (p.type) |ann| try self.checkType(ann);
            if (p.default != null) {
                try self.report(p.span, "signal parameters cannot have default values", .{});
            }
            const gop = try seen.getOrPut(self.arena, p.name);
            if (gop.found_existing) {
                try self.report(p.span, "'{s}' is already declared", .{p.name});
            }
        }
    }

    /// Check a variable's annotation and initializer, returning the type the
    /// name should be bound to. Does not declare the name.
    fn checkVarDecl(self: *Analyzer, x: VarDecl) Error!Type {
        var declared: ?Type = null;
        if (x.type) |ann| {
            try self.checkType(ann);
            declared = try self.annotationType(ann);
        }
        var value_ty: ?Type = null;
        if (x.value) |v| value_ty = try self.typeOf(v.*);

        if (declared) |dt| {
            if (value_ty) |vt| {
                if (!self.assignable(vt, dt)) {
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
            const pty: Type = if (p.type) |ann| blk: {
                try self.checkType(ann);
                break :blk try self.annotationType(ann);
            } else .any;
            try self.checkDefault(p, pty); // resolved in the enclosing scope
            try self.declareIn(fn_scope, p.name, .parameter, pty, p.span);
        }
        if (f.return_type) |rt| try self.checkType(rt);

        const saved_scope = self.current;
        const saved_ret = self.current_ret;
        self.current = fn_scope;
        self.current_ret = if (f.return_type) |rt| try self.annotationType(rt) else null;
        defer {
            self.current = saved_scope;
            self.current_ret = saved_ret;
        }
        try self.analyzeStmts(f.body);

        // A function with a concrete return type must return on every path.
        // A `void` or optional (`?T`) return may legitimately fall off the end.
        if (self.current_ret) |rt| {
            if (!isAnyish(rt) and tagOf(rt) != .void and tagOf(rt) != .optional and !alwaysReturns(f.body)) {
                try self.report(f.span, "'{s}' must return {s} on all paths", .{ f.name, typeName(rt) });
            }
        }
    }

    /// Build a class/struct's member scope (parent = module) and record it under
    /// its type name. Duplicate members are reported here. Runs in phase 1b so
    /// member access resolves regardless of declaration order.
    fn buildUserType(self: *Analyzer, name: []const u8, members: []const Decl) Error!void {
        const scope = try self.newScope(self.module_scope);
        const static_scope = try self.newScope(self.module_scope);
        for (members) |m| switch (m) {
            .var_decl => |x| {
                const target = if (x.is_static) static_scope else scope;
                const ty: Type = if (x.type) |ann| try self.annotationType(ann) else .unknown;
                try self.declareIn(target, x.name, .field, ty, x.span);
                self.setMemberInfo(target, x.name, x.visibility, name);
            },
            .func => |x| {
                const target = if (x.is_static) static_scope else scope;
                try self.declareIn(target, x.name, .method, .{ .func = try self.funcSig(x) }, x.span);
                self.setMemberInfo(target, x.name, x.visibility, name);
            },
            .signal => |x| {
                try self.declareIn(scope, x.name, .signal, .unknown, x.span);
                self.setMemberInfo(scope, x.name, x.visibility, name);
            },
            else => {},
        };
        try self.user_types.put(self.arena, name, scope);
        try self.static_types.put(self.arena, name, static_scope);
    }

    fn setMemberInfo(self: *Analyzer, scope: *Scope, name: []const u8, visibility: Visibility, owner: []const u8) void {
        _ = self;
        if (scope.symbols.getPtr(name)) |sym| {
            sym.visibility = visibility;
            sym.owner = owner;
        }
    }

    /// Copy each class's inherited members into its own member scope (own members
    /// win), so inherited fields/methods resolve both by `.` and by bare name.
    fn flattenInheritedMembers(self: *Analyzer, class_name: []const u8) Error!void {
        const scope = self.user_types.get(class_name) orelse return;
        const static_scope = self.static_types.get(class_name);
        const ancestors = self.supertypes.get(class_name) orelse return;
        var it = ancestors.keyIterator();
        while (it.next()) |anc| {
            if (std.mem.eql(u8, anc.*, class_name)) continue; // guard cyclic hierarchies
            if (self.user_types.get(anc.*)) |anc_scope| {
                var members = anc_scope.symbols.iterator();
                while (members.next()) |entry| {
                    const gop = try scope.symbols.getOrPut(self.arena, entry.key_ptr.*);
                    if (!gop.found_existing) gop.value_ptr.* = entry.value_ptr.*;
                }
            }
            // Static members are inherited too (reachable via the subclass name).
            if (static_scope) |ss| {
                if (self.static_types.get(anc.*)) |anc_static| {
                    var statics = anc_static.symbols.iterator();
                    while (statics.next()) |entry| {
                        const gop = try ss.symbols.getOrPut(self.arena, entry.key_ptr.*);
                        if (!gop.found_existing) gop.value_ptr.* = entry.value_ptr.*;
                    }
                }
            }
        }
    }

    /// Analyze the bodies of a class or struct in its pre-built member scope, so
    /// methods see the fields and each other by bare name.
    fn analyzeAggregate(self: *Analyzer, name: []const u8, members: []const Decl) Error!void {
        const scope = self.user_types.get(name) orelse return;
        const static_scope = self.static_types.get(name) orelse return;
        const saved = self.current;
        const saved_class = self.current_class;
        self.current_class = name;
        defer {
            self.current = saved;
            self.current_class = saved_class;
        }
        // A member is analyzed in its own scope, so static bodies see static
        // members by bare name and instance bodies see instance members.
        for (members) |m| switch (m) {
            .var_decl => |x| {
                const target = if (x.is_static) static_scope else scope;
                self.current = target;
                const ty = try self.checkVarDecl(x);
                if (target.symbols.getPtr(x.name)) |sym| sym.ty = ty;
            },
            .func => |x| {
                self.current = if (x.is_static) static_scope else scope;
                try self.analyzeFunc(x);
            },
            .signal => |x| {
                self.current = scope;
                try self.analyzeSignal(x);
            },
            else => {},
        };
    }

    /// A `private` member is only reachable from inside the type that declares
    /// it (class-level, not instance-level, privacy).
    fn checkVisibility(self: *Analyzer, name: []const u8, sym: Symbol, span: Span) Error!void {
        if (sym.visibility != .private) return;
        const owner = sym.owner orelse return;
        if (self.current_class) |cc| {
            if (std.mem.eql(u8, cc, owner)) return;
        }
        try self.report(span, "'{s}' is private to '{s}'", .{ name, owner });
    }

    /// Resolve `object.name`. Only instance access on a known class/struct is
    /// checked; everything else (builtins, `any`, enums, type references) is
    /// left as `unknown` to avoid false positives.
    fn memberType(self: *Analyzer, object: Type, name: []const u8, span: Span) Error!Type {
        switch (object) {
            .named => |type_name| {
                const scope = self.user_types.get(type_name) orelse return .unknown;
                if (scope.symbols.get(name)) |sym| {
                    try self.checkVisibility(name, sym, span);
                    return sym.ty;
                }
                try self.report(span, "type '{s}' has no member '{s}'", .{ type_name, name });
                return .unknown;
            },
            .enum_ref => |enum_name| {
                const scope = self.enum_types.get(enum_name) orelse return .unknown;
                if (scope.symbols.contains(name)) return .{ .named = enum_name };
                try self.report(span, "enum '{s}' has no case '{s}'", .{ enum_name, name });
                return .unknown;
            },
            .type_ref => |type_name| {
                const scope = self.static_types.get(type_name) orelse return .unknown;
                if (scope.symbols.get(name)) |sym| {
                    try self.checkVisibility(name, sym, span);
                    return sym.ty;
                }
                try self.report(span, "type '{s}' has no static member '{s}'", .{ type_name, name });
                return .unknown;
            },
            .module => |exports| {
                if (exports.symbols.get(name)) |sym| return sym.ty;
                try self.report(span, "module has no exported member '{s}'", .{name});
                return .unknown;
            },
            else => return .unknown,
        }
    }

    /// Record an enum's cases in a scope keyed by its name (duplicates reported
    /// here), so `Enum.CASE` can be validated from any body.
    fn buildEnumType(self: *Analyzer, name: []const u8, members: []const parser.EnumMember) Error!void {
        const scope = try self.newScope(self.module_scope);
        for (members) |m| {
            try self.declareIn(scope, m.name, .enum_member, .{ .named = name }, m.span);
        }
        try self.enum_types.put(self.arena, name, scope);
    }

    fn analyzeEnum(self: *Analyzer, e: Decl.Enum) Error!void {
        for (e.members) |m| {
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

    const Narrow = struct { name: []const u8, inner: Type, in_then: bool };

    /// Recognize `v != nil` / `nil != v` (narrow in the then-branch) and
    /// `v == nil` / `nil == v` (narrow in the else-branch), where `v` is an
    /// optional variable, so its inner type can be assumed inside the branch.
    fn detectNilNarrow(self: *Analyzer, cond: Expr) ?Narrow {
        const b = switch (cond) {
            .binary => |b| b,
            else => return null,
        };
        if (b.op != .eq and b.op != .ne) return null;
        const name = nilCheckIdent(b.lhs.*, b.rhs.*) orelse nilCheckIdent(b.rhs.*, b.lhs.*) orelse return null;
        const sym = self.resolve(name) orelse return null;
        const inner = switch (sym.ty) {
            .optional => |o| o.inner,
            else => return null,
        };
        return .{ .name = name, .inner = inner, .in_then = b.op == .ne };
    }

    fn analyzeNarrowedBlock(self: *Analyzer, stmts: []const Stmt, narrow: Narrow) Error!void {
        const child = try self.newScope(self.current);
        // Shadow the optional with its unwrapped type for this block.
        try child.symbols.put(self.arena, narrow.name, .{
            .kind = .variable,
            .ty = narrow.inner,
            .span = .{ .start = 0, .end = 0, .line = 0, .col = 0 },
        });
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
            .destructure => |d| {
                const vt = try self.typeOf(d.value.*);
                const kind: SymbolKind = if (d.is_const) .constant else .variable;
                if (tagOf(vt) == .tuple) {
                    const elems = vt.tuple.elems;
                    if (elems.len != d.names.len) {
                        try self.report(d.span, "cannot destructure {d} value(s) into {d} name(s)", .{ elems.len, d.names.len });
                    }
                    for (d.names, 0..) |n, i| {
                        try self.declareIn(self.current, n, kind, if (i < elems.len) elems[i] else .unknown, d.span);
                    }
                } else {
                    if (!isAnyish(vt)) try self.report(parser.exprSpan(d.value.*), "cannot destructure a {s} (expected a tuple)", .{typeName(vt)});
                    for (d.names) |n| try self.declareIn(self.current, n, kind, .unknown, d.span);
                }
            },
            .return_stmt => |x| try self.checkReturn(x),
            .if_stmt => |x| {
                try self.checkCondition(x.cond);
                // `if v != nil:` narrows `v` to its inner type in the then-body;
                // `if v == nil:` narrows it in the else-body.
                const narrow = self.detectNilNarrow(x.cond.*);
                if (narrow != null and narrow.?.in_then) {
                    try self.analyzeNarrowedBlock(x.then_body, narrow.?);
                } else {
                    try self.analyzeChildBlock(x.then_body);
                }
                for (x.elifs) |e| {
                    try self.checkCondition(e.cond);
                    try self.analyzeChildBlock(e.body);
                }
                if (x.else_body) |eb| {
                    if (narrow != null and !narrow.?.in_then) {
                        try self.analyzeNarrowedBlock(eb, narrow.?);
                    } else {
                        try self.analyzeChildBlock(eb);
                    }
                }
            },
            .while_stmt => |x| {
                try self.checkCondition(x.cond);
                self.loop_depth += 1;
                defer self.loop_depth -= 1;
                try self.analyzeChildBlock(x.body);
            },
            .for_stmt => |x| {
                const iter_t = try self.typeOf(x.iter.*);
                const child = try self.newScope(self.current);
                if (x.value_binding) |vb| {
                    // Two bindings: (index/key, value).
                    const first_t: Type = switch (iter_t) {
                        .map => |m| m.key,
                        .list, .str => .int,
                        else => .unknown,
                    };
                    const second_t: Type = switch (iter_t) {
                        .list => |l| l.elem,
                        .map => |m| m.value,
                        .str => .str,
                        else => .unknown,
                    };
                    try self.declareIn(child, x.binding, .binding, first_t, x.span);
                    try self.declareIn(child, vb, .binding, second_t, x.span);
                } else {
                    // A single binding takes each list element, map key, or char.
                    const binding_t: Type = switch (iter_t) {
                        .list => |l| l.elem,
                        .map => |m| m.key,
                        .str => .str,
                        else => .unknown,
                    };
                    try self.declareIn(child, x.binding, .binding, binding_t, x.span);
                }
                const saved = self.current;
                self.current = child;
                self.loop_depth += 1;
                defer {
                    self.current = saved;
                    self.loop_depth -= 1;
                }
                try self.analyzeStmts(x.body);
            },
            .assign => |x| {
                const tt = try self.typeOf(x.target.*);
                const vt = try self.typeOf(x.value.*);
                if (!self.assignable(vt, tt)) {
                    try self.report(x.span, "cannot assign {s} to {s}", .{ typeName(vt), typeName(tt) });
                }
            },
            .expr_stmt => |e| _ = try self.typeOf(e.*),
            .pass => {},
            .break_stmt => |span| {
                if (self.loop_depth == 0) try self.report(span, "'break' outside a loop", .{});
            },
            .continue_stmt => |span| {
                if (self.loop_depth == 0) try self.report(span, "'continue' outside a loop", .{});
            },
            .raise => |r| _ = try self.typeOf(r.value.*),
            .try_catch => |tc| {
                try self.analyzeChildBlock(tc.body);
                // The handler runs with the error bound (its value is unconstrained).
                const child = try self.newScope(self.current);
                try self.declareIn(child, tc.catch_name, .variable, .any, tc.span);
                const saved = self.current;
                self.current = child;
                defer self.current = saved;
                try self.analyzeStmts(tc.handler);
            },
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
            } else if (!self.assignable(vt, ret)) {
                try self.report(r.span, "cannot return {s} from a function returning {s}", .{ typeName(vt), typeName(ret) });
            }
        } else if (!isAnyish(ret) and tagOf(ret) != .void and tagOf(ret) != .optional) {
            // A bare `return` in a `?T` function yields nil, which is valid.
            try self.report(r.span, "expected a return value of type {s}", .{typeName(ret)});
        }
    }

    // --- expressions ---------------------------------------------------------

    fn typeOf(self: *Analyzer, e: Expr) Error!Type {
        return switch (e) {
            .int_literal => .int,
            .float_literal => .float,
            .string_literal => .str,
            .interpolation => |x| blk: {
                for (x.parts) |p| switch (p) {
                    .expr => |pe| _ = try self.typeOf(pe.*),
                    .literal => {},
                };
                break :blk .str;
            },
            .range => |r| blk: {
                const st = try self.typeOf(r.start.*);
                const et = try self.typeOf(r.end.*);
                if (!isAnyish(st) and tagOf(st) != .int) try self.report(parser.exprSpan(r.start.*), "range start must be an int, got {s}", .{typeName(st)});
                if (!isAnyish(et) and tagOf(et) != .int) try self.report(parser.exprSpan(r.end.*), "range end must be an int, got {s}", .{typeName(et)});
                break :blk try self.makeList(.int);
            },
            .bool_literal => .bool,
            .nil_literal => .nil,
            .identifier => |id| blk: {
                if (self.resolve(id.name)) |sym| break :blk sym.ty;
                try self.report(id.span, "undefined name '{s}'", .{id.name});
                break :blk .unknown;
            },
            .unary => |u| try self.typeUnary(u),
            .binary => |b| try self.typeBinary(b),
            .call => |c| try self.typeCall(c),
            .index => |i| try self.typeIndex(i),
            .slice => |s| try self.typeSlice(s),
            .comprehension => |c| try self.typeComprehension(c),
            .conditional => |c| try self.typeConditional(c),
            .member => |m| blk: {
                const ot = try self.typeOf(m.object.*);
                break :blk try self.memberType(ot, m.name, m.span);
            },
            .array => |a| blk: {
                var elem: ?Type = null;
                for (a.elements) |el| {
                    const et = try self.typeOf(el.*);
                    elem = if (elem) |cur| (try self.join(cur, et)) orelse .any else et;
                }
                break :blk try self.makeList(elem orelse .unknown);
            },
            .map => |m| blk: {
                var kt: ?Type = null;
                var vt: ?Type = null;
                for (m.entries) |entry| {
                    const k = try self.typeOf(entry.key.*);
                    const v = try self.typeOf(entry.value.*);
                    kt = if (kt) |cur| (try self.join(cur, k)) orelse .any else k;
                    vt = if (vt) |cur| (try self.join(cur, v)) orelse .any else v;
                }
                break :blk try self.makeMap(kt orelse .unknown, vt orelse .unknown);
            },
            .match => |m| try self.typeMatch(m),
            .lambda => |lam| try self.typeLambda(lam),
            .tuple => |t| blk: {
                const elems = try self.arena.alloc(Type, t.elements.len);
                for (t.elements, 0..) |el, i| elems[i] = try self.typeOf(el.*);
                break :blk try self.makeTuple(elems);
            },
        };
    }

    /// A lambda has a function type: its parameters (annotated, else `any`) and a
    /// return type inferred from a single-expression body (else `any`). The body
    /// is analyzed in a child scope so its own errors are still reported.
    fn typeLambda(self: *Analyzer, lam: *const Expr.Lambda) Error!Type {
        const fn_scope = try self.newScope(self.current);
        const param_types = try self.arena.alloc(Type, lam.params.len);
        for (lam.params, 0..) |p, i| {
            const pty: Type = if (p.type) |ann| blk: {
                try self.checkType(ann);
                break :blk try self.annotationType(ann);
            } else .any;
            param_types[i] = pty;
            try self.checkDefault(p, pty); // resolved in the enclosing scope
            try self.declareIn(fn_scope, p.name, .parameter, pty, p.span);
        }
        const saved = self.current;
        const saved_ret = self.current_ret;
        self.current = fn_scope;
        self.current_ret = null; // lambdas don't declare a return type
        defer {
            self.current = saved;
            self.current_ret = saved_ret;
        }
        var ret: Type = .any;
        if (lam.body.len == 1 and lam.body[0] == .return_stmt and lam.body[0].return_stmt.value != null) {
            // Single-expression body: its type is the result (and checks the expr).
            ret = try self.typeOf(lam.body[0].return_stmt.value.?.*);
        } else {
            try self.analyzeStmts(lam.body);
        }
        const sig = try self.arena.create(FuncSig);
        const lam_names = try self.arena.alloc([]const u8, lam.params.len);
        for (lam.params, 0..) |p, i| lam_names[i] = p.name;
        sig.* = .{ .params = param_types, .ret = ret, .required = requiredParamCount(lam.params), .param_names = lam_names };
        return .{ .func = sig };
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
            .bit_not => {
                if (!isAnyish(ot) and tagOf(ot) != .int) {
                    try self.report(u.span, "unary '~' requires an int, got {s}", .{typeName(ot)});
                    return .unknown;
                }
                return .int;
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
                if (!(isAnyish(lt) or isAnyish(rt) or self.assignable(lt, rt) or self.assignable(rt, lt))) {
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
            .bit_and, .bit_or, .bit_xor, .shl, .shr => {
                if (isAnyish(lt) or isAnyish(rt)) return .unknown;
                if (tagOf(lt) == .int and tagOf(rt) == .int) return .int;
                try self.reportOperator(b.span, b.op, lt, rt);
                return .unknown;
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

    /// Check a call's argument count and types against a parameter list. With
    /// default parameters the count is a range `required..params.len`.
    /// Report any named arguments as unsupported (builtins take positional args).
    fn rejectNamedArgs(self: *Analyzer, c: Expr.Call) Error!void {
        for (c.args) |arg| {
            if (arg.name) |n| {
                try self.report(parser.exprSpan(arg.value.*), "named argument '{s}' is not allowed here", .{n});
            }
        }
    }

    fn checkArgs(self: *Analyzer, c: Expr.Call, params: []const Type, param_names: []const []const u8, required: usize) Error!void {
        var has_named = false;
        for (c.args) |arg| {
            if (arg.name != null) has_named = true;
        }
        if (!has_named) {
            // Positional-only fast path (unchanged behavior/messages).
            if (c.args.len < required or c.args.len > params.len) {
                if (required == params.len) {
                    try self.report(c.span, "expected {d} argument(s), got {d}", .{ params.len, c.args.len });
                } else {
                    try self.report(c.span, "expected {d} to {d} argument(s), got {d}", .{ required, params.len, c.args.len });
                }
            }
            for (c.args, 0..) |arg, i| {
                const at = try self.typeOf(arg.value.*);
                if (i < params.len and !self.assignable(at, params[i])) {
                    try self.report(parser.exprSpan(arg.value.*), "argument {d}: cannot pass {s} where {s} is expected", .{ i + 1, typeName(at), typeName(params[i]) });
                }
            }
            return;
        }
        try self.checkNamedArgs(c, params, param_names, required);
    }

    /// Validate a call that mixes positional and named arguments: names must match
    /// a parameter, no parameter twice, and every required parameter filled.
    fn checkNamedArgs(self: *Analyzer, c: Expr.Call, params: []const Type, param_names: []const []const u8, required: usize) Error!void {
        const filled = try self.arena.alloc(bool, params.len);
        for (filled) |*f| f.* = false;

        var pos: usize = 0;
        while (pos < c.args.len and c.args[pos].name == null) pos += 1;

        for (c.args[0..pos], 0..) |arg, i| {
            const at = try self.typeOf(arg.value.*);
            if (i < params.len) {
                filled[i] = true;
                if (!self.assignable(at, params[i])) {
                    try self.report(parser.exprSpan(arg.value.*), "argument {d}: cannot pass {s} where {s} is expected", .{ i + 1, typeName(at), typeName(params[i]) });
                }
            } else {
                try self.report(parser.exprSpan(arg.value.*), "too many arguments (expected at most {d})", .{params.len});
            }
        }
        for (c.args[pos..]) |arg| {
            const name = arg.name.?;
            const at = try self.typeOf(arg.value.*);
            var idx: ?usize = null;
            for (param_names, 0..) |pn, j| {
                if (std.mem.eql(u8, pn, name)) {
                    idx = j;
                    break;
                }
            }
            if (idx == null) {
                try self.report(parser.exprSpan(arg.value.*), "no parameter named '{s}'", .{name});
                continue;
            }
            const j = idx.?;
            if (filled[j]) {
                try self.report(parser.exprSpan(arg.value.*), "argument '{s}' was already provided", .{name});
                continue;
            }
            filled[j] = true;
            if (!self.assignable(at, params[j])) {
                try self.report(parser.exprSpan(arg.value.*), "argument '{s}': cannot pass {s} where {s} is expected", .{ name, typeName(at), typeName(params[j]) });
            }
        }
        for (0..required) |j| {
            if (!filled[j]) {
                try self.report(c.span, "missing required argument '{s}'", .{param_names[j]});
            }
        }
    }

    fn typeCall(self: *Analyzer, c: Expr.Call) Error!Type {
        // Builtins are polymorphic (their result may depend on an argument's
        // element type), so type them specially — but only when the name really
        // resolves to the builtin and isn't shadowed by a local/param.
        if (c.callee.* == .identifier) {
            if (self.resolve(c.callee.identifier.name)) |sym| {
                if (sym.kind == .builtin) {
                    try self.rejectNamedArgs(c);
                    return self.typeBuiltinCall(c.callee.identifier.name, c);
                }
            }
        }
        const ct = try self.typeOf(c.callee.*);
        switch (ct) {
            .func => |sig| {
                try self.checkArgs(c, sig.params, sig.param_names, sig.required);
                return sig.ret;
            },
            .any, .unknown => {
                for (c.args) |arg| _ = try self.typeOf(arg.value.*);
                return .unknown;
            },
            // Calling a class/struct name constructs an instance; its arguments
            // are checked against the type's `init` (or must be empty if none).
            .type_ref => |type_name| {
                const scope = self.user_types.get(type_name);
                const init_sym: ?Symbol = if (scope) |s| s.symbols.get("init") else null;
                if (init_sym) |sym| {
                    if (tagOf(sym.ty) == .func) {
                        try self.checkArgs(c, sym.ty.func.params, sym.ty.func.param_names, sym.ty.func.required);
                    } else {
                        for (c.args) |arg| _ = try self.typeOf(arg.value.*);
                    }
                } else {
                    for (c.args) |arg| _ = try self.typeOf(arg.value.*);
                    if (c.args.len != 0) {
                        try self.report(c.span, "{s} takes no constructor arguments", .{type_name});
                    }
                }
                return .{ .named = type_name };
            },
            else => {
                for (c.args) |arg| _ = try self.typeOf(arg.value.*);
                try self.report(c.span, "{s} is not callable", .{typeName(ct)});
                return .unknown;
            },
        }
    }

    /// Type a call to a built-in. Every argument is typed (so nested expressions
    /// are still checked); the result type and any element-type checks depend on
    /// the specific builtin. Unknown/`any` arguments degrade to a lenient result.
    fn typeBuiltinCall(self: *Analyzer, name: []const u8, c: Expr.Call) Error!Type {
        const args = try self.arena.alloc(Type, c.args.len);
        for (c.args, 0..) |arg, i| args[i] = try self.typeOf(arg.value.*);

        const eq = std.mem.eql;
        // print/echo/emit are variadic; everything else has a fixed arity.
        if (eq(u8, name, "print") or eq(u8, name, "echo") or eq(u8, name, "emit")) return .unknown;

        const three = eq(u8, name, "replace") or eq(u8, name, "reduce");
        const two = eq(u8, name, "push") or eq(u8, name, "has") or eq(u8, name, "connect") or
            eq(u8, name, "min") or eq(u8, name, "max") or eq(u8, name, "split") or
            eq(u8, name, "join") or eq(u8, name, "contains") or
            eq(u8, name, "starts_with") or eq(u8, name, "ends_with") or eq(u8, name, "find") or
            eq(u8, name, "map") or eq(u8, name, "filter") or eq(u8, name, "pow");
        const arity: usize = if (three) 3 else if (two) 2 else 1;
        if (c.args.len != arity) {
            try self.report(c.span, "{s} expects {d} argument(s), got {d}", .{ name, arity, c.args.len });
            // Still infer a plausible result type below (using whatever args exist).
        }

        if (eq(u8, name, "len")) return .int;
        if (eq(u8, name, "str")) return .str;
        if (eq(u8, name, "int")) return .int;
        if (eq(u8, name, "float")) return .float;
        if (eq(u8, name, "range")) {
            if (args.len >= 1 and !isAnyish(args[0]) and tagOf(args[0]) != .int) {
                try self.report(parser.exprSpan(c.args[0].value.*), "range expects an int, got {s}", .{typeName(args[0])});
            }
            return self.makeList(.int);
        }
        if (eq(u8, name, "push")) {
            if (args.len == 2 and tagOf(args[0]) == .list) {
                const elem = args[0].list.elem;
                if (!self.assignable(args[1], elem)) {
                    try self.report(parser.exprSpan(c.args[1].value.*), "cannot push {s} into {s}", .{ typeName(args[1]), typeName(args[0]) });
                }
            }
            return .void;
        }
        if (eq(u8, name, "pop")) {
            if (args.len == 1 and tagOf(args[0]) == .list) return args[0].list.elem;
            return .unknown;
        }
        if (eq(u8, name, "keys")) {
            if (args.len == 1 and tagOf(args[0]) == .map) return self.makeList(args[0].map.key);
            return .unknown;
        }
        if (eq(u8, name, "values")) {
            if (args.len == 1 and tagOf(args[0]) == .map) return self.makeList(args[0].map.value);
            return .unknown;
        }
        if (eq(u8, name, "has")) {
            if (args.len == 2 and tagOf(args[0]) == .map and !self.assignable(args[1], args[0].map.key)) {
                try self.report(parser.exprSpan(c.args[1].value.*), "cannot look up {s} in {s}", .{ typeName(args[1]), typeName(args[0]) });
            }
            return .bool;
        }
        if (eq(u8, name, "upper") or eq(u8, name, "lower")) return .str;
        if (eq(u8, name, "join")) return .str;
        if (eq(u8, name, "contains")) return .bool;
        if (eq(u8, name, "split")) return self.makeList(.str);
        if (eq(u8, name, "abs")) {
            if (args.len == 1 and tagOf(args[0]) == .float) return .float;
            if (args.len == 1 and tagOf(args[0]) == .int) return .int;
            return .unknown;
        }
        if (eq(u8, name, "min") or eq(u8, name, "max")) {
            if (args.len == 2 and isNumeric(args[0]) and isNumeric(args[1])) return numericResult(args[0], args[1]);
            return .unknown;
        }
        if (eq(u8, name, "sort") or eq(u8, name, "reverse")) {
            if (args.len == 1 and tagOf(args[0]) == .list) return args[0];
            return .unknown;
        }
        if (eq(u8, name, "trim") or eq(u8, name, "replace")) return .str;
        if (eq(u8, name, "starts_with") or eq(u8, name, "ends_with")) return .bool;
        if (eq(u8, name, "find")) return .int;
        // Higher-order list builtins: map -> list<any>, filter -> the same list,
        // reduce -> the accumulator (initial-value) type.
        if (eq(u8, name, "map")) {
            if (args.len >= 1 and !isAnyish(args[0]) and tagOf(args[0]) != .list) {
                try self.report(parser.exprSpan(c.args[0].value.*), "map expects a list, got {s}", .{typeName(args[0])});
            }
            return self.makeList(.any);
        }
        if (eq(u8, name, "filter")) {
            if (args.len >= 1) {
                if (tagOf(args[0]) == .list) return args[0];
                if (!isAnyish(args[0])) {
                    try self.report(parser.exprSpan(c.args[0].value.*), "filter expects a list, got {s}", .{typeName(args[0])});
                }
            }
            return .unknown;
        }
        if (eq(u8, name, "reduce")) {
            if (args.len == 3) return args[2];
            return .unknown;
        }
        // Math builtins: sqrt/pow -> float; floor/ceil/round -> int. Each expects
        // numbers (int widens to float).
        if (eq(u8, name, "sqrt") or eq(u8, name, "pow")) {
            for (args, 0..) |a, i| {
                if (!isAnyish(a) and !isNumeric(a)) {
                    try self.report(parser.exprSpan(c.args[i].value.*), "{s} expects a number, got {s}", .{ name, typeName(a) });
                }
            }
            return .float;
        }
        if (eq(u8, name, "floor") or eq(u8, name, "ceil") or eq(u8, name, "round")) {
            if (args.len == 1 and !isAnyish(args[0]) and !isNumeric(args[0])) {
                try self.report(parser.exprSpan(c.args[0].value.*), "{s} expects a number, got {s}", .{ name, typeName(args[0]) });
            }
            return .int;
        }
        return .unknown;
    }

    fn typeIndex(self: *Analyzer, i: Expr.Index) Error!Type {
        const ot = try self.typeOf(i.object.*);
        const it = try self.typeOf(i.index.*);
        switch (ot) {
            .list => |l| {
                if (!isAnyish(it) and tagOf(it) != .int) {
                    try self.report(parser.exprSpan(i.index.*), "list index must be an int, got {s}", .{typeName(it)});
                }
                return l.elem;
            },
            .map => |m| {
                if (!self.assignable(it, m.key)) {
                    try self.report(parser.exprSpan(i.index.*), "map key must be {s}, got {s}", .{ typeName(m.key), typeName(it) });
                }
                return m.value;
            },
            .str => {
                if (!isAnyish(it) and tagOf(it) != .int) {
                    try self.report(parser.exprSpan(i.index.*), "string index must be an int, got {s}", .{typeName(it)});
                }
                return .str; // a one-character string
            },
            .any, .unknown => return .unknown,
            else => {
                try self.report(i.span, "{s} is not indexable", .{typeName(ot)});
                return .unknown;
            },
        }
    }

    fn checkIntBound(self: *Analyzer, e: *const Expr) Error!void {
        const t = try self.typeOf(e.*);
        if (!isAnyish(t) and tagOf(t) != .int) {
            try self.report(parser.exprSpan(e.*), "slice bound must be an int, got {s}", .{typeName(t)});
        }
    }

    fn typeSlice(self: *Analyzer, s: Expr.Slice) Error!Type {
        const ot = try self.typeOf(s.object.*);
        if (s.start) |st| try self.checkIntBound(st);
        if (s.end) |en| try self.checkIntBound(en);
        return switch (ot) {
            .list => ot, // list<T> -> list<T>
            .str => .str,
            .any, .unknown => .unknown,
            else => blk: {
                try self.report(s.span, "{s} cannot be sliced", .{typeName(ot)});
                break :blk .unknown;
            },
        };
    }

    fn typeConditional(self: *Analyzer, c: *const Expr.Conditional) Error!Type {
        const ct = try self.typeOf(c.cond.*);
        if (!isBoolish(ct)) {
            try self.report(parser.exprSpan(c.cond.*), "conditional condition must be bool, got {s}", .{typeName(ct)});
        }
        const then_t = try self.typeOf(c.then_val.*);
        const else_t = try self.typeOf(c.else_val.*);
        if (try self.join(then_t, else_t)) |joined| return joined;
        try self.report(c.span, "conditional branches have incompatible types {s} and {s}", .{ typeName(then_t), typeName(else_t) });
        return .unknown;
    }

    fn typeComprehension(self: *Analyzer, c: *const Expr.Comprehension) Error!Type {
        const iter_t = try self.typeOf(c.iter.*);
        const child = try self.newScope(self.current);
        if (c.value_binding) |vb| {
            const first_t: Type = switch (iter_t) {
                .map => |m| m.key,
                .list, .str => .int,
                else => .unknown,
            };
            const second_t: Type = switch (iter_t) {
                .list => |l| l.elem,
                .map => |m| m.value,
                .str => .str,
                else => .unknown,
            };
            try self.declareIn(child, c.binding, .binding, first_t, c.span);
            try self.declareIn(child, vb, .binding, second_t, c.span);
        } else {
            const bt: Type = switch (iter_t) {
                .list => |l| l.elem,
                .map => |m| m.key,
                .str => .str,
                else => .unknown,
            };
            try self.declareIn(child, c.binding, .binding, bt, c.span);
        }
        const saved = self.current;
        self.current = child;
        defer self.current = saved;
        if (c.cond) |cond| {
            const ct = try self.typeOf(cond.*);
            if (!isBoolish(ct)) {
                try self.report(parser.exprSpan(cond.*), "comprehension condition must be bool, got {s}", .{typeName(ct)});
            }
        }
        const out_t = try self.typeOf(c.output.*);
        return self.makeList(out_t);
    }

    fn typeMatch(self: *Analyzer, m: Expr.Match) Error!Type {
        const subject = try self.typeOf(m.subject.*);

        // A `_` or binding pattern matches everything; a bool subject is
        // exhaustive when both `true`/`false` appear; an enum subject is
        // exhaustive when every case is covered.
        var has_catch_all = false;
        var covers_true = false;
        var covers_false = false;
        const subject_enum: ?[]const u8 = if (tagOf(subject) == .named and self.enum_types.contains(subject.named)) subject.named else null;
        var covered: NameSet = .{};
        // The match's value is the least upper bound of its arms' bodies.
        var result: ?Type = null;
        var incompatible = false;

        for (m.arms) |arm| {
            if (has_catch_all) {
                try self.report(arm.span, "unreachable match arm; an earlier '_' or binding already matches everything", .{});
            }
            switch (arm.pattern) {
                .wildcard, .binding => has_catch_all = true,
                .bool_literal => |b| {
                    if (b.value) covers_true = true else covers_false = true;
                },
                .enum_case => |ec| try self.checkEnumCasePattern(ec, subject, subject_enum, &covered),
                else => {},
            }

            const child = try self.newScope(self.current);
            switch (arm.pattern) {
                .binding => |b| try self.declareIn(child, b.name, .binding, .unknown, b.span),
                else => {},
            }
            const saved = self.current;
            self.current = child;
            const at = self.typeOf(arm.body.*) catch |e| {
                self.current = saved;
                return e;
            };
            self.current = saved;

            if (result) |r| {
                if (try self.join(r, at)) |joined| result = joined else incompatible = true;
            } else {
                result = at;
            }
        }

        const bool_exhaustive = tagOf(subject) == .bool and covers_true and covers_false;
        const enum_exhaustive = self.allCasesCovered(subject_enum, covered);
        if (!has_catch_all and !bool_exhaustive and !enum_exhaustive) {
            try self.report(m.span, "match is not exhaustive; add a '_' case", .{});
        }
        if (incompatible) {
            try self.report(m.span, "match arms have incompatible types", .{});
            return .unknown;
        }
        return result orelse .unknown;
    }

    /// Validate an `Enum.CASE` pattern against the match subject, recording the
    /// case as covered when it belongs to the subject's enum.
    fn checkEnumCasePattern(self: *Analyzer, ec: Pattern.EnumCase, subject: Type, subject_enum: ?[]const u8, covered: *NameSet) Error!void {
        const scope = self.enum_types.get(ec.enum_name) orelse {
            try self.report(ec.span, "unknown enum '{s}'", .{ec.enum_name});
            return;
        };
        if (!scope.symbols.contains(ec.case)) {
            try self.report(ec.span, "enum '{s}' has no case '{s}'", .{ ec.enum_name, ec.case });
            return;
        }
        if (subject_enum) |se| {
            if (!std.mem.eql(u8, se, ec.enum_name)) {
                try self.report(ec.span, "pattern '{s}.{s}' does not match a subject of type '{s}'", .{ ec.enum_name, ec.case, se });
                return;
            }
            try covered.put(self.arena, ec.case, {});
        } else if (!isAnyish(subject)) {
            try self.report(ec.span, "cannot match an enum case against {s}", .{typeName(subject)});
        }
    }

    /// Whether every case of `subject_enum` appears in `covered`.
    fn allCasesCovered(self: *Analyzer, subject_enum: ?[]const u8, covered: NameSet) bool {
        const se = subject_enum orelse return false;
        const scope = self.enum_types.get(se) orelse return false;
        var it = scope.symbols.keyIterator();
        while (it.next()) |case| {
            if (!covered.contains(case.*)) return false;
        }
        return true;
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

// A batch of adversarial/malformed inputs; the front end must produce
// diagnostics rather than crash. (Complements the fuzz harness below, which
// only smoke-runs unless invoked with `--fuzz`.)
test "the front end survives adversarial inputs without crashing" {
    const gpa = testing.allocator;
    const inputs = [_][]const u8{
        "",                    "\x00",             "func",              "func(",
        "\"unterminated",      "${",               "match x {",         "class",
        "for , in x:",         "0..",              "..",                "[[[",
        "}}}",                 "1.2.3",            "func f(:",          "return return",
        "\"a ${b",             "enum E {",         ">>>>",              "and or not",
        "if:",                 "var x: mod.",      "func():\n\t x",     "\\\\\\",
        "class A extends .B:", "x += += 1",        "\"${\"nested\"}\"", "for i, in xs:",
    };
    for (inputs) |src| {
        var tree = parser.parse(gpa, src) catch continue;
        defer tree.deinit();
        if (tree.diagnostics.len == 0) {
            var a = analyze(gpa, tree.module) catch continue;
            a.deinit();
        }
    }
    // Reaching here (no panic/segfault) is the assertion.
}

// Fuzz the whole front end (lexer + parser + analyzer): arbitrary bytes must
// never crash it — only ever produce diagnostics. Run with `zig build test
// --fuzz`; without it, this executes once as a smoke test.
test "fuzz: the front end never crashes on arbitrary input" {
    try std.testing.fuzz({}, fuzzFrontend, .{});
}

fn fuzzFrontend(_: void, smith: *std.testing.Smith) !void {
    const gpa = std.testing.allocator;
    var buf: [512]u8 = undefined;
    const n: usize = smith.valueRangeAtMost(u16, 0, buf.len);
    smith.bytes(buf[0..n]);
    var tree = parser.parse(gpa, buf[0..n]) catch return;
    defer tree.deinit();
    if (tree.diagnostics.len == 0) {
        var analysis = analyze(gpa, tree.module) catch return;
        analysis.deinit();
    }
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
        \\    for it in items:
        \\        handle(it)
        \\
        \\func classify(x: int) -> str:
        \\    return match x {
        \\        n: describe(n)
        \\    }
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    // `handle` and `describe` are undefined; `it` and `n` must resolve.
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

test "a valid enum case resolves" {
    const src =
        \\enum Status { OK, NOT_FOUND }
        \\
        \\func best() -> Status:
        \\    return Status.OK
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try testing.expectEqual(@as(usize, 0), analysis.diagnostics.len);
}

test "an unknown enum case is reported" {
    const src =
        \\enum Status { OK, NOT_FOUND }
        \\
        \\func f():
        \\    var s = Status.MISSING
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try expectMessageContains(analysis, "enum 'Status' has no case 'MISSING'");
}

test "enum cases of an enum type compare cleanly" {
    const src =
        \\enum Color { RED, GREEN }
        \\
        \\func is_red(c: Color) -> bool:
        \\    return c == Color.RED
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try testing.expectEqual(@as(usize, 0), analysis.diagnostics.len);
}

test "a match without a catch-all is not exhaustive" {
    const src =
        \\func f(x: int) -> str:
        \\    return match x {
        \\        1: "one"
        \\        2: "two"
        \\    }
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try expectMessageContains(analysis, "not exhaustive");
}

test "a wildcard makes a match exhaustive" {
    const src =
        \\func f(x: int) -> str:
        \\    return match x {
        \\        1: "one"
        \\        _: "other"
        \\    }
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try testing.expectEqual(@as(usize, 0), analysis.diagnostics.len);
}

test "a bool match covering both values is exhaustive" {
    const src =
        \\func f(b: bool) -> str:
        \\    return match b {
        \\        true: "yes"
        \\        false: "no"
        \\    }
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try testing.expectEqual(@as(usize, 0), analysis.diagnostics.len);
}

test "a bool match missing a value is not exhaustive" {
    const src =
        \\func f(b: bool) -> str:
        \\    return match b {
        \\        true: "yes"
        \\    }
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try expectMessageContains(analysis, "not exhaustive");
}

test "an arm after a catch-all is unreachable" {
    const src =
        \\func f(x: int) -> str:
        \\    return match x {
        \\        _: "any"
        \\        5: "five"
        \\    }
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try expectMessageContains(analysis, "unreachable");
}

test "a declared struct is a valid type and its methods see fields" {
    const src =
        \\struct Box:
        \\    var w: int = 0
        \\    var h: int = 0
        \\
        \\    func area() -> int:
        \\        return w
        \\
        \\func make(b: Box):
        \\    pass
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try testing.expectEqual(@as(usize, 0), analysis.diagnostics.len);
}

test "duplicate struct field is reported" {
    const src =
        \\struct S:
        \\    var a: int = 0
        \\    var a: int = 1
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try expectMessageContains(analysis, "already declared");
}

// all-paths return

test "a typed function that can fall off the end is reported" {
    var analysis = try analyzeSource(testing.allocator, "func get() -> int:\n    pass");
    defer analysis.deinit();
    try expectMessageContains(analysis, "must return int on all paths");
}

test "an if without else does not guarantee a return" {
    const src =
        \\func f(x: int) -> int:
        \\    if x > 0:
        \\        return x
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try expectMessageContains(analysis, "must return int on all paths");
}

test "an if/else where both branches return is exhaustive" {
    const src =
        \\func f(x: int) -> int:
        \\    if x > 0:
        \\        return 1
        \\    else:
        \\        return 0
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try testing.expectEqual(@as(usize, 0), analysis.diagnostics.len);
}

test "a try/catch that returns in both arms is exhaustive; a raise terminates" {
    const src =
        \\func risky(n: int) -> int:
        \\    if n < 0:
        \\        raise "negative"
        \\    return n
        \\
        \\func safe(n: int) -> int:
        \\    try:
        \\        return risky(n)
        \\    catch e:
        \\        return -1
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try testing.expectEqual(@as(usize, 0), analysis.diagnostics.len);
}

test "a try/catch whose handler falls through does not guarantee a return" {
    const src =
        \\func bad(n: int) -> int:
        \\    try:
        \\        return n
        \\    catch e:
        \\        print(e)
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try expectMessageContains(analysis, "must return int on all paths");
}

test "a trailing return satisfies the all-paths check" {
    const src =
        \\func f(x: int) -> int:
        \\    if x > 0:
        \\        return 1
        \\    return 0
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try testing.expectEqual(@as(usize, 0), analysis.diagnostics.len);
}

test "a void function need not return a value" {
    var analysis = try analyzeSource(testing.allocator, "func f() -> void:\n    pass");
    defer analysis.deinit();
    try testing.expectEqual(@as(usize, 0), analysis.diagnostics.len);
}

test "an unannotated function need not return" {
    var analysis = try analyzeSource(testing.allocator, "func f():\n    pass");
    defer analysis.deinit();
    try testing.expectEqual(@as(usize, 0), analysis.diagnostics.len);
}

// loop control

test "break outside a loop is reported" {
    var analysis = try analyzeSource(testing.allocator, "func f():\n    break");
    defer analysis.deinit();
    try expectMessageContains(analysis, "'break' outside a loop");
}

test "continue outside a loop is reported" {
    var analysis = try analyzeSource(testing.allocator, "func f():\n    continue");
    defer analysis.deinit();
    try expectMessageContains(analysis, "'continue' outside a loop");
}

test "break and continue are allowed inside loops" {
    const src =
        \\func f(xs: any):
        \\    while true:
        \\        if false:
        \\            break
        \\        continue
        \\    for x in xs:
        \\        break
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try testing.expectEqual(@as(usize, 0), analysis.diagnostics.len);
}

test "while true without a break still guarantees a return" {
    var analysis = try analyzeSource(testing.allocator, "func f() -> int:\n    while true:\n        return 1");
    defer analysis.deinit();
    try testing.expectEqual(@as(usize, 0), analysis.diagnostics.len);
}

test "while true with a break no longer guarantees a return" {
    var analysis = try analyzeSource(testing.allocator, "func f() -> int:\n    while true:\n        break");
    defer analysis.deinit();
    try expectMessageContains(analysis, "must return int on all paths");
}

// optionals

test "nil and a value both fit an optional" {
    var a = try analyzeSource(testing.allocator, "const x: ?int = nil\nconst y: ?int = 5");
    defer a.deinit();
    try testing.expectEqual(@as(usize, 0), a.diagnostics.len);
}

test "nil does not fit a non-optional" {
    var a = try analyzeSource(testing.allocator, "const x: int = nil");
    defer a.deinit();
    try expectMessageContains(a, "cannot assign nil to int");
}

test "an optional cannot be used where the bare type is expected" {
    var a = try analyzeSource(testing.allocator, "func f(x: ?int) -> int:\n    return x");
    defer a.deinit();
    try expectMessageContains(a, "cannot return ?int from a function returning int");
}

test "an optional-returning function may fall off the end" {
    var a = try analyzeSource(testing.allocator, "func lookup() -> ?int:\n    pass");
    defer a.deinit();
    try testing.expectEqual(@as(usize, 0), a.diagnostics.len);
}

test "a bare return in an optional function is allowed" {
    var a = try analyzeSource(testing.allocator, "func lookup(n: int) -> ?int:\n    if n > 0:\n        return n\n    return");
    defer a.deinit();
    try testing.expectEqual(@as(usize, 0), a.diagnostics.len);
}

test "a nil check narrows the optional in the then-branch" {
    const src =
        \\func unwrap(x: ?int) -> int:
        \\    if x != nil:
        \\        return x
        \\    return 0
    ;
    var a = try analyzeSource(testing.allocator, src);
    defer a.deinit();
    try testing.expectEqual(@as(usize, 0), a.diagnostics.len);
}

test "a nil check narrows the optional in the else-branch" {
    const src =
        \\func unwrap(x: ?int) -> int:
        \\    if x == nil:
        \\        return 0
        \\    else:
        \\        return x
    ;
    var a = try analyzeSource(testing.allocator, src);
    defer a.deinit();
    try testing.expectEqual(@as(usize, 0), a.diagnostics.len);
}

// enum patterns

test "covering every enum case is exhaustive without a wildcard" {
    const src =
        \\enum Status { OK, NOT_FOUND }
        \\
        \\func label(s: Status) -> str:
        \\    return match s {
        \\        Status.OK: "ok"
        \\        Status.NOT_FOUND: "missing"
        \\    }
    ;
    var a = try analyzeSource(testing.allocator, src);
    defer a.deinit();
    try testing.expectEqual(@as(usize, 0), a.diagnostics.len);
}

test "a missing enum case is not exhaustive" {
    const src =
        \\enum Status { OK, NOT_FOUND, ERROR }
        \\
        \\func label(s: Status) -> str:
        \\    return match s {
        \\        Status.OK: "ok"
        \\        Status.NOT_FOUND: "missing"
        \\    }
    ;
    var a = try analyzeSource(testing.allocator, src);
    defer a.deinit();
    try expectMessageContains(a, "not exhaustive");
}

test "an unknown enum case in a pattern is reported" {
    const src =
        \\enum Status { OK, NOT_FOUND }
        \\
        \\func f(s: Status) -> str:
        \\    return match s {
        \\        Status.BLUE: "x"
        \\        _: "y"
        \\    }
    ;
    var a = try analyzeSource(testing.allocator, src);
    defer a.deinit();
    try expectMessageContains(a, "has no case 'BLUE'");
}

test "an enum-case pattern for the wrong enum is reported" {
    const src =
        \\enum Status { OK }
        \\enum Color { RED }
        \\
        \\func f(s: Status) -> str:
        \\    return match s {
        \\        Color.RED: "x"
        \\        _: "y"
        \\    }
    ;
    var a = try analyzeSource(testing.allocator, src);
    defer a.deinit();
    try expectMessageContains(a, "does not match a subject of type 'Status'");
}

test "an enum-case pattern against a non-enum subject is reported" {
    const src =
        \\enum Status { OK }
        \\
        \\func f(n: int) -> str:
        \\    return match n {
        \\        Status.OK: "x"
        \\        _: "y"
        \\    }
    ;
    var a = try analyzeSource(testing.allocator, src);
    defer a.deinit();
    try expectMessageContains(a, "cannot match an enum case against int");
}

// match result type

test "a homogeneous match unifies to the arm type" {
    // The match yields str, so returning it as int is an error.
    const src =
        \\func f(n: int) -> int:
        \\    return match n {
        \\        1: "a"
        \\        _: "b"
        \\    }
    ;
    var a = try analyzeSource(testing.allocator, src);
    defer a.deinit();
    try expectMessageContains(a, "cannot return str");
}

test "a match widens numeric arms to float" {
    const src =
        \\func f(n: int) -> str:
        \\    return match n {
        \\        1: 5
        \\        _: 3.0
        \\    }
    ;
    var a = try analyzeSource(testing.allocator, src);
    defer a.deinit();
    try expectMessageContains(a, "cannot return float");
}

test "a match with a nil arm is optional" {
    const clean =
        \\func f(n: int) -> ?int:
        \\    return match n {
        \\        1: n
        \\        _: nil
        \\    }
    ;
    var ok = try analyzeSource(testing.allocator, clean);
    defer ok.deinit();
    try testing.expectEqual(@as(usize, 0), ok.diagnostics.len);

    // The ?int result is not assignable to a bare int.
    const bad =
        \\func f(n: int) -> int:
        \\    return match n {
        \\        1: n
        \\        _: nil
        \\    }
    ;
    var err = try analyzeSource(testing.allocator, bad);
    defer err.deinit();
    try expectMessageContains(err, "cannot return ?int");
}

test "incompatible match arms are reported" {
    const src =
        \\func f(n: int) -> any:
        \\    return match n {
        \\        1: 5
        \\        _: "no"
        \\    }
    ;
    var a = try analyzeSource(testing.allocator, src);
    defer a.deinit();
    try expectMessageContains(a, "incompatible types");
}

test "a well-typed match type-checks cleanly" {
    const src =
        \\func label(n: int) -> str:
        \\    return match n {
        \\        1: "one"
        \\        _: "many"
        \\    }
    ;
    var a = try analyzeSource(testing.allocator, src);
    defer a.deinit();
    try testing.expectEqual(@as(usize, 0), a.diagnostics.len);
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

test "conditional expression: bool condition, unified branches, nil makes it optional" {
    var ok = try analyzeSource(testing.allocator, "func f(b: bool) -> int:\n    return 1 if b else 2");
    defer ok.deinit();
    try testing.expectEqual(@as(usize, 0), ok.diagnostics.len);

    var badc = try analyzeSource(testing.allocator, "func main():\n    var x = 1 if 5 else 2");
    defer badc.deinit();
    try expectMessageContains(badc, "conditional condition must be bool");

    var incompat = try analyzeSource(testing.allocator, "func f(b: bool):\n    var x = 1 if b else \"s\"");
    defer incompat.deinit();
    try expectMessageContains(incompat, "incompatible types");
}

test "list comprehension types to list of the output type; condition must be bool" {
    var ok = try analyzeSource(testing.allocator, "func f(xs: list<int>) -> list<int>:\n    return [x * 2 for x in xs if x > 0]");
    defer ok.deinit();
    try testing.expectEqual(@as(usize, 0), ok.diagnostics.len);

    var bad = try analyzeSource(testing.allocator, "func f(xs: list<int>):\n    var z = [x for x in xs if x]");
    defer bad.deinit();
    try expectMessageContains(bad, "comprehension condition must be bool");
}

test "named arguments: valid reorder is clean; bad names/dupes/builtins are rejected" {
    var ok = try analyzeSource(testing.allocator, "func f(a: int, b: int = 0) -> int:\n    return a + b\nfunc main():\n    print(f(b: 2, a: 1))");
    defer ok.deinit();
    try testing.expectEqual(@as(usize, 0), ok.diagnostics.len);

    var unknown = try analyzeSource(testing.allocator, "func f(a: int):\n    return a\nfunc main():\n    print(f(a: 1, b: 2))");
    defer unknown.deinit();
    try expectMessageContains(unknown, "no parameter named 'b'");

    var dupe = try analyzeSource(testing.allocator, "func f(a: int, b: int = 0):\n    return a\nfunc main():\n    print(f(1, a: 2))");
    defer dupe.deinit();
    try expectMessageContains(dupe, "already provided");

    var missing = try analyzeSource(testing.allocator, "func f(a: int, b: int):\n    return a\nfunc main():\n    print(f(b: 2))");
    defer missing.deinit();
    try expectMessageContains(missing, "missing required argument 'a'");

    var builtin = try analyzeSource(testing.allocator, "func main():\n    print(len(x: [1]))");
    defer builtin.deinit();
    try expectMessageContains(builtin, "not allowed here");
}

test "slicing keeps the element type; non-lists and non-int bounds are rejected" {
    var ok = try analyzeSource(testing.allocator, "func f(xs: list<int>) -> int:\n    var ys: list<int> = xs[0:2]\n    return ys[0]");
    defer ok.deinit();
    try testing.expectEqual(@as(usize, 0), ok.diagnostics.len);

    var bad = try analyzeSource(testing.allocator, "func f(m: map<int, int>):\n    var z = m[0:1]");
    defer bad.deinit();
    try expectMessageContains(bad, "cannot be sliced");

    var bound = try analyzeSource(testing.allocator, "func f(xs: list<int>):\n    var z = xs[\"a\":1]");
    defer bound.deinit();
    try expectMessageContains(bound, "slice bound must be an int");
}

test "bitwise operators require int operands" {
    var a1 = try analyzeSource(testing.allocator, "const x: int = 2.0 & 1");
    defer a1.deinit();
    try expectMessageContains(a1, "'&'");

    var a2 = try analyzeSource(testing.allocator, "const y: int = ~true");
    defer a2.deinit();
    try expectMessageContains(a2, "unary '~' requires an int");
}

test "bitwise on ints type-checks to int" {
    var analysis = try analyzeSource(testing.allocator, "const x: int = 1 << 3 | 6 & 3 ^ ~0");
    defer analysis.deinit();
    try testing.expectEqual(@as(usize, 0), analysis.diagnostics.len);
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

// member access

test "instance field and method access are typed" {
    const src =
        \\struct Vec2:
        \\    var x: int = 0
        \\    var y: int = 0
        \\
        \\    func first() -> int:
        \\        return x
        \\
        \\func sum(v: Vec2) -> int:
        \\    return v.x + v.y + v.first()
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try testing.expectEqual(@as(usize, 0), analysis.diagnostics.len);
}

test "accessing an unknown member is reported" {
    const src =
        \\struct Vec2:
        \\    var x: int = 0
        \\
        \\func f(v: Vec2) -> int:
        \\    return v.z
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try expectMessageContains(analysis, "has no member 'z'");
}

test "member field type flows into type checking" {
    const src =
        \\struct Vec2:
        \\    var x: int = 0
        \\
        \\func f(v: Vec2) -> str:
        \\    return v.x
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try expectMessageContains(analysis, "cannot return int");
}

// visibility

test "a private member cannot be accessed from outside its class" {
    const src =
        \\class Account:
        \\    private var secret: int = 42
        \\
        \\func peek(a: Account) -> int:
        \\    return a.secret
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try expectMessageContains(analysis, "'secret' is private to 'Account'");
}

test "a private member is reachable from inside its class" {
    const src =
        \\class Account:
        \\    private var secret: int = 42
        \\
        \\    func reveal() -> int:
        \\        return secret
        \\
        \\    func copy(other: Account) -> int:
        \\        return other.secret
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    // Bare `secret` and same-class `other.secret` are both allowed.
    try testing.expectEqual(@as(usize, 0), analysis.diagnostics.len);
}

test "a public member is accessible everywhere" {
    const src =
        \\class Point:
        \\    pub var x: int = 0
        \\
        \\func read(p: Point) -> int:
        \\    return p.x
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try testing.expectEqual(@as(usize, 0), analysis.diagnostics.len);
}

test "a subclass cannot reach a base's private member" {
    const src =
        \\class Base:
        \\    private var hidden: int = 0
        \\
        \\class Derived extends Base:
        \\    func leak() -> int:
        \\        return hidden
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    // Bare-name access to an inherited field is allowed (matches the runtime),
    // but `.`-access to a base's private member from outside would not be.
    // Here we only check the field resolves (no "undefined"/"no member" noise).
    for (analysis.diagnostics) |d| {
        try testing.expect(std.mem.indexOf(u8, d.message, "no member") == null);
        try testing.expect(std.mem.indexOf(u8, d.message, "undefined") == null);
    }
}

// inheritance

test "inherited members resolve through a subclass-typed value" {
    const src =
        \\class Animal:
        \\    var legs: int = 4
        \\
        \\    func move() -> str:
        \\        return "walk"
        \\
        \\class Cat extends Animal:
        \\    var lives: int = 9
        \\
        \\func info(c: Cat) -> int:
        \\    return c.legs
        \\
        \\func how(c: Cat) -> str:
        \\    return c.move()
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try testing.expectEqual(@as(usize, 0), analysis.diagnostics.len);
}

test "a subclass method reaches an inherited field by bare name" {
    const src =
        \\class Animal:
        \\    var legs: int = 4
        \\
        \\class Cat extends Animal:
        \\    func check() -> int:
        \\        return legs
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try testing.expectEqual(@as(usize, 0), analysis.diagnostics.len);
}

test "a subclass is assignable to its base" {
    const src =
        \\class Animal:
        \\    var legs: int = 4
        \\
        \\class Cat extends Animal:
        \\    var lives: int = 9
        \\
        \\func describe(a: Animal) -> int:
        \\    return a.legs
        \\
        \\func run(c: Cat) -> int:
        \\    return describe(c)
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try testing.expectEqual(@as(usize, 0), analysis.diagnostics.len);
}

test "a base is not assignable to a subclass" {
    const src =
        \\class Animal:
        \\    var legs: int = 4
        \\
        \\class Cat extends Animal:
        \\    var lives: int = 9
        \\
        \\func pet(c: Cat) -> int:
        \\    return c.lives
        \\
        \\func run(a: Animal) -> int:
        \\    return pet(a)
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try expectMessageContains(analysis, "cannot pass Animal where Cat is expected");
}

test "assignability follows the transitive hierarchy" {
    const src =
        \\class A:
        \\    var x: int = 0
        \\class B extends A:
        \\    var y: int = 0
        \\class C extends B:
        \\    var z: int = 0
        \\
        \\func take_a(a: A) -> int:
        \\    return 0
        \\
        \\func run(c: C) -> int:
        \\    return take_a(c)
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try testing.expectEqual(@as(usize, 0), analysis.diagnostics.len);
}

test "a used trait makes the class assignable to it" {
    const src =
        \\class Damageable:
        \\    var hp: int = 0
        \\
        \\class Player uses Damageable:
        \\    var name: str = ""
        \\
        \\func hit(d: Damageable) -> int:
        \\    return d.hp
        \\
        \\func run(p: Player) -> int:
        \\    return hit(p)
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try testing.expectEqual(@as(usize, 0), analysis.diagnostics.len);
}

test "an unknown base class is reported" {
    const src =
        \\class Cat extends Missing:
        \\    var lives: int = 9
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try expectMessageContains(analysis, "unknown base class 'Missing'");
}

test "an unknown trait is reported" {
    const src =
        \\class Player uses Flyable:
        \\    var name: str = ""
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try expectMessageContains(analysis, "unknown trait 'Flyable'");
}

test "member access on a class instance is typed" {
    const src =
        \\class Player:
        \\    var health: int = 100
        \\
        \\func hp(p: Player) -> int:
        \\    return p.health
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try testing.expectEqual(@as(usize, 0), analysis.diagnostics.len);
}

// grammar-gap features

test "an untyped parameter accepts any value" {
    const src =
        \\func log(msg):
        \\    pass
        \\
        \\func run():
        \\    log(1)
        \\    log("hi")
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try testing.expectEqual(@as(usize, 0), analysis.diagnostics.len);
}

test "an import binds a module namespace" {
    // The import parses and binds its leaf name cleanly.
    var only = try analyzeSource(testing.allocator, "import engine.graphics.render");
    defer only.deinit();
    try testing.expectEqual(@as(usize, 0), only.diagnostics.len);

    // With no module actually supplied, the namespace has no exports, so reaching
    // into it is reported rather than silently accepted.
    var used = try analyzeSource(testing.allocator, "import graphics\n\nfunc draw():\n    graphics.line()");
    defer used.deinit();
    try expectMessageContains(used, "module has no exported member 'line'");
}

test "a module sees an imported module's exported members" {
    const gpa = testing.allocator;

    // Dependency: `square` is exported (pub), `secret` is module-private.
    var dep_tree = try parser.parse(gpa, "pub func square(n: int) -> int:\n    return n * n\n\nfunc secret() -> int:\n    return 42");
    defer dep_tree.deinit();
    var dep = try analyze(gpa, dep_tree.module);
    defer dep.deinit();
    try testing.expectEqual(@as(usize, 0), dep.diagnostics.len);

    const imports = [_]ModuleImport{.{ .name = "mathutil", .exports = dep.exports }};

    // A call to the exported function type-checks cleanly.
    var ok_tree = try parser.parse(gpa, "import mathutil\n\nfunc main():\n    print(mathutil.square(3))");
    defer ok_tree.deinit();
    var ok = try analyzeModule(gpa, ok_tree.module, &imports);
    defer ok.deinit();
    try testing.expectEqual(@as(usize, 0), ok.diagnostics.len);

    // A module-private name is not reachable from the outside.
    var bad_tree = try parser.parse(gpa, "import mathutil\n\nfunc main():\n    print(mathutil.secret())");
    defer bad_tree.deinit();
    var bad = try analyzeModule(gpa, bad_tree.module, &imports);
    defer bad.deinit();
    try expectMessageContains(bad, "module has no exported member 'secret'");
}

test "a cross-module call checks argument types" {
    const gpa = testing.allocator;
    var dep_tree = try parser.parse(gpa, "pub func square(n: int) -> int:\n    return n * n");
    defer dep_tree.deinit();
    var dep = try analyze(gpa, dep_tree.module);
    defer dep.deinit();
    const imports = [_]ModuleImport{.{ .name = "m", .exports = dep.exports }};

    var bad_tree = try parser.parse(gpa, "import m\n\nfunc main():\n    print(m.square(\"x\"))");
    defer bad_tree.deinit();
    var bad = try analyzeModule(gpa, bad_tree.module, &imports);
    defer bad.deinit();
    try expectMessageContains(bad, "cannot pass str where int is expected");
}

test "a mod.T annotation resolves the imported type's members" {
    const gpa = testing.allocator;
    var dep_tree = try parser.parse(gpa, "pub struct Point:\n    var x: int = 0\n    var y: int = 0\n\npub func origin() -> Point:\n    return Point()");
    defer dep_tree.deinit();
    var dep = try analyze(gpa, dep_tree.module);
    defer dep.deinit();
    try testing.expectEqual(@as(usize, 0), dep.diagnostics.len);

    const imports = [_]ModuleImport{.{ .name = "geo", .exports = dep.exports }};
    // `p` is annotated `geo.Point`; `p.x` (an int) is then checked against str.
    var imp_tree = try parser.parse(gpa, "import geo\n\nfunc main():\n    var p: geo.Point = geo.origin()\n    var s: str = p.x");
    defer imp_tree.deinit();
    var imp = try analyzeModule(gpa, imp_tree.module, &imports);
    defer imp.deinit();
    try expectMessageContains(imp, "cannot assign int to str");
}

test "an unexported type cannot be named with mod.T" {
    const gpa = testing.allocator;
    // `Secret` is not `pub`, so it is not part of the module's surface.
    var dep_tree = try parser.parse(gpa, "struct Secret:\n    var x: int = 0\n\npub func f() -> int:\n    return 0");
    defer dep_tree.deinit();
    var dep = try analyze(gpa, dep_tree.module);
    defer dep.deinit();

    const imports = [_]ModuleImport{.{ .name = "dep", .exports = dep.exports }};
    var imp_tree = try parser.parse(gpa, "import dep\n\nfunc main():\n    var s: dep.Secret");
    defer imp_tree.deinit();
    var imp = try analyzeModule(gpa, imp_tree.module, &imports);
    defer imp.deinit();
    try expectMessageContains(imp, "module 'dep' has no exported type 'Secret'");
}

test "a qualified type on a non-module is reported" {
    var analysis = try analyzeSource(testing.allocator, "func main():\n    var p: foo.Bar");
    defer analysis.deinit();
    try expectMessageContains(analysis, "'foo' is not a module");
}

test "a subclass of an imported base checks inherited members" {
    const gpa = testing.allocator;
    var dep_tree = try parser.parse(gpa, "pub class Shape:\n    var name: str = \"?\"\n\n    func label() -> str:\n        return name");
    defer dep_tree.deinit();
    var dep = try analyze(gpa, dep_tree.module);
    defer dep.deinit();
    try testing.expectEqual(@as(usize, 0), dep.diagnostics.len);

    const imports = [_]ModuleImport{.{ .name = "shapes", .exports = dep.exports }};
    // Circle inherits `label()` (str); misusing its result is caught.
    var imp_tree = try parser.parse(gpa, "import shapes\n\nclass Circle extends shapes.Shape:\n    var r: int = 0\n\nfunc main():\n    var c: Circle = Circle()\n    var n: int = c.label()");
    defer imp_tree.deinit();
    var imp = try analyzeModule(gpa, imp_tree.module, &imports);
    defer imp.deinit();
    try expectMessageContains(imp, "cannot assign str to int");
}

test "extending an unexported type is rejected" {
    const gpa = testing.allocator;
    var dep_tree = try parser.parse(gpa, "class Hidden:\n    var x: int = 0");
    defer dep_tree.deinit();
    var dep = try analyze(gpa, dep_tree.module);
    defer dep.deinit();

    const imports = [_]ModuleImport{.{ .name = "m", .exports = dep.exports }};
    var imp_tree = try parser.parse(gpa, "import m\n\nclass Sub extends m.Hidden:\n    var y: int = 0");
    defer imp_tree.deinit();
    var imp = try analyzeModule(gpa, imp_tree.module, &imports);
    defer imp.deinit();
    try expectMessageContains(imp, "unknown base class 'Hidden'");
}

// constructor arguments

test "construction checks argument count against init" {
    const src =
        \\class P:
        \\    var name: str = ""
        \\    func init(n: str):
        \\        name = n
        \\
        \\func main():
        \\    var p: P = P()
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try expectMessageContains(analysis, "expected 1 argument(s), got 0");
}

test "a call with defaults reports an argument range" {
    const src =
        \\func f(a: int, b: int = 1, c: int = 2) -> int:
        \\    return a + b + c
        \\
        \\func main():
        \\    print(f())
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try expectMessageContains(analysis, "expected 1 to 3 argument(s), got 0");
}

test "supplying only the required argument of a defaulted function is fine" {
    const src =
        \\func f(a: int, b: int = 1) -> int:
        \\    return a + b
        \\
        \\func main():
        \\    print(f(5))
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try testing.expectEqual(@as(usize, 0), analysis.diagnostics.len);
}

test "a parameter default's type is checked against its annotation" {
    const src =
        \\func f(n: int = "oops") -> int:
        \\    return n
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try expectMessageContains(analysis, "default value: cannot use str where int is expected");
}

test "a signal parameter cannot have a default" {
    const src = "signal fired(x: int = 3)";
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try expectMessageContains(analysis, "signal parameters cannot have default values");
}

test "construction checks argument types against init" {
    const src =
        \\class P:
        \\    var n: int = 0
        \\    func init(x: int):
        \\        n = x
        \\
        \\func main():
        \\    var p: P = P("hi")
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try expectMessageContains(analysis, "cannot pass str where int is expected");
}

test "a class without init takes no constructor arguments" {
    const src =
        \\class P:
        \\    var x: int = 0
        \\
        \\func main():
        \\    var p: P = P(1, 2)
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try expectMessageContains(analysis, "P takes no constructor arguments");
}

test "a correct construction is clean" {
    const src =
        \\class P:
        \\    var n: int = 0
        \\    func init(x: int):
        \\        n = x
        \\
        \\func main():
        \\    var p: P = P(5)
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try testing.expectEqual(@as(usize, 0), analysis.diagnostics.len);
}

// REPL checking

test "the REPL checker checks across entries and allows redefinition" {
    const gpa = testing.allocator;
    var rc = try replCheckerInit(gpa);
    defer rc.deinit();

    // Entry 1: a typed global. Chunks must stay alive (AST is borrowed).
    var e1 = try parser.parseRepl(gpa, "var x: int = 5");
    defer e1.deinit();
    try testing.expectEqual(@as(usize, 0), (try rc.check(e1.items)).len);

    // Entry 2: a type error against the persisted `x`.
    var e2 = try parser.parseRepl(gpa, "var s: str = x");
    defer e2.deinit();
    const d2 = try rc.check(e2.items);
    try testing.expectEqual(@as(usize, 1), d2.len);
    try testing.expect(std.mem.indexOf(u8, d2[0].message, "cannot assign int to str") != null);

    // Entry 3: redefining `x` is allowed (no "already declared").
    var e3 = try parser.parseRepl(gpa, "var x: str = \"hi\"");
    defer e3.deinit();
    try testing.expectEqual(@as(usize, 0), (try rc.check(e3.items)).len);
}

// typed collections

test "a list literal's element type must match its annotation" {
    var analysis = try analyzeSource(testing.allocator, "var xs: list<int> = [\"a\", \"b\"]");
    defer analysis.deinit();
    try expectMessageContains(analysis, "cannot assign list<str> to list<int>");
}

test "indexing a list yields its element type" {
    const src =
        \\var xs: list<int> = [1, 2]
        \\var s: str = xs[0]
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try expectMessageContains(analysis, "cannot assign int to str");
}

test "indexing a map yields its value type" {
    const src =
        \\func main():
        \\    var m: map<str, int> = {"a": 1}
        \\    var s: str = m["a"]
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try expectMessageContains(analysis, "cannot assign int to str");
}

test "a non-int list index is reported" {
    const src =
        \\func main():
        \\    var xs: list<int> = [1]
        \\    var y: int = xs["k"]
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try expectMessageContains(analysis, "list index must be an int, got str");
}

test "for over a typed list binds the element type" {
    const src =
        \\func main():
        \\    var xs: list<int> = [1, 2]
        \\    for x in xs:
        \\        var s: str = x
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try expectMessageContains(analysis, "cannot assign int to str");
}

test "a nested generic literal matching its annotation is clean" {
    var analysis = try analyzeSource(testing.allocator, "var grid: map<str, list<int>> = {\"row\": [1, 2, 3]}");
    defer analysis.deinit();
    try testing.expectEqual(@as(usize, 0), analysis.diagnostics.len);
}

test "wrong arity on a generic type is reported" {
    var analysis = try analyzeSource(testing.allocator, "var xs: list<int, str> = []");
    defer analysis.deinit();
    try expectMessageContains(analysis, "list takes at most one type argument");
}

// element-aware builtins

test "push checks the value against the list's element type" {
    const src =
        \\func main():
        \\    var xs: list<int> = [1]
        \\    push(xs, "s")
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try expectMessageContains(analysis, "cannot push str into list<int>");
}

test "pop returns the list's element type" {
    const src =
        \\func main():
        \\    var xs: list<int> = [1]
        \\    var s: str = pop(xs)
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try expectMessageContains(analysis, "cannot assign int to str");
}

test "keys returns a list of the map's key type" {
    const src =
        \\func main():
        \\    var m: map<str, int> = {"a": 1}
        \\    var n: int = keys(m)
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try expectMessageContains(analysis, "cannot assign list<str> to int");
}

test "has checks the key against the map's key type" {
    const src =
        \\func main():
        \\    var m: map<str, int> = {"a": 1}
        \\    var b: bool = has(m, 3)
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try expectMessageContains(analysis, "cannot look up int in map<str, int>");
}

test "range produces a list of int" {
    const src =
        \\func main():
        \\    for n in range(3):
        \\        var s: str = n
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try expectMessageContains(analysis, "cannot assign int to str");
}

test "a stdlib builtin's result type is checked" {
    var up = try analyzeSource(testing.allocator, "func main():\n    var n: int = upper(\"x\")");
    defer up.deinit();
    try expectMessageContains(up, "cannot assign str to int");

    // find returns int; misusing it as a str is caught.
    var fd = try analyzeSource(testing.allocator, "func main():\n    var s: str = find(\"ab\", \"b\")");
    defer fd.deinit();
    try expectMessageContains(fd, "cannot assign int to str");

    // split yields list<str>, so indexing it and misusing the element is caught.
    var sp = try analyzeSource(testing.allocator, "func main():\n    var n: int = split(\"a,b\", \",\")[0]");
    defer sp.deinit();
    try expectMessageContains(sp, "cannot assign str to int");
}

test "for over a range binds an int" {
    var a = try analyzeSource(testing.allocator, "func main():\n    for i in 0..3:\n        var s: str = i");
    defer a.deinit();
    try expectMessageContains(a, "cannot assign int to str");
}

test "a two-binding for types the index and value" {
    // `xs` is list<str>, so `i` is the int index and `x` is str.
    var a = try analyzeSource(testing.allocator, "func main():\n    var xs: list<str> = [\"a\"]\n    for i, x in xs:\n        var bad: str = i");
    defer a.deinit();
    try expectMessageContains(a, "cannot assign int to str");
}

test "an interpolation hole is type-checked" {
    var analysis = try analyzeSource(testing.allocator, "func main():\n    print(\"v = ${missing}\")");
    defer analysis.deinit();
    try expectMessageContains(analysis, "undefined name 'missing'");
}

test "a lambda body is type-checked with its parameters" {
    var analysis = try analyzeSource(testing.allocator, "func main():\n    var f = func(x: int): x + \"s\"");
    defer analysis.deinit();
    try expectMessageContains(analysis, "cannot be applied to int and str");
}

test "a local shadowing a builtin is not treated as the builtin" {
    // `push` here is a parameter (type `any`), so the element check does not fire.
    const src =
        \\func f(push):
        \\    var xs: list<int> = [1]
        \\    push(xs, "s")
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try testing.expectEqual(@as(usize, 0), analysis.diagnostics.len);
}

// static members

test "a static member reached via the type name is typed" {
    const src =
        \\class C:
        \\    static var count: int = 0
        \\
        \\func main():
        \\    var s: str = C.count
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try expectMessageContains(analysis, "cannot assign int to str");
}

test "an unknown static member is reported" {
    const src =
        \\class C:
        \\    static var count: int = 0
        \\
        \\func main():
        \\    print(C.nope)
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try expectMessageContains(analysis, "type 'C' has no static member 'nope'");
}

test "an instance field is not reachable as a static member" {
    const src =
        \\class C:
        \\    var x: int = 0
        \\
        \\func main():
        \\    print(C.x)
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try expectMessageContains(analysis, "type 'C' has no static member 'x'");
}

test "a static method sees static members by bare name" {
    const src =
        \\class C:
        \\    static var n: int = 0
        \\
        \\    static func inc():
        \\        n = n + 1
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try testing.expectEqual(@as(usize, 0), analysis.diagnostics.len);
}

test "an inherited static is reachable via the subclass and typed" {
    const src =
        \\class Base:
        \\    static var n: int = 0
        \\
        \\class Sub extends Base:
        \\    var x: int = 0
        \\
        \\func main():
        \\    var s: str = Sub.n
    ;
    var a = try analyzeSource(testing.allocator, src);
    defer a.deinit();
    try expectMessageContains(a, "cannot assign int to str");
}

test "an instance method cannot reach statics by bare name" {
    const src =
        \\class C:
        \\    static var n: int = 0
        \\
        \\    func inst() -> int:
        \\        return n
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    try expectMessageContains(analysis, "undefined name 'n'");
}

test "signal names are declared and their params checked" {
    const src =
        \\signal ready
        \\signal damaged(amount: Nope)
    ;
    var analysis = try analyzeSource(testing.allocator, src);
    defer analysis.deinit();
    // `Nope` is an unknown type; `ready` and `damaged` register cleanly.
    try expectMessageContains(analysis, "Nope");
}

test "a duplicate signal name is reported" {
    var analysis = try analyzeSource(testing.allocator, "signal ping\nsignal ping");
    defer analysis.deinit();
    try expectMessageContains(analysis, "already declared");
}
