package org.rosegold.ide;

import com.intellij.lang.parameterInfo.CreateParameterInfoContext;
import com.intellij.lang.parameterInfo.ParameterInfoHandler;
import com.intellij.lang.parameterInfo.ParameterInfoUIContext;
import com.intellij.lang.parameterInfo.UpdateParameterInfoContext;
import com.intellij.openapi.util.io.FileUtil;
import com.intellij.openapi.vfs.VirtualFile;
import com.intellij.psi.PsiElement;
import com.intellij.psi.PsiFile;
import org.jetbrains.annotations.Nullable;

import java.io.File;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Parameter info (Cmd/Ctrl-P, and while typing a call) for RoseGold. The PSI is a
 * flat token stream, so the enclosing call and the active argument are found by
 * scanning balanced parentheses in the document text; the callee's signature is
 * read from its {@code (…)} header — a local function, an imported {@code
 * mod.func}, or a small table of stdlib builtins.
 */
public final class RoseGoldParameterInfoHandler
        implements ParameterInfoHandler<PsiElement, RoseGoldParameterInfoHandler.Sig> {

    /** A resolved signature: the label to show and the char range of each parameter within it. */
    public static final class Sig {
        final String label;
        final int[][] ranges;

        Sig(String label, int[][] ranges) {
            this.label = label;
            this.ranges = ranges;
        }
    }

    private static final class Call {
        String callee;
        int paramIndex;
    }

    // A few builtins whose parameters are worth showing.
    private static final Map<String, String> BUILTIN_SIGS = new LinkedHashMap<>();
    static {
        BUILTIN_SIGS.put("print", "values…");
        BUILTIN_SIGS.put("len", "x");
        BUILTIN_SIGS.put("range", "n");
        BUILTIN_SIGS.put("push", "list, x");
        BUILTIN_SIGS.put("pop", "list");
        BUILTIN_SIGS.put("has", "map, key");
        BUILTIN_SIGS.put("keys", "map");
        BUILTIN_SIGS.put("values", "map");
        BUILTIN_SIGS.put("map", "list, f");
        BUILTIN_SIGS.put("filter", "list, pred");
        BUILTIN_SIGS.put("reduce", "list, f, init");
        BUILTIN_SIGS.put("split", "s, sep");
        BUILTIN_SIGS.put("join", "list, sep");
        BUILTIN_SIGS.put("replace", "s, from, to");
        BUILTIN_SIGS.put("pow", "base, exp");
        BUILTIN_SIGS.put("min", "a, b");
        BUILTIN_SIGS.put("max", "a, b");
        BUILTIN_SIGS.put("gather", "tasks");
    }

    @Override
    public @Nullable PsiElement findElementForParameterInfo(CreateParameterInfoContext context) {
        PsiFile file = context.getFile();
        String text = file.getText();
        Call call = findEnclosingCall(text, context.getOffset());
        if (call == null) {
            return null;
        }
        Sig sig = resolveSignature(file, text, call.callee);
        if (sig == null) {
            return null;
        }
        context.setItemsToShow(new Object[]{sig});
        PsiElement at = file.findElementAt(Math.max(0, context.getOffset() - 1));
        return at != null ? at : file;
    }

    @Override
    public void showParameterInfo(PsiElement element, CreateParameterInfoContext context) {
        context.showHint(element, context.getOffset(), this);
    }

    @Override
    public @Nullable PsiElement findElementForUpdatingParameterInfo(UpdateParameterInfoContext context) {
        PsiFile file = context.getFile();
        return file.findElementAt(Math.max(0, context.getOffset() - 1));
    }

    @Override
    public void updateParameterInfo(PsiElement element, UpdateParameterInfoContext context) {
        Call call = findEnclosingCall(context.getFile().getText(), context.getOffset());
        context.setCurrentParameter(call != null ? call.paramIndex : 0);
    }

    @Override
    public void updateUI(Sig sig, ParameterInfoUIContext context) {
        if (sig == null) {
            context.setUIComponentEnabled(false);
            return;
        }
        int i = context.getCurrentParameterIndex();
        int hs = -1;
        int he = -1;
        if (i >= 0 && i < sig.ranges.length) {
            hs = sig.ranges[i][0];
            he = sig.ranges[i][1];
        }
        context.setupUIComponentPresentation(sig.label, hs, he, false, false, false,
                context.getDefaultParameterColor());
    }

    // --- call + signature resolution ----------------------------------------

    /** The call that encloses {@code offset}: its callee and the active argument index. */
    private static @Nullable Call findEnclosingCall(String text, int offset) {
        int depth = 0;
        int commas = 0;
        int i = offset - 1;
        int scanned = 0;
        for (; i >= 0 && scanned < 4000; i--, scanned++) {
            char c = text.charAt(i);
            if (c == ')') {
                depth++;
            } else if (c == '(') {
                if (depth == 0) {
                    break;
                }
                depth--;
            } else if (c == ',' && depth == 0) {
                commas++;
            }
        }
        if (i < 0) {
            return null;
        }
        int open = i;
        int j = open - 1;
        while (j >= 0 && Character.isWhitespace(text.charAt(j))) j--;
        int end = j + 1;
        while (j >= 0 && isIdentPart(text.charAt(j))) j--;
        int start = j + 1;
        if (start >= end) {
            return null;
        }
        // Include a `mod.` prefix if present.
        if (start > 0 && text.charAt(start - 1) == '.') {
            int s = start - 2;
            while (s >= 0 && isIdentPart(text.charAt(s))) s--;
            start = s + 1;
        }
        Call call = new Call();
        call.callee = text.substring(start, end);
        call.paramIndex = commas;
        return call;
    }

    /** Resolve a callee to a signature: `mod.func`, a local func, or a builtin. */
    private static @Nullable Sig resolveSignature(PsiFile file, String text, String callee) {
        int dot = callee.indexOf('.');
        if (dot > 0) {
            String mod = callee.substring(0, dot);
            String func = callee.substring(dot + 1);
            File modFile = resolveModuleFile(file, mod, text);
            if (modFile != null) {
                try {
                    Sig s = sigFromSource(FileUtil.loadFile(modFile), func);
                    if (s != null) {
                        return s;
                    }
                } catch (Exception ignored) {
                    // fall through
                }
            }
            return null;
        }
        Sig local = sigFromSource(text, callee);
        if (local != null) {
            return local;
        }
        String params = BUILTIN_SIGS.get(callee);
        return params != null ? buildSig(callee, params) : null;
    }

    /** Read `func NAME(<params>)` from source and build a signature. */
    private static @Nullable Sig sigFromSource(String src, String name) {
        Pattern p = Pattern.compile("\\bfunc\\s+" + Pattern.quote(name) + "\\s*\\(");
        Matcher m = p.matcher(src);
        if (!m.find()) {
            return null;
        }
        int open = m.end() - 1;
        int depth = 0;
        int i = open;
        for (; i < src.length(); i++) {
            char c = src.charAt(i);
            if (c == '(') {
                depth++;
            } else if (c == ')') {
                depth--;
                if (depth == 0) {
                    break;
                }
            }
        }
        if (i >= src.length()) {
            return null;
        }
        return buildSig(name, src.substring(open + 1, i).trim());
    }

    /** Build the "name(a, b, c)" label with a char range per parameter. */
    private static Sig buildSig(String name, String params) {
        String label = name + "(" + params + ")";
        int base = name.length() + 1;
        List<int[]> ranges = new ArrayList<>();
        int depth = 0;
        int segStart = 0;
        for (int i = 0; i <= params.length(); i++) {
            boolean atEnd = i == params.length();
            char c = atEnd ? ',' : params.charAt(i);
            if (!atEnd && (c == '<' || c == '(' || c == '[')) {
                depth++;
            } else if (!atEnd && (c == '>' || c == ')' || c == ']')) {
                depth--;
            } else if (c == ',' && depth == 0) {
                addTrimmed(ranges, params, base, segStart, i);
                segStart = i + 1;
            }
        }
        if (ranges.isEmpty() && !params.isEmpty()) {
            ranges.add(new int[]{base, base + params.length()});
        }
        return new Sig(label, ranges.toArray(new int[0][]));
    }

    private static void addTrimmed(List<int[]> ranges, String params, int base, int from, int to) {
        int s = from;
        int e = to;
        while (s < e && Character.isWhitespace(params.charAt(s))) s++;
        while (e > s && Character.isWhitespace(params.charAt(e - 1))) e--;
        if (e > s) {
            ranges.add(new int[]{base + s, base + e});
        }
    }

    /** Resolve an imported module named `mod` to its source file. */
    private static @Nullable File resolveModuleFile(PsiFile file, String mod, String text) {
        Pattern imp = Pattern.compile("^\\s*import\\s+([A-Za-z_][A-Za-z0-9_.]*)", Pattern.MULTILINE);
        Matcher m = imp.matcher(text);
        String[] segs = null;
        while (m.find()) {
            String[] s = m.group(1).split("\\.");
            if (s[s.length - 1].equals(mod)) {
                segs = s;
                break;
            }
        }
        if (segs == null) {
            return null;
        }
        String rel = String.join(File.separator, segs) + ".rg";
        List<File> bases = new ArrayList<>();
        VirtualFile vf = file.getVirtualFile();
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
        String base = file.getProject().getBasePath();
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

    private static boolean isIdentPart(char c) {
        return c == '_' || Character.isLetterOrDigit(c);
    }
}
