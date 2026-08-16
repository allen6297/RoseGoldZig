package org.rosegold.ide.debug;

import com.intellij.icons.AllIcons;
import com.intellij.xdebugger.frame.XExecutionStack;
import com.intellij.xdebugger.frame.XStackFrame;
import com.intellij.xdebugger.frame.XSuspendContext;
import org.jetbrains.annotations.NotNull;
import org.jetbrains.annotations.Nullable;

import java.util.List;

/** The paused state: a single execution stack built from the DAP backtrace. */
public final class RoseGoldSuspendContext extends XSuspendContext {
    private final Stack stack;

    public RoseGoldSuspendContext(List<RoseGoldStackFrame> frames) {
        this.stack = new Stack(frames);
    }

    @Override
    public @Nullable XExecutionStack getActiveExecutionStack() {
        return stack;
    }

    @Override
    public XExecutionStack @NotNull [] getExecutionStacks() {
        return new XExecutionStack[]{stack};
    }

    private static final class Stack extends XExecutionStack {
        private final List<RoseGoldStackFrame> frames;

        Stack(List<RoseGoldStackFrame> frames) {
            super("main", AllIcons.Debugger.ThreadCurrent);
            this.frames = frames;
        }

        @Override
        public @Nullable XStackFrame getTopFrame() {
            return frames.isEmpty() ? null : frames.get(0);
        }

        @Override
        public void computeStackFrames(int firstFrameIndex, XStackFrameContainer container) {
            if (firstFrameIndex <= frames.size()) {
                container.addStackFrames(frames.subList(firstFrameIndex, frames.size()), true);
            } else {
                container.addStackFrames(List.of(), true);
            }
        }
    }
}
