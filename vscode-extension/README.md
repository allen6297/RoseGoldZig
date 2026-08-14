# RoseGold — VS Code extension

Editor support for RoseGold (`.rg`) files in Visual Studio Code:

- **Syntax highlighting** via a TextMate grammar (keywords, types, strings with
  `${…}` interpolation, `##` comments, numbers, function defs and calls).
- **Language configuration** — `##` comment toggling, bracket matching and
  auto-closing, and auto-indent after a line ending in `:`.
- **Language server** — a client for `RoseGold_Zig lsp`, giving **live
  diagnostics** (matching the compiler's `check`), **hover** (standard-library
  docs), **go-to-definition**, a **symbol outline**, **completion** (keywords,
  types, builtins, your declarations, and a module's exports after `mod.`),
  **signature help** (parameter hints while typing a call's arguments),
  **document highlight**, **find all references**, and **rename** across the
  workspace.
- **Run command** — *RoseGold: Run Current File* (command palette) runs the file
  on the tree-walker, or the bytecode VM when `rosegold.useVm` is set.

## Requirements

The extension shells out to the **`RoseGold_Zig`** executable (build it with
`zig build` at the repo root). Point the extension at it with the
`rosegold.serverPath` setting, or put it on your `PATH`. Highlighting works
without it; diagnostics and navigation need it.

## Install / develop

```bash
cd vscode-extension
npm install          # fetches vscode-languageclient (needed for the server)
```

Then press **F5** in VS Code (with this folder open) to launch an Extension
Development Host, or package it:

```bash
npm install -g @vscode/vsce
vsce package         # → rosegold-0.1.0.vsix
code --install-extension rosegold-0.1.0.vsix
```

## Settings

| Setting | Default | Meaning |
| --- | --- | --- |
| `rosegold.serverPath` | `""` | Path to `RoseGold_Zig`; empty ⇒ found on `PATH`. |
| `rosegold.useVm` | `false` | Run files on the bytecode VM (`run --vm`). |
| `rosegold.enableLanguageServer` | `true` | Start the language server for diagnostics/hover/navigation. |
| `rosegold.importPaths` | `[]` | Extra module search roots for imports (relative paths resolve against the workspace). Workspace folders are always searched. |

## Status / caveats

The extension is written in plain JavaScript (no build step). It targets stable
VS Code and `vscode-languageclient` 9 APIs but has **not been run in the
environment where it was authored** — treat it as a solid starting point. If
`vscode-languageclient` isn't installed, the extension degrades gracefully to
highlighting + the run command only. The language server (`RoseGold_Zig lsp`)
resolves imports across files — searching the workspace folders (and
`rosegold.importPaths`), with unsaved buffers overlaid on disk — so diagnostics
are accurate across modules and reflect live edits.
