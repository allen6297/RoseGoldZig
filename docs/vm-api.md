# RoseGold VM — Embedding API Reference

The bytecode VM (`src/fontend/vm.zig`) has two public surfaces:

1. **Whole-program execution** — `run` / `runProgram` / `disassemble`, used by the CLI.
2. **Embedding** — `Session`, host functions, value marshalling, and bytecode
   serialization, for a host program (e.g. the Strata engine) that keeps a VM
   alive, calls script functions repeatedly, and exposes engine functionality to
   scripts.

Both live in the same module and share one `Value` type; the embedding surface is
additive and does not change how the CLI paths behave.

```zig
const vm = @import("fontend/vm.zig");
```

## Conventions

- **Allocators.** Every entry point takes a `gpa: std.mem.Allocator`. Results that
  own memory (`Result`, `Image`, `SerializeResult`, `Session`) hold an arena (or a
  pinned allocation) and expose `deinit`. Call it to free everything at once.
- **Ownership.** Compiled bytecode, runtime values, and error messages produced by
  a call live in the owning object's arena and stay valid until its `deinit`. A
  string you hand *into* the VM (`strValue`, a native's return) is **borrowed** —
  its bytes must outlive the values that reference it.
- **Errors never panic.** A malformed script, a runtime fault, or bad bytecode is
  returned as an error, never a crash or `unreachable`. Runtime errors carry a
  source line/col.
- **`Error`** below is shorthand for `error{ OutOfMemory, Compile }` (the module's
  internal alias). Individual functions list the errors they actually return.

---

## Core types

### `Value`

```zig
pub const Value = union(enum) { nil, int: i64, float: f64, bool: bool, str: []const u8, ... }
```

The VM's runtime value. Embedders treat it as opaque apart from the five scalar
kinds (`nil`/`int`/`float`/`bool`/`str`); everything else (lists, maps, class
instances, closures, enums, …) is passed back into the VM unchanged. Use the
marshalling helpers below rather than constructing non-scalar variants by hand.

### `ValueKind`

```zig
pub const ValueKind = enum { nil, int, float, bool, str, other };
pub fn kindOf(v: Value) ValueKind
```

`kindOf` classifies a `Value` without converting it. `other` covers every
non-scalar variant.

### `RuntimeError`

```zig
pub const RuntimeError = struct { message: []const u8, line: u32, col: u32 };
```

A runtime fault with 1-based source position. Returned via `Result.runtime_error`
or `Session.lastError()`. `message` is arena-owned by the producing object.

### `Diagnostic` (`lexer.Diagnostic`)

```zig
pub const Diagnostic = struct { message: []const u8, line: u32, col: u32 };
```

A compile-time (parse/compile) problem. Returned via `Result.diagnostics`,
`SerializeResult.diagnostics`, and `Session.compileDiagnostics()`.

### `Module`, `ProgramModule`, `ModuleImport`

```zig
pub const ModuleImport  = struct { name: []const u8, module_index: usize };
pub const ProgramModule = struct { module: Module, imports: []const ModuleImport = &.{}, name: []const u8 = "module" };
```

`Module` is a parsed AST (`parser.Module`, from `parser.parse`). A `ProgramModule`
pairs a module with the imports it resolves, by index into the module list. A
single-file program is one `ProgramModule` with no imports; the modules are given
in dependency order with the entry **last**.

---

## Value marshalling

Construct scalars (host → VM):

```zig
pub fn nilValue() Value
pub fn intValue(n: i64) Value
pub fn floatValue(f: f64) Value
pub fn boolValue(b: bool) Value
pub fn strValue(s: []const u8) Value   // borrows s
```

Read scalars back (VM → host); each returns `null` on a kind mismatch:

```zig
pub fn asInt(v: Value) ?i64
pub fn asFloat(v: Value) ?f64          // strict: does not accept an int
pub fn asBool(v: Value) ?bool
pub fn asStr(v: Value) ?[]const u8     // borrowed
```

Accessors are **strict**: `asFloat` returns `null` for an `int`. RoseGold widens
`int` to `float` in the language, so a script may hand back either — check
`kindOf` first and coerce if you want to accept both.

---

## Host functions

```zig
pub const HostError = error{ HostFailure, OutOfMemory };
pub const HostFn = *const fn (ctx: ?*anyopaque, args: []const Value) HostError!Value;
```

A native function callable from RoseGold. `ctx` is the opaque pointer given at
`Session.init`, so the callback can reach engine state. `args` are borrowed for the
duration of the call — do not retain them. Return a `Value`; a returned string must
outlive the call.

- Return `error.HostFailure` to raise a catchable runtime error naming the function.
- `error.OutOfMemory` propagates.
- Register natives with `Session.registerHost` **before** `load`. A native is placed
  into the module globals as an ordinary callable, so a script calls it exactly like
  any function.

```zig
fn hostAdd(ctx: ?*anyopaque, args: []const vm.Value) vm.HostError!vm.Value {
    const engine: *Engine = @ptrCast(@alignCast(ctx.?));
    const a = vm.asInt(args[0]) orelse return error.HostFailure;
    const b = vm.asInt(args[1]) orelse return error.HostFailure;
    return vm.intValue(a + b + engine.base);
}
```

---

## Print routing

```zig
pub const PrintFn = *const fn (ctx: ?*anyopaque, text: []const u8) void;
```

By default `print`/`echo` buffer into the VM's output. An embedder can redirect them
to a callback (one full line per call, trailing newline included) with
`Session.setPrint`.

---

## `Session` — the persistent, embeddable VM

```zig
pub const Session = struct { ... }
```

One `Session` owns one compiled program and **its own module globals — those
globals are the per-instance state and persist across `call`s**. For many scripted
entities the engine creates one `Session` per script instance. A Session is
single-threaded and owns no shared mutable global state.

### Lifecycle

```zig
pub fn init(gpa: std.mem.Allocator, host_ctx: ?*anyopaque) Error!*Session
pub fn deinit(self: *Session) void
```

`init` returns a heap-pinned Session (the VM holds pointers into it) bound to
`host_ctx`. `deinit` frees everything the Session allocated — globals, compiled
functions, and any values produced during calls. Errors: `OutOfMemory`.

### Configuration (before `load`)

```zig
pub fn registerHost(self: *Session, name: []const u8, func: HostFn) Error!void
pub fn setPrint(self: *Session, func: PrintFn, ctx: ?*anyopaque) void
```

`registerHost` makes `func` callable from RoseGold as the global `name`. Must be
called before `load` (natives are injected when modules load). `setPrint` routes
`print`/`echo` to `func`.

### Loading

```zig
pub const LoadError = error{ Compile, Runtime, OutOfMemory };

pub fn load(self: *Session, modules: []const ProgramModule) LoadError!void
pub fn loadModule(self: *Session, module: Module) LoadError!void
pub fn loadImage(self: *Session, image: *const Image) LoadError!void
```

Compile (or, for `loadImage`, take a deserialized program) and run each module's
top-level code **once** to define functions/consts and populate globals — but not
`main`. After this, `resolve`/`call` are ready.

- `load` compiles `modules`; `loadModule` is the single-module convenience.
- `loadImage` skips compilation and loads a `deserialize`d `Image` (the pack-file
  path); the `image` must outlive the Session, and one Image maps to one Session.
- Errors: `Compile` (details via `compileDiagnostics`), `Runtime` (a fault in
  top-level code — details via `lastError`), `OutOfMemory`.

### Calling

```zig
pub const FnHandle = struct { callee: Value, name: []const u8 };
pub const CallError = error{ Runtime, Reentrant, NotCallable, OutOfMemory };

pub fn resolve(self: *Session, name: []const u8) ?FnHandle
pub fn call(self: *Session, handle: FnHandle, args: []const Value) CallError!Value
```

`resolve` turns a top-level function name into a reusable handle (a cheap map
lookup), or `null` if it isn't a defined callable — **resolve once, call many**.
`call` invokes the handle with `args` and returns its result, reusing the persistent
stack (no per-call setup allocation beyond what the script body does).

- `error.Runtime` — the script raised or faulted; see `lastError()` (line/col
  preserved). The Session is reset and remains usable for the next call.
- `error.Reentrant` — a host function tried to call back into the *same* Session
  while it was running; rejected before touching the stack.
- `error.OutOfMemory`.

### Diagnostics

```zig
pub fn lastError(self: *Session) ?RuntimeError
pub fn compileDiagnostics(self: *Session) []const lexer.Diagnostic
```

`lastError` is the runtime error from the most recent `call`/`load` that returned
`error.Runtime`. `compileDiagnostics` holds the diagnostics from a `load` that
returned `error.Compile`. Both are valid until the Session is destroyed.

---

## Bytecode serialization

Compile once, write to bytes, reload later with no source and no compiler.

```zig
pub const SerError = error{ OutOfMemory, Compile, Unserializable };
pub const ImageError = error{ OutOfMemory, BadImage };  // (also Compile in the alias; not returned here)

pub const SerializeResult = struct {
    bytes: []const u8,                       // empty on a compile error
    diagnostics: []const lexer.Diagnostic,   // non-empty on a compile error
    pub fn deinit(self: *SerializeResult) void
};
pub const Image = struct {
    programs: []const Program,
    global_cache_count: usize,
    pub fn deinit(self: *Image) void
};

pub fn serialize(gpa: std.mem.Allocator, modules: []const ProgramModule, entry_runs_main: bool) SerError!SerializeResult
pub fn deserialize(gpa: std.mem.Allocator, bytes: []const u8) ImageError!Image
pub fn runImage(gpa: std.mem.Allocator, image: *const Image) Error!Result
```

- `serialize` compiles `modules` and dumps the compiled program to `bytes`.
  `entry_runs_main` bakes a `main()` call into the entry script (`true` = like `run`;
  `false` = like the embedding `Session`, where you call functions by name). On a
  compile error, `bytes` is empty and `diagnostics` is set.
- `deserialize` reads bytes from `serialize` into a runnable `Image`, copying the
  whole graph into the Image's arena — so `bytes` may be freed afterward. Malformed
  input returns `error.BadImage` (every read is bounds-checked).
- `runImage` runs a deserialized program directly (like `runProgram`, minus
  compilation); or embed it with `Session.loadImage`.

**Run an `Image` once.** Running populates the image's module globals with that
run's state, so use one Image per run/Session; `deserialize` again for another
instance. (Sharing one Image across many Sessions is a known limitation.) Only the
structural graph is serialized; module globals, signal handlers, and static-var
values are rebuilt by running the top-level script.

---

## Whole-program execution (CLI-level)

```zig
pub const Result = struct {
    output: []const u8,
    runtime_error: ?RuntimeError,
    diagnostics: []const lexer.Diagnostic,
    pub fn deinit(self: *Result) void
};

pub fn run(gpa: std.mem.Allocator, module: Module) Error!Result
pub fn runProgram(gpa: std.mem.Allocator, modules: []const ProgramModule) Error!Result
```

Compile and execute to completion (calling `main`), capturing printed text in
`Result.output`. `run` is the single-module convenience; `runProgram` takes a
dependency-ordered module set. A compile error yields empty `output` with
`diagnostics` set; a runtime fault sets `runtime_error`.

```zig
pub const DisasmResult = struct {
    text: []const u8,
    diagnostics: []const lexer.Diagnostic,
    pub fn deinit(self: *DisasmResult) void
};
pub fn disassemble(gpa: std.mem.Allocator, modules: []const ProgramModule) Error!DisasmResult
```

Compile the modules and return a human-readable bytecode listing instead of running
them (backs `run --disasm`).

---

## Threading & memory model

- **One `Session`/`Image` per thread.** A Session is single-threaded with no shared
  mutable global state; run one per world/thread.
- **Re-entrancy is rejected.** A host function calling back into the same Session
  returns `error.Reentrant` rather than corrupting the shared stack.
- **No garbage collection.** Values allocated during a call live in the Session's
  arena until `deinit`. For a per-frame loop, keep host functions returning scalars
  and avoid unbounded collection growth. Destroy and recreate the Session to reclaim.
- **`check` and host names.** The analyzer doesn't know host-registered names, so
  running `check` on a script that calls them reports them as undefined; the VM
  resolves them at run time.

---

## End-to-end example (engine-style)

```zig
const vm = @import("fontend/vm.zig");
const parser = @import("fontend/parser.zig");

const Engine = struct { base: i64 };

fn hostAdd(ctx: ?*anyopaque, args: []const vm.Value) vm.HostError!vm.Value {
    const e: *Engine = @ptrCast(@alignCast(ctx.?));
    const a = vm.asInt(args[0]) orelse return error.HostFailure;
    const b = vm.asInt(args[1]) orelse return error.HostFailure;
    return vm.intValue(a + b + e.base);
}

pub fn attach(gpa: std.mem.Allocator, engine: *Engine, source: []const u8) !void {
    var tree = try parser.parse(gpa, source);
    defer tree.deinit();

    const session = try vm.Session.init(gpa, engine);
    defer session.deinit();

    try session.registerHost("host_add", hostAdd);   // before load
    try session.loadModule(tree.module);             // compile once; run top-level defs

    const update = session.resolve("update") orelse return error.NoUpdate;
    var frame: i64 = 0;
    while (frame < 3) : (frame += 1) {               // resolve once, call many
        const r = session.call(update, &.{ vm.intValue(frame) }) catch |err| switch (err) {
            error.Runtime => {
                const e = session.lastError().?;
                std.log.err("script error at {d}:{d}: {s}", .{ e.line, e.col, e.message });
                return err;
            },
            else => return err,
        };
        _ = vm.asInt(r);
    }
}
```

For the packed-bytecode path, replace `loadModule` with:

```zig
var ser = try vm.serialize(gpa, &.{.{ .module = tree.module }}, false);
defer ser.deinit();
// ... write ser.bytes to a pack file; later, on load:
var image = try vm.deserialize(gpa, bytes);
defer image.deinit();
try session.loadImage(&image);
```

---

See also: the **Embedding the VM** section in [`../README.md`](../README.md) for a
narrative overview, and [`../CLAUDE.md`](../CLAUDE.md) for implementation notes.
