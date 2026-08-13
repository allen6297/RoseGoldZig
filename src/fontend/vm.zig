//! A bytecode compiler + stack VM: an alternative execution backend to the
//! tree-walking interpreter, reached via `run --vm`. It covers the core of the
//! language — expressions, control flow, functions (with recursion), locals and
//! globals, lists/maps/ranges, lambdas with by-reference closures (upvalues),
//! string interpolation, and the common builtins — enough to run programs like
//! `fib` and list/loop processing. Constructs it does not compile (classes,
//! modules, signals, `match`, member access, …) are reported as unsupported, so
//! the tree-walker remains the full-featured default.
//!
//! Design: each function compiles to a `Chunk` of opcodes + constants; the VM
//! runs a `Chunk` over a value stack with a frame stack for calls.

const std = @import("std");
const parser = @import("parser.zig");
const lexer = @import("lexer.zig");

const Decl = parser.Decl;
const Stmt = parser.Stmt;
const Expr = parser.Expr;
const BinaryOp = parser.BinaryOp;
const Span = lexer.Span;
const Module = parser.Module;

const Error = std.mem.Allocator.Error || error{Compile};

// --- values ------------------------------------------------------------------

const List = std.ArrayList(Value);
const MapEntry = struct { key: Value, value: Value };
const Map = struct { entries: std.ArrayList(MapEntry) = .empty };

const Builtin = enum {
    print,   echo,  len,   str,   int,   float, range, push, pop, keys, values, has,
    abs,     min,   max,   upper, lower, split, join,  contains, sort, reverse,
    trim,    starts_with, ends_with, find, replace,
};

const builtin_names = [_][]const u8{
    "print", "echo", "len", "str", "int", "float", "range", "push", "pop", "keys", "values", "has",
    "abs",   "min",  "max", "upper", "lower", "split", "join", "contains", "sort", "reverse",
    "trim",  "starts_with", "ends_with", "find", "replace",
};

/// A compile-time upvalue descriptor: `is_local` captures local slot `index` of
/// the immediately-enclosing function; otherwise it captures upvalue `index` of
/// the enclosing function (chaining a capture up multiple levels).
const Upvalue = struct { is_local: bool, index: u8 };

const Function = struct {
    name: []const u8,
    arity: usize,
    chunk: Chunk = .{},
    upvalues: []const Upvalue = &.{},
};

/// A runtime upvalue: while `stack_index` is set it aliases that stack slot
/// (shared by reference); once the slot goes out of scope it is "closed" into
/// `value`.
const UpvalueObj = struct { stack_index: ?usize, value: Value = .nil };

/// A function paired with the upvalues it captured where it was created.
const Closure = struct { func: *const Function, upvalues: []*UpvalueObj };

const Value = union(enum) {
    nil,
    int: i64,
    float: f64,
    bool: bool,
    str: []const u8,
    list: *List,
    map: *Map,
    closure: *Closure,
    builtin: Builtin,
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
        .closure => |x| b == .closure and x == b.closure,
        .builtin => |x| b == .builtin and x == b.builtin,
    };
}

fn valueLess(_: void, a: Value, b: Value) bool {
    if (toFloat(a)) |fa| {
        if (toFloat(b)) |fb| return fa < fb;
    }
    if (a == .str and b == .str) return std.mem.order(u8, a.str, b.str) == .lt;
    return false;
}

// --- bytecode ----------------------------------------------------------------

const Op = enum(u8) {
    constant, // u16 const index
    nil,
    true_,
    false_,
    pop,
    negate,
    not,
    add,
    sub,
    mul,
    div,
    mod,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    get_local, // u8 slot
    set_local, // u8 slot (stores top, keeps it on the stack)
    get_global, // u16 name-const index
    set_global, // u16
    define_global, // u16
    get_upvalue, // u8 index
    set_upvalue, // u8 index (stores top, keeps it on the stack)
    closure, // u16 func-const index -> capture upvalues, push a Closure
    close_upvalue, // close the open upvalue for the top slot, then pop it
    jump, // u16 (absolute target)
    jump_if_false, // u16
    call, // u8 argc
    ret,
    build_list, // u16 count
    build_map, // u16 entry count (2*count values popped)
    interp, // u16 part count -> concat the parts as strings
    make_range, // pop end, start -> list [start, end)
    index_get,
    index_set,
    // Iteration protocol (works over list/map/str), used to compile `for`:
    iter_len, // pop iterable -> int length
    iter_single, // (iterable, i) -> the single-binding value (list/str elem, map key)
    iter_key, // (iterable, i) -> first-of-two (list/str index, map key)
    iter_val, // (iterable, i) -> second-of-two (list/str elem, map value)
};

const Chunk = struct {
    code: std.ArrayList(u8) = .empty,
    lines: std.ArrayList(u32) = .empty,
    constants: std.ArrayList(Value) = .empty,
    /// Nested function prototypes referenced by the `closure` opcode.
    functions: std.ArrayList(*const Function) = .empty,
};

// --- result ------------------------------------------------------------------

pub const RuntimeError = struct { message: []const u8, line: u32, col: u32 };

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    output: []const u8,
    runtime_error: ?RuntimeError,
    diagnostics: []const lexer.Diagnostic,

    pub fn deinit(self: *Result) void {
        self.arena.deinit();
    }
};

/// Compile and run `module` on the VM. Diagnostics is non-empty if a construct
/// could not be compiled; otherwise output/runtime_error report execution.
pub fn run(gpa: std.mem.Allocator, module: Module) Error!Result {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var diagnostics: std.ArrayList(lexer.Diagnostic) = .empty;

    var c = Compiler{ .alloc = alloc, .diagnostics = &diagnostics };
    const program = c.compileModule(module) catch |e| switch (e) {
        error.Compile => {
            return .{ .arena = arena, .output = "", .runtime_error = null, .diagnostics = try diagnostics.toOwnedSlice(alloc) };
        },
        else => return e,
    };
    if (diagnostics.items.len > 0) {
        return .{ .arena = arena, .output = "", .runtime_error = null, .diagnostics = try diagnostics.toOwnedSlice(alloc) };
    }

    var output: std.ArrayList(u8) = .empty;
    var vm = VM{ .alloc = alloc, .output = &output };
    vm.run(program) catch |e| switch (e) {
        error.Runtime => return .{ .arena = arena, .output = try output.toOwnedSlice(alloc), .runtime_error = vm.runtime_error, .diagnostics = &.{} },
        error.OutOfMemory => return error.OutOfMemory,
    };
    return .{ .arena = arena, .output = try output.toOwnedSlice(alloc), .runtime_error = null, .diagnostics = &.{} };
}

const Program = struct { script: *Function };

// --- compiler ----------------------------------------------------------------

const Local = struct { name: []const u8, depth: u32, captured: bool = false };

const Loop = struct {
    /// Local count at loop entry, so `break`/`continue` can pop body locals.
    local_count: usize,
    /// Jumps to patch: to the end (breaks) and to the continue target (continues).
    breaks: std.ArrayList(usize) = .empty,
    continues: std.ArrayList(usize) = .empty,
};

/// Per-function compile state. The `enclosing` chain lets a lambda resolve
/// captures against the functions it is nested in.
const FnState = struct {
    func: *Function,
    locals: std.ArrayList(Local) = .empty,
    scope_depth: u32 = 0,
    /// Compile-time stack height (values above `frame.base`). Reset to the live
    /// local count at each statement and advanced one-per-expression; `match`
    /// reads it to find the absolute slot of its subject temporary.
    stack_top: usize = 0,
    upvalues: std.ArrayList(Upvalue) = .empty,
    loops: std.ArrayList(*Loop) = .empty,
    enclosing: ?*FnState = null,
};

