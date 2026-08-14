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
zig build run -- run FILE.rg    # parse, analyze, and execute FILE (tree-walker)
zig build run -- run --vm FILE.rg  # execute on the bytecode VM instead
zig build run -- run --disasm FILE.rg  # print the compiled VM bytecode (don't run)
zig build run -- check FILE.rg  # parse and analyze only, report problems
zig build run -- repl           # interactive session (also the default, no file)
zig build run -- fmt FILE.rg    # print FILE re-formatted (canonical style); -w rewrites it
zig build test                  # run every test (312 as of writing)

# Fast iteration on one layer — imports pull in its dependencies, so this
# also runs the tests of the files it imports:
zig test src/fontend/parser.zig
zig test src/fontend/interpreter.zig   # covers parser + lexer too
```

The CLI (`run`/`check`/`repl`/`fmt`, default `run` with a file / `repl` without)
prints program output to **stdout** and renders diagnostics (with a source line +
caret) to **stderr**, exiting non-zero on any error. `repl` starts an interactive
read-eval-print loop whose definitions and values persist across entries. `fmt`
re-prints a file in canonical style (to stdout, or in place with `-w`); it walks
the AST but the lexer keeps `##` line comments, which the formatter re-emits by
line (block comments and original blank lines are not preserved).

## Layout

Note the directory is spelled **`fontend`** (a typo baked into the real path — keep it).

| File | Role |
| --- | --- |
| `src/main.zig` | CLI driver: arg parsing, file read, pipeline, diagnostic rendering, and the `repl` read-eval-print loop. Plus scaffold tests. |
| `src/fontend/lexer.zig` | Lexer. Indentation → INDENT/DEDENT/NEWLINE layout tokens; comments; diagnostics. |
| `src/fontend/parser.zig` | Recursive-descent parser → AST (all `pub`). Owns the AST node types. |
| `src/fontend/loader.zig` | Module loader: reads + parses the entry file and its transitive imports into a dependency-ordered `Graph`; path resolution, dedup, cycle detection. |
| `src/fontend/analyzer.zig` | Combined name resolution + type checking over the AST. |
| `src/fontend/interpreter.zig` | Tree-walking evaluator (the default backend, full language). |
| `src/fontend/vm.zig` | Alternative backend behind `run --vm`: a bytecode compiler + stack VM covering the whole language, incl. modules + cross-module inheritance (see below). Also `run --disasm`. |
| `src/fontend/formatter.zig` | Canonical source printer (AST → formatted text) behind `fmt`; re-emits `##` line comments by line. |
| `src/fontend/tests.zig` | Test aggregator; the `zig build test` frontend target roots here. |
| `src/root.zig` | Leftover `zig init` scaffold (unused by the language; do not build on it). |
| `build.zig` | Build. Exe = `main.zig`; frontend test target = `tests.zig`. |
| `examples/*.rg` | Sample programs: `demo.rg` (single file), `app.rg` + `mathutil.rg` + `geometry.rg` (modules — runs on both backends), `messy.rg` (badly-formatted input for `fmt`), `primes.rg`, `signals.rg`, and `mathdemo.rg` (run on both backends). `tour.repl` is a REPL input script (`repl < examples/tour.repl`). |

Each layer imports the ones below it (`interpreter`/`analyzer` → `parser` → `lexer`,
and `loader`/`formatter` → `parser`); there are no upward dependencies. `main.zig`
drives the loader, then the analyzer and interpreter over the loaded module set
(or the formatter for `fmt`).

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
- **Recursion guards.** The recursive-descent parser bounds nesting (`max_nesting`,
  in `parseExpr`/`parseIndentedStmts`) and the tree-walking interpreter bounds call
  depth (`max_call_depth`), so pathological nesting or runaway recursion becomes a
  diagnostic / runtime error instead of a native stack overflow. A fuzz harness and
  an adversarial-input batch (both in `analyzer.zig`) guard the front end against
  crashes on malformed input; `--fuzz` mode is currently blocked by a Zig 0.16
  test-runner bug, so the harness runs as a smoke test.
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
  `signal name(params)`. `pub`/`private` visibility; `static` on a class/struct
  member makes it belong to the type (shared storage / no receiver), reached via
  `Type.member`.
