//! RoseGold interpreter.
//! Targets Zig 0.16.0.
//!
//! A tree-walking evaluator over the parser's AST. It executes the core of the
//! language: scalars, variables, arithmetic/comparison/logical operators,
//! functions (with recursion), `if`/`elif`/`else`, `while`, `for`, `return`,
//! `match`, list/map literals and indexing, and the `print`, `echo`, `len`,
//! and `range` builtins. `for` iterates a list's elements, a string's
//! characters, or a map's keys.
//!
//! Execution binds each module's globals (functions and evaluated `const`/`var`)
//! into its own environment, then calls the entry module's `main()`. A program
//! is one or more modules in dependency order (`runProgram`); `run` is the
//! single-module case. An imported module is a value whose members are its
//! globals, and a function/method carries the globals of the module that defined
//! it, so it always resolves names in its own module. Program output is collected
//! into a buffer rather than written directly, so it is easy to test.
//!
//! Classes and structs execute: `Name(...)` constructs an instance (fields take
//! their declared defaults; a method named `init` runs as the constructor),
//! fields and methods are reached with `.`, and a method's body sees its own
//! instance's fields and methods by bare name. Inheritance is honored at
//! runtime: a subclass instance is built with its inherited fields, and method
//! lookup walks the `extends`/`uses` chain (the most-derived method wins). Enum
//! cases execute as `Enum.CASE` values that print as `Enum.CASE` and compare
//! equal only to the same case.
//!
//! All runtime data lives in an arena owned by the returned `RunResult`. The
//! AST (and its source) must outlive the run, since function values borrow it.

const std = @import("std");
const parser = @import("parser.zig");
const lexer = @import("lexer.zig");

const Module = parser.Module;
const Decl = parser.Decl;
const Stmt = parser.Stmt;
const Expr = parser.Expr;
const BinaryOp = parser.BinaryOp;
const Span = lexer.Span;

const Error = std.mem.Allocator.Error || error{Runtime};

const zero_span: Span = .{ .start = 0, .end = 0, .line = 0, .col = 0 };

/// Maximum interpreter call-stack depth before a runtime error is raised. Each
/// language call spans several deep native frames, so this is kept well below
/// the native stack limit (calibrated so runaway recursion faults gracefully).
const max_call_depth = 700;

// --- values ------------------------------------------------------------------

const List = std.ArrayList(Value);

const MapEntry = struct { key: Value, value: Value };
const Map = struct { entries: std.ArrayList(MapEntry) = .empty };

const Builtin = enum {
    print,   echo,  len,     range, str,  int,   float,
    push,    pop,   keys,    values, has, connect, emit,
    abs,     min,   max,     upper, lower, split, join,
    contains, sort, reverse,
    trim,    starts_with, ends_with, find, replace,
    map,     filter, reduce,
    sqrt,    pow,    floor,  ceil,  round,
};

/// The names bound to each builtin. Shared with the analyzer (see analyzer.zig)
/// so a program using them both analyzes and runs.
pub const builtin_names = [_][]const u8{
    "print",    "echo", "len",     "range",  "str",   "int",   "float",
    "push",     "pop",  "keys",    "values", "has",   "connect", "emit",
    "abs",      "min",  "max",     "upper",  "lower", "split", "join",
    "contains", "sort", "reverse",
    "trim",     "starts_with", "ends_with", "find", "replace",
    "map",      "filter", "reduce",
    "sqrt",     "pow",  "floor",   "ceil",   "round",
};

/// A field declared on a class/struct, with its default-value expression.
const FieldDef = struct { name: []const u8, value: ?*const Expr };

/// The runtime shape of a class or struct: its own fields and methods, its
/// declared supertypes, and (computed once) the transitive ancestors and full
/// inherited field list.
const TypeInfo = struct {
    name: []const u8,
    /// The globals of the module that defines this type, so its methods and
    /// field defaults resolve names in their own module (not the caller's).
    module: *Env = undefined,
    own_fields: []const FieldDef,
    methods: std.StringHashMapUnmanaged(*const Decl.Func) = .{},
    super_names: []const []const u8 = &.{},
    /// Supertypes imported from another module, already resolved (their own
    /// ancestors/fields are computed in their home module).
    imported_supers: []const *const TypeInfo = &.{},
    /// Transitive supertypes, most-derived first (used for method resolution).
    ancestors: []const *const TypeInfo = &.{},
    /// This type's fields plus inherited ones, base classes first (used for
    /// construction and printing).
    all_fields: []const FieldDef = &.{},
    /// Storage shared across all instances: static vars (by value) and static
    /// methods (as `static_method` values). Reached via `TypeName.member`.
    statics: *Env = undefined,
    /// Static `var` members, whose initializers are evaluated once (after the
    /// module's globals exist) into `statics`.
    static_fields: []const FieldDef = &.{},
    /// Signal members declared directly on this type.
    own_signals: []const []const u8 = &.{},
    /// This type's signals plus inherited ones; a fresh signal per name is
    /// created on each instance.
    all_signals: []const []const u8 = &.{},
};

/// A live class/struct instance.
const Instance = struct {
    info: *const TypeInfo,
    fields: std.StringHashMapUnmanaged(Value) = .{},
};

/// A method plus the type it is defined on (whose module it runs in).
const MethodRef = struct { func: *const Decl.Func, owner: *const TypeInfo };

/// A method paired with the instance it was accessed on and the type that
/// defines it (so an inherited method runs in its base's module).
const BoundMethod = struct { receiver: *Instance, func: *const Decl.Func, owner: *const TypeInfo };

/// A function value: the declaration plus the globals of the module that
/// defined it, so calling it resolves names in its home module.
const FuncValue = struct { decl: *const Decl.Func, module: *Env };

/// A `static` method paired with the type it belongs to, so its body resolves
/// bare names against that type's statics (and its module).
const StaticMethod = struct { ti: *const TypeInfo, func: *const Decl.Func };

/// A closure: an anonymous function plus the environment (and receiver/statics
/// and module) captured where it was created, so it resolves outer names later.
const Closure = struct {
    lambda: *const Expr.Lambda,
    env: *Env,
    module: *Env,
    receiver: ?*Instance,
    statics: ?*Env,
};

/// An enum type: its name and the set of member names it declares.
const EnumType = struct {
    name: []const u8,
    members: std.StringHashMapUnmanaged(void) = .{},
};

/// A single enum case, e.g. `Status.OK`.
const EnumValue = struct { type_name: []const u8, member: []const u8 };

/// A live signal: an ordered list of handlers (any callable value) to invoke
/// when the signal is emitted. Top-level signals are shared; a class signal is
/// created fresh per instance.
const Signal = struct {
    name: []const u8,
    handlers: std.ArrayList(Value) = .empty,
};

pub const Value = union(enum) {
    nil,
    int: i64,
    float: f64,
    bool: bool,
    str: []const u8,
    list: *List,
    map: *Map,
    func: *const FuncValue,
    builtin: Builtin,
    instance: *Instance,
    bound_method: *BoundMethod,
    static_method: *const StaticMethod,
    closure: *const Closure,
    type_ref: *const TypeInfo,
    enum_type: *const EnumType,
    enum_value: *const EnumValue,
    signal: *Signal,
    /// A tuple `(a, b, ...)` — a fixed, ordered group; compared elementwise.
    tuple: *List,
    /// An imported module, reached by its bound name; members are its globals.
    module: *Env,
};

/// The parameter list of a callable value (for named-argument reordering), or
/// null for a builtin / non-callable (which take positional args only).
fn calleeParams(callee: Value) ?[]const parser.Param {
    return switch (callee) {
        .func => |f| f.decl.params,
        .closure => |cl| cl.lambda.params,
        .bound_method => |bm| bm.func.params,
        .static_method => |sm| sm.func.params,
        .type_ref => |ti| if (ti.methods.get("init")) |init| init.params else &.{},
        else => null,
    };
}

/// The home module of a callable value (where its default values are evaluated).
fn calleeModule(callee: Value) ?*Env {
    return switch (callee) {
        .func => |f| f.module,
        .closure => |cl| cl.module,
        .bound_method => |bm| bm.owner.module,
        .static_method => |sm| sm.ti.module,
        .type_ref => |ti| ti.module,
        else => null,
    };
}

/// The count of leading parameters with no default value (defaults are
/// trailing), i.e. the minimum number of arguments a call must supply.
fn requiredParamCount(params: []const parser.Param) usize {
    for (params, 0..) |p, i| {
        if (p.default != null) return i;
    }
    return params.len;
}

fn isTruthy(v: Value) bool {
    return switch (v) {
        .nil => false,
        .bool => |b| b,
        .int => |n| n != 0,
        .float => |f| f != 0,
        .str => |s| s.len != 0,
        else => true,
    };
}

fn toFloat(v: Value) ?f64 {
    return switch (v) {
        .int => |n| @floatFromInt(n),
        .float => |f| f,
        else => null,
    };
}

fn valuesEqual(a: Value, b: Value) bool {
    return switch (a) {
        .nil => b == .nil,
        .int => |x| switch (b) {
            .int => |y| x == y,
            .float => |y| @as(f64, @floatFromInt(x)) == y,
            else => false,
        },
        .float => |x| switch (b) {
            .int => |y| x == @as(f64, @floatFromInt(y)),
            .float => |y| x == y,
            else => false,
        },
        .bool => |x| b == .bool and b.bool == x,
        .str => |x| b == .str and std.mem.eql(u8, x, b.str),
        .list => |x| b == .list and x == b.list,
        .map => |x| b == .map and x == b.map,
        .func => |x| b == .func and x == b.func,
        .builtin => |x| b == .builtin and x == b.builtin,
        .instance => |x| b == .instance and x == b.instance,
        .bound_method => |x| b == .bound_method and x == b.bound_method,
        .static_method => |x| b == .static_method and x == b.static_method,
        .closure => |x| b == .closure and x == b.closure,
        .type_ref => |x| b == .type_ref and x == b.type_ref,
        .enum_type => |x| b == .enum_type and x == b.enum_type,
        .enum_value => |x| b == .enum_value and
            std.mem.eql(u8, x.type_name, b.enum_value.type_name) and
            std.mem.eql(u8, x.member, b.enum_value.member),
        .signal => |x| b == .signal and x == b.signal,
        .tuple => |x| b == .tuple and blk: {
            if (x.items.len != b.tuple.items.len) break :blk false;
            for (x.items, b.tuple.items) |ea, eb| {
                if (!valuesEqual(ea, eb)) break :blk false;
            }
            break :blk true;
        },
        .module => |x| b == .module and x == b.module,
    };
}

/// Ordering used by `sort`: numbers ascending, strings lexicographically, other
/// mixes left as-is (stable).
fn valueLess(_: void, a: Value, b: Value) bool {
    if (toFloat(a)) |fa| {
        if (toFloat(b)) |fb| return fa < fb;
    }
    if (a == .str and b == .str) return std.mem.order(u8, a.str, b.str) == .lt;
    return false;
}

// --- environment -------------------------------------------------------------

const Env = struct {
    parent: ?*Env,
    vars: std.StringHashMapUnmanaged(Value) = .{},
};

// --- result ------------------------------------------------------------------

pub const RuntimeError = struct {
    message: []const u8,
    line: u32,
    col: u32,
};

pub const RunResult = struct {
    arena: std.heap.ArenaAllocator,
    output: []const u8,
    runtime_error: ?RuntimeError,

    pub fn deinit(self: *RunResult) void {
        self.arena.deinit();
    }
};

/// One import edge for `runProgram`: the bound name and the index (into the
/// `modules` slice) of the module it refers to.
pub const ModuleImport = struct { name: []const u8, module_index: usize };

/// A module plus its resolved imports, as consumed by `runProgram`.
pub const ProgramModule = struct { module: Module, imports: []const ModuleImport };

pub fn run(gpa: std.mem.Allocator, module: Module) Error!RunResult {
    const one = [_]ProgramModule{.{ .module = module, .imports = &.{} }};
    return runProgram(gpa, &one);
}

/// Execute a program of one or more modules given in dependency order (each
/// module's imports refer to earlier entries; the last entry is the root whose
/// `main()` runs). Every module gets its own globals; a module value exposes
/// those globals, and functions/methods resolve names in their home module.
pub fn runProgram(gpa: std.mem.Allocator, modules: []const ProgramModule) Error!RunResult {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    const placeholder = try alloc.create(Env);
    placeholder.* = .{ .parent = null };

    var output: std.ArrayList(u8) = .empty;

    var interp = Interpreter{
        .arena = alloc,
        .globals = placeholder,
        .env = placeholder,
        .output = &output,
    };

    interp.runModules(modules) catch |e| switch (e) {
        error.Runtime => {
            return .{
                .arena = arena,
                .output = try output.toOwnedSlice(alloc),
                .runtime_error = interp.runtime_error,
            };
        },
        else => return e,
    };

    return .{
        .arena = arena,
        .output = try output.toOwnedSlice(alloc),
        .runtime_error = null,
    };
}

// --- REPL --------------------------------------------------------------------

/// The result of running one REPL entry: the text it produced (prints plus the
/// printed value of any bare expression) and a runtime error if it hit one.
pub const ReplOutcome = struct { output: []const u8, runtime_error: ?RuntimeError };

/// A persistent interpreter for the REPL: globals, types, and output survive
/// across entries. Heap-allocated so the interpreter's self-references (into its
/// own arena and output) stay valid. The parsed `ReplChunk`s must be kept alive
/// (function values borrow their AST); the caller owns that.
pub const Repl = struct {
    arena: std.heap.ArenaAllocator,
    interp: Interpreter,
    output: std.ArrayList(u8),

    pub fn deinit(self: *Repl) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self);
    }

    /// Run one parsed entry, returning the output it produced and any runtime
    /// error. Output is fresh each call.
    pub fn run(self: *Repl, items: []const parser.ReplItem) Error!ReplOutcome {
        self.output.clearRetainingCapacity();
        const in = &self.interp;
        in.runtime_error = null;
        in.env = in.globals;
        in.current_receiver = null;
        in.current_statics = null;
        for (items) |item| {
            const res = switch (item) {
                .decl => |d| in.registerReplDecl(d),
                .stmt => |s| in.runReplStmt(s),
            };
            res catch |e| switch (e) {
                error.Runtime => return .{ .output = self.output.items, .runtime_error = in.runtime_error },
                else => |other| return other,
            };
        }
        return .{ .output = self.output.items, .runtime_error = null };
    }
};

pub fn replInit(gpa: std.mem.Allocator) Error!*Repl {
    const repl = try gpa.create(Repl);
    errdefer gpa.destroy(repl);
    repl.* = .{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .interp = undefined,
        .output = .empty,
    };
    const alloc = repl.arena.allocator();
    const globals = try alloc.create(Env);
    globals.* = .{ .parent = null };
    repl.interp = .{
        .arena = alloc,
        .globals = globals,
        .env = globals,
        .output = &repl.output,
    };
    try repl.interp.registerBuiltins();
    return repl;
}

