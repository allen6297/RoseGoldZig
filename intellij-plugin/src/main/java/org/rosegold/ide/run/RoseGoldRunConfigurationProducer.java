package org.rosegold.ide.run;

import com.intellij.execution.actions.ConfigurationContext;
import com.intellij.execution.actions.LazyRunConfigurationProducer;
import com.intellij.execution.configurations.ConfigurationFactory;
import com.intellij.openapi.util.Ref;
import com.intellij.openapi.vfs.VirtualFile;
import com.intellij.psi.PsiElement;
import com.intellij.psi.PsiFile;
import org.jetbrains.annotations.NotNull;
import org.rosegold.ide.RoseGoldFile;

/** Lets you Run/Debug a .rg file from the editor gutter or right-click menu. */
public final class RoseGoldRunConfigurationProducer extends LazyRunConfigurationProducer<RoseGoldRunConfiguration> {
    @Override
    public @NotNull ConfigurationFactory getConfigurationFactory() {
        return RoseGoldRunConfigurationType.getInstance().getConfigurationFactories()[0];
    }

    @Override
    protected boolean setupConfigurationFromContext(@NotNull RoseGoldRunConfiguration configuration,
                                                    @NotNull ConfigurationContext context,
                                                    @NotNull Ref<PsiElement> sourceElement) {
        PsiFile file = psiFile(context);
        if (file == null) {
            return false;
        }
        VirtualFile vf = file.getVirtualFile();
        if (vf == null) {
            return false;
        }
        configuration.setFilePath(vf.getPath());
        configuration.setName(vf.getName());
        return true;
    }

    @Override
    public boolean isConfigurationFromContext(@NotNull RoseGoldRunConfiguration configuration,
                                              @NotNull ConfigurationContext context) {
        PsiFile file = psiFile(context);
        if (file == null) {
            return false;
        }
        VirtualFile vf = file.getVirtualFile();
        return vf != null && vf.getPath().equals(configuration.getFilePath());
    }

    private static PsiFile psiFile(ConfigurationContext context) {
        PsiElement location = context.getPsiLocation();
        if (location == null) {
            return null;
        }
        PsiFile file = location.getContainingFile();
        return (file instanceof RoseGoldFile) ? file : null;
    }
}
