package org.rosegold.ide;

import com.intellij.openapi.util.TextRange;
import com.intellij.psi.PsiElement;
import com.intellij.psi.PsiFile;
import com.intellij.psi.PsiReferenceBase;
import org.jetbrains.annotations.Nullable;

/**
 * Resolves an identifier to a same-named top-level or class-member declaration
 * found by {@link RoseGoldDeclarations}. Enough for go-to-declaration and the
 * editor's automatic "highlight usages of this declaration" pass. Locals and
 * parameters aren't scanned, so those simply don't resolve (no false jump).
 */
public final class RoseGoldReference extends PsiReferenceBase<PsiElement> {
    private final String name;

    public RoseGoldReference(PsiElement element) {
        super(element, new TextRange(0, element.getTextLength()));
        this.name = element.getText();
    }

    @Override
    public @Nullable PsiElement resolve() {
        PsiFile file = myElement.getContainingFile();
        if (file == null) {
            return null;
        }
        CharSequence text = file.getViewProvider().getContents();

        // Cross-module: `mod.member` jumps to the `pub` declaration of `member`
        // in the imported module's file.
        int start = myElement.getTextRange().getStartOffset();
        if (start >= 2 && text.charAt(start - 1) == '.') {
            int j = start - 1;
            int k = j;
            while (k > 0 && isIdentChar(text.charAt(k - 1))) {
                k--;
            }
            if (k < j) {
                String receiver = text.subSequence(k, j).toString();
                String[] segs = RoseGoldModules.importSegments(text, receiver);
                if (segs != null) {
                    com.intellij.openapi.vfs.VirtualFile vf = RoseGoldModules.resolveModuleFile(file, segs);
                    if (vf != null) {
                        PsiFile modPsi = com.intellij.psi.PsiManager.getInstance(file.getProject()).findFile(vf);
                        if (modPsi != null) {
                            CharSequence modText = modPsi.getViewProvider().getContents();
                            for (RoseGoldDeclaration d : RoseGoldDeclarations.scan(modText)) {
                                if (d.name.equals(name) && d.isPublic) {
                                    return modPsi.findElementAt(d.nameOffset);
                                }
                            }
                        }
                    }
                }
            }
        }

        RoseGoldDeclaration best = null;
        for (RoseGoldDeclaration d : RoseGoldDeclarations.scanFlat(text)) {
            if (d.name.equals(name)) {
                // Prefer the declaration itself when the caret is on it; otherwise
                // the first match (top-level scan order) is the natural target.
                if (d.nameOffset == myElement.getTextRange().getStartOffset()) {
                    return file.findElementAt(d.nameOffset);
                }
                if (best == null) {
                    best = d;
                }
            }
        }
        return best == null ? null : file.findElementAt(best.nameOffset);
    }

    private static boolean isIdentChar(char c) {
        return c == '_' || Character.isLetterOrDigit(c);
    }

    @Override
    public Object @org.jetbrains.annotations.NotNull [] getVariants() {
        return EMPTY_ARRAY;
    }
}
