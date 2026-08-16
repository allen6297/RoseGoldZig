package org.rosegold.ide.debug;

import com.google.gson.JsonObject;
import com.intellij.execution.process.ProcessHandler;
import com.intellij.execution.process.ProcessOutputTypes;
import com.intellij.openapi.vfs.VirtualFile;
import com.intellij.xdebugger.XDebugProcess;
import com.intellij.xdebugger.XDebugSession;
import com.intellij.xdebugger.breakpoints.XBreakpointHandler;
import com.intellij.xdebugger.breakpoints.XBreakpointProperties;
import com.intellij.xdebugger.breakpoints.XLineBreakpoint;
import com.intellij.xdebugger.evaluation.XDebuggerEditorsProvider;
import com.intellij.xdebugger.frame.XSuspendContext;
import org.jetbrains.annotations.NotNull;
import org.jetbrains.annotations.Nullable;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

/**
 * Bridges IntelliJ's XDebugger to a `RoseGold_Zig dap` process via {@link
 * DapClient}. Line breakpoints and the step actions map to DAP requests; a DAP
 * `stopped` event fetches the backtrace and drives {@code positionReached};
 * program output is routed to the console; `terminated` ends the session.
 */
public final class RoseGoldDebugProcess extends XDebugProcess implements DapClient.EventListener {
    private final DapClient client;
    private final ProcessHandler processHandler;
    private final VirtualFile file;
    private final String programPath;
    private final RoseGoldDebuggerEditorsProvider editorsProvider = new RoseGoldDebuggerEditorsProvider();
    private final BreakpointHandler breakpointHandler = new BreakpointHandler();
    private final Set<Integer> breakpointLines = new LinkedHashSet<>(); // 1-based
    private volatile boolean started = false;

    public RoseGoldDebugProcess(@NotNull XDebugSession session, ProcessHandler processHandler,
                                java.io.InputStream procOut, java.io.OutputStream procIn,
                                VirtualFile file, String programPath) {
        super(session);
        this.processHandler = processHandler;
        this.client = new DapClient(procOut, procIn, this);
        this.file = file;
        this.programPath = programPath;
    }

    @Override
    public void sessionInitialized() {
        client.start();
        client.send("initialize", new JsonObject()); // the `initialized` event drives the rest
    }

    @Override
    public @NotNull XDebuggerEditorsProvider getEditorsProvider() {
        return editorsProvider;
    }

    @Override
    public XBreakpointHandler<?> @NotNull [] getBreakpointHandlers() {
        return new XBreakpointHandler[]{breakpointHandler};
    }

    @Override
    protected ProcessHandler doGetProcessHandler() {
        return processHandler;
    }

    // --- resume / stepping -> DAP --------------------------------------------

    @Override
    public void resume(@Nullable XSuspendContext context) {
        client.send("continue", threadArg());
    }

    @Override
    public void startStepOver(@Nullable XSuspendContext context) {
        client.send("next", threadArg());
    }

    @Override
    public void startStepInto(@Nullable XSuspendContext context) {
        client.send("stepIn", threadArg());
    }

    @Override
    public void startStepOut(@Nullable XSuspendContext context) {
        client.send("stepOut", threadArg());
    }

    @Override
    public void stop() {
        client.send("disconnect", new JsonObject());
        client.close();
    }

    // --- DAP events ----------------------------------------------------------

    @Override
    public void onEvent(String event, JsonObject body) {
        switch (event) {
            case "initialized" -> {
                JsonObject launch = new JsonObject();
                launch.addProperty("program", programPath);
                launch.addProperty("stopOnEntry", false);
                client.send("launch", launch);
                sendBreakpoints();
                client.send("configurationDone", new JsonObject());
                started = true;
            }
            case "stopped" -> onStopped();
            case "output" -> processHandler.notifyTextAvailable(DapClient.str(body, "output"), ProcessOutputTypes.STDOUT);
            case "terminated", "exited" -> getSession().stop();
            default -> {
            }
        }
    }

    @Override
    public void onClosed() {
        getSession().stop();
    }

    private void onStopped() {
        client.send("stackTrace", threadArg(), (ok, body) -> {
            List<RoseGoldStackFrame> frames = new ArrayList<>();
            if (body.has("stackFrames") && body.get("stackFrames").isJsonArray()) {
                for (var f : body.getAsJsonArray("stackFrames")) {
                    JsonObject fo = f.getAsJsonObject();
                    frames.add(new RoseGoldStackFrame(client, file,
                            DapClient.intOr(fo, "id", 0), DapClient.str(fo, "name"), DapClient.intOr(fo, "line", 1)));
                }
            }
            getSession().positionReached(new RoseGoldSuspendContext(frames));
        });
    }

    private void sendBreakpoints() {
        JsonObject args = new JsonObject();
        JsonObject source = new JsonObject();
        source.addProperty("path", programPath);
        args.add("source", source);
        com.google.gson.JsonArray bps = new com.google.gson.JsonArray();
        for (int line : breakpointLines) {
            JsonObject bp = new JsonObject();
            bp.addProperty("line", line);
            bps.add(bp);
        }
        args.add("breakpoints", bps);
        client.send("setBreakpoints", args);
    }

    private static JsonObject threadArg() {
        JsonObject a = new JsonObject();
        a.addProperty("threadId", 1);
        return a;
    }

    // --- breakpoints ----------------------------------------------------------

    private final class BreakpointHandler extends XBreakpointHandler<XLineBreakpoint<XBreakpointProperties<?>>> {
        BreakpointHandler() {
            super(RoseGoldLineBreakpointType.class);
        }

        @Override
        public void registerBreakpoint(@NotNull XLineBreakpoint<XBreakpointProperties<?>> breakpoint) {
            breakpointLines.add(breakpoint.getLine() + 1); // XLineBreakpoint is 0-based
            if (started) {
                sendBreakpoints();
            }
        }

        @Override
        public void unregisterBreakpoint(@NotNull XLineBreakpoint<XBreakpointProperties<?>> breakpoint, boolean temporary) {
            breakpointLines.remove(breakpoint.getLine() + 1);
            if (started) {
                sendBreakpoints();
            }
        }
    }
}
