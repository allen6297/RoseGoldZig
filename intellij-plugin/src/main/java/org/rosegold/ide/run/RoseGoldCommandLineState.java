package org.rosegold.ide.run;

import com.intellij.execution.ExecutionException;
import com.intellij.execution.configurations.CommandLineState;
import com.intellij.execution.configurations.GeneralCommandLine;
import com.intellij.execution.process.OSProcessHandler;
import com.intellij.execution.process.ProcessHandler;
import com.intellij.execution.process.ProcessTerminatedListener;
import com.intellij.execution.runners.ExecutionEnvironment;
import org.jetbrains.annotations.NotNull;
import org.rosegold.ide.RoseGoldExecutable;

import java.io.File;

public final class RoseGoldCommandLineState extends CommandLineState {
    private final RoseGoldRunConfiguration config;

    RoseGoldCommandLineState(@NotNull ExecutionEnvironment environment, @NotNull RoseGoldRunConfiguration config) {
        super(environment);
        this.config = config;
    }

    @Override
    protected @NotNull ProcessHandler startProcess() throws ExecutionException {
        String basePath = config.getProject().getBasePath();
        String exe = RoseGoldExecutable.resolve(basePath);

        GeneralCommandLine cmd = new GeneralCommandLine(exe, "run");
        if (config.isUseVm()) {
            cmd.addParameter("--vm");
        }
        cmd.addParameter(config.getFilePath());

        // Run from the file's directory so relative imports resolve.
        File file = new File(config.getFilePath());
        File dir = file.getParentFile();
        cmd.setWorkDirectory(dir != null ? dir : (basePath != null ? new File(basePath) : null));
        cmd.setCharset(java.nio.charset.StandardCharsets.UTF_8);

        OSProcessHandler handler = new OSProcessHandler(cmd);
        ProcessTerminatedListener.attach(handler);
        return handler;
    }
}
