package org.rosegold.ide;

import com.intellij.openapi.application.ApplicationManager;
import com.intellij.openapi.components.PersistentStateComponent;
import com.intellij.openapi.components.State;
import com.intellij.openapi.components.Storage;
import com.intellij.util.xmlb.XmlSerializerUtil;
import org.jetbrains.annotations.NotNull;
import org.jetbrains.annotations.Nullable;

/** Application-wide settings: where to find the {@code RoseGold_Zig} executable. */
@State(name = "RoseGoldSettings", storages = @Storage("rosegold.xml"))
public final class RoseGoldSettings implements PersistentStateComponent<RoseGoldSettings> {
    /** Absolute path to the executable; blank means "resolve automatically". */
    public String executablePath = "";

    public static RoseGoldSettings getInstance() {
        return ApplicationManager.getApplication().getService(RoseGoldSettings.class);
    }

    @Override
    public @Nullable RoseGoldSettings getState() {
        return this;
    }

    @Override
    public void loadState(@NotNull RoseGoldSettings state) {
        XmlSerializerUtil.copyBean(state, this);
    }
}
