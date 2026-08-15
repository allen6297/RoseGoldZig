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

Uses the **IntelliJ Platform Gradle Plugin 2.x** and a committed Gradle wrapper
(`./gradlew`, Gradle 9.6), so you don't need Gradle on your PATH.

By default it builds against **IntelliJ IDEA 2026.2.1** (platform build 262).
That platform runs on **JDK 25**, so the plugin must be compiled with a JDK 25 —
`gradle.properties` points the toolchain at the JBR 25 bundled inside an
installed IDE (`/Applications/IntelliJ IDEA.app/Contents/jbr`), and
`settings.gradle` enables toolchain auto-provisioning as a fallback (Gradle
downloads a JDK 25 if none is found).

**From the command line:**

```bash
cd intellij-plugin
./gradlew buildPlugin        # → build/distributions/rosegold-intellij-0.1.0.zip
./gradlew runIde             # launch a sandbox IDE to try it
```

Then install the zip via *Settings | Plugins | ⚙ | Install Plugin from Disk…*.

**Targeting a different IDE version:** pass `-PplatformVersion=…` to match your
IDE, e.g. `./gradlew buildPlugin -PplatformVersion=2025.3`. If your IDE's bundled
JBR lives elsewhere, add its `…/Contents/Home` to
`org.gradle.java.installations.paths` in `gradle.properties` (or let the foojay
resolver download the matching JDK). The plugin declares `since-build=233` with
no upper bound, so a single build loads on current and future IDEs.

**From the IDE:** open the `intellij-plugin/` folder in IntelliJ IDEA as a Gradle
project and run the **`runIde`** or **`buildPlugin`** Gradle task.

> First run downloads the target IntelliJ IDEA distribution (a few hundred MB)
> and, if needed, a JDK 25 — expect it to take a while.

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
