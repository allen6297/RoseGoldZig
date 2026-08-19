# RoseGold

A small, statically-typed, indentation-based programming language with **two
execution backends** — a tree-walking interpreter and a bytecode VM — implemented
from scratch in **Zig 0.16**. The whole toolchain is a complete front end (lexer,
parser, module loader, type checker) plus two byte-identical evaluators, a REPL,
a code formatter, and a bytecode disassembler.

```rosegold
enum Suit { HEARTS, SPADES, CLUBS, DIAMONDS }

struct Card:
    var rank: int = 0
    var suit: Suit = Suit.HEARTS

    func name() -> str:
        return match rank {
            1: "Ace"
            11: "Jack"
            12: "Queen"
            13: "King"
            _: "pip"
        }

func main():
    var c = Card()
    c.rank = 12
    c.suit = Suit.SPADES
    print("${c.name()} of ${c.suit}")     ## Queen of Suit.SPADES
```

## Build & run

Requires Zig 0.16.

```bash
zig build                              # build the CLI → zig-out/bin/RoseGold_Zig
zig build run -- run FILE.rg           # run on the tree-walker (default)
zig build run -- run --vm FILE.rg      # run on the bytecode VM instead
zig build run -- run --disasm FILE.rg  # print the compiled VM bytecode, don't run
zig build run -- check FILE.rg         # type-check only, report problems
zig build run -- fmt FILE.rg           # print in canonical style (-w rewrites in place)
zig build run -- repl                  # interactive session (also the default with no file)
zig build test                         # run the test suite
```

Program output goes to stdout; diagnostics (with a source line and a caret) go to
stderr, and the process exits non-zero on any error.

## A tour of the language

### Values, variables, functions

```rosegold
const PI: float = 3.14159        ## const or var; the type annotation is optional
var count = 0                    ## inferred as int

func area(r: int) -> float:      ## params may be untyped (→ any); return type optional
    return PI * r * r

func scale(x: int, by: int = 2) -> int:   ## trailing params may have default values
    return x * by

func main():
    print(area(2))               ## 12.56636
    print(scale(5))              ## 10 (by defaults to 2)
    print(scale(5, 3))           ## 15
```

Types: `int`, `float` (`int` widens to `float`), `str`, `bool`, `void`, `any`,
`list<T>`, `map<K, V>`, tuples `(A, B)`, optionals `?T`, and your own
classes/structs/enums. Strings interpolate with `"a ${expr} b"`.

### Control flow

```rosegold
func classify(n: int) -> str:
    if n < 0:
        return "negative"
    elif n == 0:
        return "zero"
    else:
        return "positive"

func main():
    for i in range(5):           ## 0 1 2 3 4
        print(i)
    for i, x in ["a", "b"]:      ## index + element
        print(i, x)
    var total = 0
    for n in 1..4:               ## a range: the ints 1, 2, 3
        total += n
    print(total)                 ## 6
```

`match` dispatches on literals, `_`, a binding name, or an enum case, and is
checked for exhaustiveness:

```rosegold
enum Status { OK, NOT_FOUND }

func label(s: Status) -> str:
    return match s {
        Status.OK: "ok"
        Status.NOT_FOUND: "missing"
    }
```

### Collections, tuples, and destructuring

```rosegold
func minmax(xs: list<int>) -> (int, int):
    var lo = xs[0]
    var hi = xs[0]
    for x in xs:
        if x < lo:
            lo = x
        if x > hi:
            hi = x
    return (lo, hi)

func main():
    var lo, hi = minmax([3, 7, 1, 9])    ## destructure a returned tuple
    print(lo, hi)                        ## 1 9
    var m = {"a": 1, "b": 2}
    print(has(m, "a"), keys(m))          ## true [a, b]
```

### Classes, structs, inheritance, statics

