package org.rosegold.ide;

import com.intellij.execution.lineMarker.ExecutorAction;
import com.intellij.execution.lineMarker.RunLineMarkerContributor;
import com.intellij.icons.AllIcons;
import com.intellij.openapi.actionSystem.AnAction;
import com.intellij.psi.PsiElement;
import com.intellij.util.Function;
import org.jetbrains.annotations.Nullable;

import java.util.regex.Pattern;

/**
 * A gutter Run/Debug icon next to a top-level `func main()` — clicking it builds
 * (via {@link org.rosegold.ide.run.RoseGoldRunConfigurationProducer}) and runs
 * the file. The icon anchors on the `main` identifier leaf of the declaration.
 */
public final class RoseGoldRunLineMarkerContributor extends RunLineMarkerContributor {
    private static final Pattern MAIN_DECL =
            Pattern.compile("^(?:pub\\s+|private\\s+)?func\\s+main\\s*\\(");

    @Override
    public @Nullable Info getInfo(PsiElement element) {
        if (!(element.getContainingFile() instanceof RoseGoldFile)) {
            return null;
        }
        if (element.getNode() == null || element.getNode().getElementType() != RoseGoldTokenTypes.IDENTIFIER) {
            return null;
        }
        if (!"main".equals(element.getText())) {
            return null;
        }
        if (!isTopLevelMainDeclaration(element)) {
            return null;
        }
        AnAction[] actions = ExecutorAction.getActions(0);
        Function<PsiElement, String> tooltip = e -> "Run / Debug this RoseGold file";
        return new Info(AllIcons.RunConfigurations.TestState.Run, actions, tooltip);
    }

    /** True when `element` is the name of a `func main(` at column 0. */
    private static boolean isTopLevelMainDeclaration(PsiElement element) {
        CharSequence text = element.getContainingFile().getViewProvider().getContents();
        int offset = element.getTextRange().getStartOffset();
        int lineStart = offset;
        while (lineStart > 0 && text.charAt(lineStart - 1) != '\n') {
            lineStart--;
        }
        int lineEnd = offset;
        int n = text.length();
        while (lineEnd < n && text.charAt(lineEnd) != '\n') {
            lineEnd++;
        }
        String line = text.subSequence(lineStart, lineEnd).toString();
        return MAIN_DECL.matcher(line).find();
    }
}
