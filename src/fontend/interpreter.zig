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
//! Execution starts by binding the module's globals (functions and evaluated
//! `const`/`var`), then calling `main()` if it exists. Program output is
//! collected into a buffer rather than written directly, so it is easy to test.
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

// --- values ------------------------------------------------------------------

const List = std.ArrayList(Value);

const MapEntry = struct { key: Value, value: Value };
const Map = struct { entries: std.ArrayList(MapEntry) = .empty };

const Builtin = enum { print, echo, len, range };

/// A field declared on a class/struct, with its default-value expression.
const FieldDef = struct { name: []const u8, value: ?*const Expr };

/// The runtime shape of a class or struct: its own fields and methods, its
/// declared supertypes, and (computed once) the transitive ancestors and full
/// inherited field list.
const TypeInfo = struct {
    name: []const u8,
    own_fields: []const FieldDef,
    methods: std.StringHashMapUnmanaged(*const Decl.Func) = .{},
    super_names: []const []const u8 = &.{},
    /// Transitive supertypes, most-derived first (used for method resolution).
    ancestors: []const *const TypeInfo = &.{},
    /// This type's fields plus inherited ones, base classes first (used for
    /// construction and printing).
    all_fields: []const FieldDef = &.{},
};

/// A live class/struct instance.
const Instance = struct {
    info: *const TypeInfo,
    fields: std.StringHashMapUnmanaged(Value) = .{},
};

/// A method paired with the instance it was accessed on.
const BoundMethod = struct { receiver: *Instance, func: *const Decl.Func };

/// An enum type: its name and the set of member names it declares.
const EnumType = struct {
    name: []const u8,
    members: std.StringHashMapUnmanaged(void) = .{},
};

/// A single enum case, e.g. `Status.OK`.
const EnumValue = struct { type_name: []const u8, member: []const u8 };

pub const Value = union(enum) {
    nil,
    int: i64,
    float: f64,
    bool: bool,
    str: []const u8,
    list: *List,
    map: *Map,
    func: *const Decl.Func,
    builtin: Builtin,
    instance: *Instance,
    bound_method: *BoundMethod,
    type_ref: *const TypeInfo,
    enum_type: *const EnumType,
    enum_value: *const EnumValue,
};

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
        .type_ref => |x| b == .type_ref and x == b.type_ref,
        .enum_type => |x| b == .enum_type and x == b.enum_type,
        .enum_value => |x| b == .enum_value and
            std.mem.eql(u8, x.type_name, b.enum_value.type_name) and
            std.mem.eql(u8, x.member, b.enum_value.member),
    };
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

