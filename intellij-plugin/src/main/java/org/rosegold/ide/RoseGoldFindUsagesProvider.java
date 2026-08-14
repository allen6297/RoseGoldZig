package org.rosegold.ide;

import com.intellij.lang.cacheBuilder.DefaultWordsScanner;
import com.intellij.lang.cacheBuilder.WordsScanner;
import com.intellij.lang.findUsages.FindUsagesProvider;
import com.intellij.psi.PsiElement;
import org.jetbrains.annotations.NotNull;
import org.jetbrains.annotations.Nullable;

/**
 * Powers Find Usages by indexing identifier words (via the RoseGold lexer) and
 * describing declaration elements. Resolution back to a declaration is handled
 * by {@link RoseGoldReference#resolve()}. Rename is intentionally not offered —
 * it needs a real named-element PSI tree rather than this flat token stream.
 */
public final class RoseGoldFindUsagesProvider implements FindUsagesProvider {
    @Override
    public @Nullable WordsScanner getWordsScanner() {
        return new DefaultWordsScanner(new RoseGoldLexer(),
                RoseGoldTokenTypes.IDENTIFIERS,
                RoseGoldTokenTypes.COMMENTS,
                RoseGoldTokenTypes.STRINGS);
    }

    @Override
    public boolean canFindUsagesFor(@NotNull PsiElement psiElement) {
        return psiElement.getNode() != null
                && psiElement.getNode().getElementType() == RoseGoldTokenTypes.IDENTIFIER;
    }

    @Override
    public @Nullable String getHelpId(@NotNull PsiElement psiElement) {
        return null;
    }

    @Override
    public @NotNull String getType(@NotNull PsiElement element) {
        CharSequence text = element.getContainingFile() == null
                ? null : element.getContainingFile().getViewProvider().getContents();
        if (text != null) {
            int offset = element.getTextRange().getStartOffset();
            for (RoseGoldDeclaration d : RoseGoldDeclarations.scanFlat(text)) {
                if (d.nameOffset == offset) {
                    return d.kind.name().toLowerCase();
                }
            }
        }
        return "identifier";
    }

    @Override
    public @NotNull String getDescriptiveName(@NotNull PsiElement element) {
        return element.getText();
    }

    @Override
    public @NotNull String getNodeText(@NotNull PsiElement element, boolean useFullName) {
        return element.getText();
    }
}
