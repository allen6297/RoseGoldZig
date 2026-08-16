package org.rosegold.ide.debug;

import com.google.gson.JsonArray;
import com.google.gson.JsonObject;
import com.intellij.openapi.vfs.VirtualFile;
import com.intellij.ui.ColoredTextContainer;
import com.intellij.ui.SimpleTextAttributes;
import com.intellij.xdebugger.XDebuggerUtil;
import com.intellij.xdebugger.XSourcePosition;
import com.intellij.xdebugger.frame.XCompositeNode;
import com.intellij.xdebugger.frame.XStackFrame;
import com.intellij.xdebugger.frame.XValueChildrenList;
import org.jetbrains.annotations.Nullable;

/** One backtrace frame: its name + source line, and (lazily) its locals. */
public final class RoseGoldStackFrame extends XStackFrame {
    private final DapClient client;
    private final VirtualFile file;
    private final int frameId;
    private final String name;
    private final int line; // 1-based (DAP)

    public RoseGoldStackFrame(DapClient client, VirtualFile file, int frameId, String name, int line) {
        this.client = client;
        this.file = file;
        this.frameId = frameId;
        this.name = name;
        this.line = line;
    }

    @Override
    public @Nullable XSourcePosition getSourcePosition() {
        return file == null ? null : XDebuggerUtil.getInstance().createPosition(file, line - 1);
    }

    @Override
    public void customizePresentation(ColoredTextContainer component) {
        component.append(name, SimpleTextAttributes.REGULAR_ATTRIBUTES);
        component.append("  (line " + line + ")", SimpleTextAttributes.GRAYED_ATTRIBUTES);
    }

    @Override
    public void computeChildren(XCompositeNode node) {
        JsonObject scopeArgs = new JsonObject();
        scopeArgs.addProperty("frameId", frameId);
        client.send("scopes", scopeArgs, (ok, scopesBody) -> {
            int ref = 0;
            if (scopesBody.has("scopes") && scopesBody.get("scopes").isJsonArray()) {
                JsonArray scopes = scopesBody.getAsJsonArray("scopes");
                if (scopes.size() > 0) {
                    ref = DapClient.intOr(scopes.get(0).getAsJsonObject(), "variablesReference", 0);
                }
            }
            JsonObject varArgs = new JsonObject();
            varArgs.addProperty("variablesReference", ref);
            client.send("variables", varArgs, (ok2, varsBody) -> {
                XValueChildrenList children = new XValueChildrenList();
                if (varsBody.has("variables") && varsBody.get("variables").isJsonArray()) {
                    for (var v : varsBody.getAsJsonArray("variables")) {
                        JsonObject vo = v.getAsJsonObject();
                        children.add(DapClient.str(vo, "name"), new RoseGoldValue(DapClient.str(vo, "value")));
                    }
                }
                node.addChildren(children, true);
            });
        });
    }
}