const Compiler = struct {
    alloc: std.mem.Allocator,
    diagnostics: *std.ArrayList(lexer.Diagnostic),
    cur: *FnState = undefined,

    fn chunk(self: *Compiler) *Chunk {
        return &self.cur.func.chunk;
    }

    fn fail(self: *Compiler, span: Span, comptime fmt: []const u8, args: anytype) Error {
        const msg = try std.fmt.allocPrint(self.alloc, fmt, args);
        try self.diagnostics.append(self.alloc, .{ .message = msg, .line = span.line, .col = span.col });
        return error.Compile;
    }

    fn compileModule(self: *Compiler, module: Module) Error!Program {
        // Reject unsupported top-level constructs early with a clear message.
        for (module.decls) |decl| switch (decl) {
            .func, .var_decl => {},
            else => return self.fail(declSpan(decl), "the --vm backend does not support this construct yet; use the default interpreter", .{}),
        };

        // The script runs as a function with no enclosing scope.
        const script = try self.alloc.create(Function);
        script.* = .{ .name = "<script>", .arity = 0 };
        var script_fs = FnState{ .func = script, .enclosing = null };
        self.cur = &script_fs;

        // Compile each top-level function (they capture nothing — no enclosing).
        var funcs: std.StringHashMapUnmanaged(*Function) = .{};
        for (module.decls) |decl| if (decl == .func) {
            const f = try self.compileFunction(decl.func, null);
            try funcs.put(self.alloc, decl.func.name, f);
        };

        // The script body: bind functions/globals, then call main(). Top-level
        // values become globals (not locals), so each starts from a clean stack.
        for (module.decls) |decl| {
            self.cur.stack_top = 0;
            switch (decl) {
                .func => |fd| {
                    try self.emitClosure(funcs.get(fd.name).?, fd.span);
                    try self.defineGlobal(fd.name, fd.span);
                },
                .var_decl => |v| {
                    if (v.value) |val| try self.expr(val.*) else try self.emit(.nil, v.span);
                    try self.defineGlobal(v.name, v.span);
                },
                else => {},
            }
        }
        if (funcs.get("main")) |_| {
            try self.emitGlobal(.get_global, "main", zeroSpan);
            try self.emit(.call, zeroSpan);
            try self.emitByte(0, zeroSpan); // argc
            try self.emit(.pop, zeroSpan);
        }
        try self.emit(.nil, zeroSpan); // the script's return value
        try self.emit(.ret, zeroSpan);

        return .{ .script = script };
    }

    fn compileFunction(self: *Compiler, f: Decl.Func, enclosing: ?*FnState) Error!*Function {
        const func = try self.alloc.create(Function);
        func.* = .{ .name = f.name, .arity = f.params.len };

        var fs = FnState{ .func = func, .enclosing = enclosing };
        const saved = self.cur;
        self.cur = &fs;
        defer self.cur = saved;

        for (f.params) |p| try self.cur.locals.append(self.alloc, .{ .name = p.name, .depth = 0 });
        try self.block(f.body);
        try self.emit(.nil, f.span); // implicit `return nil`
        try self.emit(.ret, f.span);
        func.upvalues = try fs.upvalues.toOwnedSlice(self.alloc);
        return func;
    }

    /// Compile a lambda expression: compile its body to a Function, then emit a
    /// `closure` op that captures its upvalues from the current frame.
    fn compileLambda(self: *Compiler, lam: *const Expr.Lambda) Error!void {
        const func = try self.alloc.create(Function);
        func.* = .{ .name = "<lambda>", .arity = lam.params.len };
        var fs = FnState{ .func = func, .enclosing = self.cur };
        const saved = self.cur;
        self.cur = &fs;
        for (lam.params) |p| try self.cur.locals.append(self.alloc, .{ .name = p.name, .depth = 0 });
        try self.block(lam.body);
        try self.emit(.nil, lam.span);
        try self.emit(.ret, lam.span);
        func.upvalues = try fs.upvalues.toOwnedSlice(self.alloc);
        self.cur = saved;
        try self.emitClosure(func, lam.span);
    }

    /// Compile a `match` expression. The subject is evaluated once into an
    /// anonymous local slot; each arm reads it back for its equality test (or
    /// binds it), and the winning arm's body value replaces it as the result.
    fn compileMatch(self: *Compiler, m: Expr.Match) Error!void {
        // The subject lands at the current stack top; its absolute slot is the
        // stack height captured *before* we push it.
        const subj: usize = self.cur.stack_top;
        try self.expr(m.subject.*);

        // A binding pattern names the subject, so its local slot must equal the
        // subject's stack slot. Pad the locals array up to that index (the pad
        // entries shadow live temporaries below the subject and are never named).
        const orig_len = self.cur.locals.items.len;
        while (self.cur.locals.items.len < subj) {
            try self.cur.locals.append(self.alloc, .{ .name = "$m", .depth = self.cur.scope_depth });
        }
        try self.cur.locals.append(self.alloc, .{ .name = "$match", .depth = self.cur.scope_depth });
        defer self.cur.locals.shrinkRetainingCapacity(orig_len);

        var end_jumps: std.ArrayList(usize) = .empty;
        for (m.arms) |arm| switch (arm.pattern) {
            .wildcard => {
                try self.expr(arm.body.*);
                try end_jumps.append(self.alloc, try self.emitJump(.jump, arm.span));
            },
            .binding => |bd| {
                // The subject *is* the bound value: rename its slot so the body
                // resolves the binding name to it, then restore the name.
                const saved = self.cur.locals.items[subj].name;
                self.cur.locals.items[subj].name = bd.name;
                try self.expr(arm.body.*);
                self.cur.locals.items[subj].name = saved;
                try end_jumps.append(self.alloc, try self.emitJump(.jump, arm.span));
            },
            .enum_case => return self.fail(arm.span, "the --vm backend does not support enum-case match patterns yet", .{}),
            else => {
                try self.emitLocal(.get_local, subj, arm.span);
                try self.patternConst(arm.pattern);
                try self.emit(.eq, arm.span);
                const next = try self.emitJump(.jump_if_false, arm.span);
                try self.expr(arm.body.*);
                try end_jumps.append(self.alloc, try self.emitJump(.jump, arm.span));
                self.patchJump(next);
            },
        };
        // No arm matched -> nil (mirrors the interpreter).
        try self.emit(.nil, m.span);
        for (end_jumps.items) |j| self.patchJump(j);

        // Collapse [subject, result] to just [result] at the subject's slot.
        try self.emitLocal(.set_local, subj, m.span);
        try self.emit(.pop, m.span);
    }

    /// Push a literal pattern's value as a constant (for the arm's `==` test).
    fn patternConst(self: *Compiler, p: parser.Pattern) Error!void {
        switch (p) {
            .int_literal => |lit| {
                const n = std.fmt.parseInt(i64, lit.text, 10) catch return self.fail(lit.span, "invalid integer '{s}'", .{lit.text});
                try self.emitConst(.{ .int = n }, lit.span);
            },
            .float_literal => |lit| {
                const f = std.fmt.parseFloat(f64, lit.text) catch return self.fail(lit.span, "invalid float '{s}'", .{lit.text});
                try self.emitConst(.{ .float = f }, lit.span);
            },
            .string_literal => |lit| try self.emitConst(.{ .str = try self.unquote(lit.text) }, lit.span),
            .bool_literal => |b| try self.emit(if (b.value) .true_ else .false_, b.span),
            else => unreachable,
        }
    }

    /// Resolve `name` as an upvalue of `fs`: a local of the enclosing function
    /// (captured directly), or an upvalue of it (captured transitively). Returns
    /// the upvalue index in `fs`, or null if `name` is not an enclosing local.
    fn resolveUpvalue(self: *Compiler, fs: *FnState, name: []const u8) Error!?u8 {
        const enclosing = fs.enclosing orelse return null;
        if (localSlot(enclosing, name)) |slot| {
            enclosing.locals.items[slot].captured = true;
            return try self.addUpvalue(fs, true, @intCast(slot));
        }
        if (try self.resolveUpvalue(enclosing, name)) |up| {
            return try self.addUpvalue(fs, false, up);
        }
        return null;
    }

    fn addUpvalue(self: *Compiler, fs: *FnState, is_local: bool, index: u8) Error!u8 {
        for (fs.upvalues.items, 0..) |uv, i| {
            if (uv.is_local == is_local and uv.index == index) return @intCast(i);
        }
        try fs.upvalues.append(self.alloc, .{ .is_local = is_local, .index = index });
        return @intCast(fs.upvalues.items.len - 1);
    }

    // --- statements ----------------------------------------------------------

    fn block(self: *Compiler, stmts: []const Stmt) Error!void {
        self.cur.scope_depth += 1;
        for (stmts) |s| try self.stmt(s);
        try self.endScope();
    }

    fn endScope(self: *Compiler) Error!void {
        self.cur.scope_depth -= 1;
        while (self.cur.locals.items.len > 0 and self.cur.locals.items[self.cur.locals.items.len - 1].depth > self.cur.scope_depth) {
            const local = self.cur.locals.pop().?;
            // A captured local is closed (its upvalue takes ownership) then popped.
            try self.emit(if (local.captured) .close_upvalue else .pop, zeroSpan);
        }
    }

    fn stmt(self: *Compiler, s: Stmt) Error!void {
        // Statements begin with a balanced stack: the height is exactly the live
        // local count. (Expressions restore this themselves; see `expr`.)
        self.cur.stack_top = self.cur.locals.items.len;
        switch (s) {
            .pass => {},
            .var_decl => |v| {
                if (v.value) |val| try self.expr(val.*) else try self.emit(.nil, v.span);
                try self.cur.locals.append(self.alloc, .{ .name = v.name, .depth = self.cur.scope_depth });
            },
            .expr_stmt => |e| {
                try self.expr(e.*);
                try self.emit(.pop, parser.exprSpan(e.*));
            },
            .return_stmt => |r| {
                if (r.value) |v| try self.expr(v.*) else try self.emit(.nil, r.span);
                try self.emit(.ret, r.span);
            },
            .assign => |a| try self.assign(a),
            .if_stmt => |x| try self.ifStmt(x),
            .while_stmt => |x| try self.whileStmt(x),
            .for_stmt => |x| try self.forStmt(x),
            .break_stmt => |sp| {
                const loop = self.currentLoop() orelse return self.fail(sp, "'break' outside a loop", .{});
                try self.popLocalsTo(loop.local_count, sp);
                const j = try self.emitJump(.jump, sp);
                try loop.breaks.append(self.alloc, j);
            },
            .continue_stmt => |sp| {
                const loop = self.currentLoop() orelse return self.fail(sp, "'continue' outside a loop", .{});
                try self.popLocalsTo(loop.local_count, sp);
                const j = try self.emitJump(.jump, sp);
                try loop.continues.append(self.alloc, j);
            },
        }
    }

    fn assign(self: *Compiler, a: Stmt.Assign) Error!void {
        switch (a.target.*) {
            .identifier => |id| {
                try self.expr(a.value.*);
                if (self.resolveLocal(id.name)) |slot| {
                    try self.emit(.set_local, a.span);
                    try self.emitByte(@intCast(slot), a.span);
                } else if (try self.resolveUpvalue(self.cur, id.name)) |up| {
                    try self.emit(.set_upvalue, a.span);
                    try self.emitByte(up, a.span);
                } else {
                    try self.emitGlobal(.set_global, id.name, a.span);
                }
                try self.emit(.pop, a.span);
            },
            .index => |idx| {
                try self.expr(idx.object.*);
                try self.expr(idx.index.*);
                try self.expr(a.value.*);
                try self.emit(.index_set, a.span);
            },
            else => return self.fail(a.span, "the --vm backend does not support this assignment target", .{}),
        }
    }

    fn ifStmt(self: *Compiler, x: Stmt.If) Error!void {
        try self.expr(x.cond.*);
        const else_jump = try self.emitJump(.jump_if_false, parser.exprSpan(x.cond.*));
        try self.block(x.then_body);
        const end_jumps = try self.compileElse(x, else_jump);
        for (end_jumps.items) |j| self.patchJump(j);
    }

    /// Compile the elif/else chain; returns the list of jumps that skip to the
    /// end of the whole `if`.
    fn compileElse(self: *Compiler, x: Stmt.If, first_else: usize) Error!std.ArrayList(usize) {
        var end_jumps: std.ArrayList(usize) = .empty;
        const skip = try self.emitJump(.jump, x.span); // after the then-body, skip the rest
        try end_jumps.append(self.alloc, skip);
        self.patchJump(first_else); // a false condition lands at the elif/else chain

        for (x.elifs) |e| {
            try self.expr(e.cond.*);
            const ej = try self.emitJump(.jump_if_false, parser.exprSpan(e.cond.*));
            try self.block(e.body);
            const sj = try self.emitJump(.jump, x.span);
            try end_jumps.append(self.alloc, sj);
            self.patchJump(ej);
        }
        if (x.else_body) |eb| try self.block(eb);
        return end_jumps;
    }

    fn whileStmt(self: *Compiler, x: Stmt.While) Error!void {
        const start = self.here();
        var loop = Loop{ .local_count = self.cur.locals.items.len };
        try self.cur.loops.append(self.alloc, &loop);
        defer _ = self.cur.loops.pop();

        try self.expr(x.cond.*);
        const exit = try self.emitJump(.jump_if_false, parser.exprSpan(x.cond.*));
        try self.block(x.body);
        try self.emitLoopJump(start, x.span);
        self.patchJump(exit);
        for (loop.breaks.items) |j| self.patchJump(j);
        for (loop.continues.items) |j| self.patchJumpTo(j, start); // continue re-checks the condition
    }

    fn forStmt(self: *Compiler, x: Stmt.For) Error!void {
        // Index iteration over any iterable via the iter_* opcodes: hidden locals
        // hold the iterable and the index; the binding(s) are set each round.
        self.cur.scope_depth += 1;
        try self.expr(x.iter.*);
        const it_slot = self.cur.locals.items.len;
        try self.cur.locals.append(self.alloc, .{ .name = "$it", .depth = self.cur.scope_depth });
        try self.emitConst(.{ .int = 0 }, x.span);
        const idx_slot = self.cur.locals.items.len;
        try self.cur.locals.append(self.alloc, .{ .name = "$idx", .depth = self.cur.scope_depth });
        const first_slot = self.cur.locals.items.len;
        try self.cur.locals.append(self.alloc, .{ .name = x.binding, .depth = self.cur.scope_depth });
        try self.emit(.nil, x.span);
        var second_slot: usize = 0;
        if (x.value_binding) |vb| {
            second_slot = self.cur.locals.items.len;
            try self.cur.locals.append(self.alloc, .{ .name = vb, .depth = self.cur.scope_depth });
            try self.emit(.nil, x.span);
        }

        var loop = Loop{ .local_count = self.cur.locals.items.len };
        try self.cur.loops.append(self.alloc, &loop);
        defer _ = self.cur.loops.pop();

        const start = self.here();
        // idx < iter_len(it)
        try self.emitLocal(.get_local, idx_slot, x.span);
        try self.emitLocal(.get_local, it_slot, x.span);
        try self.emit(.iter_len, x.span);
        try self.emit(.lt, x.span);
        const exit = try self.emitJump(.jump_if_false, x.span);
        // bind the loop variable(s)
        if (x.value_binding != null) {
            try self.emitBind(.iter_key, it_slot, idx_slot, first_slot, x.span);
            try self.emitBind(.iter_val, it_slot, idx_slot, second_slot, x.span);
        } else {
            try self.emitBind(.iter_single, it_slot, idx_slot, first_slot, x.span);
        }
        // body
        try self.block(x.body);
        // increment (the continue target)
        const inc = self.here();
        try self.emitLocal(.get_local, idx_slot, x.span);
        try self.emitConst(.{ .int = 1 }, x.span);
        try self.emit(.add, x.span);
        try self.emitLocal(.set_local, idx_slot, x.span);
        try self.emit(.pop, x.span);
        try self.emitLoopJump(start, x.span);
        self.patchJump(exit);
        for (loop.breaks.items) |j| self.patchJump(j);
        for (loop.continues.items) |j| self.patchJumpTo(j, inc);
        try self.endScope(); // pops the binding(s), $idx, $it
    }

    /// Emit `dest = <iter_op>(it, idx)`.
    fn emitBind(self: *Compiler, iter_op: Op, it_slot: usize, idx_slot: usize, dest: usize, span: Span) Error!void {
        try self.emitLocal(.get_local, it_slot, span);
        try self.emitLocal(.get_local, idx_slot, span);
        try self.emit(iter_op, span);
        try self.emitLocal(.set_local, dest, span);
        try self.emit(.pop, span);
    }

    // --- expressions ---------------------------------------------------------

    /// Compile an expression. Every expression nets exactly one value on the
    /// stack, so we snapshot the height on entry and restore `before + 1` on
    /// exit — that keeps `stack_top` an accurate compile-time stack pointer even
    /// across branchy sub-expressions, which `match` needs to locate its subject.
    fn expr(self: *Compiler, e: Expr) Error!void {
        const before = self.cur.stack_top;
        try self.exprInner(e);
        self.cur.stack_top = before + 1;
    }

    fn exprInner(self: *Compiler, e: Expr) Error!void {
        switch (e) {
            .int_literal => |lit| {
                const n = std.fmt.parseInt(i64, lit.text, 10) catch return self.fail(lit.span, "invalid integer '{s}'", .{lit.text});
                try self.emitConst(.{ .int = n }, lit.span);
            },
            .float_literal => |lit| {
                const f = std.fmt.parseFloat(f64, lit.text) catch return self.fail(lit.span, "invalid float '{s}'", .{lit.text});
                try self.emitConst(.{ .float = f }, lit.span);
            },
            .string_literal => |lit| try self.emitConst(.{ .str = try self.unquote(lit.text) }, lit.span),
            .bool_literal => |b| try self.emit(if (b.value) .true_ else .false_, b.span),
            .nil_literal => |sp| try self.emit(.nil, sp),
            .identifier => |id| {
                if (self.resolveLocal(id.name)) |slot| {
                    try self.emitLocal(.get_local, slot, id.span);
                } else if (try self.resolveUpvalue(self.cur, id.name)) |up| {
                    try self.emit(.get_upvalue, id.span);
                    try self.emitByte(up, id.span);
                } else {
                    try self.emitGlobal(.get_global, id.name, id.span);
                }
            },
            .unary => |u| {
                try self.expr(u.operand.*);
                try self.emit(switch (u.op) {
                    .neg => .negate,
                    .not => .not,
                }, u.span);
            },
            .binary => |b| try self.binary(b),
            .call => |c| {
                try self.expr(c.callee.*);
                for (c.args) |arg| try self.expr(arg.*);
                try self.emit(.call, c.span);
                try self.emitByte(@intCast(c.args.len), c.span);
            },
            .index => |idx| {
                try self.expr(idx.object.*);
                try self.expr(idx.index.*);
                try self.emit(.index_get, idx.span);
            },
            .array => |a| {
                for (a.elements) |el| try self.expr(el.*);
                try self.emit(.build_list, a.span);
                try self.emitU16(@intCast(a.elements.len), a.span);
            },
            .map => |m| {
                for (m.entries) |entry| {
                    try self.expr(entry.key.*);
                    try self.expr(entry.value.*);
                }
                try self.emit(.build_map, m.span);
                try self.emitU16(@intCast(m.entries.len), m.span);
            },
            .range => |r| {
                try self.expr(r.start.*);
                try self.expr(r.end.*);
                try self.emit(.make_range, r.span);
            },
            .interpolation => |it| {
                // Push each part (literal run as a constant, hole as its value),
                // then concatenate them all — stringified — into one string.
                for (it.parts) |p| switch (p) {
                    .literal => |lit| try self.emitConst(.{ .str = try self.unescape(lit) }, it.span),
                    .expr => |pe| try self.expr(pe.*),
                };
                try self.emit(.interp, it.span);
                try self.emitU16(@intCast(it.parts.len), it.span);
            },
            .lambda => |lam| try self.compileLambda(lam),
            .match => |m| try self.compileMatch(m),
            else => return self.fail(parser.exprSpan(e), "the --vm backend does not support this expression yet", .{}),
        }
    }

    fn binary(self: *Compiler, b: Expr.Binary) Error!void {
        // Logical operators short-circuit (and pop the left operand on the
        // short-circuit path), so they compile to jumps rather than an opcode.
        if (b.op == .logical_and or b.op == .logical_or) {
            try self.expr(b.lhs.*);
            try self.shortCircuit(b);
            return;
        }
        try self.expr(b.lhs.*);
        try self.expr(b.rhs.*);
        try self.emit(switch (b.op) {
            .add => .add,
            .sub => .sub,
            .mul => .mul,
            .div => .div,
            .mod => .mod,
            .eq => .eq,
            .ne => .ne,
            .lt => .lt,
            .le => .le,
            .gt => .gt,
            .ge => .ge,
            else => unreachable,
        }, b.span);
    }

    /// `a and b` / `a or b` without a DUP opcode: evaluate lhs; on the
    /// short-circuit path push the constant result, otherwise evaluate rhs.
    fn shortCircuit(self: *Compiler, b: Expr.Binary) Error!void {
        // lhs already evaluated by caller.
        if (b.op == .logical_and) {
            const to_false = try self.emitJump(.jump_if_false, b.span); // pops lhs
            try self.expr(b.rhs.*);
            const done = try self.emitJump(.jump, b.span);
            self.patchJump(to_false);
            try self.emit(.false_, b.span);
            self.patchJump(done);
        } else {
            // or: if lhs is false -> rhs ; else -> true
            const to_rhs = try self.emitJump(.jump_if_false, b.span); // pops lhs
            try self.emit(.true_, b.span);
            const done = try self.emitJump(.jump, b.span);
            self.patchJump(to_rhs);
            try self.expr(b.rhs.*);
            self.patchJump(done);
        }
    }

    fn unquote(self: *Compiler, text: []const u8) Error![]const u8 {
        const inner = if (text.len >= 2) text[1 .. text.len - 1] else text;
        return self.unescape(inner);
    }

    /// Resolve escape sequences in `inner` (a string body without quotes); used
    /// for both plain literals and interpolation literal runs.
    fn unescape(self: *Compiler, inner: []const u8) Error![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < inner.len) : (i += 1) {
            if (inner[i] == '\\' and i + 1 < inner.len) {
                i += 1;
                try buf.append(self.alloc, switch (inner[i]) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    '0' => 0,
                    else => inner[i],
                });
            } else try buf.append(self.alloc, inner[i]);
        }
        return buf.toOwnedSlice(self.alloc);
    }

    // --- locals / loops ------------------------------------------------------

    fn resolveLocal(self: *Compiler, name: []const u8) ?usize {
        return localSlot(self.cur, name);
    }

    fn currentLoop(self: *Compiler) ?*Loop {
        if (self.cur.loops.items.len == 0) return null;
        return self.cur.loops.items[self.cur.loops.items.len - 1];
    }

    // --- emit ----------------------------------------------------------------

    fn here(self: *Compiler) usize {
        return self.chunk().code.items.len;
    }

    fn emit(self: *Compiler, op: Op, span: Span) Error!void {
        try self.emitByte(@intFromEnum(op), span);
    }

    fn emitByte(self: *Compiler, byte: u8, span: Span) Error!void {
        try self.chunk().code.append(self.alloc, byte);
        try self.chunk().lines.append(self.alloc, span.line);
    }

    fn emitU16(self: *Compiler, v: u16, span: Span) Error!void {
        try self.emitByte(@intCast(v >> 8), span);
        try self.emitByte(@intCast(v & 0xff), span);
    }

    /// Emit a `closure` op referencing `func` via the current chunk's function
    /// table (the VM captures its upvalues at runtime).
    fn emitClosure(self: *Compiler, func: *const Function, span: Span) Error!void {
        const idx = self.chunk().functions.items.len;
        try self.chunk().functions.append(self.alloc, func);
        try self.emit(.closure, span);
        try self.emitU16(@intCast(idx), span);
    }

    fn emitConst(self: *Compiler, v: Value, span: Span) Error!void {
        const idx = self.chunk().constants.items.len;
        try self.chunk().constants.append(self.alloc, v);
        try self.emit(.constant, span);
        try self.emitU16(@intCast(idx), span);
    }

    fn emitLocal(self: *Compiler, op: Op, slot: usize, span: Span) Error!void {
        try self.emit(op, span);
        try self.emitByte(@intCast(slot), span);
    }

    fn emitGlobal(self: *Compiler, op: Op, name: []const u8, span: Span) Error!void {
        const idx = self.chunk().constants.items.len;
        try self.chunk().constants.append(self.alloc, .{ .str = name });
        try self.emit(op, span);
        try self.emitU16(@intCast(idx), span);
    }

    fn defineGlobal(self: *Compiler, name: []const u8, span: Span) Error!void {
        try self.emitGlobal(.define_global, name, span);
    }

    /// Emit a jump with a placeholder target; returns the operand offset to patch.
    fn emitJump(self: *Compiler, op: Op, span: Span) Error!usize {
        try self.emit(op, span);
        const at = self.here();
        try self.emitU16(0xffff, span);
        return at;
    }

    fn patchJump(self: *Compiler, at: usize) void {
        self.patchJumpTo(at, self.here());
    }

    fn patchJumpTo(self: *Compiler, at: usize, target: usize) void {
        const t: u16 = @intCast(target);
        self.chunk().code.items[at] = @intCast(t >> 8);
        self.chunk().code.items[at + 1] = @intCast(t & 0xff);
    }

    /// Pop each local declared past `count` (for break/continue), closing any
    /// that were captured.
    fn popLocalsTo(self: *Compiler, count: usize, sp: Span) Error!void {
        var n = self.cur.locals.items.len;
        while (n > count) : (n -= 1) {
            try self.emit(if (self.cur.locals.items[n - 1].captured) .close_upvalue else .pop, sp);
        }
    }

    /// Emit an unconditional jump back to `target`.
    fn emitLoopJump(self: *Compiler, target: usize, span: Span) Error!void {
        try self.emit(.jump, span);
        try self.emitU16(@intCast(target), span);
    }
};

