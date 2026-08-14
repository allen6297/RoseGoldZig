package org.rosegold.ide;

import com.intellij.psi.tree.IElementType;
import org.jetbrains.annotations.NonNls;
import org.jetbrains.annotations.NotNull;

public final class RoseGoldTokenType extends IElementType {
    public RoseGoldTokenType(@NotNull @NonNls String debugName) {
        super(debugName, RoseGoldLanguage.INSTANCE);
    }

    @Override
    public String toString() {
        return "RoseGold:" + super.toString();
    }
}
