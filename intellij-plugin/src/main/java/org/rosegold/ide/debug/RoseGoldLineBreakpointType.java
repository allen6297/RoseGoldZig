package org.rosegold.ide.debug;

import com.intellij.openapi.project.Project;
import com.intellij.openapi.vfs.VirtualFile;
import com.intellij.xdebugger.breakpoints.XBreakpointProperties;
import com.intellij.xdebugger.breakpoints.XLineBreakpointType;
import org.jetbrains.annotations.NotNull;
import org.jetbrains.annotations.Nullable;
import org.rosegold.ide.RoseGoldFileType;

/** Allows line breakpoints in `.rg` files (in the gutter). */
public final class RoseGoldLineBreakpointType extends XLineBreakpointType<XBreakpointProperties<?>> {
    public RoseGoldLineBreakpointType() {
        super("rosegold-line", "RoseGold Breakpoints");
    }

    @Override
    public boolean canPutAt(@NotNull VirtualFile file, int line, @NotNull Project project) {
        return file.getFileType() == RoseGoldFileType.INSTANCE;
    }

    @Override
    public @Nullable XBreakpointProperties<?> createBreakpointProperties(@NotNull VirtualFile file, int line) {
        return null;
    }
}