```rosegold
class Shape:
    var name: str = "shape"
    func area() -> float:
        return 0.0
    func describe() -> str:
        return "${name}: ${area()}"      ## bare names resolve to fields/methods

class Circle extends Shape:
    var r: float = 1.0
    static var made: int = 0
    func init(radius: float):            ## a method named init is the constructor
        r = radius
        name = "circle"
        Circle.made = Circle.made + 1
    func area() -> float:                ## overrides Shape.area (virtual dispatch)
        return 3.14 * r * r

func main():
    var c = Circle(2.0)
    print(c.describe())                  ## circle: 12.56
    print(Circle.made)                   ## 1
```

`struct` is a class without inheritance. `class` supports single inheritance
(`extends`) and mixins (`uses`); an inherited method still resolves names in the
module that defined it, and dispatch goes through the receiver's runtime type.

### Closures, higher-order functions

```rosegold
func adder(x: int):
    return func(y): x + y                ## a closure capturing x

func main():
    var add10 = adder(10)
    print(add10(5))                      ## 15
    var nums = [1, 2, 3, 4]
    print(map(nums, func(n): n * n))     ## [1, 4, 9, 16]
    print(filter(nums, func(n): n % 2 == 0))  ## [2, 4]
    print(reduce(nums, func(a, x): a + x, 0))  ## 10
```

### Signals (events)

```rosegold
class Button:
    signal pressed(who)
    func press(who):
        emit(pressed, who)

func main():
    var b = Button()
    connect(b.pressed, func(who): print("clicked by", who))
    b.press("alice")                     ## clicked by alice
```

### Error handling

```rosegold
func checked_div(a: int, b: int) -> int:
    if b == 0:
        raise "division by zero"
    return a / b

func main():
    try:
        print(checked_div(10, 0))
    catch e:
        print("caught:", e)              ## caught: division by zero
```

Built-in runtime errors (out-of-range index, etc.) are catchable too — the caught
value is the error message string.

### Optionals

```rosegold
func first(xs: list<int>) -> ?int:
    if len(xs) > 0:
        return xs[0]
    return nil

func main():
    var v = first([])
    if v != nil:                         ## narrows ?int to int
        print(v)
    else:
        print("empty")
```

### Modules

A module is a `.rg` file. `import mathutil` loads `mathutil.rg` (relative to the
importer) and binds `mathutil` as a namespace; only `pub` declarations are visible
across the boundary.

```rosegold
## mathutil.rg
pub const PI: float = 3.14159
pub func square(n: int) -> int:
    return n * n

## app.rg
import mathutil
func main():
    print(mathutil.PI, mathutil.square(6))
```

Functions, consts, types, enums, signals, and even class inheritance all work
across module boundaries; an imported function resolves *its own* module's names,
so it can use its private helpers.

## Two backends

Both backends produce **byte-identical output**. The default is the tree-walking
interpreter; `--vm` runs a bytecode compiler + stack VM that covers the entire
language and runs compute-heavy code ~3–4× faster (see [`bench/`](bench/)):

```bash
zig build run -- run       examples/primes.rg   # tree-walker
zig build run -- run --vm  examples/primes.rg   # bytecode VM — same output, faster
```

`run --disasm FILE.rg` prints the compiled bytecode for every function, which is a
nice way to see how the language lowers:

```
== fib ==
0000  get_local 0
0002  constant 2
0005  lt
0006  jump_if_false -> 15
...
```

## Embedding the VM

Besides the CLI, the bytecode VM exposes a small **embedding API** (`vm.zig`) for a
host program — a game engine, say — that wants to keep a VM alive, register native
functions, and call script functions every frame. It's a second surface layered on
the same compiler; the CLI/LSP/DAP paths are untouched. Full signature-level
reference: [`docs/vm-api.md`](docs/vm-api.md).

