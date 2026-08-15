package org.rosegold.ide;

import com.intellij.codeInsight.AutoPopupController;
import com.intellij.codeInsight.editorActions.TypedHandlerDelegate;
import com.intellij.openapi.editor.Editor;
import com.intellij.openapi.project.Project;
import com.intellij.psi.PsiFile;
import org.jetbrains.annotations.NotNull;

/**
 * Opens the completion popup automatically after a `.` in a RoseGold file, so
 * module-member completion (e.g. `lists.<caret>`) appears without Ctrl-Space.
 */
public final class RoseGoldTypedHandler extends TypedHandlerDelegate {
    @Override
    public @NotNull Result checkAutoPopup(char charTyped, @NotNull Project project,
                                          @NotNull Editor editor, @NotNull PsiFile file) {
        if (charTyped == '.' && file instanceof RoseGoldFile) {
            AutoPopupController.getInstance(project).autoPopupMemberLookup(editor, null);
            return Result.STOP;
        }
        return Result.CONTINUE;
    }
}
