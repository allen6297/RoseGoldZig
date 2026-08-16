package org.rosegold.ide.debug;

import com.intellij.openapi.editor.Document;
import com.intellij.openapi.editor.EditorFactory;
import com.intellij.openapi.fileTypes.FileType;
import com.intellij.openapi.project.Project;
import com.intellij.xdebugger.XExpression;
import com.intellij.xdebugger.XSourcePosition;
import com.intellij.xdebugger.evaluation.EvaluationMode;
import com.intellij.xdebugger.evaluation.XDebuggerEditorsProvider;
import org.jetbrains.annotations.NotNull;
import org.rosegold.ide.RoseGoldFileType;

/** Minimal editors provider (used by the expression-evaluation / breakpoint UI). */
public final class RoseGoldDebuggerEditorsProvider extends XDebuggerEditorsProvider {
    @Override
    public @NotNull FileType getFileType() {
        return RoseGoldFileType.INSTANCE;
    }

    @Override
    public @NotNull Document createDocument(@NotNull Project project,
                                            @NotNull XExpression expression,
                                            XSourcePosition sourcePosition,
                                            @NotNull EvaluationMode mode) {
        return EditorFactory.getInstance().createDocument(expression.getExpression());
    }
}
