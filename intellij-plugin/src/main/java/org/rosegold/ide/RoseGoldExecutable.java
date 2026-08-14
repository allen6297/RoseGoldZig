package org.rosegold.ide;

import org.jetbrains.annotations.Nullable;

import java.io.File;

/** Resolves the RoseGold_Zig executable to invoke for `check` and `run`. */
public final class RoseGoldExecutable {
    private RoseGoldExecutable() {
    }

    /**
     * Resolution order: the configured path, then a project-local build
     * (`zig-out/bin/RoseGold_Zig`), then the bare name (found on PATH).
     */
    public static String resolve(@Nullable String projectBasePath) {
        String configured = RoseGoldSettings.getInstance().executablePath;
        if (configured != null && !configured.isBlank()) {
            return configured.trim();
        }
        if (projectBasePath != null) {
            File local = new File(projectBasePath, "zig-out/bin/RoseGold_Zig");
            if (local.canExecute()) {
                return local.getAbsolutePath();
            }
        }
        return "RoseGold_Zig";
    }
}