```zig
const vm = @import("fontend/vm.zig");

// A native the script can call. `ctx` is the pointer you gave at init, so the
// callback can reach engine state; args/return use the VM's Value.
fn hostAdd(ctx: ?*anyopaque, args: []const vm.Value) vm.HostError!vm.Value {
    const engine: *Engine = @ptrCast(@alignCast(ctx.?));
    const a = vm.asInt(args[0]) orelse return error.HostFailure;
    const b = vm.asInt(args[1]) orelse return error.HostFailure;
    return vm.intValue(a + b + engine.base);
}

var session = try vm.Session.init(gpa, engine);   // VM kept alive; `engine` is the ctx
defer session.deinit();

try session.registerHost("host_add", hostAdd);    // register before loading
try session.loadModule(tree.module);              // compile once; runs top-level defs

const update = session.resolve("update").?;       // resolve a function once…
var frame: i64 = 0;
while (frame < 3) : (frame += 1) {                 // …call it many times
    const r = try session.call(update, &.{ vm.intValue(frame) });
    _ = vm.asInt(r);                               // marshal the result back out
}
```

- **Lifetime.** A `Session` owns one compiled program plus **its own module globals,
  and those globals are the per-instance state** — a script's top-level `var`s persist
  across `call`s. `init` compiles nothing; `loadModule`/`load` compiles the module(s)
  **once** and runs their top-level code to define functions and populate globals (but
  not `main`); `resolve` turns a name into a reusable handle (resolve once, call many —
  no per-call name lookup); `deinit` frees everything. For many scripted entities the
  engine creates **one `Session` per script instance** — each is cheap (a small stack +
  that instance's globals). *(One VM per instance, rather than one VM juggling swapped
  environments: it keeps state isolation trivial and adds no hidden shared state.)*
- **Host functions.** `registerHost(name, fn)` makes `fn` callable from RoseGold as an
  ordinary global. Under the hood a native is just another callable `Value`, so
  `host_add(a, b)` compiles to the same `get_global` + `call` as any function and rides
  the existing inline cache — no separate dispatch path. Register before `load`.
  **`registerFn` (below) is usually the better call** — it takes a plain Zig function
  and writes the unpacking for you.
- **Value marshalling.** `intValue`/`floatValue`/`boolValue`/`strValue`/`nilValue` go
  host → VM; `asInt`/`asFloat`/`asBool`/`asStr` come back (returning `null` on a kind
  mismatch), and `kindOf(v)` reports the kind first (`int` widens to `float` in the
  language, so a script may hand back either — you decide whether to coerce). A returned
  string is borrowed: its bytes must outlive the values holding it.
- **`print` routing.** `setPrint(fn, ctx)` sends `print`/`echo` output to a callback
  (one line at a time) instead of the internal buffer — e.g. an editor output panel.
- **Errors never panic.** A script runtime error makes `call` return `error.Runtime`;
  `session.lastError()` carries the message with line/col, and the Session resets so the
  next call still works. A compile failure is `error.Compile` (`compileDiagnostics()`).
- **Threading.** A `Session` is **single-threaded and owns no shared mutable global
  state** — use one per thread (one world per thread is fine). If a host function tries
  to call back into the *same* Session while it's running, `call` returns
  `error.Reentrant` instead of corrupting the stack.

### Declaring the host API in script (`extern`)

`registerHost` alone leaves the boundary untyped: the script just sees a global, so the
analyzer can't check a call and the editor can't describe one. An **`extern func`**
declares the host binding in RoseGold source — a signature with no body, resolved by
*linkage* at load time rather than by a definition:

```rosegold
## Bindings provided by the engine.
pub extern func host_add(a: int, b: int) -> int
extern "zig" func spawn(kind: str, x: float, y: float) -> int

func update(frame: int) -> int:
    return host_add(frame, 10)
```

This is Zig's own `extern fn` model, with `Session.registerHost` in the linker's seat —
and, as in Zig, the declared signature is an **unchecked promise**: linkage verifies the
name is registered, not that the host's Zig function matches the types you wrote.

- **Call sites get checked.** Arity and argument/return types are enforced against the
  declaration, and `hover`, `documentSymbol`, `fmt`, and `doc` all work on the host API —
  it's an ordinary declaration to every tool.
