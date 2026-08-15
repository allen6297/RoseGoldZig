package org.rosegold.ide;

import com.intellij.codeInsight.AutoPopupController;
import com.intellij.codeInsight.completion.CompletionContributor;
import com.intellij.codeInsight.completion.CompletionParameters;
import com.intellij.codeInsight.completion.CompletionProvider;
import com.intellij.codeInsight.completion.CompletionResultSet;
import com.intellij.codeInsight.completion.CompletionType;
import com.intellij.codeInsight.completion.InsertHandler;
import com.intellij.codeInsight.completion.PrioritizedLookupElement;
import com.intellij.codeInsight.lookup.LookupElement;
import com.intellij.codeInsight.lookup.LookupElementBuilder;
import com.intellij.openapi.editor.Document;
import com.intellij.openapi.editor.Editor;
import com.intellij.openapi.util.io.FileUtil;
import com.intellij.openapi.vfs.VirtualFile;
import com.intellij.patterns.PlatformPatterns;
import com.intellij.util.ProcessingContext;
import org.jetbrains.annotations.NotNull;

import java.io.File;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
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

    private static final Pattern IMPORT_LINE =
            Pattern.compile("^\\s*import\\s+[A-Za-z0-9_.]*$");
    private static final Pattern IMPORT =
            Pattern.compile("^\\s*import\\s+([A-Za-z_][A-Za-z0-9_.]*)", Pattern.MULTILINE);
    private static final Pattern PUB_DECL = Pattern.compile(
            "^pub\\s+(?:static\\s+)?(enum|class|struct|func|const|var|signal)\\s+([A-Za-z_][A-Za-z0-9_]*)",
            Pattern.MULTILINE);
    private static final Pattern ANY_DECL = Pattern.compile(
            "^(?:pub\\s+|private\\s+)?(?:static\\s+)?(enum|class|struct|func|const|var|signal)\\s+([A-Za-z_][A-Za-z0-9_]*)",
            Pattern.MULTILINE);

    /** Insert `()` after a function name, put the caret inside, and pop parameter info. */
    private static final InsertHandler<LookupElement> CALL = (ctx, item) -> {
        Editor editor = ctx.getEditor();
        Document doc = editor.getDocument();
        int tail = ctx.getTailOffset();
        if (tail < doc.getTextLength() && doc.getCharsSequence().charAt(tail) == '(') {
            editor.getCaretModel().moveToOffset(tail + 1);
        } else {
            doc.insertString(tail, "()");
            editor.getCaretModel().moveToOffset(tail + 1);
        }
        AutoPopupController.getInstance(ctx.getProject()).autoPopupParameterInfo(editor, null);
    };

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

                        int lineStart = text.lastIndexOf('\n', Math.max(0, offset - 1)) + 1;
                        String linePrefix = text.substring(lineStart, offset);

                        // `import <caret>` → module paths.
                        if (IMPORT_LINE.matcher(linePrefix).matches()) {
                            addImportPaths(parameters, result);
                            return;
                        }

                        // `receiver.<caret>` → that module's members.
                        int i = offset;
                        while (i > 0 && isIdentChar(text.charAt(i - 1))) i--;
                        if (i > 0 && text.charAt(i - 1) == '.') {
                            int dot = i - 1;
                            int j = dot;
                            while (j > 0 && isIdentChar(text.charAt(j - 1))) j--;
                            addModuleMembers(parameters, text, text.substring(j, dot), result);
                            return;
                        }

                        // Plain: keywords, builtins, and this file's own declarations —
                        // de-duplicated, with your own declarations ranked highest.
                        Set<String> seen = new HashSet<>();
                        Matcher dm = ANY_DECL.matcher(text);
                        while (dm.find()) {
                            String name = dm.group(2);
                            if (seen.add(name)) {
                                boolean fn = dm.group(1).equals("func");
                                result.addElement(prioritized(
                                        base(name, dm.group(1), fn), 30));
                            }
                        }
                        for (String b : BUILTINS) {
                            if (seen.add(b)) {
                                result.addElement(prioritized(base(b, "builtin", true), 10));
                            }
                        }
                        for (String kw : KEYWORDS) {
                            if (seen.add(kw)) {
                                result.addElement(prioritized(
                                        LookupElementBuilder.create(kw).bold(), 5));
                            }
                        }
                    }
                });
    }

    private static LookupElementBuilder base(String name, String typeText, boolean isFunction) {
        LookupElementBuilder e = LookupElementBuilder.create(name).withTypeText(typeText, true);
        return isFunction ? e.withInsertHandler(CALL) : e;
    }

    private static LookupElement prioritized(LookupElementBuilder e, double priority) {
        return PrioritizedLookupElement.withPriority(e, priority);
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
            String kind = pm.group(1);
            result.addElement(prioritized(
                    base(pm.group(2), receiver + " " + kind, kind.equals("func")), 20));
        }
    }

    /** `import <caret>` → sibling `.rg` modules and `std.*` modules. */
    private static void addImportPaths(CompletionParameters parameters, CompletionResultSet result) {
        VirtualFile vf = parameters.getOriginalFile().getVirtualFile();
        Set<String> seen = new HashSet<>();
        if (vf != null && vf.getParent() != null) {
            for (File f : listRg(new File(vf.getParent().getPath()))) {
                add(result, seen, stripRg(f.getName()));
            }
        }
        String base = parameters.getOriginalFile().getProject().getBasePath();
        if (base != null) {
            File std = new File(base, "std");
            for (File f : listRg(std)) {
                add(result, seen, "std." + stripRg(f.getName()));
            }
        }
    }

    private static void add(CompletionResultSet result, Set<String> seen, String path) {
        if (seen.add(path)) {
            result.addElement(LookupElementBuilder.create(path).withTypeText("module", true));
        }
    }

    private static File[] listRg(File dir) {
        if (dir == null || !dir.isDirectory()) {
            return new File[0];
        }
        File[] fs = dir.listFiles((d, n) -> n.endsWith(".rg"));
        return fs != null ? fs : new File[0];
    }

    private static String stripRg(String name) {
        return name.endsWith(".rg") ? name.substring(0, name.length() - 3) : name;
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