pub fn run(gpa: std.mem.Allocator, module: Module) Error!RunResult {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    const globals = try alloc.create(Env);
    globals.* = .{ .parent = null };

    var output: std.ArrayList(u8) = .empty;

    var interp = Interpreter{
        .arena = alloc,
        .globals = globals,
        .env = globals,
        .output = &output,
    };

    interp.execute(module) catch |e| switch (e) {
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

// --- interpreter -------------------------------------------------------------

const Flow = enum { normal, returned };

const Interpreter = struct {
    arena: std.mem.Allocator,
    globals: *Env,
    env: *Env,
    output: *std.ArrayList(u8),
    ret_value: Value = .nil,
    runtime_error: ?RuntimeError = null,
    /// The instance whose method is currently executing, so bare `field` names
    /// inside a method resolve to (and assign to) that instance.
    current_receiver: ?*Instance = null,
    /// Every class/struct by name, so supertypes can be resolved.
    types: std.StringHashMapUnmanaged(*TypeInfo) = .{},

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
            if (self.findMethod(recv.info, name)) |func| {
                const bm = try self.arena.create(BoundMethod);
                bm.* = .{ .receiver = recv, .func = func };
                return .{ .bound_method = bm };
            }
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
        for (members, 0..) |m, j| switch (m) {
            .var_decl => |v| try fields.append(self.arena, .{ .name = v.name, .value = v.value }),
            .func => try methods.put(self.arena, members[j].func.name, &members[j].func),
            else => {},
        };
        var supers: std.ArrayList([]const u8) = .empty;
        if (extends) |b| try supers.append(self.arena, b.name);
        for (uses) |t| try supers.append(self.arena, t.name);

        const own_fields = try fields.toOwnedSlice(self.arena);
        const ti = try self.arena.create(TypeInfo);
        ti.* = .{
            .name = name,
            .own_fields = own_fields,
            .methods = methods,
            .super_names = try supers.toOwnedSlice(self.arena),
            .all_fields = own_fields, // recomputed with inheritance in computeInheritance
        };
        try self.types.put(self.arena, name, ti);
        try self.define(self.globals, name, .{ .type_ref = ti });
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
    }

    /// Look up a method on `ti` or any of its ancestors (most-derived wins).
    fn findMethod(self: *Interpreter, ti: *const TypeInfo, name: []const u8) ?*const Decl.Func {
        _ = self;
        if (ti.methods.get(name)) |m| return m;
        for (ti.ancestors) |a| {
            if (a.methods.get(name)) |m| return m;
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
        const inst = try self.arena.create(Instance);
        inst.* = .{ .info = ti };

        // Evaluate field defaults with the fresh instance as the receiver, so a
        // later field may reference an earlier one.
        const saved_env = self.env;
        const saved_recv = self.current_receiver;
        self.env = self.globals;
        self.current_receiver = inst;
        for (ti.all_fields) |f| {
            const v = if (f.value) |val| try self.eval(val.*) else Value.nil;
            try inst.fields.put(self.arena, f.name, v);
        }
        self.env = saved_env;
        self.current_receiver = saved_recv;

        // A method named `init` (inherited or own) acts as the constructor.
        if (self.findMethod(ti, "init")) |init_fn| {
            _ = try self.callMethod(init_fn, inst, args, span);
        } else if (args.len != 0) {
            return self.fail(span, "{s} takes no constructor arguments", .{ti.name});
        }
        return .{ .instance = inst };
    }

    // --- top level -----------------------------------------------------------

    fn execute(self: *Interpreter, module: Module) Error!void {
        try self.registerBuiltins();

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
            .func => try self.define(self.globals, decl.func.name, .{ .func = &module.decls[i].func }),
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
        // Run main() if present.
        if (self.globals.vars.get("main")) |m| {
            if (m == .func) _ = try self.callFunction(m.func, &.{}, zero_span);
        }
    }

    fn registerBuiltins(self: *Interpreter) Error!void {
        try self.define(self.globals, "print", .{ .builtin = .print });
        try self.define(self.globals, "echo", .{ .builtin = .echo });
        try self.define(self.globals, "len", .{ .builtin = .len });
        try self.define(self.globals, "range", .{ .builtin = .range });
    }

    // --- statements ----------------------------------------------------------

    fn execBlock(self: *Interpreter, stmts: []const Stmt) Error!Flow {
        for (stmts) |s| {
            if (try self.execStmt(s) == .returned) return .returned;
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

    fn execStmt(self: *Interpreter, stmt: Stmt) Error!Flow {
        switch (stmt) {
            .pass => {},
            .expr_stmt => |e| _ = try self.eval(e.*),
            .var_decl => |x| {
                const v = if (x.value) |val| try self.eval(val.*) else Value.nil;
                try self.define(self.env, x.name, v);
            },
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
                    if (try self.execChildBlock(x.body) == .returned) return .returned;
                }
            },
            .for_stmt => |x| return self.execFor(x),
        }
        return .normal;
    }

    fn execFor(self: *Interpreter, x: Stmt.For) Error!Flow {
        const iter = try self.eval(x.iter.*);
        // Iterate a list's elements, a string's characters, or a map's keys.
        const items: []const Value = switch (iter) {
            .list => |l| l.items,
            .str => |s| blk: {
                const chars = try self.arena.alloc(Value, s.len);
                for (0..s.len) |i| chars[i] = .{ .str = s[i .. i + 1] };
                break :blk chars;
            },
            .map => |m| blk: {
                const keys = try self.arena.alloc(Value, m.entries.items.len);
                for (m.entries.items, 0..) |entry, i| keys[i] = entry.key;
                break :blk keys;
            },
            else => return self.fail(x.span, "cannot iterate over {s}", .{@tagName(iter)}),
        };
        for (items) |item| {
            const child = try self.newEnv(self.env);
            const saved = self.env;
            self.env = child;
            try self.define(child, x.binding, item);
            const flow = self.execBlock(x.body);
            self.env = saved;
            if (try flow == .returned) return .returned;
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

    fn callFunction(self: *Interpreter, func: *const Decl.Func, args: []const Value, span: Span) Error!Value {
        if (args.len != func.params.len) {
            return self.fail(span, "{s} expects {d} argument(s), got {d}", .{ func.name, func.params.len, args.len });
        }
        const call_env = try self.newEnv(self.globals);
        for (func.params, args) |p, arg| try self.define(call_env, p.name, arg);

        const saved_env = self.env;
        const saved_ret = self.ret_value;
        self.env = call_env;
        self.ret_value = .nil;
        defer {
            self.env = saved_env;
            self.ret_value = saved_ret;
        }
        const flow = try self.execBlock(func.body);
        return if (flow == .returned) self.ret_value else Value.nil;
    }

    fn callMethod(self: *Interpreter, func: *const Decl.Func, receiver: *Instance, args: []const Value, span: Span) Error!Value {
        if (args.len != func.params.len) {
            return self.fail(span, "{s} expects {d} argument(s), got {d}", .{ func.name, func.params.len, args.len });
        }
        const call_env = try self.newEnv(self.globals);
        for (func.params, args) |p, arg| try self.define(call_env, p.name, arg);

        const saved_env = self.env;
        const saved_ret = self.ret_value;
        const saved_recv = self.current_receiver;
        self.env = call_env;
        self.ret_value = .nil;
        self.current_receiver = receiver;
        defer {
            self.env = saved_env;
            self.ret_value = saved_ret;
            self.current_receiver = saved_recv;
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
        }
    }

    // --- expressions ---------------------------------------------------------

    fn eval(self: *Interpreter, e: Expr) Error!Value {
        return switch (e) {
            .int_literal => |lit| .{ .int = std.fmt.parseInt(i64, lit.text, 10) catch return self.fail(lit.span, "invalid integer '{s}'", .{lit.text}) },
            .float_literal => |lit| .{ .float = std.fmt.parseFloat(f64, lit.text) catch return self.fail(lit.span, "invalid float '{s}'", .{lit.text}) },
            .string_literal => |lit| .{ .str = try self.unquote(lit.text) },
            .bool_literal => |b| .{ .bool = b.value },
            .identifier => |id| try self.resolveName(id.name, id.span),
            .unary => |u| try self.evalUnary(u),
            .binary => |b| try self.evalBinary(b),
            .call => |c| try self.evalCall(c),
            .index => |idx| try self.evalIndex(idx),
            .array => |a| try self.evalArray(a),
            .map => |m| try self.evalMap(m),
            .match => |m| try self.evalMatch(m),
            .member => |m| try self.evalMember(m),
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
        const args = try self.arena.alloc(Value, c.args.len);
        for (c.args, 0..) |arg, i| args[i] = try self.eval(arg.*);
        return switch (callee) {
            .func => |f| try self.callFunction(f, args, c.span),
            .builtin => |b| try self.callBuiltin(b, args, c.span),
            .bound_method => |bm| try self.callMethod(bm.func, bm.receiver, args, c.span),
            .type_ref => |ti| try self.construct(ti, args, c.span),
            else => self.fail(c.span, "{s} is not callable", .{@tagName(callee)}),
        };
    }

    fn evalMember(self: *Interpreter, m: Expr.MemberAccess) Error!Value {
        const obj = try self.eval(m.object.*);
        switch (obj) {
            .instance => |inst| {
                if (inst.fields.get(m.name)) |v| return v;
                if (self.findMethod(inst.info, m.name)) |func| {
                    const bm = try self.arena.create(BoundMethod);
                    bm.* = .{ .receiver = inst, .func = func };
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
            .int_literal => |lit| .{ .int = std.fmt.parseInt(i64, lit.text, 10) catch return self.fail(lit.span, "invalid integer '{s}'", .{lit.text}) },
            .float_literal => |lit| .{ .float = std.fmt.parseFloat(f64, lit.text) catch return self.fail(lit.span, "invalid float '{s}'", .{lit.text}) },
            .string_literal => |lit| .{ .str = try self.unquote(lit.text) },
            .bool_literal => |b| .{ .bool = b.value },
            else => .nil,
        };
    }

    // --- helpers -------------------------------------------------------------

    /// Strip the surrounding quotes from a string literal and resolve escapes.
    fn unquote(self: *Interpreter, text: []const u8) Error![]const u8 {
        const inner = if (text.len >= 2) text[1 .. text.len - 1] else text;
        var buf: std.ArrayList(u8) = .empty;
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
        return buf.toOwnedSlice(self.arena);
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
            .func, .builtin, .bound_method => try buf.appendSlice(self.arena, "<function>"),
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
