package org.rosegold.ide;

import com.intellij.openapi.actionSystem.CommonDataKeys;
import com.intellij.openapi.actionSystem.DataContext;
import com.intellij.openapi.command.WriteCommandAction;
import com.intellij.openapi.editor.Document;
import com.intellij.openapi.editor.Editor;
import com.intellij.openapi.project.Project;
import com.intellij.openapi.ui.InputValidator;
import com.intellij.openapi.ui.Messages;
import com.intellij.openapi.util.TextRange;
import com.intellij.psi.PsiElement;
import com.intellij.psi.PsiFile;
import com.intellij.refactoring.rename.RenameHandler;
import org.jetbrains.annotations.NotNull;
import org.jetbrains.annotations.Nullable;

import java.util.ArrayList;
import java.util.List;
import java.util.Set;

/**
 * A text-based Rename (Shift+F6) for RoseGold. The flat PSI has no named
 * elements or real references, so instead of the reference-driven refactoring we
 * find the identifier under the caret, collect every whole-word occurrence in the
 * file — skipping {@code ##} comments and string text, but including identifiers
 * inside {@code ${…}} interpolation holes — and replace them all in one command.
 *
 * <p>Whole-file scope (matching the same-file navigation the plugin already
 * provides); shadowed locals in different scopes aren't distinguished.
 */
public final class RoseGoldRenameHandler implements RenameHandler {
    private static final Set<String> KEYWORDS = Set.of(
            "import", "class", "struct", "extends", "uses", "func", "var", "const",
            "enum", "if", "elif", "else", "match", "for", "in", "while", "break",
            "continue", "return", "pass", "nil", "pub", "private", "static", "true",
            "false", "and", "or", "not", "signal", "try", "catch", "raise", "async",
            "await", "int", "float", "str", "bool", "void", "any", "list", "map", "task");

    @Override
    public boolean isAvailableOnDataContext(@NotNull DataContext dataContext) {
        Editor editor = CommonDataKeys.EDITOR.getData(dataContext);
        PsiFile file = CommonDataKeys.PSI_FILE.getData(dataContext);
        if (editor == null || !(file instanceof RoseGoldFile)) {
            return false;
        }
        return identAt(editor.getDocument().getCharsSequence(), editor.getCaretModel().getOffset()) != null;
    }

    @Override
    public void invoke(@NotNull Project project, @NotNull Editor editor, PsiFile file, DataContext dataContext) {
        if (!(file instanceof RoseGoldFile)) {
            return;
        }
        Document doc = editor.getDocument();
        CharSequence text = doc.getCharsSequence();
        TextRange word = identAt(text, editor.getCaretModel().getOffset());
        if (word == null) {
            return;
        }
        final String oldName = text.subSequence(word.getStartOffset(), word.getEndOffset()).toString();
        if (KEYWORDS.contains(oldName)) {
            return;
        }
        String newName = Messages.showInputDialog(project,
                "Rename '" + oldName + "' to:", "Rename", null, oldName, new NameValidator());
        if (newName == null || newName.isEmpty() || newName.equals(oldName)) {
            return;
        }
        List<TextRange> hits = occurrences(text, oldName);
        WriteCommandAction.runWriteCommandAction(project, "Rename " + oldName, null, () -> {
            // Replace back-to-front so earlier offsets stay valid.
            for (int k = hits.size() - 1; k >= 0; k--) {
                TextRange r = hits.get(k);
                doc.replaceString(r.getStartOffset(), r.getEndOffset(), newName);
            }
        }, file);
    }

    @Override
    public void invoke(@NotNull Project project, PsiElement @NotNull [] elements, DataContext dataContext) {
        // Rename is only offered from the editor (isAvailableOnDataContext), so
        // there's nothing to do for a pre-selected element set.
    }

    /** The identifier range covering (or immediately left of) `offset`, or null. */
    private static @Nullable TextRange identAt(CharSequence text, int offset) {
        int n = text.length();
        int start = offset;
        while (start > 0 && isIdentChar(text.charAt(start - 1))) {
            start--;
        }
        int end = offset;
        while (end < n && isIdentChar(text.charAt(end))) {
            end++;
        }
        if (end == start) {
            return null;
        }
        // The first char must be an identifier start (not a digit), so we don't
        // treat a number under the caret as a name.
        char c0 = text.charAt(start);
        if (!(c0 == '_' || Character.isLetter(c0))) {
            return null;
        }
        return new TextRange(start, end);
    }

    /**
     * Every whole-word occurrence of `name` in code — skipping `##` comments and
     * string literals, but scanning inside `${…}` interpolation holes (which, per
     * the language, contain no nested strings).
     */
    private static List<TextRange> occurrences(CharSequence text, String name) {
        List<TextRange> out = new ArrayList<>();
        int n = text.length();
        int i = 0;
        boolean inString = false;
        int holeDepth = 0;
        while (i < n) {
            char c = text.charAt(i);
            if (!inString) {
                if (c == '#' && i + 1 < n && text.charAt(i + 1) == '#') {
                    while (i < n && text.charAt(i) != '\n') i++;
                    continue;
                }
                if (c == '"') {
                    inString = true;
                    i++;
                    continue;
                }
                if (isIdentStart(c)) {
                    i = scanIdent(text, i, name, out);
                    continue;
                }
                i++;
            } else if (holeDepth > 0) {
                // Inside ${…}: real code (no nested strings).
                if (c == '{') {
                    holeDepth++;
                    i++;
                } else if (c == '}') {
                    holeDepth--;
                    i++;
                } else if (isIdentStart(c)) {
                    i = scanIdent(text, i, name, out);
                } else {
                    i++;
                }
            } else {
                // Inside string text.
                if (c == '\\') {
                    i += 2;
                } else if (c == '"') {
                    inString = false;
                    i++;
                } else if (c == '$' && i + 1 < n && text.charAt(i + 1) == '{') {
                    holeDepth = 1;
                    i += 2;
                } else {
                    i++;
                }
            }
        }
        return out;
    }

    /** Read the identifier starting at `i`; record its range if it equals `name`. */
    private static int scanIdent(CharSequence text, int i, String name, List<TextRange> out) {
        int start = i;
        int n = text.length();
        while (i < n && isIdentChar(text.charAt(i))) {
            i++;
        }
        if (name.contentEquals(text.subSequence(start, i))) {
            out.add(new TextRange(start, i));
        }
        return i;
    }

    private static boolean isIdentChar(char c) {
        return c == '_' || Character.isLetterOrDigit(c);
    }

    private static boolean isIdentStart(char c) {
        return c == '_' || Character.isLetter(c);
    }

    /** Accepts a valid RoseGold identifier that isn't a language keyword. */
    private static final class NameValidator implements InputValidator {
        @Override
        public boolean checkInput(String input) {
            if (input == null || input.isEmpty() || KEYWORDS.contains(input) || !isIdentStart(input.charAt(0))) {
                return false;
            }
            for (int k = 1; k < input.length(); k++) {
                if (!isIdentChar(input.charAt(k))) {
                    return false;
                }
            }
            return true;
        }

        @Override
        public boolean canClose(String input) {
            return checkInput(input);
        }
    }
}
