package org.rosegold.ide;

import com.intellij.codeInsight.completion.CompletionContributor;
import com.intellij.codeInsight.completion.CompletionParameters;
import com.intellij.codeInsight.completion.CompletionProvider;
import com.intellij.codeInsight.completion.CompletionResultSet;
import com.intellij.codeInsight.completion.CompletionType;
import com.intellij.codeInsight.lookup.LookupElementBuilder;
import com.intellij.openapi.editor.Editor;
import com.intellij.openapi.util.io.FileUtil;
import com.intellij.openapi.vfs.VirtualFile;
import com.intellij.patterns.PlatformPatterns;
import com.intellij.util.ProcessingContext;
import org.jetbrains.annotations.NotNull;

import java.io.File;
import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public final class RoseGoldCompletionContributor extends CompletionContributor {
    private static final String[] KEYWORDS = {
            "import", "class", "struct", "extends", "uses", "func", "var", "const",
            "enum", "if", "elif", "else", "match", "for", "in", "while", "break",
            "continue", "return", "pass", "nil", "pub", "private", "static", "true",
            "false", "and", "or", "not", "signal", "try", "catch", "raise", "async",
            "await",
            "int", "float", "str", "bool", "void", "any", "list", "map", "task",
    };

    private static final String[] BUILTINS = {
            "print", "echo", "len", "range", "str", "int", "float", "push", "pop",
            "keys", "values", "has", "connect", "emit", "abs", "min", "max", "upper",
            "lower", "split", "join", "contains", "sort", "reverse", "trim",
            "starts_with", "ends_with", "find", "replace", "map", "filter", "reduce",
            "sqrt", "pow", "floor", "ceil", "round", "gather",
    };

    // `import a.b.c` — captures the dotted path (leaf = module namespace name).
    private static final Pattern IMPORT =
            Pattern.compile("^\\s*import\\s+([A-Za-z_][A-Za-z0-9_.]*)", Pattern.MULTILINE);
    // A `pub` top-level declaration (what another module can see).
    private static final Pattern PUB_DECL = Pattern.compile(
            "^pub\\s+(?:static\\s+)?(enum|class|struct|func|const|var|signal)\\s+([A-Za-z_][A-Za-z0-9_]*)",
            Pattern.MULTILINE);
    // Any top-level declaration in the current file (for local suggestions).
    private static final Pattern ANY_DECL = Pattern.compile(
            "^(?:pub\\s+|private\\s+)?(?:static\\s+)?(enum|class|struct|func|const|var|signal)\\s+([A-Za-z_][A-Za-z0-9_]*)",
            Pattern.MULTILINE);

    public RoseGoldCompletionContributor() {
        extend(CompletionType.BASIC,
                PlatformPatterns.psiElement().withLanguage(RoseGoldLanguage.INSTANCE),
                new CompletionProvider<>() {
                    @Override
                    protected void addCompletions(@NotNull CompletionParameters parameters,
                                                  @NotNull ProcessingContext context,
                                                  @NotNull CompletionResultSet result) {
                        Editor editor = parameters.getEditor();
                        String text = editor.getDocument().getText();
                        int offset = parameters.getOffset();

                        // If the caret is right after `receiver.`, suggest the members
                        // of that module (its `pub` exports) — nothing else.
                        int i = offset;
                        while (i > 0 && isIdentChar(text.charAt(i - 1))) i--;
                        if (i > 0 && text.charAt(i - 1) == '.') {
                            int dot = i - 1;
                            int j = dot;
                            while (j > 0 && isIdentChar(text.charAt(j - 1))) j--;
                            String receiver = text.substring(j, dot);
                            addModuleMembers(parameters, text, receiver, result);
                            return;
                        }

                        // Plain context: keywords, stdlib builtins, and this file's own
                        // top-level declarations.
                        for (String kw : KEYWORDS) {
                            result.addElement(LookupElementBuilder.create(kw).bold());
                        }
                        for (String b : BUILTINS) {
                            result.addElement(LookupElementBuilder.create(b).withTypeText("builtin", true));
                        }
                        Matcher dm = ANY_DECL.matcher(text);
                        while (dm.find()) {
                            result.addElement(LookupElementBuilder.create(dm.group(2))
                                    .withTypeText(dm.group(1), true));
                        }
                    }
                });
    }

    /** After `receiver.`: if `receiver` is an imported module, add its `pub` members. */
    private static void addModuleMembers(CompletionParameters parameters, String text,
                                         String receiver, CompletionResultSet result) {
        String[] segs = null;
        Matcher im = IMPORT.matcher(text);
        while (im.find()) {
            String[] s = im.group(1).split("\\.");
            if (s[s.length - 1].equals(receiver)) {
                segs = s;
                break;
            }
        }
        if (segs == null) {
            return;
        }
        File mod = resolveModuleFile(parameters, segs);
        if (mod == null) {
            return;
        }
        final String src;
        try {
            src = FileUtil.loadFile(mod);
        } catch (Exception e) {
            return;
        }
        Matcher pm = PUB_DECL.matcher(src);
        while (pm.find()) {
            result.addElement(LookupElementBuilder.create(pm.group(2))
                    .withTypeText(receiver + " " + pm.group(1), true));
        }
    }

    /** Resolve `a.b.c` → the `a/b/c.rg` file: importer dir, project base, a few ancestors. */
    private static File resolveModuleFile(CompletionParameters parameters, String[] segs) {
        String rel = String.join(File.separator, segs) + ".rg";
        List<File> bases = new ArrayList<>();
        VirtualFile vf = parameters.getOriginalFile().getVirtualFile();
        if (vf != null && vf.getParent() != null) {
            File dir = new File(vf.getParent().getPath());
            bases.add(dir);
            File up = dir;
            for (int k = 0; k < 4 && up != null; k++) {
                up = up.getParentFile();
                if (up != null) {
                    bases.add(up);
                }
            }
        }
        String base = parameters.getOriginalFile().getProject().getBasePath();
        if (base != null) {
            bases.add(new File(base));
        }
        for (File b : bases) {
            File f = new File(b, rel);
            if (f.isFile()) {
                return f;
            }
        }
        return null;
    }

    private static boolean isIdentChar(char c) {
        return c == '_' || Character.isLetterOrDigit(c);
    }
}
