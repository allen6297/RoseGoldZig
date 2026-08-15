package org.rosegold.ide;

import com.intellij.codeInsight.intention.IntentionAction;
import com.intellij.openapi.editor.Document;
import com.intellij.openapi.editor.Editor;
import com.intellij.openapi.project.Project;
import com.intellij.psi.PsiFile;
import com.intellij.util.IncorrectOperationException;
import org.jetbrains.annotations.NotNull;

/**
 * Quick-fix (Alt-Enter) that replaces the text at {@code [start, end)} with a
 * qualified form — e.g. an unresolved {@code Error} with {@code Global.Error},
 * where {@code Global} is an imported module that exports {@code Error}.
 */
public final class RoseGoldQualifyFix implements IntentionAction {
    private final int start;
    private final int end;
    private final String replacement;

    public RoseGoldQualifyFix(int start, int end, String replacement) {
        this.start = start;
        this.end = end;
        this.replacement = replacement;
    }

    @Override
    public @NotNull String getText() {
        return "Qualify as '" + replacement + "'";
    }

    @Override
    public @NotNull String getFamilyName() {
        return "RoseGold";
    }

    @Override
    public boolean isAvailable(@NotNull Project project, Editor editor, PsiFile file) {
        return editor != null && end <= editor.getDocument().getTextLength() && start < end;
    }

    @Override
    public boolean startInWriteAction() {
        return true;
    }

    @Override
    public void invoke(@NotNull Project project, Editor editor, PsiFile file) throws IncorrectOperationException {
        if (editor == null) {
            return;
        }
        Document doc = editor.getDocument();
        if (start < end && end <= doc.getTextLength()) {
            doc.replaceString(start, end, replacement);
        }
    }
}