const zeroSpan: Span = .{ .start = 0, .end = 0, .line = 0, .col = 0 };

/// The slot of the innermost local named `name` in `fs`, or null.
fn localSlot(fs: *FnState, name: []const u8) ?usize {
    var i = fs.locals.items.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, fs.locals.items[i].name, name)) return i;
    }
    return null;
}

fn declSpan(d: Decl) Span {
    return switch (d) {
        .import => |x| x.span,
        .var_decl => |x| x.span,
        .func => |x| x.span,
        .class => |x| x.span,
        .struct_decl => |x| x.span,
        .enum_decl => |x| x.span,
        .signal => |x| x.span,
    };
}

// --- VM ----------------------------------------------------------------------

const VMError = std.mem.Allocator.Error || error{Runtime};

const Frame = struct { closure: *Closure, ip: usize, base: usize };

const VM = struct {
    alloc: std.mem.Allocator,
    output: *std.ArrayList(u8),
    stack: std.ArrayList(Value) = .empty,
    frames: std.ArrayList(Frame) = .empty,
    globals: std.StringHashMapUnmanaged(Value) = .{},
    open_upvalues: std.ArrayList(*UpvalueObj) = .empty,
    runtime_error: ?RuntimeError = null,

    fn fail(self: *VM, comptime fmt: []const u8, args: anytype) VMError {
        const line = self.currentLine();
        self.runtime_error = .{
            .message = std.fmt.allocPrint(self.alloc, fmt, args) catch "out of memory",
            .line = line,
            .col = 1,
        };
        return error.Runtime;
    }

    fn currentLine(self: *VM) u32 {
        if (self.frames.items.len == 0) return 0;
        const fr = self.frames.items[self.frames.items.len - 1];
        const ip = if (fr.ip > 0) fr.ip - 1 else 0;
        const lines = fr.closure.func.chunk.lines.items;
        if (ip < lines.len) return lines[ip];
        return 0;
    }

    fn run(self: *VM, program: Program) VMError!void {
        // Register builtins as globals.
        inline for (builtin_names, 0..) |name, i| {
            try self.globals.put(self.alloc, name, .{ .builtin = @enumFromInt(i) });
        }
        const script_cl = try self.alloc.create(Closure);
        script_cl.* = .{ .func = program.script, .upvalues = &.{} };
        try self.frames.append(self.alloc, .{ .closure = script_cl, .ip = 0, .base = 0 });
        try self.exec();
    }

    fn push(self: *VM, v: Value) VMError!void {
        try self.stack.append(self.alloc, v);
    }

    fn pop(self: *VM) Value {
        return self.stack.pop().?;
    }

    fn peek(self: *VM, distance: usize) Value {
        return self.stack.items[self.stack.items.len - 1 - distance];
    }

    fn exec(self: *VM) VMError!void {
        var frame = &self.frames.items[self.frames.items.len - 1];
        while (true) {
            const chunk = &frame.closure.func.chunk;
            const op: Op = @enumFromInt(chunk.code.items[frame.ip]);
            frame.ip += 1;
            switch (op) {
                .constant => try self.push(chunk.constants.items[self.readU16(frame)]),
                .nil => try self.push(.nil),
                .true_ => try self.push(.{ .bool = true }),
                .false_ => try self.push(.{ .bool = false }),
                .pop => _ = self.pop(),
                .negate => {
                    const v = self.pop();
                    switch (v) {
                        .int => |n| try self.push(.{ .int = -n }),
                        .float => |f| try self.push(.{ .float = -f }),
                        else => return self.fail("cannot negate {s}", .{@tagName(v)}),
                    }
                },
                .not => try self.push(.{ .bool = !isTruthy(self.pop()) }),
                .add, .sub, .mul, .div, .mod => try self.arith(op),
                .eq => {
                    const b = self.pop();
                    const a = self.pop();
                    try self.push(.{ .bool = valuesEqual(a, b) });
                },
                .ne => {
                    const b = self.pop();
                    const a = self.pop();
                    try self.push(.{ .bool = !valuesEqual(a, b) });
                },
                .lt, .le, .gt, .ge => try self.compare(op),
                .get_local => {
                    const slot = self.readByte(frame);
                    try self.push(self.stack.items[frame.base + slot]);
                },
                .set_local => {
                    const slot = self.readByte(frame);
                    self.stack.items[frame.base + slot] = self.peek(0);
                },
                .get_global => {
                    const name = chunk.constants.items[self.readU16(frame)].str;
                    if (self.globals.get(name)) |v| try self.push(v) else return self.fail("undefined name '{s}'", .{name});
                },
                .set_global => {
                    const name = chunk.constants.items[self.readU16(frame)].str;
                    if (self.globals.getPtr(name)) |slot| slot.* = self.peek(0) else return self.fail("undefined name '{s}'", .{name});
                },
                .define_global => {
                    const name = chunk.constants.items[self.readU16(frame)].str;
                    try self.globals.put(self.alloc, name, self.pop());
                },
                .get_upvalue => {
                    const idx = self.readByte(frame);
                    const up = frame.closure.upvalues[idx];
                    try self.push(if (up.stack_index) |si| self.stack.items[si] else up.value);
                },
                .set_upvalue => {
                    const idx = self.readByte(frame);
                    const up = frame.closure.upvalues[idx];
                    if (up.stack_index) |si| self.stack.items[si] = self.peek(0) else up.value = self.peek(0);
                },
                .closure => {
                    const f = chunk.functions.items[self.readU16(frame)];
                    const cl = try self.alloc.create(Closure);
                    const ups = try self.alloc.alloc(*UpvalueObj, f.upvalues.len);
                    for (f.upvalues, 0..) |uv, i| {
                        ups[i] = if (uv.is_local)
                            try self.captureUpvalue(frame.base + uv.index)
                        else
                            frame.closure.upvalues[uv.index];
                    }
                    cl.* = .{ .func = f, .upvalues = ups };
                    try self.push(.{ .closure = cl });
                },
                .close_upvalue => {
                    self.closeUpvalues(self.stack.items.len - 1);
                    _ = self.pop();
                },
                .jump => frame.ip = self.readU16(frame),
                .jump_if_false => {
                    const target = self.readU16(frame);
                    if (!isTruthy(self.pop())) frame.ip = target;
                },
                .call => {
                    const argc = self.readByte(frame);
                    try self.call(argc);
                    frame = &self.frames.items[self.frames.items.len - 1];
                },
                .ret => {
                    const result = self.pop();
                    const finished = self.frames.pop().?;
                    // Close any upvalues that captured this frame's locals before
                    // they're popped, so escaping closures keep their own copy.
                    self.closeUpvalues(finished.base);
                    if (self.frames.items.len == 0) return; // script returned
                    // Drop the frame's locals AND the callee that sat just below.
                    self.stack.shrinkRetainingCapacity(finished.base - 1);
                    try self.push(result);
                    frame = &self.frames.items[self.frames.items.len - 1];
                },
                .build_list => {
                    const count = self.readU16(frame);
                    const l = try self.alloc.create(List);
                    l.* = .empty;
                    const start = self.stack.items.len - count;
                    try l.appendSlice(self.alloc, self.stack.items[start..]);
                    self.stack.shrinkRetainingCapacity(start);
                    try self.push(.{ .list = l });
                },
                .build_map => {
                    const count = self.readU16(frame);
                    const m = try self.alloc.create(Map);
                    m.* = .{};
                    const start = self.stack.items.len - 2 * count;
                    var i: usize = 0;
                    while (i < count) : (i += 1) try self.mapSet(m, self.stack.items[start + 2 * i], self.stack.items[start + 2 * i + 1]);
                    self.stack.shrinkRetainingCapacity(start);
                    try self.push(.{ .map = m });
                },
                .interp => {
                    const count = self.readU16(frame);
                    const start = self.stack.items.len - count;
                    var buf: std.ArrayList(u8) = .empty;
                    for (self.stack.items[start..]) |part| try self.appendValueTo(&buf, part);
                    self.stack.shrinkRetainingCapacity(start);
                    try self.push(.{ .str = try buf.toOwnedSlice(self.alloc) });
                },
                .make_range => {
                    const end = self.pop();
                    const startv = self.pop();
                    if (startv != .int or end != .int) return self.fail("range bounds must be integers", .{});
                    const l = try self.alloc.create(List);
                    l.* = .empty;
                    var i = startv.int;
                    while (i < end.int) : (i += 1) try l.append(self.alloc, .{ .int = i });
                    try self.push(.{ .list = l });
                },
                .index_get => {
                    const key = self.pop();
                    const container = self.pop();
                    try self.push(try self.indexGet(container, key));
                },
                .index_set => {
                    const value = self.pop();
                    const key = self.pop();
                    const container = self.pop();
                    try self.indexSet(container, key, value);
                },
                .iter_len => {
                    const it = self.pop();
                    try self.push(.{ .int = @intCast(try self.iterLen(it)) });
                },
                .iter_single, .iter_key, .iter_val => {
                    const i = self.pop();
                    const it = self.pop();
                    if (i != .int) return self.fail("iteration index must be an int", .{});
                    try self.push(try self.iterAt(it, @intCast(i.int), op));
                },
            }
        }
    }

    fn readByte(self: *VM, frame: *Frame) u8 {
        _ = self;
        const b = frame.closure.func.chunk.code.items[frame.ip];
        frame.ip += 1;
        return b;
    }

    fn readU16(self: *VM, frame: *Frame) usize {
        const hi = self.readByte(frame);
        const lo = self.readByte(frame);
        return (@as(usize, hi) << 8) | lo;
    }

    fn arith(self: *VM, op: Op) VMError!void {
        const b = self.pop();
        const a = self.pop();
        if (op == .add and a == .str and b == .str) {
            try self.push(.{ .str = try std.mem.concat(self.alloc, u8, &.{ a.str, b.str }) });
            return;
        }
        if (a == .int and b == .int) {
            const x = a.int;
            const y = b.int;
            try self.push(.{ .int = switch (op) {
                .add => x + y,
                .sub => x - y,
                .mul => x * y,
                .div => if (y == 0) return self.fail("division by zero", .{}) else @divTrunc(x, y),
                .mod => if (y == 0) return self.fail("division by zero", .{}) else @rem(x, y),
                else => unreachable,
            } });
            return;
        }
        const x = toFloat(a) orelse return self.fail("cannot apply arithmetic to {s}", .{@tagName(a)});
        const y = toFloat(b) orelse return self.fail("cannot apply arithmetic to {s}", .{@tagName(b)});
        try self.push(.{ .float = switch (op) {
            .add => x + y,
            .sub => x - y,
            .mul => x * y,
            .div => if (y == 0) return self.fail("division by zero", .{}) else x / y,
            .mod => @rem(x, y),
            else => unreachable,
        } });
    }

    fn compare(self: *VM, op: Op) VMError!void {
        const b = self.pop();
        const a = self.pop();
        const x = toFloat(a);
        const y = toFloat(b);
        if (x != null and y != null) {
            try self.push(.{ .bool = switch (op) {
                .lt => x.? < y.?,
                .le => x.? <= y.?,
                .gt => x.? > y.?,
                .ge => x.? >= y.?,
                else => unreachable,
            } });
            return;
        }
        if (a == .str and b == .str) {
            const ord = std.mem.order(u8, a.str, b.str);
            try self.push(.{ .bool = switch (op) {
                .lt => ord == .lt,
                .le => ord != .gt,
                .gt => ord == .gt,
                .ge => ord != .lt,
                else => unreachable,
            } });
            return;
        }
        return self.fail("cannot order {s} and {s}", .{ @tagName(a), @tagName(b) });
    }

    /// Return the open upvalue aliasing `stack_index`, creating (and recording)
    /// one if none exists yet, so all closures over the same slot share it.
    fn captureUpvalue(self: *VM, stack_index: usize) VMError!*UpvalueObj {
        for (self.open_upvalues.items) |up| {
            if (up.stack_index == stack_index) return up;
        }
        const up = try self.alloc.create(UpvalueObj);
        up.* = .{ .stack_index = stack_index };
        try self.open_upvalues.append(self.alloc, up);
        return up;
    }

    /// Close every open upvalue whose slot is at or above `from`: copy the live
    /// stack value into the upvalue and detach it from the stack.
    fn closeUpvalues(self: *VM, from: usize) void {
        var i: usize = 0;
        while (i < self.open_upvalues.items.len) {
            const up = self.open_upvalues.items[i];
            if (up.stack_index) |si| {
                if (si >= from) {
                    up.value = self.stack.items[si];
                    up.stack_index = null;
                    _ = self.open_upvalues.swapRemove(i);
                    continue;
                }
            }
            i += 1;
        }
    }

    fn call(self: *VM, argc: usize) VMError!void {
        const callee = self.peek(argc);
        switch (callee) {
            .closure => |cl| {
                const f = cl.func;
                if (argc != f.arity) return self.fail("{s} expects {d} argument(s), got {d}", .{ f.name, f.arity, argc });
                // The callee sits just below the arguments; use it as slot 0 base.
                const base = self.stack.items.len - argc;
                try self.frames.append(self.alloc, .{ .closure = cl, .ip = 0, .base = base });
            },
            .builtin => |bi| {
                const base = self.stack.items.len - argc;
                const args = self.stack.items[base..];
                const result = try self.callBuiltin(bi, args);
                self.stack.shrinkRetainingCapacity(base - 1); // drop callee + args
                try self.push(result);
            },
            else => return self.fail("{s} is not callable", .{@tagName(callee)}),
        }
    }

    fn callBuiltin(self: *VM, b: Builtin, args: []const Value) VMError!Value {
        switch (b) {
            .print, .echo => {
                for (args, 0..) |arg, i| {
                    if (i > 0) try self.output.append(self.alloc, ' ');
                    try self.appendValue(arg);
                }
                try self.output.append(self.alloc, '\n');
                return .nil;
            },
            .len => {
                if (args.len != 1) return self.fail("len expects 1 argument", .{});
                return switch (args[0]) {
                    .list => |l| .{ .int = @intCast(l.items.len) },
                    .str => |s| .{ .int = @intCast(s.len) },
                    .map => |m| .{ .int = @intCast(m.entries.items.len) },
                    else => self.fail("len expects a list, string, or map", .{}),
                };
            },
            .keys, .values => {
                if (args.len != 1 or args[0] != .map) return self.fail("{s} expects a map", .{@tagName(b)});
                const l = try self.alloc.create(List);
                l.* = .empty;
                for (args[0].map.entries.items) |e| try l.append(self.alloc, if (b == .keys) e.key else e.value);
                return .{ .list = l };
            },
            .has => {
                if (args.len != 2 or args[0] != .map) return self.fail("has expects a map and a key", .{});
                for (args[0].map.entries.items) |e| if (valuesEqual(e.key, args[1])) return .{ .bool = true };
                return .{ .bool = false };
            },
            .str => {
                if (args.len != 1) return self.fail("str expects 1 argument", .{});
                var buf: std.ArrayList(u8) = .empty;
                try self.appendValueTo(&buf, args[0]);
                return .{ .str = try buf.toOwnedSlice(self.alloc) };
            },
            .int => {
                if (args.len != 1) return self.fail("int expects 1 argument", .{});
                return switch (args[0]) {
                    .int => args[0],
                    .float => |f| .{ .int = @intFromFloat(f) },
                    .bool => |bl| .{ .int = if (bl) 1 else 0 },
                    .str => |s| .{ .int = std.fmt.parseInt(i64, std.mem.trim(u8, s, " "), 10) catch return self.fail("cannot convert '{s}' to int", .{s}) },
                    else => self.fail("int expects a number, bool, or string", .{}),
                };
            },
            .float => {
                if (args.len != 1) return self.fail("float expects 1 argument", .{});
                return switch (args[0]) {
                    .float => args[0],
                    .int => |n| .{ .float = @floatFromInt(n) },
                    .str => |s| .{ .float = std.fmt.parseFloat(f64, std.mem.trim(u8, s, " ")) catch return self.fail("cannot convert '{s}' to float", .{s}) },
                    else => self.fail("float expects a number or string", .{}),
                };
            },
            .range => {
                if (args.len != 1 or args[0] != .int) return self.fail("range expects one int", .{});
                const l = try self.alloc.create(List);
                l.* = .empty;
                var i: i64 = 0;
                while (i < args[0].int) : (i += 1) try l.append(self.alloc, .{ .int = i });
                return .{ .list = l };
            },
            .push => {
                if (args.len != 2 or args[0] != .list) return self.fail("push expects a list and a value", .{});
                try args[0].list.append(self.alloc, args[1]);
                return .nil;
            },
            .pop => {
                if (args.len != 1 or args[0] != .list) return self.fail("pop expects a list", .{});
                return args[0].list.pop() orelse self.fail("pop from an empty list", .{});
            },
            .abs => {
                if (args.len != 1) return self.fail("abs expects 1 argument", .{});
                return switch (args[0]) {
                    .int => |n| .{ .int = if (n < 0) -n else n },
                    .float => |f| .{ .float = @abs(f) },
                    else => self.fail("abs expects a number", .{}),
                };
            },
            .min, .max => {
                if (args.len != 2) return self.fail("{s} expects 2 arguments", .{@tagName(b)});
                const a0 = toFloat(args[0]) orelse return self.fail("{s} expects numbers", .{@tagName(b)});
                const a1 = toFloat(args[1]) orelse return self.fail("{s} expects numbers", .{@tagName(b)});
                const first = if (b == .min) a0 <= a1 else a0 >= a1;
                return if (first) args[0] else args[1];
            },
            .upper, .lower => {
                if (args.len != 1 or args[0] != .str) return self.fail("{s} expects a string", .{@tagName(b)});
                const s = args[0].str;
                const out = try self.alloc.alloc(u8, s.len);
                for (s, 0..) |ch, i| out[i] = if (b == .upper) std.ascii.toUpper(ch) else std.ascii.toLower(ch);
                return .{ .str = out };
            },
            .split => {
                if (args.len != 2 or args[0] != .str or args[1] != .str) return self.fail("split expects two strings", .{});
                const l = try self.alloc.create(List);
                l.* = .empty;
                if (args[1].str.len == 0) {
                    var i: usize = 0;
                    while (i < args[0].str.len) : (i += 1) try l.append(self.alloc, .{ .str = args[0].str[i..][0..1] });
                } else {
                    var it = std.mem.splitSequence(u8, args[0].str, args[1].str);
                    while (it.next()) |part| try l.append(self.alloc, .{ .str = part });
                }
                return .{ .list = l };
            },
            .join => {
                if (args.len != 2 or args[0] != .list or args[1] != .str) return self.fail("join expects a list and a string", .{});
                var buf: std.ArrayList(u8) = .empty;
                for (args[0].list.items, 0..) |item, i| {
                    if (i > 0) try buf.appendSlice(self.alloc, args[1].str);
                    try self.appendValueTo(&buf, item);
                }
                return .{ .str = try buf.toOwnedSlice(self.alloc) };
            },
            .contains, .find => {
                if (args.len != 2) return self.fail("{s} expects 2 arguments", .{@tagName(b)});
                var idx: i64 = -1;
                switch (args[0]) {
                    .str => |s| {
                        if (args[1] != .str) return self.fail("{s} on a string expects a string", .{@tagName(b)});
                        if (std.mem.indexOf(u8, s, args[1].str)) |i| idx = @intCast(i);
                    },
                    .list => |l| {
                        for (l.items, 0..) |item, i| if (valuesEqual(item, args[1])) {
                            idx = @intCast(i);
                            break;
                        };
                    },
                    else => return self.fail("{s} expects a string or list", .{@tagName(b)}),
                }
                return if (b == .contains) .{ .bool = idx >= 0 } else .{ .int = idx };
            },
            .sort, .reverse => {
                if (args.len != 1 or args[0] != .list) return self.fail("{s} expects a list", .{@tagName(b)});
                const l = try self.alloc.create(List);
                l.* = .empty;
                try l.appendSlice(self.alloc, args[0].list.items);
                if (b == .sort) std.mem.sort(Value, l.items, {}, valueLess) else std.mem.reverse(Value, l.items);
                return .{ .list = l };
            },
            .trim => {
                if (args.len != 1 or args[0] != .str) return self.fail("trim expects a string", .{});
                return .{ .str = std.mem.trim(u8, args[0].str, " \t\r\n") };
            },
            .starts_with, .ends_with => {
                if (args.len != 2 or args[0] != .str or args[1] != .str) return self.fail("{s} expects two strings", .{@tagName(b)});
                const yes = if (b == .starts_with) std.mem.startsWith(u8, args[0].str, args[1].str) else std.mem.endsWith(u8, args[0].str, args[1].str);
                return .{ .bool = yes };
            },
            .replace => {
                if (args.len != 3 or args[0] != .str or args[1] != .str or args[2] != .str) return self.fail("replace expects three strings", .{});
                if (args[1].str.len == 0) return .{ .str = args[0].str };
                return .{ .str = try std.mem.replaceOwned(u8, self.alloc, args[0].str, args[1].str, args[2].str) };
            },
        }
    }

    fn indexGet(self: *VM, container: Value, key: Value) VMError!Value {
        switch (container) {
            .list => |l| {
                if (key != .int) return self.fail("list index must be an int", .{});
                if (key.int < 0 or key.int >= l.items.len) return self.fail("list index {d} out of range", .{key.int});
                return l.items[@intCast(key.int)];
            },
            .str => |s| {
                if (key != .int) return self.fail("string index must be an int", .{});
                if (key.int < 0 or key.int >= s.len) return self.fail("string index {d} out of range", .{key.int});
                return .{ .str = s[@intCast(key.int)..][0..1] };
            },
            .map => |m| {
                for (m.entries.items) |e| if (valuesEqual(e.key, key)) return e.value;
                return .nil; // a missing key reads as nil
            },
            else => return self.fail("cannot index {s}", .{@tagName(container)}),
        }
    }

    fn indexSet(self: *VM, container: Value, key: Value, value: Value) VMError!void {
        switch (container) {
            .list => |l| {
                if (key != .int) return self.fail("list index must be an int", .{});
                if (key.int < 0 or key.int >= l.items.len) return self.fail("list index {d} out of range", .{key.int});
                l.items[@intCast(key.int)] = value;
            },
            .map => |m| try self.mapSet(m, key, value),
            else => return self.fail("cannot index-assign {s}", .{@tagName(container)}),
        }
    }

    fn mapSet(self: *VM, m: *Map, key: Value, value: Value) VMError!void {
        for (m.entries.items) |*e| {
            if (valuesEqual(e.key, key)) {
                e.value = value;
                return;
            }
        }
        try m.entries.append(self.alloc, .{ .key = key, .value = value });
    }

    fn iterLen(self: *VM, it: Value) VMError!usize {
        return switch (it) {
            .list => |l| l.items.len,
            .str => |s| s.len,
            .map => |m| m.entries.items.len,
            else => self.fail("cannot iterate over {s}", .{@tagName(it)}),
        };
    }

    /// The i-th key or value of an iterable, per the requested iterator opcode.
    fn iterAt(self: *VM, it: Value, i: usize, op: Op) VMError!Value {
        switch (it) {
            .list => |l| return if (op == .iter_key) .{ .int = @intCast(i) } else l.items[i],
            .str => |s| return if (op == .iter_key) .{ .int = @intCast(i) } else .{ .str = s[i..][0..1] },
            .map => |m| return if (op == .iter_val) m.entries.items[i].value else m.entries.items[i].key,
            else => return self.fail("cannot iterate over {s}", .{@tagName(it)}),
        }
    }

    fn appendValue(self: *VM, v: Value) VMError!void {
        try self.appendValueTo(self.output, v);
    }

    fn appendValueTo(self: *VM, buf: *std.ArrayList(u8), v: Value) VMError!void {
        switch (v) {
            .nil => try buf.appendSlice(self.alloc, "nil"),
            .int => |n| try buf.print(self.alloc, "{d}", .{n}),
            .float => |f| try buf.print(self.alloc, "{d}", .{f}),
            .bool => |b| try buf.appendSlice(self.alloc, if (b) "true" else "false"),
            .str => |s| try buf.appendSlice(self.alloc, s),
            .list => |l| {
                try buf.append(self.alloc, '[');
                for (l.items, 0..) |item, i| {
                    if (i > 0) try buf.appendSlice(self.alloc, ", ");
                    try self.appendValueTo(buf, item);
                }
                try buf.append(self.alloc, ']');
            },
            .map => |m| {
                try buf.append(self.alloc, '{');
                for (m.entries.items, 0..) |e, i| {
                    if (i > 0) try buf.appendSlice(self.alloc, ", ");
                    try self.appendValueTo(buf, e.key);
                    try buf.appendSlice(self.alloc, ": ");
                    try self.appendValueTo(buf, e.value);
                }
                try buf.append(self.alloc, '}');
            },
            .closure, .builtin => try buf.appendSlice(self.alloc, "<function>"),
        }
    }
};

