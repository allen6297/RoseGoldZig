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

        final XDebugProcessStarter starter = new XDebugProcessStarter() {
            @Override
            public @NotNull XDebugProcess start(@NotNull XDebugSession session) {
                return new RoseGoldDebugProcess(session, handler, process.getInputStream(), process.getOutputStream(), vf, path);
            }
        };
        // On 2026.1+ the debugger is split (backend/frontend): the debug tool window is
        // created on the frontend, and the backend runner must NOT pull the
        // RunContentDescriptor — session.getRunContentDescriptor() is deprecated and logs a
        // "[Split debugger] RunContentDescriptor should not be used" error. Let the platform
        // build and SHOW the debug tab itself via startSessionAndShowTab, then return null so
        // we never touch the descriptor. This keeps the Debug tool window appearing while
        // avoiding the deprecated call.
        XDebuggerManager.getInstance(env.getProject())
            .startSessionAndShowTab(cfg.getName(), env.getContentToReuse(), starter);
        return null;
    }
}