- **Unregistered means load failure.** A missing native fails when the module loads, the
  way a linker rejects an undefined symbol, rather than surfacing a confusing "undefined
  name" at the first call. (So a script using `extern` can't run under the plain
  `run --vm` CLI — there's no host to register anything.)
- **A shared bindings module is the intended shape.** One `engine.rg` declaring every
  `pub extern`, imported by each game script; natives are injected into every module's
  globals, so it links wherever it's declared.
- **Linkage tags.** Bare `extern` means `extern "zig"` — the embedding host's registered
  natives. `extern "c"` is *reserved* for shared-library linkage by C ABI and currently
  reports "not supported yet"; the syntax exists so adding it later doesn't churn the
  language.
- **Limits.** Top-level only (not a class member), no default parameter values, and no
  named arguments at a call site — a native carries no parameter names for either backend
  to reorder against. The tree-walker has no embedding API at all, so calling an extern
  under `run` (without `--vm`) is a runtime error; *declaring* one is fine, so a module
  can hold bindings and still run its extern-free parts.

### Plain Zig host functions (`registerFn`)

Writing natives against the raw `HostFn` means re-writing the same arity check and
`asInt`/`asStr` ladder in every one. `registerFn` derives all of it from the Zig
function's own type at comptime, so you just write Zig:

```zig
fn spawn(engine: *Engine, kind: []const u8, x: f64, times: i64) i64 {
    return engine.world.spawn(kind, x, times);
}

try session.registerFn("spawn", spawn);
```