// --- tests -------------------------------------------------------------------

const testing = std.testing;

fn runSource(gpa: std.mem.Allocator, src: []const u8) !Result {
    var tree = try parser.parse(gpa, src);
    defer tree.deinit();
    return run(gpa, tree.module);
}

fn expectVMOutput(src: []const u8, expected: []const u8) !void {
    var result = try runSource(testing.allocator, src);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    try testing.expect(result.runtime_error == null);
    try testing.expectEqualStrings(expected, result.output);
}

test "vm: arithmetic and precedence" {
    try expectVMOutput("func main():\n    print(1 + 2 * 3 - 4)", "3\n");
}

test "vm: recursion" {
    const src =
        \\func fib(n: int) -> int:
        \\    if n < 2:
        \\        return n
        \\    return fib(n - 1) + fib(n - 2)
        \\
        \\func main():
        \\    print(fib(10))
    ;
    try expectVMOutput(src, "55\n");
}

test "vm: loops, locals, and lists" {
    const src =
        \\func main():
        \\    var xs = [1, 2, 3, 4]
        \\    var total = 0
        \\    for x in xs:
        \\        total = total + x
        \\    print(total)
        \\    var i = 0
        \\    while i < 3:
        \\        push(xs, i)
        \\        i = i + 1
        \\    print(len(xs))
    ;
    try expectVMOutput(src, "10\n7\n");
}

