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
