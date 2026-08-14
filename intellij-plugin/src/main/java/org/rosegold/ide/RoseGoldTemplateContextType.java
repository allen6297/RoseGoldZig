package org.rosegold.ide;

import com.intellij.codeInsight.template.TemplateActionContext;
import com.intellij.codeInsight.template.TemplateContextType;
import org.jetbrains.annotations.NotNull;

/** Makes RoseGold live templates available inside `.rg` files. */
public final class RoseGoldTemplateContextType extends TemplateContextType {
    public RoseGoldTemplateContextType() {
        super("RoseGold");
    }

    @Override
    public boolean isInContext(@NotNull TemplateActionContext templateActionContext) {
        return templateActionContext.getFile() instanceof RoseGoldFile;
    }
}