test "vm: maps, ranges, and generalized for" {
    const src =
        \\func main():
        \\    var total = 0
        \\    for i in 0..5:
        \\        total = total + i
        \\    print("range sum:", total)
        \\    var m = {"a": 1, "b": 2, "c": 3}
        \\    m["d"] = m["a"] + 9
        \\    print("has d?", has(m, "d"), "size", len(m), "d=", m["d"])
        \\    for k, v in m:
        \\        total = total + v
        \\    print("keys:", keys(m), "grand total:", total)
        \\    for i, x in ["x", "y"]:
        \\        print(i, x)
    ;
    try expectVMOutput(src, "range sum: 10\nhas d? true size 4 d= 10\nkeys: [a, b, c, d] grand total: 26\n0 x\n1 y\n");
}

test "vm: stdlib builtins" {
    const src =
        \\func main():
        \\    print(abs(-5), min(3, 7), max(3, 7))
        \\    print(upper("hi"), lower("BYE"))
        \\    print(sort([3, 1, 2]), reverse([1, 2, 3]))
        \\    print(split("a,b,c", ","), join(["x", "y"], "-"))
        \\    print(contains("hello", "ell"), find([10, 20], 20))
        \\    print("[" + trim("  z  ") + "]", starts_with("hello", "he"))
        \\    print(replace("a-b", "-", "+"))
    ;
    try expectVMOutput(src, "5 3 7\nHI bye\n[1, 2, 3] [3, 2, 1]\n[a, b, c] x-y\ntrue 1\n[z] true\na+b\n");
}

