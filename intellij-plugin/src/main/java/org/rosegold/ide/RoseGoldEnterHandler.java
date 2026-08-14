package org.rosegold.ide;

import com.intellij.codeInsight.editorActions.enter.EnterHandlerDelegateAdapter;
import com.intellij.openapi.actionSystem.DataContext;
import com.intellij.openapi.editor.Document;
import com.intellij.openapi.editor.Editor;
import com.intellij.openapi.util.TextRange;
import com.intellij.psi.PsiFile;
import org.jetbrains.annotations.NotNull;

/** After Enter on a line whose code ends with `:`, add one indentation level. */
public final class RoseGoldEnterHandler extends EnterHandlerDelegateAdapter {
    private static final String INDENT_UNIT = "    ";

    @Override
    public Result postProcessEnter(@NotNull PsiFile file, @NotNull Editor editor, @NotNull DataContext dataContext) {
        if (!(file instanceof RoseGoldFile)) {
            return Result.Continue;
        }
        Document doc = editor.getDocument();
        int caret = editor.getCaretModel().getOffset();
        int line = doc.getLineNumber(caret);
        if (line == 0) {
            return Result.Continue;
        }
        int prev = line - 1;
        String prevText = doc.getText(new TextRange(doc.getLineStartOffset(prev), doc.getLineEndOffset(prev)));
        if (codeEndsWithColon(prevText)) {
            doc.insertString(caret, INDENT_UNIT);
            editor.getCaretModel().moveToOffset(caret + INDENT_UNIT.length());
            return Result.Stop;
        }
        return Result.Continue;
    }

    private static boolean codeEndsWithColon(String line) {
        int hash = line.indexOf("##");
        String code = (hash >= 0 ? line.substring(0, hash) : line).stripTrailing();
        return code.endsWith(":");
    }
}
