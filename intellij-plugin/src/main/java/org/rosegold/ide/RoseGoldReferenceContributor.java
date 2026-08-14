package org.rosegold.ide;

import com.intellij.patterns.PlatformPatterns;
import com.intellij.psi.PsiElement;
import com.intellij.psi.PsiReference;
import com.intellij.psi.PsiReferenceContributor;
import com.intellij.psi.PsiReferenceProvider;
import com.intellij.psi.PsiReferenceRegistrar;
import com.intellij.util.ProcessingContext;
import org.jetbrains.annotations.NotNull;

/** Gives every identifier a reference to its declaration (see {@link RoseGoldReference}). */
public final class RoseGoldReferenceContributor extends PsiReferenceContributor {
    @Override
    public void registerReferenceProviders(@NotNull PsiReferenceRegistrar registrar) {
        registrar.registerReferenceProvider(
                PlatformPatterns.psiElement().withElementType(RoseGoldTokenTypes.IDENTIFIER),
                new PsiReferenceProvider() {
                    @Override
                    public PsiReference @NotNull [] getReferencesByElement(@NotNull PsiElement element,
                                                                          @NotNull ProcessingContext context) {
                        if (!(element.getContainingFile() instanceof RoseGoldFile)) {
                            return PsiReference.EMPTY_ARRAY;
                        }
                        return new PsiReference[]{new RoseGoldReference(element)};
                    }
                });
    }
}
