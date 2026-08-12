# RoseGold

A small statically-typed, indentation-based language, implemented in **Zig 0.16.0**.
The toolchain is a complete front end plus a tree-walking interpreter:

```
entry .rg → loader (parse it + its imports) → analyzer (per module) → interpreter
             └ lexer → parser (AST) per file ┘
```

The **loader** turns an entry file into a dependency-ordered set of modules
(each lexed + parsed); the analyzer and interpreter then process that whole set.
A single file with no imports is just a one-module set, so the pipeline is
uniform. See `examples/demo.rg` (single file) and `examples/app.rg` (imports
`mathutil` and `geometry`) for representative programs.

## Commands

```bash
zig build                       # build the CLI (exe: zig-out/bin/RoseGold_Zig)
zig build run -- run FILE.rg    # parse, analyze, and execute FILE
zig build run -- check FILE.rg  # parse and analyze only, report problems
zig build test                  # run every test (193 as of writing)

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
| `src/fontend/loader.zig` | Module loader: reads + parses the entry file and its transitive imports into a dependency-ordered `Graph`; path resolution, dedup, cycle detection. |
| `src/fontend/analyzer.zig` | Combined name resolution + type checking over the AST. |
| `src/fontend/interpreter.zig` | Tree-walking evaluator. |
| `src/fontend/tests.zig` | Test aggregator; the `zig build test` frontend target roots here. |
| `src/root.zig` | Leftover `zig init` scaffold (unused by the language; do not build on it). |
| `build.zig` | Build. Exe = `main.zig`; frontend test target = `tests.zig`. |
| `examples/*.rg` | Sample programs: `demo.rg` (single file), `app.rg` + `mathutil.rg` + `geometry.rg` (modules). |

Each layer imports the ones below it (`interpreter`/`analyzer` → `parser` → `lexer`,
and `loader` → `parser`); there are no upward dependencies. `main.zig` drives the
loader, then the analyzer and interpreter over the loaded module set.

## Conventions & patterns

- **Diagnostics** are `lexer.Diagnostic { message, line, col }` and **self-contained**
  (messages are `allocPrint`ed into the owning arena), so a result can outlive the tree
  it came from. Spans (`lexer.Span { start, end, line, col }`) are threaded through every
  token and AST node.
- **Arena ownership.** `parser.parse` → `Tree`, `loader.load` → `Graph`,
  `analyzer.analyze`/`analyzeModule` → `Analysis`, `interpreter.run`/`runProgram` →
  `RunResult` each own a `std.heap.ArenaAllocator` and expose `deinit`. Build the
  result slice *before* the return literal so the moved arena includes it. The
  interpreter/analyzer **borrow** the parse tree (function values and member scopes
  point into it), so keep the `Tree`/`Graph` alive for the duration. `Graph` owns the
  parsed trees; a dependent module's `Analysis.exports` point into the *dependency's*
  analysis arena, so keep every module's analysis alive while later ones use it.
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

- **Declarations:** `import a.b.c` (dotted; loads `a/b/c.rg` and binds the leaf name
  `c` as a module namespace — see **Modules** below), `const`/`var`
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
  (patterns: literals, `_`, a binding name, or an enum case `Enum.CASE` — covering
  every case is exhaustive without a `_`).
- **Types:** `int`, `float`, `str`, `bool`, `void`, `any`, `list`/`map` (optionally
  with element types — `list<T>`, `map<K, V>`, nestable; a bare `list`/`map` is
  `list<any>`/`map<any, any>`), plus user classes/structs/enums, and optionals `?T`
  (hold `T` or `nil`). `int` widens to `float`.
  A subclass is assignable to its bases (via `extends`/`uses`, transitively). `nil` and a
  value both fit `?T`; a `?T` must be unwrapped (e.g. narrowed via `if v != nil:`) before
  it's usable as `T`. `?T`-returning functions may fall off the end (yielding `nil`).
- **Analyzer checks:** undefined names, duplicate declarations, unknown types,
  init/return/operator/condition/assignment/call type compatibility, member access,
  enum-case validity (`Status.OK`), `match` exhaustiveness + unreachable arms +
  arm-type unification (arms unify to a common type; a `nil` arm makes it optional),
  `extends`/`uses` validity + inheritance-aware assignability, member access
  (including inherited members) with `private` reachable only inside its own
  type, that every path of a function with a concrete return type returns a
  value, and collection element types (a list/map literal's inferred element
  types, list/map indexing result + index type, and `for`-binding types — all
  element-aware but lenient on `any`/`unknown`).
- **Interpreter:** runs everything above. Classes/structs: `Name(...)` constructs (fields
  take defaults; a method named `init` is the constructor), inheritance is honored at
  runtime (inherited fields, method override, chained `init`). Enum cases are distinct
  values printing as `Enum.CASE`. Builtins (`interpreter.builtin_names`, shared with
  the analyzer): `print`, `echo`, `len`, `range`, `str`, `int`, `float`, `push`, `pop`,
  `keys`, `values`, `has`.

### Modules
- **A module is a `.rg` file.** `import a.b` loads `a/b.rg` **relative to the importing
  file's directory** and binds the leaf name (`b`) as a namespace value. Reach its
  exports with `b.name`.
- **`pub` is the export boundary.** Only `pub` top-level declarations are visible to
  importers; anything else is module-private (so top-level visibility is now enforced —
  cross-module, by what a module exports). Class/struct *member* visibility is unchanged.
- **The loader** (`loader.zig`) reads the entry file and everything it transitively
  imports, normalizes paths lexically (so a file reached two ways loads once), detects
  **circular imports**, and returns the modules in **dependency order**. `main.zig` then
  analyzes each in that order (handing every module the exports of the ones it imports)
  and runs them (dependencies first; the entry's `main()` last).
- **Closures over the home module.** A function/method value carries the globals of the
  module that defined it (`FuncValue.module`, `TypeInfo.module`), so when it's called
  from another module its body still resolves names in *its own* module — it can use its
  module's private helpers and consts. The analyzer mirrors this: an imported name has a
  `module` type whose members are that module's exports.
- **Limits (v1):** imports resolve relative to the importer's dir (no search path); type
  *annotations* can't be module-qualified (`var x: mod.T` won't parse), so an imported
  type is only used through the values a module's functions return; cross-module
  inheritance isn't supported; a runtime error is attributed to the entry file.

### Known gaps / future work
- No **static** class members at runtime (only enum cases via `Enum.CASE`).
- Collection **element types are analyzer-only** and not runtime-enforced; the
  `push`/`keys`/`values`/etc. builtins are still typed `any`, so they neither
  consume nor produce element-typed results (e.g. `keys(m)` is `any`, not `list<K>`).
  Element assignability is covariant (unsound under mutation, but matches the
  lenient design).
- Module resolution has no **search path / package roots** and no cross-module type
  annotations (see **Modules → Limits**). `static` still parses unused.
