package org.rosegold.ide;

import com.intellij.lang.ASTNode;
import com.intellij.lang.folding.FoldingBuilderEx;
import com.intellij.lang.folding.FoldingDescriptor;
import com.intellij.openapi.editor.Document;
import com.intellij.openapi.project.DumbAware;
import com.intellij.openapi.util.TextRange;
import com.intellij.psi.PsiElement;
import org.jetbrains.annotations.NotNull;
import org.jetbrains.annotations.Nullable;

import java.util.ArrayList;
import java.util.List;
import java.util.regex.Pattern;

/**
 * Folds the indented body of a `func`/`class`/`struct`/`enum` colon-block. Works
 * off the document's lines and indentation, so it needs no real grammar.
 */
public final class RoseGoldFoldingBuilder extends FoldingBuilderEx implements DumbAware {
    private static final Pattern HEADER =
            Pattern.compile("^(?:pub\\s+|private\\s+)?(?:static\\s+)?(?:func|class|struct|enum)\\b");

    @Override
    public FoldingDescriptor @NotNull [] buildFoldRegions(@NotNull PsiElement root,
                                                          @NotNull Document document,
                                                          boolean quick) {
        List<FoldingDescriptor> result = new ArrayList<>();
        ASTNode rootNode = root.getNode();
        if (rootNode == null) {
            return FoldingDescriptor.EMPTY_ARRAY;
        }
        int lineCount = document.getLineCount();
        for (int i = 0; i < lineCount; i++) {
            String line = lineText(document, i);
            String code = codeOf(line);
            if (!HEADER.matcher(code).find() || !code.endsWith(":")) {
                continue;
            }
            int headerIndent = indentOf(line);
            int blockEnd = -1;
            for (int j = i + 1; j < lineCount; j++) {
                String l = lineText(document, j);
                if (l.strip().isEmpty()) {
                    continue; // internal blank lines belong to the block
                }
                if (indentOf(l) > headerIndent) {
                    blockEnd = j;
                } else {
                    break;
                }
            }
            if (blockEnd > i) {
                int start = document.getLineEndOffset(i);
                int end = document.getLineEndOffset(blockEnd);
                if (end > start) {
                    result.add(new FoldingDescriptor(rootNode, new TextRange(start, end)));
                }
            }
        }
        return result.toArray(FoldingDescriptor.EMPTY_ARRAY);
    }

    @Override
    public @Nullable String getPlaceholderText(@NotNull ASTNode node) {
        return " ...";
    }

    @Override
    public boolean isCollapsedByDefault(@NotNull ASTNode node) {
        return false;
    }

    private static String lineText(Document document, int line) {
        return document.getText(new TextRange(document.getLineStartOffset(line), document.getLineEndOffset(line)));
    }

    private static String codeOf(String line) {
        int hash = line.indexOf("##");
        return (hash >= 0 ? line.substring(0, hash) : line).strip();
    }

    private static int indentOf(String line) {
        int i = 0;
        while (i < line.length() && Character.isWhitespace(line.charAt(i))) {
            i++;
        }
        return i;
    }
}
