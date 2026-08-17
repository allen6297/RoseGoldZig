package org.rosegold.ide.debug;

import com.intellij.execution.ExecutionException;
import com.intellij.execution.configurations.GeneralCommandLine;
import com.intellij.execution.configurations.RunProfile;
import com.intellij.execution.configurations.RunProfileState;
import com.intellij.execution.executors.DefaultDebugExecutor;
import com.intellij.execution.runners.ExecutionEnvironment;
import com.intellij.execution.runners.GenericProgramRunner;
import com.intellij.execution.ui.RunContentDescriptor;
import com.intellij.openapi.fileEditor.FileDocumentManager;
import com.intellij.openapi.vfs.LocalFileSystem;
import com.intellij.openapi.vfs.VirtualFile;
import com.intellij.xdebugger.XDebugProcess;
import com.intellij.xdebugger.XDebugProcessStarter;
import com.intellij.xdebugger.XDebugSession;
import com.intellij.xdebugger.XDebuggerManager;
import org.jetbrains.annotations.NotNull;
import org.jetbrains.annotations.Nullable;
import org.rosegold.ide.RoseGoldExecutable;
import org.rosegold.ide.run.RoseGoldRunConfiguration;

/**
 * Handles the Debug executor for a RoseGold run configuration: it launches
 * `RoseGold_Zig dap` and starts an {@link XDebugSession} driven by
 * {@link RoseGoldDebugProcess} (which speaks DAP to that process).
 */
public final class RoseGoldDebugRunner extends GenericProgramRunner<com.intellij.execution.configurations.RunnerSettings> {
    @Override
    public @NotNull String getRunnerId() {
        return "RoseGoldDebugRunner";
    }

    @Override
    public boolean canRun(@NotNull String executorId, @NotNull RunProfile profile) {
        return DefaultDebugExecutor.EXECUTOR_ID.equals(executorId) && profile instanceof RoseGoldRunConfiguration;
    }

    @Override
    protected @Nullable RunContentDescriptor doExecute(@NotNull RunProfileState state,
                                                       @NotNull ExecutionEnvironment env) throws ExecutionException {
        FileDocumentManager.getInstance().saveAllDocuments();
        RoseGoldRunConfiguration cfg = (RoseGoldRunConfiguration) env.getRunProfile();
        final String path = cfg.getFilePath();
        if (path == null || path.isEmpty()) {
            throw new ExecutionException("No file to debug.");
        }
        final String exe = RoseGoldExecutable.resolve(env.getProject().getBasePath());
        final Process process = new GeneralCommandLine(exe, "dap").createProcess();
        final DetachedProcessHandler handler = new DetachedProcessHandler(process);
        final VirtualFile vf = LocalFileSystem.getInstance().findFileByPath(path);

        XDebugSession session = XDebuggerManager.getInstance(env.getProject()).startSession(env, new XDebugProcessStarter() {
            @Override
            public @NotNull XDebugProcess start(@NotNull XDebugSession session) {
                return new RoseGoldDebugProcess(session, handler, process.getInputStream(), process.getOutputStream(), vf, path);
            }
        });
        // NOTE: On 2026.1+ with the split debugger, XDebugSession.getRunContentDescriptor()
        // is deprecated and logs a non-fatal error ("RunContentDescriptor should not be used
        // in split mode") — the session still starts and breakpoints/stepping work. The
        // sanctioned replacement (AsyncProgramRunner returning
        // XSessionStartedResult.getRunContentDescriptor()) is not yet shipped in 2026.2.1
        // (those types don't exist in the SDK), so this classic path stays until the plugin
        // targets a platform that ships them.
        return session.getRunContentDescriptor();
    }
}