- **Statements:** `return`, `if`/`elif`/`else`, `while`, `for x in iter:` (also
  `for i, x in iter:` — a second binding gives index+element for a list/string or
  key+value for a map), `break`, `continue`, `pass`, assignment (incl. compound
  `+= -= *= /= %=`, which
  the parser desugars to `x = x <op> e`), tuple **destructuring** `var a, b = tuple`
  (also destructures a list; arity is checked), `raise expr` and
  `try: ... catch e: ...` (see **Error handling**), expression statements. All statement
  blocks are colon-blocks (indentation); braces `{ }` are only for `enum`/`match`
  bodies.
- **Expressions:** literals (incl. `nil`), string interpolation `"a ${expr} b"`
  (the parser splits the literal and sub-parses each hole; `\$` escapes; no string
  literals inside a hole), identifiers, `and`/`or`/`not`,
  arithmetic/comparison with precedence, a range `a..b` (the ints `a` … `b-1`, as a
  `list<int>`), calls, indexing `a[i]`, member access `x.f`,
  array `[...]` and map `{k: v}` literals, tuple literals `(a, b, ...)` (two or more
  elements; a single `(e)` is just grouping), anonymous functions `func(params): expr`
  (single expression, implicitly returned; or `func(params):` + an indented block)
  that close over the surrounding scope, and `match subj { pattern: body, ... }`
  (patterns: literals, `_`, a binding name, or an enum case `Enum.CASE` — covering
  every case is exhaustive without a `_`).
- **Types:** `int`, `float`, `str`, `bool`, `void`, `any`, `list`/`map` (optionally
  with element types — `list<T>`, `map<K, V>`, nestable; a bare `list`/`map` is
  `list<any>`/`map<any, any>`), tuples `(A, B, ...)` (fixed, ordered, compared
  elementwise; used for multiple return values), plus user classes/structs/enums, an
  imported type named `mod.T`, and optionals `?T` (hold `T` or `nil`). `int` widens to
  `float`.
  A subclass is assignable to its bases (via `extends`/`uses`, transitively). `nil` and a
  value both fit `?T`; a `?T` must be unwrapped (e.g. narrowed via `if v != nil:`) before
  it's usable as `T`. `?T`-returning functions may fall off the end (yielding `nil`).