// --- interpreter -------------------------------------------------------------

const Flow = enum { normal, returned, break_loop, continue_loop };

const Interpreter = struct {
    arena: std.mem.Allocator,
    globals: *Env,
    env: *Env,
    output: *std.ArrayList(u8),
    ret_value: Value = .nil,
    runtime_error: ?RuntimeError = null,
    /// Set by `raise` to the thrown value, carried out via `error.Runtime` until a
    /// `try`/`catch` binds it (or it becomes the top-level runtime error).
    thrown_value: ?Value = null,
    /// The instance whose method is currently executing, so bare `field` names
    /// inside a method resolve to (and assign to) that instance.
    current_receiver: ?*Instance = null,
    /// The statics of the type whose `static` method is currently executing, so
    /// bare names inside it resolve to (and assign to) that type's static members.
    current_statics: ?*Env = null,
    /// The type whose `static` method is running, so a bare name can resolve to a
    /// static inherited from a base (walking ancestors), not just an own static.
    current_static_ti: ?*const TypeInfo = null,
    /// Every class/struct by name, so supertypes can be resolved.
    types: std.StringHashMapUnmanaged(*TypeInfo) = .{},
    /// Current call-stack depth, so runaway recursion becomes a runtime error
    /// instead of a native stack overflow.
    call_depth: u32 = 0,

    fn fail(self: *Interpreter, span: Span, comptime fmt: []const u8, args: anytype) Error {
        self.runtime_error = .{
            .message = std.fmt.allocPrint(self.arena, fmt, args) catch "out of memory",
            .line = span.line,
            .col = span.col,
        };
        return error.Runtime;
    }

    fn newEnv(self: *Interpreter, parent: *Env) Error!*Env {
        const e = try self.arena.create(Env);
        e.* = .{ .parent = parent };
        return e;
    }

    fn define(self: *Interpreter, env: *Env, name: []const u8, value: Value) Error!void {
        try env.vars.put(self.arena, name, value);
    }

    /// Resolve a name for reading: local scopes, then (inside a method) the
    /// receiver's fields and methods, then globals.
    fn resolveName(self: *Interpreter, name: []const u8, span: Span) Error!Value {
        var env: ?*Env = self.env;
        while (env) |e| : (env = e.parent) {
            if (e == self.globals) break;
            if (e.vars.get(name)) |v| return v;
        }
        if (self.current_receiver) |recv| {
            if (recv.fields.get(name)) |v| return v;
            if (self.findMethod(recv.info, name)) |mr| {
                const bm = try self.arena.create(BoundMethod);
                bm.* = .{ .receiver = recv, .func = mr.func, .owner = mr.owner };
                return .{ .bound_method = bm };
            }
        }
        if (self.current_static_ti) |ti| {
            if (self.staticsEnvFor(ti, name)) |senv| return senv.vars.get(name).?;
        } else if (self.current_statics) |st| {
            if (st.vars.get(name)) |v| return v;
        }
        if (self.globals.vars.get(name)) |v| return v;
        return self.fail(span, "undefined name '{s}'", .{name});
    }

    /// Resolve a name for writing: local scopes, then the receiver's fields,
    /// then globals. Returns false if the name is not bound anywhere.
    fn assignVar(self: *Interpreter, name: []const u8, value: Value) bool {
        var env: ?*Env = self.env;
        while (env) |e| : (env = e.parent) {
            if (e == self.globals) break;
            if (e.vars.getPtr(name)) |slot| {
                slot.* = value;
                return true;
            }
        }
        if (self.current_receiver) |recv| {
            if (recv.fields.getPtr(name)) |slot| {
                slot.* = value;
                return true;
            }
        }
        if (self.current_static_ti) |ti| {
            if (self.staticsEnvFor(ti, name)) |senv| {
                senv.vars.getPtr(name).?.* = value;
                return true;
            }
        } else if (self.current_statics) |st| {
            if (st.vars.getPtr(name)) |slot| {
                slot.* = value;
                return true;
            }
        }
        if (self.globals.vars.getPtr(name)) |slot| {
            slot.* = value;
            return true;
        }
        return false;
    }

    fn registerType(
        self: *Interpreter,
        name: []const u8,
        members: []const Decl,
        extends: ?parser.TypeRef,
        uses: []const parser.TypeRef,
    ) Error!void {
        var fields: std.ArrayList(FieldDef) = .empty;
        var methods: std.StringHashMapUnmanaged(*const Decl.Func) = .{};
        var static_fields: std.ArrayList(FieldDef) = .empty;
        var signals: std.ArrayList([]const u8) = .empty;
        // Partition members: `static` ones belong to the type, the rest to
        // instances. Static methods need the finished `ti`, so they are bound
        // after it is created.
        for (members, 0..) |m, j| switch (m) {
            .var_decl => |v| {
                const slot = if (v.is_static) &static_fields else &fields;
                try slot.append(self.arena, .{ .name = v.name, .value = v.value });
            },
            .func => |f| if (!f.is_static) try methods.put(self.arena, f.name, &members[j].func),
            .signal => |sg| try signals.append(self.arena, sg.name),
            else => {},
        };
        // A `mod.Base` super is imported: resolve it to its TypeInfo now (its
        // module is already loaded). A bare super resolves later, by name, in
        // computeInheritance.
        var supers: std.ArrayList([]const u8) = .empty;
        var imported: std.ArrayList(*const TypeInfo) = .empty;
        if (extends) |b| try self.addSuper(b, &supers, &imported);
        for (uses) |t| try self.addSuper(t, &supers, &imported);

        const statics = try self.arena.create(Env);
        statics.* = .{ .parent = self.globals };

        const own_fields = try fields.toOwnedSlice(self.arena);
        const ti = try self.arena.create(TypeInfo);
        ti.* = .{
            .name = name,
            .module = self.globals,
            .own_fields = own_fields,
            .methods = methods,
            .super_names = try supers.toOwnedSlice(self.arena),
            .imported_supers = try imported.toOwnedSlice(self.arena),
            .all_fields = own_fields, // recomputed with inheritance in computeInheritance
            .statics = statics,
            .static_fields = try static_fields.toOwnedSlice(self.arena),
            .own_signals = try signals.toOwnedSlice(self.arena),
        };

        // Bind static methods into the statics env, carrying `ti`.
        for (members, 0..) |m, j| switch (m) {
            .func => |f| if (f.is_static) {
                const sm = try self.arena.create(StaticMethod);
                sm.* = .{ .ti = ti, .func = &members[j].func };
                try statics.vars.put(self.arena, f.name, .{ .static_method = sm });
            },
            else => {},
        };

        try self.types.put(self.arena, name, ti);
        try self.define(self.globals, name, .{ .type_ref = ti });
    }

    /// Evaluate a type's static `var` initializers into its statics env. Runs
    /// after the module's globals and functions exist, so an initializer may use
    /// them (and earlier statics, and this type's static methods).
    fn initStatics(self: *Interpreter, ti: *const TypeInfo) Error!void {
        if (ti.static_fields.len == 0) return;
        const saved_env = self.env;
        const saved_recv = self.current_receiver;
        const saved_statics = self.current_statics;
        const saved_static_ti = self.current_static_ti;
        const saved_globals = self.globals;
        self.globals = ti.module;
        self.env = ti.module;
        self.current_receiver = null;
        self.current_statics = ti.statics;
        self.current_static_ti = ti;
        defer {
            self.env = saved_env;
            self.current_receiver = saved_recv;
            self.current_statics = saved_statics;
            self.current_static_ti = saved_static_ti;
            self.globals = saved_globals;
        }
        for (ti.static_fields) |f| {
            const v = if (f.value) |val| try self.eval(val.*) else Value.nil;
            try ti.statics.vars.put(self.arena, f.name, v);
        }
    }

    fn computeInheritance(self: *Interpreter, ti: *TypeInfo) Error!void {
        // Ancestors: transitive supertypes, most-derived first, deduped.
        var ancestors: std.ArrayList(*const TypeInfo) = .empty;
        var seen_anc: std.StringHashMapUnmanaged(void) = .{};
        try self.collectAncestors(ti, &ancestors, &seen_anc);
        ti.ancestors = try ancestors.toOwnedSlice(self.arena);

        // Fields: base classes first, then own, deduped by name.
        var all: std.ArrayList(FieldDef) = .empty;
        var seen_f: std.StringHashMapUnmanaged(void) = .{};
        var i = ti.ancestors.len;
        while (i > 0) {
            i -= 1;
            for (ti.ancestors[i].own_fields) |f| {
                if ((try seen_f.getOrPut(self.arena, f.name)).found_existing) continue;
                try all.append(self.arena, f);
            }
        }
        for (ti.own_fields) |f| {
            if ((try seen_f.getOrPut(self.arena, f.name)).found_existing) continue;
            try all.append(self.arena, f);
        }
        ti.all_fields = try all.toOwnedSlice(self.arena);

        // Signals: same base-first, deduped shape as fields.
        var all_sig: std.ArrayList([]const u8) = .empty;
        var seen_s: std.StringHashMapUnmanaged(void) = .{};
        var k = ti.ancestors.len;
        while (k > 0) {
            k -= 1;
            for (ti.ancestors[k].own_signals) |s| {
                if ((try seen_s.getOrPut(self.arena, s)).found_existing) continue;
                try all_sig.append(self.arena, s);
            }
        }
        for (ti.own_signals) |s| {
            if ((try seen_s.getOrPut(self.arena, s)).found_existing) continue;
            try all_sig.append(self.arena, s);
        }
        ti.all_signals = try all_sig.toOwnedSlice(self.arena);
    }

    /// Record one supertype: a `mod.Base` is resolved to its TypeInfo through the
    /// imported module's namespace; a bare `Base` is kept as a name for later.
    fn addSuper(self: *Interpreter, t: parser.TypeRef, supers: *std.ArrayList([]const u8), imported: *std.ArrayList(*const TypeInfo)) Error!void {
        if (t.module) |mod_name| {
            if (self.globals.vars.get(mod_name)) |modv| {
                if (modv == .module) {
                    if (modv.module.vars.get(t.name)) |bv| {
                        if (bv == .type_ref) {
                            try imported.append(self.arena, bv.type_ref);
                            return;
                        }
                    }
                }
            }
            // Unresolved (the analyzer already reported it); ignore.
        } else {
            try supers.append(self.arena, t.name);
        }
    }

    fn collectAncestors(
        self: *Interpreter,
        ti: *const TypeInfo,
        out: *std.ArrayList(*const TypeInfo),
        seen: *std.StringHashMapUnmanaged(void),
    ) Error!void {
        for (ti.super_names) |sn| {
            const sup = self.types.get(sn) orelse continue;
            if ((try seen.getOrPut(self.arena, sn)).found_existing) continue;
            try out.append(self.arena, sup);
            try self.collectAncestors(sup, out, seen);
        }
        // Imported supers already have their own ancestors computed; splice them
        // in (self and each ancestor), deduped by name.
        for (ti.imported_supers) |sup| {
            if (!(try seen.getOrPut(self.arena, sup.name)).found_existing) try out.append(self.arena, sup);
            for (sup.ancestors) |a| {
                if (!(try seen.getOrPut(self.arena, a.name)).found_existing) try out.append(self.arena, a);
            }
        }
    }

    /// Look up a method on `ti` or any of its ancestors (most-derived wins).
    /// The statics env that holds `name` — this type's, or an ancestor's — so a
    /// subclass reaches (and shares) an inherited static through its own name.
    fn staticsEnvFor(self: *Interpreter, ti: *const TypeInfo, name: []const u8) ?*Env {
        _ = self;
        if (ti.statics.vars.contains(name)) return ti.statics;
        for (ti.ancestors) |a| {
            if (a.statics.vars.contains(name)) return a.statics;
        }
        return null;
    }

    fn findMethod(self: *Interpreter, ti: *const TypeInfo, name: []const u8) ?MethodRef {
        _ = self;
        if (ti.methods.get(name)) |m| return .{ .func = m, .owner = ti };
        for (ti.ancestors) |a| {
            if (a.methods.get(name)) |m| return .{ .func = m, .owner = a };
        }
        return null;
    }

    fn registerEnum(self: *Interpreter, name: []const u8, members: []const parser.EnumMember) Error!void {
        const et = try self.arena.create(EnumType);
        et.* = .{ .name = name };
        for (members) |m| try et.members.put(self.arena, m.name, {});
        try self.define(self.globals, name, .{ .enum_type = et });
    }

    fn construct(self: *Interpreter, ti: *const TypeInfo, args: []const Value, span: Span) Error!Value {
        self.call_depth += 1;
        defer self.call_depth -= 1;
        if (self.call_depth > max_call_depth) return self.fail(span, "call stack overflow (too much recursion)", .{});
        const inst = try self.arena.create(Instance);
        inst.* = .{ .info = ti };

        // Evaluate field defaults with the fresh instance as the receiver, so a
        // later field may reference an earlier one. Defaults resolve names in the
        // type's own module.
        const saved_env = self.env;
        const saved_recv = self.current_receiver;
        const saved_statics = self.current_statics;
        const saved_static_ti = self.current_static_ti;
        const saved_globals = self.globals;
        self.globals = ti.module;
        self.env = ti.module;
        self.current_receiver = inst;
        self.current_statics = null;
        self.current_static_ti = null;
        for (ti.all_fields) |f| {
            const v = if (f.value) |val| try self.eval(val.*) else Value.nil;
            try inst.fields.put(self.arena, f.name, v);
        }
        self.env = saved_env;
        self.current_receiver = saved_recv;
        self.current_statics = saved_statics;
        self.current_static_ti = saved_static_ti;
        self.globals = saved_globals;

        // Each instance gets its own signals, reached via `inst.name`.
        for (ti.all_signals) |sname| {
            const s = try self.arena.create(Signal);
            s.* = .{ .name = sname };
            try inst.fields.put(self.arena, sname, .{ .signal = s });
        }

        // A method named `init` (inherited or own) acts as the constructor.
        if (self.findMethod(ti, "init")) |init_ref| {
            _ = try self.callMethod(init_ref.func, init_ref.owner, inst, args, span);
        } else if (args.len != 0) {
            return self.fail(span, "{s} takes no constructor arguments", .{ti.name});
        }
        return .{ .instance = inst };
    }

    // --- top level -----------------------------------------------------------

    /// Load every module into its own globals (dependencies first), then run the
    /// root module's `main()`.
    fn runModules(self: *Interpreter, modules: []const ProgramModule) Error!void {
        if (modules.len == 0) return;
        const envs = try self.arena.alloc(*Env, modules.len);
        for (modules, 0..) |pm, i| {
            const genv = try self.arena.create(Env);
            genv.* = .{ .parent = null };
            self.globals = genv;
            self.env = genv;
            self.current_receiver = null;
            self.types = .{}; // each module has its own type table
            try self.loadModule(pm, envs);
            envs[i] = genv;
        }

        // Run the root module's main() in its own globals.
        const entry = envs[modules.len - 1];
        self.globals = entry;
        self.env = entry;
        if (entry.vars.get("main")) |m| {
            if (m == .func) _ = try self.callFunction(m.func, &.{}, zero_span);
        }
    }

    /// Bind everything a module declares into the current globals (`self.globals`,
    /// set up by the caller): builtins, imported modules, types, functions, and
    /// evaluated top-level `const`/`var`. Does not run `main`.
    fn loadModule(self: *Interpreter, pm: ProgramModule, envs: []const *Env) Error!void {
        const module = pm.module;
        try self.registerBuiltins();

        // Bind each imported module to its (already-loaded) globals.
        for (pm.imports) |imp| {
            try self.define(self.globals, imp.name, .{ .module = envs[imp.module_index] });
        }

        // Bind class/struct/enum names so `Name(...)` and `Enum.CASE` resolve.
        for (module.decls) |decl| switch (decl) {
            .class => |c| try self.registerType(c.name, c.members, c.extends, c.uses),
            .struct_decl => |s| try self.registerType(s.name, s.members, null, &.{}),
            .enum_decl => |en| try self.registerEnum(en.name, en.members),
            else => {},
        };
        // Resolve the transitive ancestors and inherited fields of each type,
        // now that every type is registered.
        for (module.decls) |decl| switch (decl) {
            .class => |c| try self.computeInheritance(self.types.get(c.name).?),
            .struct_decl => |s| try self.computeInheritance(self.types.get(s.name).?),
            else => {},
        };
        // Bind functions so globals and `main` can call any of them.
        for (module.decls, 0..) |decl, i| switch (decl) {
            .func => {
                const fv = try self.arena.create(FuncValue);
                fv.* = .{ .decl = &module.decls[i].func, .module = self.globals };
                try self.define(self.globals, decl.func.name, .{ .func = fv });
            },
            else => {},
        };
        // Bind top-level signals as shared signal values.
        for (module.decls) |decl| switch (decl) {
            .signal => |sg| {
                const s = try self.arena.create(Signal);
                s.* = .{ .name = sg.name };
                try self.define(self.globals, sg.name, .{ .signal = s });
            },
            else => {},
        };
        // Evaluate top-level const/var.
        for (module.decls) |decl| switch (decl) {
            .var_decl => |x| {
                const v = if (x.value) |val| try self.eval(val.*) else Value.nil;
                try self.define(self.globals, x.name, v);
            },
            else => {},
        };
        // Evaluate static field initializers, now that globals/functions exist.
        for (module.decls) |decl| switch (decl) {
            .class => |c| try self.initStatics(self.types.get(c.name).?),
            .struct_decl => |s| try self.initStatics(self.types.get(s.name).?),
            else => {},
        };
    }

    fn registerBuiltins(self: *Interpreter) Error!void {
        inline for (builtin_names, 0..) |name, i| {
            try self.define(self.globals, name, .{ .builtin = @enumFromInt(i) });
        }
    }

    /// Register one REPL declaration into the persistent globals. `decl` points
    /// into a chunk the caller keeps alive (function values borrow it).
    fn registerReplDecl(self: *Interpreter, decl: *const Decl) Error!void {
        switch (decl.*) {
            .class => |c| {
                try self.registerType(c.name, c.members, c.extends, c.uses);
                const ti = self.types.get(c.name).?;
                try self.computeInheritance(ti);
                try self.initStatics(ti);
            },
            .struct_decl => |s| {
                try self.registerType(s.name, s.members, null, &.{});
                const ti = self.types.get(s.name).?;
                try self.computeInheritance(ti);
                try self.initStatics(ti);
            },
            .enum_decl => |en| try self.registerEnum(en.name, en.members),
            .func => |*f| {
                const fv = try self.arena.create(FuncValue);
                fv.* = .{ .decl = f, .module = self.globals };
                try self.define(self.globals, f.name, .{ .func = fv });
            },
            .var_decl => |v| {
                const val = if (v.value) |x| try self.eval(x.*) else Value.nil;
                try self.define(self.globals, v.name, val);
            },
            .signal => |sg| {
                const s = try self.arena.create(Signal);
                s.* = .{ .name = sg.name };
                try self.define(self.globals, sg.name, .{ .signal = s });
            },
            .import => |im| return self.fail(im.span, "import is not supported in the REPL", .{}),
        }
    }

    /// Run one REPL statement. A bare expression is evaluated and its value
    /// printed (unless nil); everything else executes in the globals.
    fn runReplStmt(self: *Interpreter, stmt: *const Stmt) Error!void {
        switch (stmt.*) {
            .expr_stmt => |e| {
                const v = try self.eval(e.*);
                if (v != .nil) {
                    try self.appendValue(self.output, v);
                    try self.output.append(self.arena, '\n');
                }
            },
            else => _ = try self.execStmt(stmt.*),
        }
    }

    // --- statements ----------------------------------------------------------

    fn execBlock(self: *Interpreter, stmts: []const Stmt) Error!Flow {
        for (stmts) |s| {
            const flow = try self.execStmt(s);
            if (flow != .normal) return flow; // propagate return/break/continue
        }
        return .normal;
    }

    /// Run a block in a fresh child scope.
    fn execChildBlock(self: *Interpreter, stmts: []const Stmt) Error!Flow {
        const child = try self.newEnv(self.env);
        const saved = self.env;
        self.env = child;
        defer self.env = saved;
        return self.execBlock(stmts);
    }

    /// Run `try`'s body; on a raised error (or built-in runtime error) run the
    /// handler with the error value bound. Zig `defer`s in the call chain restore
    /// the environment as the error unwinds, so `catch` resumes cleanly.
    fn execTryCatch(self: *Interpreter, tc: Stmt.TryCatch) Error!Flow {
        return self.execChildBlock(tc.body) catch |e| {
            if (e != error.Runtime) return e; // OutOfMemory etc. still propagate
            const errval = self.thrown_value orelse
                Value{ .str = if (self.runtime_error) |re| re.message else "error" };
            self.thrown_value = null;
            self.runtime_error = null;
            const child = try self.newEnv(self.env);
            try self.define(child, tc.catch_name, errval);
            const saved = self.env;
            self.env = child;
            defer self.env = saved;
            return self.execBlock(tc.handler);
        };
    }

    fn valueToString(self: *Interpreter, v: Value) Error![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        try self.appendValue(&buf, v);
        return buf.toOwnedSlice(self.arena);
    }

    fn execStmt(self: *Interpreter, stmt: Stmt) Error!Flow {
        switch (stmt) {
            .pass => {},
            .expr_stmt => |e| _ = try self.eval(e.*),
            .var_decl => |x| {
                const v = if (x.value) |val| try self.eval(val.*) else Value.nil;
                try self.define(self.env, x.name, v);
            },
            .destructure => |d| {
                const v = try self.eval(d.value.*);
                const items: []const Value = switch (v) {
                    .tuple, .list => |l| l.items,
                    else => return self.fail(d.span, "cannot destructure a {s}", .{@tagName(v)}),
                };
                if (items.len != d.names.len) {
                    return self.fail(d.span, "cannot destructure {d} value(s) into {d} name(s)", .{ items.len, d.names.len });
                }
                for (d.names, items) |n, item| try self.define(self.env, n, item);
            },
            .raise => |r| {
                self.thrown_value = try self.eval(r.value.*);
                self.runtime_error = .{ .message = try self.valueToString(self.thrown_value.?), .line = r.span.line, .col = r.span.col };
                return error.Runtime;
            },
            .try_catch => |tc| return self.execTryCatch(tc),
            .assign => |x| try self.execAssign(x),
            .return_stmt => |x| {
                self.ret_value = if (x.value) |v| try self.eval(v.*) else Value.nil;
                return .returned;
            },
            .if_stmt => |x| {
                if (isTruthy(try self.eval(x.cond.*))) return self.execChildBlock(x.then_body);
                for (x.elifs) |e| {
                    if (isTruthy(try self.eval(e.cond.*))) return self.execChildBlock(e.body);
                }
                if (x.else_body) |eb| return self.execChildBlock(eb);
            },
            .while_stmt => |x| {
                while (isTruthy(try self.eval(x.cond.*))) {
                    switch (try self.execChildBlock(x.body)) {
                        .returned => return .returned,
                        .break_loop => break,
                        .normal, .continue_loop => {},
                    }
                }
            },
            .for_stmt => |x| return self.execFor(x),
            .break_stmt => return .break_loop,
            .continue_stmt => return .continue_loop,
        }
        return .normal;
    }

    fn evalRange(self: *Interpreter, r: Expr.Range) Error!Value {
        const s = try self.eval(r.start.*);
        const e = try self.eval(r.end.*);
        if (s != .int or e != .int) return self.fail(r.span, "range bounds must be integers", .{});
        const l = try self.arena.create(List);
        l.* = .empty;
        var i = s.int;
        while (i < e.int) : (i += 1) try l.append(self.arena, .{ .int = i });
        return .{ .list = l };
    }

    fn execFor(self: *Interpreter, x: Stmt.For) Error!Flow {
        const iter = try self.eval(x.iter.*);
        const two = x.value_binding != null;
        // Build (index/key, value) pairs. A single binding takes the value for a
        // list/string, but the key for a map (matching `for k in map`).
        var firsts: std.ArrayList(Value) = .empty;
        var seconds: std.ArrayList(Value) = .empty;
        var single_first = false;
        switch (iter) {
            .list => |l| for (l.items, 0..) |el, i| {
                try firsts.append(self.arena, .{ .int = @intCast(i) });
                try seconds.append(self.arena, el);
            },
            .str => |s| for (0..s.len) |i| {
                try firsts.append(self.arena, .{ .int = @intCast(i) });
                try seconds.append(self.arena, .{ .str = s[i .. i + 1] });
            },
            .map => |m| {
                single_first = true;
                for (m.entries.items) |entry| {
                    try firsts.append(self.arena, entry.key);
                    try seconds.append(self.arena, entry.value);
                }
            },
            else => return self.fail(x.span, "cannot iterate over {s}", .{@tagName(iter)}),
        }
        for (firsts.items, seconds.items) |first, second| {
            const child = try self.newEnv(self.env);
            const saved = self.env;
            self.env = child;
            if (two) {
                try self.define(child, x.binding, first);
                try self.define(child, x.value_binding.?, second);
            } else {
                try self.define(child, x.binding, if (single_first) first else second);
            }
            const flow = self.execBlock(x.body);
            self.env = saved;
            switch (try flow) {
                .returned => return .returned,
                .break_loop => break,
                .normal, .continue_loop => {},
            }
        }
        return .normal;
    }

    fn execAssign(self: *Interpreter, a: Stmt.Assign) Error!void {
        const value = try self.eval(a.value.*);
        switch (a.target.*) {
            .identifier => |id| {
                if (!self.assignVar(id.name, value)) {
                    return self.fail(id.span, "cannot assign to undefined name '{s}'", .{id.name});
                }
            },
            .index => |idx| {
                const container = try self.eval(idx.object.*);
                const key = try self.eval(idx.index.*);
                try self.setIndex(container, key, value, a.span);
            },
            .member => |mem| {
                const obj = try self.eval(mem.object.*);
                switch (obj) {
                    .instance => |inst| {
                        if (inst.fields.getPtr(mem.name)) |slot| {
                            slot.* = value;
                        } else {
                            return self.fail(mem.span, "type '{s}' has no field '{s}'", .{ inst.info.name, mem.name });
                        }
                    },
                    .type_ref => |ti| {
                        if (self.staticsEnvFor(ti, mem.name)) |env| {
                            env.vars.getPtr(mem.name).?.* = value;
                        } else {
                            return self.fail(mem.span, "type '{s}' has no static field '{s}'", .{ ti.name, mem.name });
                        }
                    },
                    else => return self.fail(mem.span, "cannot assign a member of {s}", .{@tagName(obj)}),
                }
            },
            else => return self.fail(a.span, "invalid assignment target", .{}),
        }
    }

    fn setIndex(self: *Interpreter, container: Value, key: Value, value: Value, span: Span) Error!void {
        switch (container) {
            .list => |l| {
                const i = try self.listIndex(l, key, span);
                l.items[i] = value;
            },
            .map => |m| {
                for (m.entries.items) |*entry| {
                    if (valuesEqual(entry.key, key)) {
                        entry.value = value;
                        return;
                    }
                }
                try m.entries.append(self.arena, .{ .key = key, .value = value });
            },
            else => return self.fail(span, "cannot index {s}", .{@tagName(container)}),
        }
    }

    fn listIndex(self: *Interpreter, l: *List, key: Value, span: Span) Error!usize {
        if (key != .int) return self.fail(span, "list index must be an int", .{});
        const raw = key.int;
        if (raw < 0 or raw >= l.items.len) {
            return self.fail(span, "list index {d} out of range (len {d})", .{ raw, l.items.len });
        }
        return @intCast(raw);
    }

    // --- calls ---------------------------------------------------------------

    /// Bind `args` to `params` in `call_env`, then fill any missing trailing
    /// parameters from their defaults, evaluated in `module`'s global scope (no
    /// receiver or statics in view) — matching the VM's default thunks. Reports
    /// an arity error against `span`.
    fn bindArgs(self: *Interpreter, call_env: *Env, module: *Env, params: []const parser.Param, args: []const Value, name: []const u8, span: Span) Error!void {
        const required = requiredParamCount(params);
        if (args.len < required or args.len > params.len) {
            if (required == params.len)
                return self.fail(span, "{s} expects {d} argument(s), got {d}", .{ name, params.len, args.len });
            return self.fail(span, "{s} expects {d} to {d} argument(s), got {d}", .{ name, required, params.len, args.len });
        }
        for (params[0..args.len], args) |p, arg| try self.define(call_env, p.name, arg);
        if (args.len == params.len) return;

        // Evaluate the remaining defaults in the home module's scope.
        const saved_env = self.env;
        const saved_globals = self.globals;
        const saved_recv = self.current_receiver;
        const saved_statics = self.current_statics;
        const saved_static_ti = self.current_static_ti;
        self.globals = module;
        self.env = try self.newEnv(module);
        self.current_receiver = null;
        self.current_statics = null;
        self.current_static_ti = null;
        defer {
            self.env = saved_env;
            self.globals = saved_globals;
            self.current_receiver = saved_recv;
            self.current_statics = saved_statics;
            self.current_static_ti = saved_static_ti;
        }
        for (params[args.len..]) |p| {
            const v = try self.eval(p.default.?.*);
            try self.define(call_env, p.name, v);
        }
    }

    fn callFunction(self: *Interpreter, fv: *const FuncValue, args: []const Value, span: Span) Error!Value {
        self.call_depth += 1;
        defer self.call_depth -= 1;
        if (self.call_depth > max_call_depth) return self.fail(span, "call stack overflow (too much recursion)", .{});
        const func = fv.decl;
        // Run in the function's home module, so its body sees that module's
        // globals rather than the caller's. A plain function has no receiver or
        // statics in scope.
        const saved_globals = self.globals;
        const saved_recv = self.current_receiver;
        const saved_statics = self.current_statics;
        const saved_static_ti = self.current_static_ti;
        self.globals = fv.module;
        self.current_receiver = null;
        self.current_statics = null;
        self.current_static_ti = null;
        const call_env = try self.newEnv(self.globals);
        try self.bindArgs(call_env, fv.module, func.params, args, func.name, span);

        const saved_env = self.env;
        const saved_ret = self.ret_value;
        self.env = call_env;
        self.ret_value = .nil;
        defer {
            self.env = saved_env;
            self.ret_value = saved_ret;
            self.globals = saved_globals;
            self.current_receiver = saved_recv;
            self.current_statics = saved_statics;
            self.current_static_ti = saved_static_ti;
        }
        const flow = try self.execBlock(func.body);
        return if (flow == .returned) self.ret_value else Value.nil;
    }

    /// Call a closure: run its body with the captured environment as the parent
    /// scope (and the captured module/receiver/statics restored), so it still
    /// resolves the outer names it closed over.
    fn callClosure(self: *Interpreter, cl: *const Closure, args: []const Value, span: Span) Error!Value {
        self.call_depth += 1;
        defer self.call_depth -= 1;
        if (self.call_depth > max_call_depth) return self.fail(span, "call stack overflow (too much recursion)", .{});
        const params = cl.lambda.params;
        const saved_globals = self.globals;
        const saved_recv = self.current_receiver;
        const saved_statics = self.current_statics;
        const saved_static_ti = self.current_static_ti;
        self.globals = cl.module;
        self.current_receiver = cl.receiver;
        self.current_statics = cl.statics;
        self.current_static_ti = null;
        const call_env = try self.newEnv(cl.env);
        try self.bindArgs(call_env, cl.module, params, args, "lambda", span);

        const saved_env = self.env;
        const saved_ret = self.ret_value;
        self.env = call_env;
        self.ret_value = .nil;
        defer {
            self.env = saved_env;
            self.ret_value = saved_ret;
            self.globals = saved_globals;
            self.current_receiver = saved_recv;
            self.current_statics = saved_statics;
            self.current_static_ti = saved_static_ti;
        }
        const flow = try self.execBlock(cl.lambda.body);
        return if (flow == .returned) self.ret_value else Value.nil;
    }

    fn callMethod(self: *Interpreter, func: *const Decl.Func, owner: *const TypeInfo, receiver: *Instance, args: []const Value, span: Span) Error!Value {
        self.call_depth += 1;
        defer self.call_depth -= 1;
        if (self.call_depth > max_call_depth) return self.fail(span, "call stack overflow (too much recursion)", .{});
        // The method runs in the module of the type that DEFINES it (which may be
        // an imported base), with the receiver in scope and no statics.
        const saved_globals = self.globals;
        self.globals = owner.module;
        const call_env = try self.newEnv(self.globals);
        try self.bindArgs(call_env, owner.module, func.params, args, func.name, span);

        const saved_env = self.env;
        const saved_ret = self.ret_value;
        const saved_recv = self.current_receiver;
        const saved_statics = self.current_statics;
        const saved_static_ti = self.current_static_ti;
        self.env = call_env;
        self.ret_value = .nil;
        self.current_receiver = receiver;
        self.current_statics = null;
        self.current_static_ti = null;
        defer {
            self.env = saved_env;
            self.ret_value = saved_ret;
            self.current_receiver = saved_recv;
            self.current_statics = saved_statics;
            self.current_static_ti = saved_static_ti;
            self.globals = saved_globals;
        }
        const flow = try self.execBlock(func.body);
        return if (flow == .returned) self.ret_value else Value.nil;
    }

    /// Call a `static` method: no receiver, the type's statics in scope, running
    /// in the type's module.
    fn callStaticMethod(self: *Interpreter, sm: *const StaticMethod, args: []const Value, span: Span) Error!Value {
        self.call_depth += 1;
        defer self.call_depth -= 1;
        if (self.call_depth > max_call_depth) return self.fail(span, "call stack overflow (too much recursion)", .{});
        const func = sm.func;
        const saved_globals = self.globals;
        const saved_recv = self.current_receiver;
        const saved_statics = self.current_statics;
        const saved_static_ti = self.current_static_ti;
        self.globals = sm.ti.module;
        self.current_receiver = null;
        self.current_statics = sm.ti.statics;
        self.current_static_ti = sm.ti;
        const call_env = try self.newEnv(self.globals);
        try self.bindArgs(call_env, sm.ti.module, func.params, args, func.name, span);

        const saved_env = self.env;
        const saved_ret = self.ret_value;
        self.env = call_env;
        self.ret_value = .nil;
        defer {
            self.env = saved_env;
            self.ret_value = saved_ret;
            self.globals = saved_globals;
            self.current_receiver = saved_recv;
            self.current_statics = saved_statics;
            self.current_static_ti = saved_static_ti;
        }
        const flow = try self.execBlock(func.body);
        return if (flow == .returned) self.ret_value else Value.nil;
    }

    fn callBuiltin(self: *Interpreter, b: Builtin, args: []const Value, span: Span) Error!Value {
        switch (b) {
            .print, .echo => {
                for (args, 0..) |arg, i| {
                    if (i > 0) try self.output.append(self.arena, ' ');
                    try self.appendValue(self.output, arg);
                }
                try self.output.append(self.arena, '\n');
                return .nil;
            },
            .len => {
                if (args.len != 1) return self.fail(span, "len expects 1 argument", .{});
                switch (args[0]) {
                    .list => |l| return .{ .int = @intCast(l.items.len) },
                    .str => |s| return .{ .int = @intCast(s.len) },
                    .map => |m| return .{ .int = @intCast(m.entries.items.len) },
                    else => return self.fail(span, "len expects a list, str, or map", .{}),
                }
            },
            .range => {
                if (args.len != 1 or args[0] != .int) return self.fail(span, "range expects one int", .{});
                const n = args[0].int;
                const l = try self.arena.create(List);
                l.* = .empty;
                var i: i64 = 0;
                while (i < n) : (i += 1) try l.append(self.arena, .{ .int = i });
                return .{ .list = l };
            },
            .str => {
                if (args.len != 1) return self.fail(span, "str expects 1 argument", .{});
                var buf: std.ArrayList(u8) = .empty;
                try self.appendValue(&buf, args[0]);
                return .{ .str = try buf.toOwnedSlice(self.arena) };
            },
            .int => {
                if (args.len != 1) return self.fail(span, "int expects 1 argument", .{});
                switch (args[0]) {
                    .int => |n| return .{ .int = n },
                    .bool => |bo| return .{ .int = if (bo) 1 else 0 },
                    .float => |f| {
                        if (!std.math.isFinite(f) or f >= 9223372036854775808.0 or f < -9223372036854775808.0) {
                            return self.fail(span, "cannot convert {d} to int", .{f});
                        }
                        return .{ .int = @intFromFloat(f) };
                    },
                    .str => |s| return .{ .int = std.fmt.parseInt(i64, s, 10) catch return self.fail(span, "cannot parse '{s}' as int", .{s}) },
                    else => return self.fail(span, "cannot convert {s} to int", .{@tagName(args[0])}),
                }
            },
            .float => {
                if (args.len != 1) return self.fail(span, "float expects 1 argument", .{});
                switch (args[0]) {
                    .int => |n| return .{ .float = @floatFromInt(n) },
                    .float => |f| return .{ .float = f },
                    .str => |s| return .{ .float = std.fmt.parseFloat(f64, s) catch return self.fail(span, "cannot parse '{s}' as float", .{s}) },
                    else => return self.fail(span, "cannot convert {s} to float", .{@tagName(args[0])}),
                }
            },
            .push => {
                if (args.len != 2 or args[0] != .list) return self.fail(span, "push expects a list and a value", .{});
                try args[0].list.append(self.arena, args[1]);
                return .nil;
            },
            .pop => {
                if (args.len != 1 or args[0] != .list) return self.fail(span, "pop expects a list", .{});
                return args[0].list.pop() orelse self.fail(span, "pop from an empty list", .{});
            },
            .keys, .values => {
                if (args.len != 1 or args[0] != .map) return self.fail(span, "{s} expects a map", .{@tagName(b)});
                const l = try self.arena.create(List);
                l.* = .empty;
                for (args[0].map.entries.items) |entry| {
                    try l.append(self.arena, if (b == .keys) entry.key else entry.value);
                }
                return .{ .list = l };
            },
            .has => {
                if (args.len != 2 or args[0] != .map) return self.fail(span, "has expects a map and a key", .{});
                for (args[0].map.entries.items) |entry| {
                    if (valuesEqual(entry.key, args[1])) return .{ .bool = true };
                }
                return .{ .bool = false };
            },
            .connect => {
                if (args.len != 2 or args[0] != .signal) return self.fail(span, "connect expects a signal and a handler", .{});
                try args[0].signal.handlers.append(self.arena, args[1]);
                return .nil;
            },
            .emit => {
                if (args.len < 1 or args[0] != .signal) return self.fail(span, "emit expects a signal", .{});
                const sig = args[0].signal;
                // Snapshot the arguments; call each handler in connection order.
                for (sig.handlers.items) |handler| {
                    _ = try self.callValue(handler, args[1..], span);
                }
                return .nil;
            },
            .abs => {
                if (args.len != 1) return self.fail(span, "abs expects 1 argument", .{});
                switch (args[0]) {
                    .int => |n| return .{ .int = if (n < 0) -n else n },
                    .float => |f| return .{ .float = @abs(f) },
                    else => return self.fail(span, "abs expects a number", .{}),
                }
            },
            .min, .max => {
                if (args.len != 2) return self.fail(span, "{s} expects 2 arguments", .{@tagName(b)});
                const a0 = toFloat(args[0]) orelse return self.fail(span, "{s} expects numbers", .{@tagName(b)});
                const a1 = toFloat(args[1]) orelse return self.fail(span, "{s} expects numbers", .{@tagName(b)});
                const first = if (b == .min) a0 <= a1 else a0 >= a1;
                return if (first) args[0] else args[1];
            },
            .upper, .lower => {
                if (args.len != 1 or args[0] != .str) return self.fail(span, "{s} expects a string", .{@tagName(b)});
                const s = args[0].str;
                const out = try self.arena.alloc(u8, s.len);
                for (s, 0..) |c, i| out[i] = if (b == .upper) std.ascii.toUpper(c) else std.ascii.toLower(c);
                return .{ .str = out };
            },
            .split => {
                if (args.len != 2 or args[0] != .str or args[1] != .str) return self.fail(span, "split expects two strings", .{});
                const s = args[0].str;
                const sep = args[1].str;
                const l = try self.arena.create(List);
                l.* = .empty;
                if (sep.len == 0) {
                    var i: usize = 0;
                    while (i < s.len) : (i += 1) try l.append(self.arena, .{ .str = s[i..][0..1] });
                } else {
                    var it = std.mem.splitSequence(u8, s, sep);
                    while (it.next()) |part| try l.append(self.arena, .{ .str = part });
                }
                return .{ .list = l };
            },
            .join => {
                if (args.len != 2 or args[0] != .list or args[1] != .str) return self.fail(span, "join expects a list and a string", .{});
                const sep = args[1].str;
                var buf: std.ArrayList(u8) = .empty;
                for (args[0].list.items, 0..) |item, i| {
                    if (i > 0) try buf.appendSlice(self.arena, sep);
                    try self.appendValue(&buf, item);
                }
                return .{ .str = try buf.toOwnedSlice(self.arena) };
            },
            .contains => {
                if (args.len != 2) return self.fail(span, "contains expects 2 arguments", .{});
                switch (args[0]) {
                    .str => |s| {
                        if (args[1] != .str) return self.fail(span, "contains on a string expects a string", .{});
                        return .{ .bool = std.mem.indexOf(u8, s, args[1].str) != null };
                    },
                    .list => |l| {
                        for (l.items) |item| if (valuesEqual(item, args[1])) return .{ .bool = true };
                        return .{ .bool = false };
                    },
                    else => return self.fail(span, "contains expects a string or list", .{}),
                }
            },
            .sort, .reverse => {
                if (args.len != 1 or args[0] != .list) return self.fail(span, "{s} expects a list", .{@tagName(b)});
                const l = try self.arena.create(List);
                l.* = .empty;
                try l.appendSlice(self.arena, args[0].list.items);
                if (b == .sort) std.mem.sort(Value, l.items, {}, valueLess) else std.mem.reverse(Value, l.items);
                return .{ .list = l };
            },
            .trim => {
                if (args.len != 1 or args[0] != .str) return self.fail(span, "trim expects a string", .{});
                return .{ .str = std.mem.trim(u8, args[0].str, " \t\r\n") };
            },
            .starts_with, .ends_with => {
                if (args.len != 2 or args[0] != .str or args[1] != .str) return self.fail(span, "{s} expects two strings", .{@tagName(b)});
                const yes = if (b == .starts_with) std.mem.startsWith(u8, args[0].str, args[1].str) else std.mem.endsWith(u8, args[0].str, args[1].str);
                return .{ .bool = yes };
            },
            .find => {
                if (args.len != 2) return self.fail(span, "find expects 2 arguments", .{});
                switch (args[0]) {
                    .str => |s| {
                        if (args[1] != .str) return self.fail(span, "find on a string expects a string", .{});
                        if (std.mem.indexOf(u8, s, args[1].str)) |i| return .{ .int = @intCast(i) };
                        return .{ .int = -1 };
                    },
                    .list => |l| {
                        for (l.items, 0..) |item, i| if (valuesEqual(item, args[1])) return .{ .int = @intCast(i) };
                        return .{ .int = -1 };
                    },
                    else => return self.fail(span, "find expects a string or list", .{}),
                }
            },
            .replace => {
                if (args.len != 3 or args[0] != .str or args[1] != .str or args[2] != .str) return self.fail(span, "replace expects three strings", .{});
                if (args[1].str.len == 0) return .{ .str = args[0].str };
                const out = try std.mem.replaceOwned(u8, self.arena, args[0].str, args[1].str, args[2].str);
                return .{ .str = out };
            },
            .map => {
                if (args.len != 2 or args[0] != .list) return self.fail(span, "map expects a list and a function", .{});
                const out = try self.arena.create(List);
                out.* = .empty;
                for (args[0].list.items) |item| {
                    try out.append(self.arena, try self.callValue(args[1], &.{item}, span));
                }
                return .{ .list = out };
            },
            .filter => {
                if (args.len != 2 or args[0] != .list) return self.fail(span, "filter expects a list and a predicate", .{});
                const out = try self.arena.create(List);
                out.* = .empty;
                for (args[0].list.items) |item| {
                    if (isTruthy(try self.callValue(args[1], &.{item}, span))) try out.append(self.arena, item);
                }
                return .{ .list = out };
            },
            .reduce => {
                if (args.len != 3 or args[0] != .list) return self.fail(span, "reduce expects a list, a function, and an initial value", .{});
                var acc = args[2];
                for (args[0].list.items) |item| {
                    acc = try self.callValue(args[1], &.{ acc, item }, span);
                }
                return acc;
            },
            .sqrt => {
                if (args.len != 1) return self.fail(span, "sqrt expects 1 argument", .{});
                const x = toFloat(args[0]) orelse return self.fail(span, "sqrt expects a number", .{});
                return .{ .float = @sqrt(x) };
            },
            .pow => {
                if (args.len != 2) return self.fail(span, "pow expects 2 arguments", .{});
                const base = toFloat(args[0]) orelse return self.fail(span, "pow expects numbers", .{});
                const exp = toFloat(args[1]) orelse return self.fail(span, "pow expects numbers", .{});
                return .{ .float = std.math.pow(f64, base, exp) };
            },
            .floor => {
                if (args.len != 1) return self.fail(span, "floor expects 1 argument", .{});
                const x = toFloat(args[0]) orelse return self.fail(span, "floor expects a number", .{});
                return .{ .int = @intFromFloat(@floor(x)) };
            },
            .ceil => {
                if (args.len != 1) return self.fail(span, "ceil expects 1 argument", .{});
                const x = toFloat(args[0]) orelse return self.fail(span, "ceil expects a number", .{});
                return .{ .int = @intFromFloat(@ceil(x)) };
            },
            .round => {
                if (args.len != 1) return self.fail(span, "round expects 1 argument", .{});
                const x = toFloat(args[0]) orelse return self.fail(span, "round expects a number", .{});
                return .{ .int = @intFromFloat(@round(x)) };
            },
        }
    }

    // --- expressions ---------------------------------------------------------

    fn eval(self: *Interpreter, e: Expr) Error!Value {
        return switch (e) {
            .int_literal => |lit| .{ .int = std.fmt.parseInt(i64, lit.text, 0) catch return self.fail(lit.span, "invalid integer '{s}'", .{lit.text}) },
            .float_literal => |lit| .{ .float = std.fmt.parseFloat(f64, lit.text) catch return self.fail(lit.span, "invalid float '{s}'", .{lit.text}) },
            .string_literal => |lit| .{ .str = try self.unquote(lit.text) },
            .bool_literal => |b| .{ .bool = b.value },
            .nil_literal => .nil,
            .identifier => |id| try self.resolveName(id.name, id.span),
            .unary => |u| try self.evalUnary(u),
            .binary => |b| try self.evalBinary(b),
            .call => |c| try self.evalCall(c),
            .index => |idx| try self.evalIndex(idx),
            .slice => |s| try self.evalSlice(s),
            .comprehension => |c| try self.evalComprehension(c),
            .conditional => |c| if (isTruthy(try self.eval(c.cond.*)))
                try self.eval(c.then_val.*)
            else
                try self.eval(c.else_val.*),
            .array => |a| try self.evalArray(a),
            .map => |m| try self.evalMap(m),
            .match => |m| try self.evalMatch(m),
            .member => |m| try self.evalMember(m),
            .interpolation => |x| blk: {
                var buf: std.ArrayList(u8) = .empty;
                for (x.parts) |p| switch (p) {
                    .literal => |lit| try self.appendUnescaped(&buf, lit),
                    .expr => |pe| try self.appendValue(&buf, try self.eval(pe.*)),
                };
                break :blk .{ .str = try buf.toOwnedSlice(self.arena) };
            },
            .range => |r| try self.evalRange(r),
            .lambda => |lam| blk: {
                // Capture the current environment and context.
                const cl = try self.arena.create(Closure);
                cl.* = .{
                    .lambda = lam,
                    .env = self.env,
                    .module = self.globals,
                    .receiver = self.current_receiver,
                    .statics = self.current_statics,
                };
                break :blk .{ .closure = cl };
            },
            .tuple => |t| blk: {
                const l = try self.arena.create(List);
                l.* = .empty;
                for (t.elements) |el| try l.append(self.arena, try self.eval(el.*));
                break :blk .{ .tuple = l };
            },
        };
    }

    fn evalUnary(self: *Interpreter, u: Expr.Unary) Error!Value {
        const v = try self.eval(u.operand.*);
        switch (u.op) {
            .neg => return switch (v) {
                .int => |n| .{ .int = -n },
                .float => |f| .{ .float = -f },
                else => self.fail(u.span, "cannot negate {s}", .{@tagName(v)}),
            },
            .not => return .{ .bool = !isTruthy(v) },
            .bit_not => return switch (v) {
                .int => |n| .{ .int = ~n },
                else => self.fail(u.span, "unary '~' requires an int, got {s}", .{@tagName(v)}),
            },
        }
    }

    fn evalBinary(self: *Interpreter, b: Expr.Binary) Error!Value {
        // Logical operators short-circuit.
        switch (b.op) {
            .logical_and => {
                const l = try self.eval(b.lhs.*);
                if (!isTruthy(l)) return .{ .bool = false };
                return .{ .bool = isTruthy(try self.eval(b.rhs.*)) };
            },
            .logical_or => {
                const l = try self.eval(b.lhs.*);
                if (isTruthy(l)) return .{ .bool = true };
                return .{ .bool = isTruthy(try self.eval(b.rhs.*)) };
            },
            else => {},
        }

        const l = try self.eval(b.lhs.*);
        const r = try self.eval(b.rhs.*);
        return switch (b.op) {
            .add, .sub, .mul, .div, .mod => try self.evalArithmetic(b.op, l, r, b.span),
            .eq => .{ .bool = valuesEqual(l, r) },
            .ne => .{ .bool = !valuesEqual(l, r) },
            .lt, .le, .gt, .ge => try self.evalOrder(b.op, l, r, b.span),
            .bit_and, .bit_or, .bit_xor, .shl, .shr => try self.evalBitwise(b.op, l, r, b.span),
            else => unreachable,
        };
    }

    fn evalBitwise(self: *Interpreter, op: BinaryOp, l: Value, r: Value, span: Span) Error!Value {
        if (l != .int or r != .int) {
            return self.fail(span, "operator '{s}' requires int operands", .{opSymbol(op)});
        }
        const x = l.int;
        const y = r.int;
        return switch (op) {
            .bit_and => .{ .int = x & y },
            .bit_or => .{ .int = x | y },
            .bit_xor => .{ .int = x ^ y },
            .shl => if (y < 0) self.fail(span, "negative shift amount", .{}) else .{ .int = std.math.shl(i64, x, @as(u64, @intCast(y))) },
            .shr => if (y < 0) self.fail(span, "negative shift amount", .{}) else .{ .int = std.math.shr(i64, x, @as(u64, @intCast(y))) },
            else => unreachable,
        };
    }

    fn evalArithmetic(self: *Interpreter, op: BinaryOp, l: Value, r: Value, span: Span) Error!Value {
        // String concatenation with `+`.
        if (op == .add and l == .str and r == .str) {
            return .{ .str = try std.mem.concat(self.arena, u8, &.{ l.str, r.str }) };
        }
        if (l == .int and r == .int) {
            const x = l.int;
            const y = r.int;
            return switch (op) {
                .add => .{ .int = std.math.add(i64, x, y) catch return self.fail(span, "integer overflow", .{}) },
                .sub => .{ .int = std.math.sub(i64, x, y) catch return self.fail(span, "integer overflow", .{}) },
                .mul => .{ .int = std.math.mul(i64, x, y) catch return self.fail(span, "integer overflow", .{}) },
                .div => if (y == 0) return self.fail(span, "division by zero", .{}) else .{ .int = @divTrunc(x, y) },
                .mod => if (y == 0) return self.fail(span, "division by zero", .{}) else .{ .int = @rem(x, y) },
                else => unreachable,
            };
        }
        const x = toFloat(l) orelse return self.fail(span, "operator '{s}' cannot be applied to {s}", .{ opSymbol(op), @tagName(l) });
        const y = toFloat(r) orelse return self.fail(span, "operator '{s}' cannot be applied to {s}", .{ opSymbol(op), @tagName(r) });
        return switch (op) {
            .add => .{ .float = x + y },
            .sub => .{ .float = x - y },
            .mul => .{ .float = x * y },
            .div => if (y == 0) return self.fail(span, "division by zero", .{}) else .{ .float = x / y },
            .mod => if (y == 0) return self.fail(span, "division by zero", .{}) else .{ .float = @rem(x, y) },
            else => unreachable,
        };
    }

    fn evalOrder(self: *Interpreter, op: BinaryOp, l: Value, r: Value, span: Span) Error!Value {
        if (l == .str and r == .str) {
            const c = std.mem.order(u8, l.str, r.str);
            return .{ .bool = switch (op) {
                .lt => c == .lt,
                .le => c != .gt,
                .gt => c == .gt,
                .ge => c != .lt,
                else => unreachable,
            } };
        }
        const x = toFloat(l) orelse return self.fail(span, "cannot order {s}", .{@tagName(l)});
        const y = toFloat(r) orelse return self.fail(span, "cannot order {s}", .{@tagName(r)});
        return .{ .bool = switch (op) {
            .lt => x < y,
            .le => x <= y,
            .gt => x > y,
            .ge => x >= y,
            else => unreachable,
        } };
    }

    fn evalCall(self: *Interpreter, c: Expr.Call) Error!Value {
        const callee = try self.eval(c.callee.*);

        var has_named = false;
        for (c.args) |a| {
            if (a.name != null) has_named = true;
        }
        if (has_named) {
            const params = calleeParams(callee) orelse return self.fail(c.span, "named arguments are not allowed here", .{});
            const module = calleeModule(callee) orelse return self.fail(c.span, "named arguments are not allowed here", .{});
            const ordered = try self.reorderArgs(c, params, module, c.span);
            return self.callValue(callee, ordered, c.span);
        }

        const args = try self.arena.alloc(Value, c.args.len);
        for (c.args, 0..) |arg, i| args[i] = try self.eval(arg.value.*);
        return self.callValue(callee, args, c.span);
    }

    /// Evaluate a call's positional + named arguments into a full positional array
    /// (one value per parameter): positional fill left-to-right, named fill by
    /// name, and any unprovided parameter uses its default (evaluated in the
    /// callee's module scope). Reports name/arity errors.
    fn reorderArgs(self: *Interpreter, c: Expr.Call, params: []const parser.Param, module: *Env, span: Span) Error![]Value {
        const ordered = try self.arena.alloc(Value, params.len);
        const provided = try self.arena.alloc(bool, params.len);
        for (provided) |*b| b.* = false;

        var pos: usize = 0;
        while (pos < c.args.len and c.args[pos].name == null) pos += 1;
        if (pos > params.len) return self.fail(span, "too many arguments (expected at most {d})", .{params.len});
        for (c.args[0..pos], 0..) |arg, i| {
            ordered[i] = try self.eval(arg.value.*);
            provided[i] = true;
        }
        for (c.args[pos..]) |arg| {
            const name = arg.name.?;
            var idx: ?usize = null;
            for (params, 0..) |p, j| {
                if (std.mem.eql(u8, p.name, name)) {
                    idx = j;
                    break;
                }
            }
            const j = idx orelse return self.fail(span, "no parameter named '{s}'", .{name});
            if (provided[j]) return self.fail(span, "argument '{s}' was already provided", .{name});
            ordered[j] = try self.eval(arg.value.*);
            provided[j] = true;
        }
        for (params, 0..) |p, j| {
            if (!provided[j]) {
                const d = p.default orelse return self.fail(span, "missing required argument '{s}'", .{p.name});
                ordered[j] = try self.evalDefaultIn(module, d.*);
            }
        }
        return ordered;
    }

    /// Evaluate a default-value expression in `module`'s scope (no receiver or
    /// statics), matching how `bindArgs` fills omitted trailing arguments.
    fn evalDefaultIn(self: *Interpreter, module: *Env, expr: Expr) Error!Value {
        const saved_env = self.env;
        const saved_globals = self.globals;
        const saved_recv = self.current_receiver;
        const saved_statics = self.current_statics;
        const saved_static_ti = self.current_static_ti;
        self.globals = module;
        self.env = try self.newEnv(module);
        self.current_receiver = null;
        self.current_statics = null;
        self.current_static_ti = null;
        defer {
            self.env = saved_env;
            self.globals = saved_globals;
            self.current_receiver = saved_recv;
            self.current_statics = saved_statics;
            self.current_static_ti = saved_static_ti;
        }
        return self.eval(expr);
    }

    /// Call any callable value with already-evaluated arguments. Shared by
    /// `evalCall` and signal emission.
    fn callValue(self: *Interpreter, callee: Value, args: []const Value, span: Span) Error!Value {
        return switch (callee) {
            .func => |f| try self.callFunction(f, args, span),
            .builtin => |b| try self.callBuiltin(b, args, span),
            .bound_method => |bm| try self.callMethod(bm.func, bm.owner, bm.receiver, args, span),
            .static_method => |sm| try self.callStaticMethod(sm, args, span),
            .closure => |cl| try self.callClosure(cl, args, span),
            .type_ref => |ti| try self.construct(ti, args, span),
            else => self.fail(span, "{s} is not callable", .{@tagName(callee)}),
        };
    }

    fn evalMember(self: *Interpreter, m: Expr.MemberAccess) Error!Value {
        const obj = try self.eval(m.object.*);
        switch (obj) {
            .instance => |inst| {
                if (inst.fields.get(m.name)) |v| return v;
                if (self.findMethod(inst.info, m.name)) |mr| {
                    const bm = try self.arena.create(BoundMethod);
                    bm.* = .{ .receiver = inst, .func = mr.func, .owner = mr.owner };
                    return .{ .bound_method = bm };
                }
                return self.fail(m.span, "type '{s}' has no member '{s}'", .{ inst.info.name, m.name });
            },
            .enum_type => |et| {
                if (!et.members.contains(m.name)) {
                    return self.fail(m.span, "enum '{s}' has no member '{s}'", .{ et.name, m.name });
                }
                const ev = try self.arena.create(EnumValue);
                ev.* = .{ .type_name = et.name, .member = m.name };
                return .{ .enum_value = ev };
            },
            .module => |menv| {
                if (menv.vars.get(m.name)) |v| return v;
                return self.fail(m.span, "module has no member '{s}'", .{m.name});
            },
            .type_ref => |ti| {
                if (self.staticsEnvFor(ti, m.name)) |env| return env.vars.get(m.name).?;
                return self.fail(m.span, "type '{s}' has no static member '{s}'", .{ ti.name, m.name });
            },
            else => return self.fail(m.span, "cannot access a member of {s}", .{@tagName(obj)}),
        }
    }

    fn evalIndex(self: *Interpreter, idx: Expr.Index) Error!Value {
        const container = try self.eval(idx.object.*);
        const key = try self.eval(idx.index.*);
        switch (container) {
            .list => |l| {
                const i = try self.listIndex(l, key, idx.span);
                return l.items[i];
            },
            .map => |m| {
                for (m.entries.items) |entry| {
                    if (valuesEqual(entry.key, key)) return entry.value;
                }
                return .nil;
            },
            .str => |s| {
                if (key != .int) return self.fail(idx.span, "string index must be an int", .{});
                const raw = key.int;
                if (raw < 0 or raw >= s.len) return self.fail(idx.span, "string index {d} out of range", .{raw});
                return .{ .str = s[@intCast(raw)..][0..1] };
            },
            else => return self.fail(idx.span, "cannot index {s}", .{@tagName(container)}),
        }
    }

    fn evalArray(self: *Interpreter, a: Expr.Array) Error!Value {
        const l = try self.arena.create(List);
        l.* = .empty;
        for (a.elements) |el| try l.append(self.arena, try self.eval(el.*));
        return .{ .list = l };
    }

    fn evalComprehension(self: *Interpreter, c: *const Expr.Comprehension) Error!Value {
        const iter = try self.eval(c.iter.*);
        const two = c.value_binding != null;
        var firsts: List = .empty;
        var seconds: List = .empty;
        var single_first = false;
        switch (iter) {
            .list => |l| for (l.items, 0..) |el, i| {
                try firsts.append(self.arena, .{ .int = @intCast(i) });
                try seconds.append(self.arena, el);
            },
            .str => |s| for (0..s.len) |i| {
                try firsts.append(self.arena, .{ .int = @intCast(i) });
                try seconds.append(self.arena, .{ .str = s[i .. i + 1] });
            },
            .map => |m| {
                single_first = true;
                for (m.entries.items) |entry| {
                    try firsts.append(self.arena, entry.key);
                    try seconds.append(self.arena, entry.value);
                }
            },
            else => return self.fail(c.span, "cannot iterate over {s}", .{@tagName(iter)}),
        }

        const out = try self.arena.create(List);
        out.* = .empty;
        for (firsts.items, seconds.items) |first, second| {
            const child = try self.newEnv(self.env);
            const saved = self.env;
            self.env = child;
            defer self.env = saved;
            if (two) {
                try self.define(child, c.binding, first);
                try self.define(child, c.value_binding.?, second);
            } else {
                try self.define(child, c.binding, if (single_first) first else second);
            }
            if (c.cond) |cond| {
                if (!isTruthy(try self.eval(cond.*))) continue;
            }
            try out.append(self.arena, try self.eval(c.output.*));
        }
        return .{ .list = out };
    }

    /// Evaluate and clamp a slice's `[start:end]` bounds against a length.
    fn sliceBounds(self: *Interpreter, s: Expr.Slice, len: usize, span: Span) Error!struct { start: usize, end: usize } {
        const n: i64 = @intCast(len);
        var start: i64 = 0;
        var end: i64 = n;
        if (s.start) |st| {
            const v = try self.eval(st.*);
            if (v != .int) return self.fail(span, "slice bound must be an int", .{});
            start = v.int;
        }
        if (s.end) |en| {
            const v = try self.eval(en.*);
            if (v != .int) return self.fail(span, "slice bound must be an int", .{});
            end = v.int;
        }
        start = std.math.clamp(start, 0, n);
        end = std.math.clamp(end, start, n);
        return .{ .start = @intCast(start), .end = @intCast(end) };
    }

    fn evalSlice(self: *Interpreter, s: Expr.Slice) Error!Value {
        const container = try self.eval(s.object.*);
        switch (container) {
            .list => |l| {
                const b = try self.sliceBounds(s, l.items.len, s.span);
                const out = try self.arena.create(List);
                out.* = .empty;
                try out.appendSlice(self.arena, l.items[b.start..b.end]);
                return .{ .list = out };
            },
            .str => |str| {
                const b = try self.sliceBounds(s, str.len, s.span);
                return .{ .str = str[b.start..b.end] };
            },
            else => return self.fail(s.span, "cannot slice {s}", .{@tagName(container)}),
        }
    }

    fn evalMap(self: *Interpreter, m: Expr.Map) Error!Value {
        const map = try self.arena.create(Map);
        map.* = .{};
        for (m.entries) |entry| {
            const k = try self.eval(entry.key.*);
            const v = try self.eval(entry.value.*);
            try map.entries.append(self.arena, .{ .key = k, .value = v });
        }
        return .{ .map = map };
    }

    fn evalMatch(self: *Interpreter, m: Expr.Match) Error!Value {
        const subject = try self.eval(m.subject.*);
        for (m.arms) |arm| {
            switch (arm.pattern) {
                .wildcard => return self.eval(arm.body.*),
                .binding => |bd| {
                    const child = try self.newEnv(self.env);
                    try self.define(child, bd.name, subject);
                    const saved = self.env;
                    self.env = child;
                    defer self.env = saved;
                    return self.eval(arm.body.*);
                },
                else => {
                    const pv = try self.patternValue(arm.pattern);
                    if (valuesEqual(pv, subject)) return self.eval(arm.body.*);
                },
            }
        }
        return .nil;
    }

    fn patternValue(self: *Interpreter, p: parser.Pattern) Error!Value {
        return switch (p) {
            .int_literal => |lit| .{ .int = std.fmt.parseInt(i64, lit.text, 0) catch return self.fail(lit.span, "invalid integer '{s}'", .{lit.text}) },
            .float_literal => |lit| .{ .float = std.fmt.parseFloat(f64, lit.text) catch return self.fail(lit.span, "invalid float '{s}'", .{lit.text}) },
            .string_literal => |lit| .{ .str = try self.unquote(lit.text) },
            .bool_literal => |b| .{ .bool = b.value },
            .enum_case => |ec| blk: {
                const ev = try self.arena.create(EnumValue);
                ev.* = .{ .type_name = ec.enum_name, .member = ec.case };
                break :blk .{ .enum_value = ev };
            },
            else => .nil,
        };
    }

    // --- helpers -------------------------------------------------------------

    /// Strip the surrounding quotes from a string literal and resolve escapes.
    fn unquote(self: *Interpreter, text: []const u8) Error![]const u8 {
        const inner = if (text.len >= 2) text[1 .. text.len - 1] else text;
        var buf: std.ArrayList(u8) = .empty;
        try self.appendUnescaped(&buf, inner);
        return buf.toOwnedSlice(self.arena);
    }

    /// Append `inner` (a string body without quotes) to `buf`, resolving escape
    /// sequences.
    fn appendUnescaped(self: *Interpreter, buf: *std.ArrayList(u8), inner: []const u8) Error!void {
        var i: usize = 0;
        while (i < inner.len) : (i += 1) {
            if (inner[i] == '\\' and i + 1 < inner.len) {
                i += 1;
                try buf.append(self.arena, switch (inner[i]) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    '0' => 0,
                    else => inner[i],
                });
            } else {
                try buf.append(self.arena, inner[i]);
            }
        }
    }

    fn appendValue(self: *Interpreter, buf: *std.ArrayList(u8), v: Value) Error!void {
        switch (v) {
            .nil => try buf.appendSlice(self.arena, "nil"),
            .int => |n| try buf.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, "{d}", .{n})),
            .float => |f| try buf.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, "{d}", .{f})),
            .bool => |b| try buf.appendSlice(self.arena, if (b) "true" else "false"),
            .str => |s| try buf.appendSlice(self.arena, s),
            .list => |l| {
                try buf.append(self.arena, '[');
                for (l.items, 0..) |item, i| {
                    if (i > 0) try buf.appendSlice(self.arena, ", ");
                    try self.appendValue(buf, item);
                }
                try buf.append(self.arena, ']');
            },
            .tuple => |l| {
                try buf.append(self.arena, '(');
                for (l.items, 0..) |item, i| {
                    if (i > 0) try buf.appendSlice(self.arena, ", ");
                    try self.appendValue(buf, item);
                }
                try buf.append(self.arena, ')');
            },
            .map => |m| {
                try buf.append(self.arena, '{');
                for (m.entries.items, 0..) |entry, i| {
                    if (i > 0) try buf.appendSlice(self.arena, ", ");
                    try self.appendValue(buf, entry.key);
                    try buf.appendSlice(self.arena, ": ");
                    try self.appendValue(buf, entry.value);
                }
                try buf.append(self.arena, '}');
            },
            .func, .builtin, .bound_method, .static_method, .closure => try buf.appendSlice(self.arena, "<function>"),
            .module => try buf.appendSlice(self.arena, "<module>"),
            .signal => |s| {
                try buf.appendSlice(self.arena, "<signal ");
                try buf.appendSlice(self.arena, s.name);
                try buf.append(self.arena, '>');
            },
            .type_ref => |ti| {
                try buf.appendSlice(self.arena, "<type ");
                try buf.appendSlice(self.arena, ti.name);
                try buf.append(self.arena, '>');
            },
            .enum_type => |et| {
                try buf.appendSlice(self.arena, "<enum ");
                try buf.appendSlice(self.arena, et.name);
                try buf.append(self.arena, '>');
            },
            .enum_value => |ev| {
                try buf.appendSlice(self.arena, ev.type_name);
                try buf.append(self.arena, '.');
                try buf.appendSlice(self.arena, ev.member);
            },
            .instance => |inst| {
                try buf.appendSlice(self.arena, inst.info.name);
                try buf.appendSlice(self.arena, " {");
                for (inst.info.all_fields, 0..) |f, i| {
                    try buf.appendSlice(self.arena, if (i > 0) ", " else " ");
                    try buf.appendSlice(self.arena, f.name);
                    try buf.appendSlice(self.arena, ": ");
                    try self.appendValue(buf, inst.fields.get(f.name) orelse .nil);
                }
                try buf.appendSlice(self.arena, " }");
            },
        }
    }
};