test "vm: short-circuit logical operators" {
    try expectVMOutput("func main():\n    print(true and false, false or true, not false)", "false true true\n");
}

test "vm: match with literal, binding, and wildcard patterns" {
    const src =
        \\func describe(n: int) -> str:
        \\    return match n {
        \\        0: "zero"
        \\        1: "one"
        \\        other: "many (${other})"
        \\    }
        \\
        \\func grade(score: int) -> str:
        \\    return match score {
        \\        100: "perfect"
        \\        _: "keep going"
        \\    }
        \\
        \\func main():
        \\    for i in 0..4:
        \\        print(describe(i))
        \\    print(grade(100), grade(50))
    ;
    try expectVMOutput(src, "zero\none\nmany (2)\nmany (3)\nperfect keep going\n");
}

test "vm: match nested mid-expression tracks the subject slot" {
    // The match sits inside a call argument list, so its subject temporary is
    // above the live locals — this exercises the compile-time stack pointer.
    const src =
        \\func main():
        \\    var base = 100
        \\    var k = 2
        \\    print(base, k, match k { 1: "a" 2: "b" n: "n${n}" })
        \\    print(base + match k { 2: 20 _: 0 })
    ;
    try expectVMOutput(src, "100 2 b\n120\n");
}

test "vm: match on strings and bools" {
    const src =
        \\func main():
        \\    var s = "b"
        \\    print(match s { "a": 1 "b": 2 _: 0 })
        \\    print(match true { true: "yes" false: "no" })
    ;
    try expectVMOutput(src, "2\nyes\n");
}