- **Analyzer checks:** undefined names, duplicate declarations, unknown types,
  init/return/operator/condition/assignment/call type compatibility, construction
  arguments (count + types against a class's `init`, or none if it has no `init`),
  member access,
  enum-case validity (`Status.OK`), `match` exhaustiveness + unreachable arms +
  arm-type unification (arms unify to a common type; a `nil` arm makes it optional),
  `extends`/`uses` validity + inheritance-aware assignability, member access
  (including inherited members) with `private` reachable only inside its own
  type, that every path of a function with a concrete return type returns a
  value (a `raise` terminates a path; a `try/catch` counts as returning only when
  both the body and the handler do), and collection element types (a list/map
  literal's inferred element
  types, list/map indexing result + index type, `for`-binding types, and the
  collection builtins — `push`/`pop`/`keys`/`values`/`has`/`range` are typed
  element-aware, e.g. `pop(list<T>) → T`, `keys(map<K,V>) → list<K>`, `push`/`has`
  check the element/key — all lenient on `any`/`unknown`).
- **Interpreter:** runs everything above. Classes/structs: `Name(...)` constructs (fields
  take defaults; a method named `init` is the constructor), inheritance is honored at
  runtime (inherited fields, method override, chained `init`). `static` members live on
  the type (`TypeInfo.statics`): static vars are one shared cell, static methods run with
  no receiver but see the type's statics by bare name; both are reached via `Type.member`.
  Statics are inherited and shared — a subclass reaches a base's static through its own
  name (`Sub.count`, the same cell as `Base.count`).
  Enum cases are distinct
  values printing as `Enum.CASE`. A **lambda** evaluates to a closure that captures
  the current environment, module, and receiver/statics, so it resolves outer names
  (and mutations to captured locals are visible) when called later — anywhere a
  callable is expected, including signal handlers. **Signals** are real events: a `signal` is a value
  holding a handler list — top-level signals are shared globals, a class signal is made
  fresh per instance (inherited, reached via `inst.name`) — and `connect(sig, handler)`
  / `emit(sig, args…)` register and fire handlers (any callable). Builtins
  (`interpreter.builtin_names`, shared with the analyzer): `print`, `echo`, `len`,
  `range`, `str`, `int`, `float`, `push`, `pop`, `keys`, `values`, `has`, `connect`,
  `emit`, and the stdlib `abs`, `min`, `max`, `upper`, `lower`, `split`, `join`,
  `contains`, `sort`, `reverse`, `trim`, `starts_with`, `ends_with`, `find`
  (index of substring/element, `-1` if absent), `replace`, the math builtins
  `sqrt`/`pow` (→ `float`) and `floor`/`ceil`/`round` (→ `int`), and the
  higher-order list builtins `map(list, f)`, `filter(list, pred)`,
  `reduce(list, f, init)` (each invokes a callback — any callable).

### Error handling
- `raise expr` throws a value; `try: body catch e: handler` runs `body` and, on a raised
  error, runs `handler` with `e` bound to the thrown value. **Built-in runtime errors are
  catchable too** (a caught built-in error binds its message string); an uncaught error is
  the top-level runtime error as before. Both backends behave identically — the built-in
  error message text is aligned between them so the caught string matches.
- **Interpreter:** `raise` sets `thrown_value` and returns `error.Runtime`; `try/catch`
  catches it (Zig `defer`s in the call chain restore the environment as it unwinds) and
  binds `thrown_value` (or the runtime-error message for a built-in error).
- **VM:** a `push_handler`/`pop_handler`/`raise` opcode trio plus a `handlers` stack. The
  exec loop is split into `execFrames` (a wrapper that catches `error.Runtime`) over
  `runLoop`; on a catchable error it unwinds frames/stack to the handler's `try` point,
  pushes the error value, and jumps to the catch. A handler is only caught **within its
  own re-entrant scope** (`frame_len > stop_at`), so a `raise` inside a `map`/`emit`
  callback correctly propagates out through the builtin to an outer `try`.

### Modules
- **A module is a `.rg` file.** `import a.b` loads `a/b.rg`, resolved **first relative to
  the importing file's directory**, then — if not found there — against each **module
  search root** passed on the CLI (`--path DIR` / `-I DIR`, repeatable; also `--path=DIR`
  and `-Idir`), in order. The import binds the leaf name (`b`) as a namespace value; reach
  its exports with `b.name`. See `examples/pathdemo.rg` + `examples/libs/strutil.rg`
  (`run --path examples/libs examples/pathdemo.rg`, both backends).
- **`pub` is the export boundary.** Only `pub` top-level declarations are visible to
  importers; anything else is module-private (so top-level visibility is now enforced —
  cross-module, by what a module exports). Class/struct *member* visibility is unchanged.
- **The loader** (`loader.zig`) reads the entry file and everything it transitively
  imports, normalizes paths lexically (so a file reached two ways loads once), detects
  **circular imports**, and returns the modules in **dependency order**. `main.zig` then
  analyzes each in that order (handing every module the exports of the ones it imports)
  and runs them (dependencies first; the entry's `main()` last). `load` resolves imports
  importer-relative only; `loadWithPaths(…, roots)` adds the search roots (a `.missing`
  candidate falls through to the next root, a cycle stops the search).
- **Closures over the home module.** A function/method value carries the globals of the
  module that defined it (`FuncValue.module`, `TypeInfo.module`), so when it's called
  from another module its body still resolves names in *its own* module — it can use its
  module's private helpers and consts. The analyzer mirrors this: an imported name has a
  `module` type whose members are that module's exports.
- **Cross-module types.** A type annotation may be module-qualified: `var x: mod.T`
  names a `pub` type `T` exported by `mod`. The analyzer validates the module exports
  it and folds the imported type's member scopes into its own, so `x.member` (and
  `mod.T`'s statics) are checked across the boundary — as is a value returned by an
  imported function. (Names clash-resolve to the local type; construction is
  interpreter-only and already worked via `mod.T()`.)
- **Cross-module inheritance.** A class may `extends`/`uses` a `mod.Base` exported by
  an imported module. The interpreter resolves the imported base to its `TypeInfo`
  (its own ancestors/fields already computed) and splices it into the subclass; an
  inherited method runs in *its base's* module (methods carry their owning type, so
  a base method still resolves its own module's names). The analyzer folds the base's
  member scope in for checking. **The `--vm` backend does this too**: the compiler keeps
  each already-compiled module's type table (`module_types`), so `mod.Base` resolves to
  its `TypeDef` and splices in — an inherited method's compiled `Function` carries its
  own module, giving virtual dispatch across the boundary. (One level deep; base *field
  defaults* referencing the base's module-level names aren't resolved cross-module — keep
  them literal.)
- **Limits (v1):** imports resolve relative to the importer's dir, then the supplied
  search roots (no implicit/global package registry); a runtime error is attributed to
  the entry file.

### REPL
- `repl` (or no file) starts a persistent interpreter session (`interpreter.Repl`
  via `replInit`/`run`). `parser.parseRepl` accepts a mix of declarations and
  statements, so a bare expression like `1 + 1` is a statement whose value is
  printed. Definitions and values persist across entries; the CLI keeps every
  entry's source + parsed chunk alive because function values borrow that AST.
- **Each entry is type-checked before it runs** by a persistent analyzer
  (`analyzer.ReplChecker` via `replCheckerInit`/`check`) whose scope survives across
  entries and allows redefinition; on a static error the entry is reported and not
  executed (a clean re-entry continues). Reading continues across an indented block
  (ended by a blank line) or unclosed brackets. `import` is unavailable in the REPL.
- The checker resolves names at **definition time** (unlike the interpreter's
  call-time binding), so a forward reference to a not-yet-defined name is reported —
  define callees first, or put mutually-recursive definitions in one entry.

### Bytecode VM (`run --vm`)
- An alternative execution backend (`vm.zig`): a compiler lowers each function to a
  `Chunk` of stack-machine opcodes + constants, and a `VM` runs it over a value stack
  with a call-frame stack. It has its **own** small `Value` type (no coupling to the
  interpreter) and produces byte-identical output to the tree-walker. It now covers the
  **entire language** — a genuine drop-in backend, and ~2.8–3.9× faster than the
  tree-walker on compute-heavy code (see `bench/`, built `-Doptimize=ReleaseFast`).
  `run --disasm FILE` prints a human-readable listing of every compiled function's
  bytecode (`Vm.disassemble`) instead of running it — handy for inspecting codegen.
  A `pushFrame` guard bounds recursion (`max_call_depth`) so runaway recursion reports a
  clean "call stack overflow" rather than exhausting memory.
  Each `get_global`/`set_global` carries an **inline-cache slot**: a module's globals map
  is sized once up front (`RtModule.global_count`) so it never rehashes, letting the VM
  cache the resolved value pointer per site (`VM.global_cache`) and skip the string hash
  on repeat lookups (helps global-heavy code like recursion).
- **Classes/structs** compile too: construction (`Name(...)` binds the type name to a
  synthetic constructor closure that creates the instance via a `new_instance` opcode,
  runs field defaults with the instance as receiver, then calls `init`), field get/set
  (`get_member`/`set_field`), methods (compiled once with the receiver as slot 0 `$self`;
  a bound method splices the receiver in below the args on call), bare-name field/method
  resolution inside a method (`loadSelf` + `get_member`, so nested lambdas capture `$self`
  as an upvalue), and `extends`/`uses` inheritance — fields base-first, methods resolved
  with overrides, virtual dispatch through the receiver's runtime type. A compile-time
  `TypeDef` registry (two-phase: register names, then `resolveInheritance`) mirrors the
  interpreter's model; each `RtType` carries the ordered field names + method table.
- **Covers the core:** functions (recursion), locals + globals, arithmetic/comparison,
  short-circuit `and`/`or`, `if`/`elif`/`else`, `while`, `for` over a list/map/string
  with one or two bindings (a small `iter_*` opcode protocol), `break`/`continue` (with
  proper stack cleanup), ranges (`a..b`), list and map literals + indexing,
  **lambdas with by-reference closures** (Crafting-Interpreters-style upvalues: a
  captured local is shared while open, then closed into the closure when its slot goes
  out of scope — on function return or scope exit; captures chain transitively through
  nested lambdas), string interpolation (`"a ${expr} b"`, each hole stringified and
  concatenated via an `interp` opcode), and the full stdlib of builtins (`print`/`len`/
  `str`/`range`/`push`/`keys`/…/`sort`/`split`/`join`/`find`/`replace`/`trim`/`abs`/
  `min`/`max`/…) — including the higher-order `map`/`filter`/`reduce` and the signal
  builtins `connect`/`emit`, whose callbacks/handlers run via a **re-entrant**
  `execFrames(stop_at)` (a builtin pushes the callback frame and runs just that call to
  completion). Optionals
  (`?T`/`nil`) need no special runtime support and already work. `match` on
  literal/`_`/binding patterns compiles too (the subject lives in a slot found via a
  compile-time stack pointer, `FnState.stack_top`). Enums compile too: the enum name
  binds to an `enum_type` value, `Enum.CASE` reads a case via `get_member`, cases compare
  by identity and print `Enum.CASE`, and enum-case `match` arms work. `static` members
  compile too: the type name binds to a `type` value (callable to construct, and the
  target for `Type.member`); static vars live in a per-`RtType` `statics` map (initialized
  once after globals exist, shared with subclasses by walking `ancestors`), static methods
  are closures stored there, and inside a static method a bare static name (own or
  inherited) resolves via a pushed type value + `get_member`. (As in the interpreter, an
  *instance* method reaches statics only through the type name, not by bare name.)
- **Modules** compile too (`Vm.runProgram` over a dependency-ordered module set): each
  module gets its own runtime namespace (`RtModule.globals`), and every `Function` carries
  its home `module`, so `get_global`/`set_global`/`define_global` resolve in the defining
  module even when called across the boundary (like the interpreter's home-module closures).
  `import mod` binds `mod` to a `module` value; `mod.name` reads it via `get_member`; each
  module's script runs in dependency order to populate its globals, and only the entry
  runs `main`. Cross-module funcs/consts/types/enums/signals all work, as does
  **inheritance from an imported base** (`extends`/`uses mod.Base`): the compiler keeps
  each already-compiled module's type table (`module_types`), so `mod.Base` resolves to
  its `TypeDef` and its fields/methods splice in like a local base — an inherited method
  runs in *its* module (its compiled `Function` carries that module), giving virtual
  dispatch to a subclass override across the boundary.
- **Signals** compile too: a top-level `signal` is a single shared value bound in the
  module globals; a class signal is created fresh per instance in `new_instance` (stored
  alongside fields, inherited base-first via `RtType.signal_names`) and reachable by bare
  name inside a method (`isMember` includes signals). `connect` appends a handler; `emit`
  fires them in order through the re-entrant callback path.
- **Fully covered.** The remaining `--vm` rejections are for constructs the analyzer also
  wouldn't run meaningfully (e.g. a nested type declaration inside a class), reported as a
  clear "the --vm backend does not support …" diagnostic.

### Known gaps / future work
- A subclass's own **static method** now sees an inherited static by bare name (both
  backends walk the type's ancestors: the interpreter via `current_static_ti` +
  `staticsEnvFor`, the VM via `TypeDef.isStatic` + `get_member`/`staticSlot`). An
  *instance* method still reaches statics only through the type name, matching both
  backends. `static` argument checks against a static method's parameters are the same
  as any call.
- Collection **element types are analyzer-only** and not runtime-enforced (values
  stay dynamically typed). Element assignability is covariant (unsound under
  mutation, but matches the lenient design). The element-aware builtins are
  special-cased by name at their call sites rather than being first-class generic
  signatures, so calling one indirectly (`var f = push`) falls back to `any`.
- Module resolution supports **explicit search roots** (`--path`/`-I`) but no implicit
  or global **package registry** (see **Modules → Limits**).
  Cross-module inheritance works on both backends but is effectively one level deep: an
  imported base's *field defaults* referencing that base's module-level names aren't
  resolved (the subclass constructor evaluates them in its own module) — keep them literal.
