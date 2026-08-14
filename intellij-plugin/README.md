# RoseGold — IntelliJ Platform plugin

Editor support for RoseGold (`.rg`) files in IntelliJ IDEA and other JetBrains
IDEs. Written in Java against the IntelliJ Platform.

## Features

- **Syntax highlighting** — keywords, built-in types, strings, numbers, `##`
  comments, operators, and brackets, with a configurable color scheme
  (*Settings | Editor | Color Scheme | RoseGold*). A context-aware annotator also
  distinguishes **function declarations** (after `func`) from **function calls**
  (identifier before `(`), each with its own color.
- **`##` line-comment toggling** (`Cmd/Ctrl-/`) and **brace matching** for
  `()`, `[]`, `{}`.
- **Completion & quick-doc** — keywords, built-in types, and the standard-library
  builtins (`print`, `map`, `reduce`, `sqrt`, `emit`, …), each with a one-line
  signature shown on `Ctrl-Q`.
- **Live error highlighting** — an external annotator runs the RoseGold
  compiler's `check` command and underlines real diagnostics in the editor.
- **Structure view & folding** — a tree of the file's functions, classes,
  structs, enums, signals, and top-level consts/vars, and folding of colon-block
  bodies (both driven by an indentation-aware line scan, not a second grammar).
- **Reformatting** — *Reformat Code* (`Cmd/Ctrl-Alt-L`) pipes the file through
  the compiler's `fmt` command.
- **Editing ergonomics** — live templates (`func`, `for`, `class`, `match`,
  `try`, …), and auto-indent after a line whose code ends in `:`.
- **Navigation** — go-to-declaration (`Cmd/Ctrl-B`) jumps an identifier to its
  top-level or class-member declaration, and *Find Usages* indexes identifier
  words. (Rename isn't offered — it needs a real named-element PSI tree rather
  than this flat token stream.)
- **Run configurations** — Run a `.rg` file from the gutter/right-click menu, on
  the tree-walker or (with a checkbox) the bytecode VM (`run --vm`).

## Build & install

Uses the **IntelliJ Platform Gradle Plugin 2.x**, which supports Gradle 8.5+
(including Gradle 9). You need a JetBrains IDE (which bundles Gradle) or a
standalone Gradle 8.5+.

**From the command line** (with `gradle` on PATH):

```bash
cd intellij-plugin
gradle buildPlugin          # → build/distributions/rosegold-intellij-0.1.0.zip
gradle runIde               # launch a sandbox IDE to try it
```

Then install the zip via *Settings | Plugins | ⚙ | Install Plugin from Disk…*.

**From the IDE:** open the `intellij-plugin/` folder in IntelliJ IDEA as a Gradle
project and run the **`runIde`** or **`buildPlugin`** Gradle task.

> First run downloads the target IntelliJ IDEA Community distribution
> (`2023.3.8`, a few hundred MB) — expect it to take a while.
> No Gradle wrapper (`gradlew`) is committed; use your installed Gradle, or run
> `gradle wrapper` once to generate one.

## Pointing it at the compiler

The live-error annotator and the run configurations invoke the `RoseGold_Zig`
executable. It's resolved in this order:

1. the path set in *Settings | Languages & Frameworks | RoseGold*,
2. `zig-out/bin/RoseGold_Zig` under the project root (i.e. after `zig build`),
3. `RoseGold_Zig` on your `PATH`.

Live errors reflect the file **on disk**, so they refresh when you save.

## Layout

```
build.gradle · settings.gradle · gradle.properties
src/main/resources/META-INF/plugin.xml     — extension-point wiring
src/main/resources/icons/rosegold.svg      — file-type icon
src/main/resources/liveTemplates/          — live-template definitions
src/main/java/org/rosegold/ide/            — language, lexer, highlighting, annotator, completion,
                                             docs, formatting, folding, references, find-usages
src/main/java/org/rosegold/ide/structure/  — structure view
src/main/java/org/rosegold/ide/run/        — run configuration
```

## Status / caveats

This plugin was written to build against **IntelliJ Platform 2023.3** (`sinceBuild
233`) with **JDK 17**. It targets stable, long-lived platform APIs. It has **not
been compiled or run in the environment where it was authored** (no Gradle / no
IntelliJ SDK there) — so treat it as a solid starting point rather than a shipped
artifact: opening it in IntelliJ will surface any version-specific API tweaks
immediately. The run-configuration classes touch the most version-sensitive APIs
and are the likeliest to need a small adjustment for your exact IDE build.
