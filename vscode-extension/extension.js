// RoseGold VS Code extension: a thin client for the `RoseGold_Zig lsp` language
// server, plus a command to run the current file. Written in plain JS so it needs
// no build step; syntax highlighting works with no dependencies, and the language
// server activates when `vscode-languageclient` is installed and the executable
// is found.

const vscode = require("vscode");
const path = require("path");

let client; // the running LanguageClient, if any

/** Resolve configured import paths to absolute (relative ones against the workspace). */
function importPaths() {
  const configured = vscode.workspace.getConfiguration("rosegold").get("importPaths") || [];
  const folders = vscode.workspace.workspaceFolders;
  const base = folders && folders.length ? folders[0].uri.fsPath : undefined;
  return configured.map((p) => (path.isAbsolute(p) || !base ? p : path.join(base, p)));
}

/** The configured executable path, or `RoseGold_Zig` from PATH. */
function serverExe() {
  const configured = vscode.workspace.getConfiguration("rosegold").get("serverPath");
  return configured && configured.trim() ? configured.trim() : "RoseGold_Zig";
}

/** Quote an argument for a shell command line if it contains whitespace. */
function shellQuote(s) {
  return /\s/.test(s) ? `"${s}"` : s;
}

function startLanguageServer(context) {
  if (!vscode.workspace.getConfiguration("rosegold").get("enableLanguageServer")) return;

  let node;
  try {
    node = require("vscode-languageclient/node");
  } catch (e) {
    // The client library isn't installed (`npm install` not run). Highlighting
    // and the run command still work; just skip the server.
    console.warn("RoseGold: vscode-languageclient not installed; language server disabled.");
    return;
  }

  const exe = serverExe();
  const serverOptions = {
    run: { command: exe, args: ["lsp"], transport: node.TransportKind.stdio },
    debug: { command: exe, args: ["lsp"], transport: node.TransportKind.stdio },
  };
  const clientOptions = {
    documentSelector: [{ scheme: "file", language: "rosegold" }],
    // Workspace folders are sent automatically; pass any extra search roots too.
    initializationOptions: { importPaths: importPaths() },
  };

  client = new node.LanguageClient("rosegold", "RoseGold Language Server", serverOptions, clientOptions);
  client.start().catch((err) => {
    vscode.window.showWarningMessage(
      `RoseGold language server failed to start (${exe} lsp): ${err.message}. ` +
        `Set "rosegold.serverPath" to your RoseGold_Zig executable.`
    );
  });
  context.subscriptions.push({ dispose: () => client && client.stop() });
}

function runCurrentFile() {
  const editor = vscode.window.activeTextEditor;
  if (!editor || editor.document.languageId !== "rosegold") {
    vscode.window.showInformationMessage("Open a .rg file to run it.");
    return;
  }
  editor.document.save().then(() => {
    const cfg = vscode.workspace.getConfiguration("rosegold");
    const args = ["run"];
    if (cfg.get("useVm")) args.push("--vm");
    args.push(editor.document.fileName);
    const cmd = [serverExe(), ...args].map(shellQuote).join(" ");
    const terminal = vscode.window.createTerminal("RoseGold");
    terminal.show();
    terminal.sendText(cmd);
  });
}

function activate(context) {
  context.subscriptions.push(vscode.commands.registerCommand("rosegold.run", runCurrentFile));
  context.subscriptions.push(
    vscode.commands.registerCommand("rosegold.restartServer", async () => {
      if (client) {
        await client.stop();
        client = undefined;
      }
      startLanguageServer(context);
    })
  );
  startLanguageServer(context);
}

function deactivate() {
  return client ? client.stop() : undefined;
}

module.exports = { activate, deactivate };