test "vm: string interpolation" {
    const src =
        \\func main():
        \\    var name = "world"
        \\    var n = 3
        \\    print("hi ${name}, ${n} + 1 = ${n + 1}")
        \\    print("list ${[1, 2]} cost \$${n}")
    ;
    try expectVMOutput(src, "hi world, 3 + 1 = 4\nlist [1, 2] cost $3\n");
}

test "vm: a lambda captures a local by reference" {
    const src =
        \\func main():
        \\    var n = 10
        \\    var add = func(x): x + n
        \\    print(add(5))
        \\    n = 100
        \\    print(add(5))
    ;
    try expectVMOutput(src, "15\n105\n");
}

test "vm: a lambda is a first-class higher-order argument" {
    const src =
        \\func apply(f, x):
        \\    return f(x)
        \\
        \\func main():
        \\    print(apply(func(n): n * n, 7))
    ;
    try expectVMOutput(src, "49\n");
}

test "vm: a returned closure keeps its own captured cell" {
    // Each `make_counter()` closes over its own `n`; the upvalue outlives the
    // frame and the two counters stay independent.
    const src =
        \\func make_counter():
        \\    var n = 0
        \\    var step = func():
        \\        n = n + 1
        \\        return n
        \\    return step
        \\
        \\func main():
        \\    var c = make_counter()
        \\    print(c(), c(), c())
        \\    var d = make_counter()
        \\    print(d(), c())
    ;
    try expectVMOutput(src, "1 2 3\n1 4\n");
}

test "vm: nested closures capture transitively" {
    const src =
        \\func adder(x):
        \\    return func(y): func(z): x + y + z
        \\
        \\func main():
        \\    var f = adder(1)
        \\    var g = f(20)
        \\    print(g(300))
    ;
    try expectVMOutput(src, "321\n");
}

test "vm: reports unsupported constructs" {
    var result = try runSource(testing.allocator, "class C:\n    var x: int = 0\n\nfunc main():\n    pass");
    defer result.deinit();
    try testing.expect(result.diagnostics.len > 0);
    try testing.expect(std.mem.indexOf(u8, result.diagnostics[0].message, "does not support") != null);
}

test "vm: runtime error surfaces" {
    var result = try runSource(testing.allocator, "func main():\n    print(1 / 0)");
    defer result.deinit();
    try testing.expect(result.runtime_error != null);
    try testing.expect(std.mem.indexOf(u8, result.runtime_error.?.message, "division by zero") != null);
}
