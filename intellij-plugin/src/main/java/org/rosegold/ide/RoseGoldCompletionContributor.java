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
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
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

                        // `receiver.<caret>` → an imported module's members, or a
                        // typed local's / a class's own members.
                        int i = offset;
                        while (i > 0 && isIdentChar(text.charAt(i - 1))) i--;
                        if (i > 0 && text.charAt(i - 1) == '.') {
                            int dot = i - 1;
                            int j = dot;
                            while (j > 0 && isIdentChar(text.charAt(j - 1))) j--;
                            String receiver = text.substring(j, dot);
                            if (!addModuleMembers(parameters, text, receiver, result)) {
                                addTypeMembers(text, receiver, dot, result);
                            }
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

    /**
     * After `receiver.`: if `receiver` is an imported module, add its `pub`
     * members. Returns true if `receiver` resolved to a module (so the caller
     * shouldn't also try a type).
     */
    private static boolean addModuleMembers(CompletionParameters parameters, String text,
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
            return false;
        }
        File mod = resolveModuleFile(parameters, segs);
        if (mod == null) {
            return true; // it names an import; just couldn't read the file
        }
        final String src;
        try {
            src = FileUtil.loadFile(mod);
        } catch (Exception e) {
            return true;
        }
        Matcher pm = PUB_DECL.matcher(src);
        while (pm.find()) {
            String kind = pm.group(1);
            result.addElement(prioritized(
                    base(pm.group(2), receiver + " " + kind, kind.equals("func")), 20));
        }
        return true;
    }

    /**
     * After `receiver.`: when `receiver` is a class/struct name (statics) or a
     * local/parameter whose type is a class/struct declared in this file, add
     * that type's `var`/`func` members. Types are inferred from `var x: T`,
     * `var x = T(…)`, or a `x: T` parameter annotation.
     */
    private static void addTypeMembers(String text, String receiver, int before,
                                       CompletionResultSet result) {
        Map<String, RoseGoldDeclaration> types = new HashMap<>();
        boolean receiverIsEnum = false;
        for (RoseGoldDeclaration d : RoseGoldDeclarations.scanFlat(text)) {
            if (d.kind == RoseGoldDeclaration.Kind.CLASS || d.kind == RoseGoldDeclaration.Kind.STRUCT) {
                types.putIfAbsent(d.name, d);
            } else if (d.kind == RoseGoldDeclaration.Kind.ENUM && d.name.equals(receiver)) {
                receiverIsEnum = true;
            }
        }
        // `Enum.` → the enum's cases (parsed from its `{ … }` body).
        if (receiverIsEnum) {
            for (String cse : enumCaseNames(text, receiver)) {
                result.addElement(prioritized(base(cse, receiver + " case", false), 25));
            }
            return;
        }
        // `Type.` (statics) uses the name directly; otherwise infer the local's type.
        RoseGoldDeclaration type = types.get(receiver);
        if (type == null) {
            String inferred = inferLocalType(text, receiver, before, types.keySet());
            type = inferred == null ? null : types.get(inferred);
        }
        if (type == null) {
            return;
        }
        for (RoseGoldDeclaration m : type.children) {
            boolean fn = m.kind == RoseGoldDeclaration.Kind.FUNCTION;
            if (fn || m.kind == RoseGoldDeclaration.Kind.VAR) {
                result.addElement(prioritized(
                        base(m.name, type.name + " " + (fn ? "func" : "field"), fn), 25));
            }
        }
    }

    /**
     * Infer the type of local/parameter `receiver` by scanning for a binding
     * before `before`: `[var|const] receiver: T`, or `receiver = T(`. Only a `T`
     * naming a known class/struct (`knownTypes`) counts; the nearest such binding
     * wins.
     */
    private static String inferLocalType(String text, String receiver, int before, Set<String> knownTypes) {
        Pattern p = Pattern.compile(
                "\\b" + Pattern.quote(receiver) +
                        "\\s*(?::\\s*([A-Za-z_][A-Za-z0-9_]*)|=\\s*([A-Za-z_][A-Za-z0-9_]*)\\s*\\()");
        Matcher m = p.matcher(text);
        String best = null;
        while (m.find()) {
            if (m.start() >= before) {
                break;
            }
            String t = m.group(1) != null ? m.group(1) : m.group(2);
            if (t != null && knownTypes.contains(t)) {
                best = t; // last binding before the use wins
            }
        }
        return best;
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

    /** The case names of `enum <name> { … }` (payload/`= value` suffixes stripped). */
    private static List<String> enumCaseNames(String text, String name) {
        Matcher m = Pattern.compile("\\benum\\s+" + Pattern.quote(name) + "\\s*\\{").matcher(text);
        if (!m.find()) {
            return List.of();
        }
        int open = m.end() - 1; // the '{'
        int depth = 0;
        int close = -1;
        for (int i = open; i < text.length(); i++) {
            char c = text.charAt(i);
            if (c == '{') {
                depth++;
            } else if (c == '}' && --depth == 0) {
                close = i;
                break;
            }
        }
        if (close < 0) {
            return List.of();
        }
        List<String> names = new ArrayList<>();
        int depthP = 0; // bracket depth, to split cases on top-level commas
        int start = open + 1;
        for (int i = open + 1; i <= close; i++) {
            char c = i < close ? text.charAt(i) : ',';
            if (c == '(' || c == '[' || c == '<') {
                depthP++;
            } else if (c == ')' || c == ']' || c == '>') {
                depthP--;
            } else if (c == ',' && depthP == 0) {
                String part = text.substring(start, i).trim();
                int e = 0;
                while (e < part.length() && isIdentChar(part.charAt(e))) e++;
                if (e > 0) names.add(part.substring(0, e));
                start = i + 1;
            }
        }
        return names;
    }

    private static boolean isIdentChar(char c) {
        return c == '_' || Character.isLetterOrDigit(c);
    }
}
