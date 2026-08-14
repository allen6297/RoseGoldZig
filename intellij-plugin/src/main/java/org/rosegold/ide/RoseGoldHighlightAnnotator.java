package org.rosegold.ide;

import com.intellij.lang.annotation.AnnotationHolder;
import com.intellij.lang.annotation.Annotator;
import com.intellij.lang.annotation.HighlightSeverity;
import com.intellij.openapi.editor.colors.TextAttributesKey;
import com.intellij.psi.PsiElement;
import com.intellij.psi.util.PsiTreeUtil;
import org.jetbrains.annotations.NotNull;
import org.jetbrains.annotations.Nullable;

/**
 * Context-sensitive coloring the lexer can't do on its own: an identifier right
 * after the {@code func} keyword is a function <i>declaration</i>; an identifier
 * immediately followed by {@code (} is a function <i>call</i>. Runs over the PSI,
 * so it has the neighbor context a single-token highlighter lacks.
 */
public final class RoseGoldHighlightAnnotator implements Annotator {
    @Override
    public void annotate(@NotNull PsiElement element, @NotNull AnnotationHolder holder) {
        if (element.getNode() == null || element.getNode().getElementType() != RoseGoldTokenTypes.IDENTIFIER) {
            return;
        }

        final TextAttributesKey key;
        if (isKeyword(PsiTreeUtil.prevVisibleLeaf(element), "func")) {
            key = RoseGoldSyntaxHighlighter.FUN_DEF;
        } else if (isType(PsiTreeUtil.nextVisibleLeaf(element), RoseGoldTokenTypes.LPAREN)) {
            key = RoseGoldSyntaxHighlighter.FUN_CALL;
        } else {
            return;
        }

        holder.newSilentAnnotation(HighlightSeverity.INFORMATION)
                .range(element)
                .textAttributes(key)
                .create();
    }

    private static boolean isKeyword(@Nullable PsiElement leaf, @NotNull String text) {
        return leaf != null
                && leaf.getNode() != null
                && leaf.getNode().getElementType() == RoseGoldTokenTypes.KEYWORD
                && text.equals(leaf.getText());
    }

    private static boolean isType(@Nullable PsiElement leaf, Object tokenType) {
        return leaf != null && leaf.getNode() != null && leaf.getNode().getElementType() == tokenType;
    }
}
