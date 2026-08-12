# RoseGold

A small statically-typed, indentation-based language, implemented in **Zig 0.16.0**.
The toolchain is a complete front end plus a tree-walking interpreter:

```
source (.rg) → lexer → parser (AST) → analyzer (name res + types) → interpreter
```

Programs are driven through a CLI that reads a `.rg` file and runs the whole
pipeline. See `examples/demo.rg` for a representative program.

## Commands

```bash
zig build                       # build the CLI (exe: zig-out/bin/RoseGold_Zig)
zig build run -- run FILE.rg    # parse, analyze, and execute FILE
zig build run -- check FILE.rg  # parse and analyze only, report problems
zig build test                  # run every test (123 as of writing)

# Fast iteration on one layer — imports pull in its dependencies, so this
# also runs the tests of the files it imports:
zig test src/fontend/parser.zig
zig test src/fontend/interpreter.zig   # covers parser + lexer too
```

The CLI (`run`/`check`, default `run`) prints program output to **stdout** and
renders diagnostics (with a source line + caret) to **stderr**, exiting non-zero
on any error.

## Layout

Note the directory is spelled **`fontend`** (a typo baked into the real path — keep it).

| File | Role |
| --- | --- |
| `src/main.zig` | CLI driver: arg parsing, file read, pipeline, diagnostic rendering. Plus scaffold tests. |
| `src/fontend/lexer.zig` | Lexer. Indentation → INDENT/DEDENT/NEWLINE layout tokens; comments; diagnostics. |
| `src/fontend/parser.zig` | Recursive-descent parser → AST (all `pub`). Owns the AST node types. |
| `src/fontend/analyzer.zig` | Combined name resolution + type checking over the AST. |
| `src/fontend/interpreter.zig` | Tree-walking evaluator. |
| `src/fontend/tests.zig` | Test aggregator; the `zig build test` frontend target roots here. |
| `src/root.zig` | Leftover `zig init` scaffold (unused by the language; do not build on it). |
| `build.zig` | Build. Exe = `main.zig`; frontend test target = `tests.zig`. |
| `examples/demo.rg` | Sample program. |

Each layer imports the ones below it (`interpreter`/`analyzer` → `parser` → `lexer`);
there are no upward dependencies.

## Conventions & patterns

- **Diagnostics** are `lexer.Diagnostic { message, line, col }` and **self-contained**
  (messages are `allocPrint`ed into the owning arena), so a result can outlive the tree
  it came from. Spans (`lexer.Span { start, end, line, col }`) are threaded through every
  token and AST node.
- **Arena ownership.** `parser.parse` → `Tree`, `analyzer.analyze` → `Analysis`,
  `interpreter.run` → `RunResult` each own a `std.heap.ArenaAllocator` and expose
  `deinit`. Build the result slice *before* the return literal so the moved arena
  includes it. The interpreter/analyzer **borrow** the parse tree (function values and
  member scopes point into it), so keep the `Tree` alive for the duration.
- **Two-phase registration.** Module- and class-level declarations are registered
  (names, signatures, member tables) *before* any body is analyzed/executed, so
  declarations may reference each other regardless of order.
- **Lenient typing.** The analyzer's `Type` has `unknown` (unresolved) and `any` (escape
  hatch); both are assignable to/from everything, so one error never cascades. When
  unsure of a type, yield `unknown` rather than guessing.
- **Panic-mode recovery.** The parser reports a diagnostic and `synchronize()`s to the
  next statement/decl boundary (with guaranteed forward progress) so one bad construct
  doesn't abort the parse.
- **Tests** live at the bottom of each file (`test "..." { ... }`) and are aggregated by
  `tests.zig`. Interpreter tests assert on captured `output`; analyzer tests assert on
  diagnostic messages/counts. Add tests in the same file as the code.
- **Zig 0.16 idioms** used throughout: unmanaged containers (`std.ArrayList(T) = .empty`,
  `std.StringHashMapUnmanaged(V) = .{}`) with the allocator passed per call; file I/O via
  `Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(n))`; `main(init: std.process.Init)`.
  `Date.now`/`Math.random` aren't relevant here. Tagged-union `== .tag` comparisons work.

## Language reference (what's implemented)

- **Declarations:** `import a.b.c` (dotted; parses and validates but is **inert** —
  binds no name, since there is no module system yet), `const`/`var`
  (optional `: type`), `func name(p: T, q) -> R:` (params may be untyped → `any`),
  `class` (with `extends` / `uses`), `struct` (no inheritance), `enum { A, B = 2 }`,
  `signal name(params)`. `pub`/`private`/`static` modifiers parse.
- **Statements:** `return`, `if`/`elif`/`else`, `while`, `for x in iter:`,
  `break`, `continue`, `pass`, assignment, expression statements. All statement
  blocks are colon-blocks (indentation); braces `{ }` are only for `enum`/`match`
  bodies.
- **Expressions:** literals (incl. `nil`), identifiers, `and`/`or`/`not`,
  arithmetic/comparison with precedence, calls, indexing `a[i]`, member access `x.f`,
  array `[...]` and map `{k: v}` literals, and `match subj { pattern: body, ... }`
  (patterns: literals, `_`, binding).
- **Types:** `int`, `float`, `str`, `bool`, `void`, `any`, `list`, `map`, plus user
  classes/structs/enums, and optionals `?T` (hold `T` or `nil`). `int` widens to `float`.
  A subclass is assignable to its bases (via `extends`/`uses`, transitively). `nil` and a
  value both fit `?T`; a `?T` must be unwrapped (e.g. narrowed via `if v != nil:`) before
  it's usable as `T`. `?T`-returning functions may fall off the end (yielding `nil`).
- **Analyzer checks:** undefined names, duplicate declarations, unknown types,
  init/return/operator/condition/assignment/call type compatibility, member access,
  enum-case validity (`Status.OK`), `match` exhaustiveness + unreachable arms,
  `extends`/`uses` validity + inheritance-aware assignability, member access
  (including inherited members) with `private` reachable only inside its own
  type, and that every path of a function with a concrete return type returns a
  value.
- **Interpreter:** runs everything above. Classes/structs: `Name(...)` constructs (fields
  take defaults; a method named `init` is the constructor), inheritance is honored at
  runtime (inherited fields, method override, chained `init`). Enum cases are distinct
  values printing as `Enum.CASE`. Builtins: `print`, `echo`, `len`, `range`.

### Known gaps / future work
- **Top-level** `pub`/`private` isn't enforced (needs a module system); only
  class/struct *member* visibility is checked. `static` still parses unused.
- No **static** class members at runtime (only enum cases via `Enum.CASE`).
- `list`/`map` are **untyped** (no element types tracked or checked).
- `match` patterns can't match **enum cases** (`Status.OK` as a pattern) yet.
- Small builtin set; no user-facing stdlib.
