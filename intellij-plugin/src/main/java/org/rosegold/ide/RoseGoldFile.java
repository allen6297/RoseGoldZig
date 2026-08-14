package org.rosegold.ide;

import com.intellij.extapi.psi.PsiFileBase;
import com.intellij.openapi.fileTypes.FileType;
import com.intellij.psi.FileViewProvider;
import org.jetbrains.annotations.NotNull;

public final class RoseGoldFile extends PsiFileBase {
    public RoseGoldFile(@NotNull FileViewProvider viewProvider) {
        super(viewProvider, RoseGoldLanguage.INSTANCE);
    }

    @Override
    public @NotNull FileType getFileType() {
        return RoseGoldFileType.INSTANCE;
    }

    @Override
    public String toString() {
        return "RoseGold File";
    }
}
