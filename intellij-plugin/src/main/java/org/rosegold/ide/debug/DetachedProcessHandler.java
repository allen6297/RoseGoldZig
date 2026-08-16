package org.rosegold.ide.debug;

import com.intellij.execution.process.ProcessHandler;
import org.jetbrains.annotations.Nullable;

import java.io.OutputStream;

/**
 * A ProcessHandler for the `dap` subprocess that does NOT read its stdout — the
 * {@link DapClient} owns that stream for the protocol. It only manages lifecycle
 * (stop button, termination), waiting for the process to exit in a thread.
 */
public final class DetachedProcessHandler extends ProcessHandler {
    private final Process process;

    public DetachedProcessHandler(Process process) {
        this.process = process;
    }

    @Override
    public void startNotify() {
        super.startNotify();
        Thread waiter = new Thread(() -> {
            try {
                int code = process.waitFor();
                notifyProcessTerminated(code);
            } catch (InterruptedException e) {
                notifyProcessTerminated(-1);
            }
        }, "rosegold-dap-waiter");
        waiter.setDaemon(true);
        waiter.start();
    }

    @Override
    protected void destroyProcessImpl() {
        process.destroyForcibly();
    }

    @Override
    protected void detachProcessImpl() {
        notifyProcessDetached();
    }

    @Override
    public boolean detachIsDefault() {
        return false;
    }

    @Override
    public @Nullable OutputStream getProcessInput() {
        return null;
    }
}
