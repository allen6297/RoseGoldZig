package org.rosegold.ide;

import com.intellij.openapi.fileTypes.LanguageFileType;
import org.jetbrains.annotations.NotNull;

import javax.swing.Icon;

public final class RoseGoldFileType extends LanguageFileType {
    public static final RoseGoldFileType INSTANCE = new RoseGoldFileType();

    private RoseGoldFileType() {
        super(RoseGoldLanguage.INSTANCE);
    }

    @Override
    public @NotNull String getName() {
        return "RoseGold";
    }

    @Override
    public @NotNull String getDescription() {
        return "RoseGold source file";
    }

    @Override
    public @NotNull String getDefaultExtension() {
        return "rg";
    }

    @Override
    public Icon getIcon() {
        return RoseGoldIcons.FILE;
    }
}