fn opSymbol(op: BinaryOp) []const u8 {
    return switch (op) {
        .add => "+",
        .sub => "-",
        .mul => "*",
        .div => "/",
        .mod => "%",
        .bit_and => "&",
        .bit_or => "|",
        .bit_xor => "^",
        .shl => "<<",
        .shr => ">>",
        else => "?",
    };
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;

fn runSource(gpa: std.mem.Allocator, src: []const u8) !RunResult {
    var tree = try parser.parse(gpa, src);
    defer tree.deinit();
    return run(gpa, tree.module);
}

fn expectOutput(src: []const u8, expected: []const u8) !void {
    var result = try runSource(testing.allocator, src);
    defer result.deinit();
    try testing.expect(result.runtime_error == null);
    try testing.expectEqualStrings(expected, result.output);
}

test "arithmetic honors precedence" {
    try expectOutput("func main():\n    print(1 + 2 * 3)", "7\n");
}

test "globals are evaluated and visible" {
    try expectOutput("const LIMIT: int = 10\nfunc main():\n    print(LIMIT * 2)", "20\n");
}

test "recursion" {
    const src =
        \\func fact(n: int) -> int:
        \\    if n <= 1:
        \\        return 1
        \\    return n * fact(n - 1)
        \\
        \\func main():
        \\    print(fact(5))
    ;
    try expectOutput(src, "120\n");
}

test "list comprehensions: map, filter, two bindings, and nesting" {
    const src =
        \\func main():
        \\    var xs = [1, 2, 3, 4, 5]
        \\    print([x * x for x in xs])
        \\    print([x for x in xs if x % 2 == 0])
        \\    print([i * v for i, v in xs])
        \\    print([[y for y in range(x)] for x in range(3)])
        \\    var n = 10
        \\    print([x + n for x in xs if x > 3])
    ;
    try expectOutput(src, "[1, 4, 9, 16, 25]\n[2, 4]\n[0, 2, 6, 12, 20]\n[[], [0], [0, 1]]\n[14, 15]\n");
}

test "named arguments reorder, skip defaults, and work on lambdas" {
    const src =
        \\func box(w: int, h: int = 1, label: str = "?") -> str:
        \\    return label + ":" + str(w) + "x" + str(h)
        \\
        \\func main():
        \\    print(box(3))
        \\    print(box(3, label: "R"))
        \\    print(box(label: "Z", w: 4))
        \\    var scale = func(n: int, k: int = 2): n * k
        \\    print(scale(k: 3, n: 4))
    ;
    try expectOutput(src, "?:3x1\nR:3x1\nZ:4x1\n12\n");
}

test "list and string slicing with clamping" {
    const src =
        \\func main():
        \\    var xs = [10, 20, 30, 40, 50]
        \\    print(xs[1:3])
        \\    print(xs[:2])
        \\    print(xs[3:])
        \\    print(xs[2:100])
        \\    print(xs[3:1])
        \\    var s = "hello world"
        \\    print(s[0:5])
        \\    print(s[6:])
    ;
    try expectOutput(src, "[20, 30]\n[10, 20]\n[40, 50]\n[30, 40, 50]\n[]\nhello\nworld\n");
}

test "conditional (ternary) expression" {
    const src =
        \\func sign(n: int) -> str:
        \\    return "neg" if n < 0 else ("zero" if n == 0 else "pos")
        \\
        \\func main():
        \\    print(sign(-5))
        \\    print(sign(0))
        \\    print(sign(7))
        \\    print([("even" if i % 2 == 0 else "odd") for i in range(3)])
    ;
    try expectOutput(src, "neg\nzero\npos\n[even, odd, even]\n");
}

test "hex, binary, and underscore number literals" {
    const src =
        \\func main():
        \\    print(0xFF)
        \\    print(0b1010)
        \\    print(1_000_000)
        \\    print(0xFF_FF)
        \\    print(0xff & 0x0f)
        \\    print(3.14_15)
    ;
    try expectOutput(src, "255\n10\n1000000\n65535\n15\n3.1415\n");
}

test "bitwise operators and precedence" {
    const src =
        \\func main():
        \\    print(6 & 3)
        \\    print(6 | 1)
        \\    print(6 ^ 3)
        \\    print(~5)
        \\    print(1 << 4)
        \\    print(255 >> 2)
        \\    print(1 << 2 | 1)
        \\    print(2 + 3 << 1)
    ;
    try expectOutput(src, "2\n7\n5\n-6\n16\n63\n5\n10\n");
}

test "default parameters fill omitted trailing arguments" {
    const src =
        \\const BASE = 100
        \\
        \\func add(x: int, y: int = 10, z: int = BASE) -> int:
        \\    return x + y + z
        \\
        \\func main():
        \\    print(add(1))
        \\    print(add(1, 2))
        \\    print(add(1, 2, 3))
    ;
    try expectOutput(src, "111\n103\n6\n");
}

test "default parameters work on methods, constructors, and lambdas" {
    const src =
        \\class Box:
        \\    var w: int = 0
        \\    func init(width: int = 2):
        \\        w = width
        \\    func scaled(k: int = 3) -> int:
        \\        return w * k
        \\
        \\func main():
        \\    print(Box().scaled())
        \\    print(Box(5).scaled(2))
        \\    var f = func(n, k = 4): n * k
        \\    print(f(3))
    ;
    try expectOutput(src, "6\n10\n12\n");
}

test "while loop accumulates" {
    const src =
        \\func main():
        \\    var sum: int = 0
        \\    var i: int = 1
        \\    while i <= 5:
        \\        sum = sum + i
        \\        i = i + 1
        \\    print(sum)
    ;
    try expectOutput(src, "15\n");
}

test "for over range" {
    const src =
        \\func main():
        \\    var total: int = 0
        \\    for x in range(4):
        \\        total = total + x
        \\    print(total)
    ;
    try expectOutput(src, "6\n");
}

test "for over a string yields each character" {
    const src =
        \\func main():
        \\    for ch in "abc":
        \\        print(ch)
    ;
    try expectOutput(src, "a\nb\nc\n");
}

test "for over a map yields its keys in insertion order" {
    const src =
        \\func main():
        \\    var m = {"x": 1, "y": 2}
        \\    for k in m:
        \\        print(k)
    ;
    try expectOutput(src, "x\ny\n");
}

test "for over a map keys can index the map" {
    const src =
        \\func main():
        \\    var m = {"a": 10, "b": 20}
        \\    var total: int = 0
        \\    for k in m:
        \\        total = total + m[k]
        \\    print(total)
    ;
    try expectOutput(src, "30\n");
}

test "iterating a non-iterable is a runtime error" {
    var result = try runSource(testing.allocator, "func main():\n    for x in 5:\n        print(x)");
    defer result.deinit();
    try testing.expect(result.runtime_error != null);
    try testing.expect(std.mem.indexOf(u8, result.runtime_error.?.message, "cannot iterate over int") != null);
}

test "break exits a loop early" {
    const src =
        \\func main():
        \\    var i: int = 0
        \\    while i < 10:
        \\        if i == 3:
        \\            break
        \\        i = i + 1
        \\    print(i)
    ;
    try expectOutput(src, "3\n");
}

test "continue skips to the next iteration" {
    const src =
        \\func main():
        \\    var sum: int = 0
        \\    for n in range(5):
        \\        if n == 2:
        \\            continue
        \\        sum = sum + n
        \\    print(sum)
    ;
    try expectOutput(src, "8\n"); // 0 + 1 + 3 + 4
}

test "break affects only the innermost loop" {
    const src =
        \\func main():
        \\    var count: int = 0
        \\    for a in range(3):
        \\        for b in range(3):
        \\            if b == 1:
        \\                break
        \\            count = count + 1
        \\    print(count)
    ;
    try expectOutput(src, "3\n"); // inner runs once (b=0) per outer iteration
}

test "nil prints as nil" {
    try expectOutput("func main():\n    print(nil)", "nil\n");
}

test "an optional-returning function and nil checks" {
    const src =
        \\func lookup(n: int) -> ?int:
        \\    if n > 0:
        \\        return n
        \\    return nil
        \\
        \\func main():
        \\    var a = lookup(5)
        \\    if a != nil:
        \\        print("found", a)
        \\    var b = lookup(-1)
        \\    if b == nil:
        \\        print("none")
    ;
    try expectOutput(src, "found 5\nnone\n");
}

test "match dispatches on enum cases" {
    const src =
        \\enum Suit { HEARTS, SPADES }
        \\
        \\func color(s: Suit) -> str:
        \\    return match s {
        \\        Suit.HEARTS: "red"
        \\        Suit.SPADES: "black"
        \\    }
        \\
        \\func main():
        \\    print(color(Suit.HEARTS))
        \\    print(color(Suit.SPADES))
    ;
    try expectOutput(src, "red\nblack\n");
}

test "match expression selects the right arm" {
    const src =
        \\func describe(code: int) -> str:
        \\    return match code {
        \\        200: "ok"
        \\        404: "not found"
        \\        _: "unknown"
        \\    }
        \\
        \\func main():
        \\    print(describe(404))
        \\    print(describe(500))
    ;
    try expectOutput(src, "not found\nunknown\n");
}

test "strings, booleans, and logical operators" {
    const src =
        \\func main():
        \\    print("hello" + " " + "world")
        \\    print(true and false)
        \\    print(not true)
    ;
    try expectOutput(src, "hello world\nfalse\nfalse\n");
}

test "lists: literal, index, and len" {
    const src =
        \\func main():
        \\    var xs = [10, 20, 30]
        \\    print(xs[1])
        \\    print(len(xs))
        \\    print(xs)
    ;
    try expectOutput(src, "20\n3\n[10, 20, 30]\n");
}

test "maps: literal and index" {
    const src =
        \\func main():
        \\    var m = {"a": 1, "b": 2}
        \\    print(m["b"])
    ;
    try expectOutput(src, "2\n");
}

test "float arithmetic" {
    try expectOutput("func main():\n    print(3.0 / 2.0)", "1.5\n");
}

// stdlib builtins

test "str, int, and float conversions" {
    const src =
        \\func main():
        \\    print(str(42))
        \\    print(int("100") + 1)
        \\    print(int(3.9))
        \\    print(float(2))
    ;
    try expectOutput(src, "42\n101\n3\n2\n");
}

test "list push and pop" {
    const src =
        \\func main():
        \\    var xs = [1, 2]
        \\    push(xs, 3)
        \\    print(xs)
        \\    print(pop(xs))
        \\    print(xs)
    ;
    try expectOutput(src, "[1, 2, 3]\n3\n[1, 2]\n");
}

test "map keys, values, and has" {
    const src =
        \\func main():
        \\    var m = {"a": 1, "b": 2}
        \\    print(keys(m))
        \\    print(values(m))
        \\    print(has(m, "a"))
        \\    print(has(m, "z"))
    ;
    try expectOutput(src, "[a, b]\n[1, 2]\ntrue\nfalse\n");
}

test "pop from an empty list is a runtime error" {
    var result = try runSource(testing.allocator, "func main():\n    var xs = []\n    print(pop(xs))");
    defer result.deinit();
    try testing.expect(result.runtime_error != null);
    try testing.expect(std.mem.indexOf(u8, result.runtime_error.?.message, "empty list") != null);
}

test "logical operators short-circuit" {
    // If `and` did not short-circuit, boom() would run and divide by zero.
    const src =
        \\func boom() -> bool:
        \\    return 1 / 0 == 0
        \\
        \\func main():
        \\    print(false and boom())
    ;
    try expectOutput(src, "false\n");
}

test "division by zero is a runtime error" {
    var result = try runSource(testing.allocator, "func main():\n    print(10 / 0)");
    defer result.deinit();
    try testing.expect(result.runtime_error != null);
    try testing.expect(std.mem.indexOf(u8, result.runtime_error.?.message, "division by zero") != null);
}

test "list index out of range is a runtime error" {
    var result = try runSource(testing.allocator, "func main():\n    var xs = [1, 2]\n    print(xs[5])");
    defer result.deinit();
    try testing.expect(result.runtime_error != null);
    try testing.expect(std.mem.indexOf(u8, result.runtime_error.?.message, "out of range") != null);
}

test "a program with no main produces no output" {
    try expectOutput("const X: int = 1", "");
}

// classes and structs

test "struct construction, field access, and member assignment" {
    const src =
        \\struct Point:
        \\    var x: int = 0
        \\    var y: int = 0
        \\
        \\func main():
        \\    var p: Point = Point()
        \\    p.x = 3
        \\    p.y = 4
        \\    print(p.x + p.y)
    ;
    try expectOutput(src, "7\n");
}

test "methods mutate fields via bare names" {
    const src =
        \\class Counter:
        \\    var count: int = 0
        \\
        \\    func bump():
        \\        count = count + 1
        \\
        \\    func get() -> int:
        \\        return count
        \\
        \\func main():
        \\    var c: Counter = Counter()
        \\    c.bump()
        \\    c.bump()
        \\    c.bump()
        \\    print(c.get())
    ;
    try expectOutput(src, "3\n");
}

test "init acts as a constructor" {
    const src =
        \\class Box:
        \\    var w: int = 0
        \\
        \\    func init(width: int):
        \\        w = width
        \\
        \\    func area() -> int:
        \\        return w * w
        \\
        \\func main():
        \\    var b: Box = Box(5)
        \\    print(b.area())
    ;
    try expectOutput(src, "25\n");
}

test "a method calls a sibling method by bare name" {
    const src =
        \\class Calc:
        \\    var base: int = 10
        \\
        \\    func double() -> int:
        \\        return base * 2
        \\
        \\    func quad() -> int:
        \\        return double() * 2
        \\
        \\func main():
        \\    var c: Calc = Calc()
        \\    print(c.quad())
    ;
    try expectOutput(src, "40\n");
}

test "instances print their fields in declaration order" {
    const src =
        \\struct Vec2:
        \\    var x: int = 1
        \\    var y: int = 2
        \\
        \\func main():
        \\    print(Vec2())
    ;
    try expectOutput(src, "Vec2 { x: 1, y: 2 }\n");
}

test "accessing an unknown member is a runtime error" {
    const src =
        \\struct Empty:
        \\    var a: int = 0
        \\
        \\func main():
        \\    var e: Empty = Empty()
        \\    print(e.missing)
    ;
    var result = try runSource(testing.allocator, src);
    defer result.deinit();
    try testing.expect(result.runtime_error != null);
    try testing.expect(std.mem.indexOf(u8, result.runtime_error.?.message, "no member 'missing'") != null);
}

// enums

test "enum cases print and compare by identity" {
    const src =
        \\enum Status { OK = 200, NOT_FOUND = 404 }
        \\
        \\func main():
        \\    var s = Status.OK
        \\    print(s)
        \\    print(s == Status.OK)
        \\    print(s == Status.NOT_FOUND)
    ;
    try expectOutput(src, "Status.OK\ntrue\nfalse\n");
}

test "enum cases of the same ordinal position are still distinct types" {
    const src =
        \\enum A { X }
        \\enum B { X }
        \\
        \\func main():
        \\    print(A.X == B.X)
    ;
    try expectOutput(src, "false\n");
}

test "an unknown enum case is a runtime error" {
    const src =
        \\enum Color { RED, GREEN }
        \\
        \\func main():
        \\    print(Color.BLUE)
    ;
    var result = try runSource(testing.allocator, src);
    defer result.deinit();
    try testing.expect(result.runtime_error != null);
    try testing.expect(std.mem.indexOf(u8, result.runtime_error.?.message, "no member 'BLUE'") != null);
}

// runtime inheritance

test "a subclass instance has inherited fields and methods" {
    const src =
        \\class Animal:
        \\    var legs: int = 4
        \\
        \\    func count() -> int:
        \\        return legs
        \\
        \\class Cat extends Animal:
        \\    var lives: int = 9
        \\
        \\func main():
        \\    var c: Cat = Cat()
        \\    print(c.legs)
        \\    print(c.lives)
        \\    print(c.count())
    ;
    try expectOutput(src, "4\n9\n4\n");
}

test "a subclass method overrides the base" {
    const src =
        \\class Animal:
        \\    func speak() -> str:
        \\        return "..."
        \\
        \\class Dog extends Animal:
        \\    func speak() -> str:
        \\        return "woof"
        \\
        \\func main():
        \\    var d: Dog = Dog()
        \\    print(d.speak())
    ;
    try expectOutput(src, "woof\n");
}

test "an inherited init runs as the constructor" {
    const src =
        \\class Base:
        \\    var x: int = 0
        \\
        \\    func init(v: int):
        \\        x = v
        \\
        \\class Derived extends Base:
        \\    var y: int = 0
        \\
        \\func main():
        \\    var d: Derived = Derived(7)
        \\    print(d.x)
    ;
    try expectOutput(src, "7\n");
}

test "a used trait contributes fields and methods" {
    const src =
        \\class Damageable:
        \\    var hp: int = 100
        \\
        \\    func hurt(amount: int):
        \\        hp = hp - amount
        \\
        \\class Player uses Damageable:
        \\    var name: str = "hero"
        \\
        \\func main():
        \\    var p: Player = Player()
        \\    p.hurt(30)
        \\    print(p.hp)
    ;
    try expectOutput(src, "70\n");
}

test "instances print inherited fields base-first" {
    const src =
        \\class Base:
        \\    var a: int = 1
        \\
        \\class Sub extends Base:
        \\    var b: int = 2
        \\
        \\func main():
        \\    print(Sub())
    ;
    try expectOutput(src, "Sub { a: 1, b: 2 }\n");
}

test "static var and method are shared on the type" {
    const src =
        \\class Counter:
        \\    static var count: int = 0
        \\
        \\    static func bump():
        \\        count = count + 1
        \\
        \\func main():
        \\    Counter.bump()
        \\    Counter.bump()
        \\    print(Counter.count)
    ;
    try expectOutput(src, "2\n");
}

test "a static factory sees statics and constructs instances" {
    const src =
        \\class Widget:
        \\    var id: int = 0
        \\    static var next: int = 100
        \\
        \\    static func make() -> Widget:
        \\        var w: Widget = Widget()
        \\        w.id = next
        \\        next = next + 1
        \\        return w
        \\
        \\func main():
        \\    var a: Widget = Widget.make()
        \\    var b: Widget = Widget.make()
        \\    print(a.id, b.id, Widget.next)
    ;
    try expectOutput(src, "100 101 102\n");
}

test "compound assignment updates a variable" {
    const src =
        \\func main():
        \\    var n: int = 10
        \\    n += 5
        \\    n -= 2
        \\    n *= 3
        \\    print(n)
    ;
    try expectOutput(src, "39\n");
}

test "compound assignment on a list element and map value" {
    const src =
        \\func main():
        \\    var xs: list<int> = [1, 2, 3]
        \\    xs[1] += 10
        \\    var m: map<str, int> = {"a": 1}
        \\    m["a"] += 5
        \\    print(xs, m["a"])
    ;
    try expectOutput(src, "[1, 12, 3] 6\n");
}

test "compound assignment on a field via a method" {
    const src =
        \\class C:
        \\    var v: int = 0
        \\    func bump():
        \\        v += 7
        \\
        \\func main():
        \\    var c: C = C()
        \\    c.bump()
        \\    c.bump()
        \\    print(c.v)
    ;
    try expectOutput(src, "14\n");
}

test "a top-level signal invokes connected handlers in order" {
    const src =
        \\signal tick(n)
        \\
        \\var log: list<int> = []
        \\
        \\func on_tick(n):
        \\    push(log, n)
        \\
        \\func main():
        \\    connect(tick, on_tick)
        \\    emit(tick, 1)
        \\    emit(tick, 2)
        \\    print(log)
    ;
    try expectOutput(src, "[1, 2]\n");
}

test "an instance signal calls a bound-method handler" {
    const src =
        \\class Button:
        \\    signal pressed(label)
        \\
        \\class Logger:
        \\    var count: int = 0
        \\    func on_press(label):
        \\        count += 1
        \\
        \\func main():
        \\    var b: Button = Button()
        \\    var lg: Logger = Logger()
        \\    connect(b.pressed, lg.on_press)
        \\    emit(b.pressed, "ok")
        \\    emit(b.pressed, "go")
        \\    print(lg.count)
    ;
    try expectOutput(src, "2\n");
}

test "instance signals are independent per instance" {
    const src =
        \\class Button:
        \\    signal pressed()
        \\
        \\var hits: int = 0
        \\
        \\func on_press():
        \\    hits += 1
        \\
        \\func main():
        \\    var a: Button = Button()
        \\    var b: Button = Button()
        \\    connect(a.pressed, on_press)
        \\    emit(a.pressed)
        \\    emit(b.pressed)
        \\    print(hits)
    ;
    try expectOutput(src, "1\n");
}

test "string stdlib builtins" {
    const src =
        \\func main():
        \\    var raw = "  hi  "
        \\    print("[" + trim(raw) + "]")
        \\    print(starts_with("hello", "he"), ends_with("hello", "lo"))
        \\    print(find("hello", "ll"), find([10, 20, 30], 20), find("x", "y"))
        \\    print(replace("a-b-c", "-", "+"))
    ;
    try expectOutput(src, "[hi]\ntrue true\n2 1 -1\na+b+c\n");
}

test "string and collection stdlib builtins" {
    const src =
        \\func main():
        \\    print(upper("hi"), lower("BYE"))
        \\    print(split("a,b,c", ","))
        \\    print(join(["x", "y", "z"], "-"))
        \\    print(contains("hello", "ell"), contains([1, 2, 3], 2))
        \\    print(sort([3, 1, 2]), reverse([1, 2, 3]))
        \\    print(abs(-5), min(3, 7), max(3, 7))
    ;
    try expectOutput(src, "HI bye\n[a, b, c]\nx-y-z\ntrue true\n[1, 2, 3] [3, 2, 1]\n5 3 7\n");
}

test "error handling: raise, catch, and built-in errors" {
    const src =
        \\func checked(a: int, b: int) -> int:
        \\    if b == 0:
        \\        raise "div by zero"
        \\    return a / b
        \\
        \\func main():
        \\    try:
        \\        print(checked(10, 2))
        \\        print(checked(10, 0))
        \\        print("unreached")
        \\    catch e:
        \\        print("caught:", e)
        \\    try:
        \\        var xs = [1, 2]
        \\        print(xs[9])
        \\    catch e:
        \\        print("builtin:", e)
        \\    print("done")
    ;
    try expectOutput(src, "5\ncaught: div by zero\nbuiltin: list index 9 out of range (len 2)\ndone\n");
}

test "tuples: literals, multiple return, destructuring, equality" {
    const src =
        \\func minmax(xs: list<int>) -> (int, int):
        \\    var lo = xs[0]
        \\    var hi = xs[0]
        \\    for x in xs:
        \\        if x < lo:
        \\            lo = x
        \\        if x > hi:
        \\            hi = x
        \\    return (lo, hi)
        \\
        \\func main():
        \\    var lo, hi = minmax([3, 7, 1, 9])
        \\    print(lo, hi)
        \\    print((1, "two"))
        \\    print((1, 2) == (1, 2), (1, 2) == (1, 3))
        \\    var a, b = (10, 20)
        \\    print(a + b)
    ;
    try expectOutput(src, "1 9\n(1, two)\ntrue false\n30\n");
}

test "math builtins: sqrt, pow, floor, ceil, round" {
    const src =
        \\func main():
        \\    print(sqrt(16.0), pow(2.0, 10.0))
        \\    print(floor(2.9), ceil(2.1), round(2.5), round(2.4))
        \\    print(floor(-1.5), ceil(-1.5), round(-2.5))
        \\    print(sqrt(9), pow(2, 8))
    ;
    try expectOutput(src, "4 1024\n2 3 3 2\n-2 -1 -3\n3 256\n");
}

test "map, filter, and reduce apply a callback over a list" {
    const src =
        \\func triple(x: int) -> int:
        \\    return x * 3
        \\
        \\func main():
        \\    var xs = [1, 2, 3, 4, 5]
        \\    print(map(xs, func(x): x * x))
        \\    print(map(xs, triple))
        \\    print(filter(xs, func(x): x % 2 == 0))
        \\    print(reduce(xs, func(a, x): a + x, 0))
        \\    print(reduce(["a", "b"], func(a, x): a + x, ""))
    ;
    try expectOutput(src, "[1, 4, 9, 16, 25]\n[3, 6, 9, 12, 15]\n[2, 4]\n15\nab\n");
}

test "runaway recursion is a runtime error, not a crash" {
    const src =
        \\func f(n):
        \\    return f(n) + 1
        \\
        \\func main():
        \\    print(f(1))
    ;
    var result = try runSource(testing.allocator, src);
    defer result.deinit();
    try testing.expect(result.runtime_error != null);
    try testing.expect(std.mem.indexOf(u8, result.runtime_error.?.message, "call stack overflow") != null);
}

test "range loops and index/value iteration" {
    const src =
        \\func main():
        \\    var sum = 0
        \\    for i in 0..4:
        \\        sum += i
        \\    print(sum)
        \\    var xs = ["a", "b"]
        \\    for i, x in xs:
        \\        print("${i}=${x}")
        \\    var m = {"k": 9}
        \\    for key, v in m:
        \\        print("${key}:${v}")
    ;
    try expectOutput(src, "6\n0=a\n1=b\nk:9\n");
}

test "string interpolation evaluates and concatenates its holes" {
    const src =
        \\func main():
        \\    var name = "Ada"
        \\    var n = 3
        \\    print("hi ${name}, ${n + 1} left")
        \\    print("nested ${upper(name)}!")
    ;
    try expectOutput(src, "hi Ada, 4 left\nnested ADA!\n");
}

test "a lambda captures a local by reference" {
    const src =
        \\func main():
        \\    var n = 10
        \\    var add = func(x): x + n
        \\    print(add(5))
        \\    n = 100
        \\    print(add(5))
    ;
    try expectOutput(src, "15\n105\n");
}

test "a lambda is a first-class higher-order argument" {
    const src =
        \\func apply(f, x):
        \\    return f(x)
        \\
        \\func main():
        \\    print(apply(func(n): n * n, 7))
    ;
    try expectOutput(src, "49\n");
}

test "a lambda works as a signal handler and captures a local" {
    const src =
        \\signal ping(msg)
        \\
        \\func main():
        \\    var seen = []
        \\    connect(ping, func(m): push(seen, m))
        \\    emit(ping, "a")
        \\    emit(ping, "b")
        \\    print(seen)
    ;
    try expectOutput(src, "[a, b]\n");
}

test "a lambda in a method captures the receiver" {
    const src =
        \\class Counter:
        \\    var n = 0
        \\    func adder():
        \\        return func(x): n + x
        \\
        \\func main():
        \\    var c = Counter()
        \\    c.n = 10
        \\    var f = c.adder()
        \\    print(f(5))
    ;
    try expectOutput(src, "15\n");
}

test "the REPL keeps state across entries" {
    const gpa = testing.allocator;
    var repl = try replInit(gpa);
    defer repl.deinit();

    // Entry 1: a global var and a function that reads it. Chunks must be kept
    // alive because the function value borrows this AST.
    var c1 = try parser.parseRepl(gpa, "var acc: int = 10\n\nfunc add(n: int) -> int:\n    return acc + n");
    defer c1.deinit();
    const o1 = try repl.run(c1.items);
    try testing.expect(o1.runtime_error == null);
    try testing.expectEqualStrings("", o1.output); // definitions print nothing

    // Entry 2: a bare expression prints its value, using both.
    var c2 = try parser.parseRepl(gpa, "add(5)");
    defer c2.deinit();
    const o2 = try repl.run(c2.items);
    try testing.expectEqualStrings("15\n", o2.output);

    // Entry 3: mutate the global; the function sees the new value.
    var c3 = try parser.parseRepl(gpa, "acc = 100\nadd(1)");
    defer c3.deinit();
    const o3 = try repl.run(c3.items);
    try testing.expectEqualStrings("101\n", o3.output);
}

test "a REPL runtime error is reported and state survives" {
    const gpa = testing.allocator;
    var repl = try replInit(gpa);
    defer repl.deinit();

    var c1 = try parser.parseRepl(gpa, "nope()");
    defer c1.deinit();
    const o1 = try repl.run(c1.items);
    try testing.expect(o1.runtime_error != null);

    // The session is still usable afterward.
    var c2 = try parser.parseRepl(gpa, "1 + 2");
    defer c2.deinit();
    const o2 = try repl.run(c2.items);
    try testing.expect(o2.runtime_error == null);
    try testing.expectEqualStrings("3\n", o2.output);
}

test "a subclass reaches and shares inherited statics" {
    const src =
        \\class Base:
        \\    static var n: int = 0
        \\    static func bump():
        \\        n += 1
        \\
        \\class Sub extends Base:
        \\    var x: int = 0
        \\
        \\func main():
        \\    Base.bump()
        \\    Sub.bump()
        \\    print(Sub.n)
        \\    Sub.n = 50
        \\    print(Base.n)
    ;
    try expectOutput(src, "2\n50\n");
}

test "a subclass static method sees an inherited static by bare name" {
    const src =
        \\class Base:
        \\    static var n: int = 0
        \\
        \\class Sub extends Base:
        \\    static func bump() -> int:
        \\        n = n + 1
        \\        return n
        \\
        \\func main():
        \\    print(Sub.bump())
        \\    print(Sub.bump())
        \\    print(Base.n)
    ;
    try expectOutput(src, "1\n2\n2\n");
}

test "static fields are not instance fields" {
    const src =
        \\class Widget:
        \\    var id: int = 7
        \\    static var count: int = 0
        \\
        \\func main():
        \\    print(Widget())
    ;
    try expectOutput(src, "Widget { id: 7 }\n");
}

// --- modules -----------------------------------------------------------------

/// Run a two-module program: `dep_src` bound as `dep_name`, imported by
/// `entry_src` whose `main()` runs.
fn expectProgramOutput(dep_name: []const u8, dep_src: []const u8, entry_src: []const u8, expected: []const u8) !void {
    const gpa = testing.allocator;
    var dep_tree = try parser.parse(gpa, dep_src);
    defer dep_tree.deinit();
    var entry_tree = try parser.parse(gpa, entry_src);
    defer entry_tree.deinit();

    const imports = [_]ModuleImport{.{ .name = dep_name, .module_index = 0 }};
    const modules = [_]ProgramModule{
        .{ .module = dep_tree.module, .imports = &.{} },
        .{ .module = entry_tree.module, .imports = &imports },
    };
    var result = try runProgram(gpa, &modules);
    defer result.deinit();
    try testing.expect(result.runtime_error == null);
    try testing.expectEqualStrings(expected, result.output);
}

test "an imported function closes over its own module's globals" {
    // `bump` references `BASE`, a global of the imported module, not the caller's.
    try expectProgramOutput(
        "mathutil",
        "const BASE: int = 10\n\npub func bump(n: int) -> int:\n    return n + BASE",
        "import mathutil\n\nfunc main():\n    print(mathutil.bump(5))",
        "15\n",
    );
}

test "an exported function may call a module-private sibling" {
    try expectProgramOutput(
        "util",
        "func helper(n: int) -> int:\n    return n * 2\n\npub func doubleUp(n: int) -> int:\n    return helper(n) + helper(n)",
        "import util\n\nfunc main():\n    print(util.doubleUp(3))",
        "12\n",
    );
}

test "an imported type constructs and its methods run in its module" {
    try expectProgramOutput(
        "shapes",
        "pub struct Point:\n    var x: int = 0\n    var y: int = 0\n\n    func sum() -> int:\n        return x + y",
        "import shapes\n\nfunc main():\n    var p = shapes.Point()\n    p.x = 3\n    p.y = 4\n    print(p.sum())",
        "7\n",
    );
}

test "a class inherits from an imported base" {
    // The inherited `label()` runs in its base's module, so it resolves `KIND`
    // there (not in the subclass's module), and reads the inherited `name` field.
    try expectProgramOutput(
        "shapes",
        "pub const KIND: str = \"shape\"\n\npub class Shape:\n    var name: str = \"?\"\n\n    func label() -> str:\n        return name + \" (\" + KIND + \")\"",
        "import shapes\n\nclass Circle extends shapes.Shape:\n    var radius: int = 0\n\nfunc main():\n    var c: Circle = Circle()\n    c.name = \"circle\"\n    print(c.label())",
        "circle (shape)\n",
    );
}

test "reaching an undefined module member is a runtime error" {
    const gpa = testing.allocator;
    var dep_tree = try parser.parse(gpa, "pub func real() -> int:\n    return 1");
    defer dep_tree.deinit();
    var entry_tree = try parser.parse(gpa, "import util\n\nfunc main():\n    print(util.nope())");
    defer entry_tree.deinit();

    const imports = [_]ModuleImport{.{ .name = "util", .module_index = 0 }};
    const modules = [_]ProgramModule{
        .{ .module = dep_tree.module, .imports = &.{} },
        .{ .module = entry_tree.module, .imports = &imports },
    };
    var result = try runProgram(gpa, &modules);
    defer result.deinit();
    try testing.expect(result.runtime_error != null);
    try testing.expect(std.mem.indexOf(u8, result.runtime_error.?.message, "module has no member 'nope'") != null);
}