- An optional **leading `*Ctx`** parameter receives the Session context. There's no
  ambiguity: no script value marshals into a single-item pointer, so `[]const u8` is
  still an ordinary `str` parameter. (The cast to `*Ctx` is *unchecked* — `Session.init`
  erases the type — so it must match what you passed there. It's the one part of the
  boundary `wrap` can't verify.)
- Parameters and the return may be any int or float type, `bool`, `[]const u8`, `void`,
  or a raw `vm.Value` for "any". Anything else is a **compile error at the `registerFn`
  call site**, naming the type. The return may be an error union — a returned error
  becomes a catchable RoseGold error (`OutOfMemory` propagates).
- `int` widens to `float` as it does everywhere else in the language, and integers are
  range-checked on the way in.

The payoff beyond ergonomics is that `registerFn` also **records the signature**, which
turns the `extern` declaration from a promise into a checked contract:

```
extern func spawn(kind: str, x: float, times: int) -> int    # ✓ matches
extern func spawn(kind: int, x: float, times: int) -> int    # ✗ at load:
#   extern 'spawn' parameter 1: declared int, but the host takes str
```

That check runs at **load**, before any call — so a script and an engine that disagree
fail immediately and legibly, rather than at the ABI boundary the way C (and Zig's own
`extern fn`) would. Arguments are checked at **call** time too, which matters for
`Session.call` from the host since it bypasses the analyzer entirely: you get
`spawn argument 2: expected float, got str` instead of an opaque failure. Both checks
stay lenient where the language is — `any` on either side opts out.

`registerHost` remains for natives that want the raw `[]const Value` (variadic-ish
shapes, or hand-tuned unpacking); those keep the old unchecked behavior. `vm.wrap` is
exported on its own if you want the generated marshalling without the signature.

### Bytecode serialization

Compile a program once and reload it later **without the source or the compiler** — for
shipping bytecode in a pack file:

```zig
// Build step: compile → bytes → write to your pack.
var ser = try vm.serialize(gpa, modules, true);  // true = bake a main() call
defer ser.deinit();
try pack.write("player.rgb", ser.bytes);

// Runtime: read bytes → image → run (or load into a Session).
var image = try vm.deserialize(gpa, bytes);      // AST-free; copies into its arena
defer image.deinit();
var result = try vm.runImage(gpa, &image);       // or: session.loadImage(&image)
```

The compiled graph is cyclic (a type points at its methods; a method points back at the
type), so serialization uses index tables and a two-phase load. Only the *structural*
graph is written — module globals, signal handlers, and static-var values are runtime
state, rebuilt by running the top-level script, exactly as a fresh compile would. Malformed
bytes are rejected with `error.BadImage`, never a crash. Run an `Image` once (running
populates its module globals with that run's state); deserialize again for another instance.

**Known gaps.** The VM does not garbage-collect: values allocated during a call live in
the Session's arena until `deinit`, so for a per-frame loop keep host functions returning
scalars and avoid growing collections without bound. Compiled bytecode is **not yet shared
between Sessions/Images** (each instance deserializes its own copy — still far cheaper than
re-parsing + recompiling). The analyzer doesn't know about host-registered names, so
`check` will flag them as undefined; the VM resolves them at run time.

## Toolchain

- **`repl`** — an interactive read-eval-print loop; definitions and values persist
  across entries, and each entry is type-checked before it runs. Try
  `zig build run -- repl < examples/tour.repl`.
- **`fmt`** — a canonical source formatter (AST → text); `-w` rewrites in place.
- **`check`** — runs the front end (parse + type-check) and reports problems without
  executing.

## How it's built

```
entry.rg → loader (parse it + its imports) → analyzer (per module) → interpreter
             └ lexer → parser (AST) per file ┘                     ↘ or the VM
```

| Component | File |
| --- | --- |
| Lexer (indentation → layout tokens) | `src/fontend/lexer.zig` |
| Recursive-descent parser → AST | `src/fontend/parser.zig` |
| Module loader (dependency graph) | `src/fontend/loader.zig` |
| Name resolution + type checker | `src/fontend/analyzer.zig` |
| Tree-walking interpreter | `src/fontend/interpreter.zig` |
| Bytecode compiler + stack VM | `src/fontend/vm.zig` |
| Source formatter | `src/fontend/formatter.zig` |
| CLI driver + REPL | `src/main.zig` |

Design notes worth calling out:

- **Lenient, non-cascading types.** The checker has `unknown` and `any` escape
  hatches that are compatible with everything, so one type error never triggers a
  cascade of spurious ones.
- **Panic-mode recovery.** A bad construct is reported and the parser resynchronizes
  to the next statement, so you get many diagnostics per run, not just the first.
- **Bounded recursion.** Both the parser (nesting depth) and the evaluators (call
  depth) are bounded, so pathological input becomes a clean diagnostic rather than a
  crash.
- **Two backends, one source of truth.** The VM has its own value model and bytecode
  but is validated against the interpreter — every example program produces identical
  output on both.

See [`CLAUDE.md`](CLAUDE.md) for a deeper implementation reference, and
[`examples/`](examples/) for runnable programs (`demo.rg`, `app.rg` + its modules,
`signals.rg`, `mathdemo.rg`, `primes.rg`, and `messy.rg` for the formatter).

## Editor support

The compiler ships a **Language Server** — `RoseGold_Zig lsp` speaks LSP over
stdio, reusing the parser + analyzer for live diagnostics (matching `check`),
plus hover, go-to-definition, a document-symbol outline, completion
(keywords, builtins, your declarations, and a module's exports after `mod.`),
signature help, document highlight, folding, formatting, and workspace-wide
find-references and rename. Any LSP-capable editor can drive it.

- [`vscode-extension/`](vscode-extension/) — a VS Code client for the language
  server, with a TextMate grammar for highlighting and a "run" command.
- [`intellij-plugin/`](intellij-plugin/) — a JetBrains IDE plugin (Java + Gradle):
  syntax highlighting, `##` comment toggling, brace matching, keyword/builtin
  completion + quick-doc, live error highlighting via `check`, structure view,
  folding, reformat via `fmt`, go-to-declaration, and run configurations for both
  backends. See its [README](intellij-plugin/README.md) to build it.

## Status

Feature-complete for a language of this size: full static analysis, two
byte-identical backends, modules with cross-module inheritance, closures, signals,
tuples, error handling, a REPL, a formatter, and a disassembler, all covered by a
300+ test suite. It has no dependencies beyond the Zig standard library.
