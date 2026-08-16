package org.rosegold.ide;

import com.intellij.lang.documentation.AbstractDocumentationProvider;
import com.intellij.openapi.editor.Editor;
import com.intellij.psi.PsiElement;
import com.intellij.psi.PsiFile;
import org.jetbrains.annotations.Nullable;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * Quick-documentation (Ctrl-Q / hover) for RoseGold: the standard-library
 * builtins from a table, and — for a name declared in the file — its header line
 * plus the {@code ##} doc-comment block written directly above it (the same
 * association the {@code rosegold doc} generator uses).
 */
public final class RoseGoldDocumentationProvider extends AbstractDocumentationProvider {
    private static final Map<String, String> DOCS = Map.ofEntries(
            Map.entry("print", "print(values…) — write the values, space-separated, and a newline."),
            Map.entry("echo", "echo(values…) — alias of print."),
            Map.entry("len", "len(x) → int — length of a list, map, or string."),
            Map.entry("range", "range(n) → list&lt;int&gt; — the ints 0 … n-1."),
            Map.entry("str", "str(x) → str — the string form of any value."),
            Map.entry("int", "int(x) → int — convert a number/bool/string to int."),
            Map.entry("float", "float(x) → float — convert to float."),
            Map.entry("push", "push(list, x) — append x to the list."),
            Map.entry("pop", "pop(list&lt;T&gt;) → T — remove and return the last element."),
            Map.entry("keys", "keys(map&lt;K,V&gt;) → list&lt;K&gt; — the map's keys."),
            Map.entry("values", "values(map&lt;K,V&gt;) → list&lt;V&gt; — the map's values."),
            Map.entry("has", "has(map, key) → bool — whether the key is present."),
            Map.entry("connect", "connect(signal, handler) — register a signal handler."),
            Map.entry("emit", "emit(signal, args…) — fire a signal's handlers in order."),
            Map.entry("abs", "abs(x) — absolute value (int→int, float→float)."),
            Map.entry("min", "min(a, b) — the smaller of two numbers."),
            Map.entry("max", "max(a, b) — the larger of two numbers."),
            Map.entry("upper", "upper(s) → str — uppercase."),
            Map.entry("lower", "lower(s) → str — lowercase."),
            Map.entry("split", "split(s, sep) → list&lt;str&gt; — split a string on sep."),
            Map.entry("join", "join(list&lt;str&gt;, sep) → str — join with sep."),
            Map.entry("contains", "contains(haystack, needle) → bool — substring / element test."),
            Map.entry("sort", "sort(list) → list — a sorted copy."),
            Map.entry("reverse", "reverse(list) → list — a reversed copy."),
            Map.entry("trim", "trim(s) → str — strip surrounding whitespace."),
            Map.entry("starts_with", "starts_with(s, prefix) → bool."),
            Map.entry("ends_with", "ends_with(s, suffix) → bool."),
            Map.entry("find", "find(haystack, needle) → int — index, or -1 if absent."),
            Map.entry("replace", "replace(s, from, to) → str."),
            Map.entry("map", "map(list, f) → list — apply f to each element."),
            Map.entry("filter", "filter(list, pred) → list — keep elements where pred is true."),
            Map.entry("reduce", "reduce(list, f, init) — fold left: acc = f(acc, x)."),
            Map.entry("sqrt", "sqrt(x) → float — square root."),
            Map.entry("pow", "pow(base, exp) → float — base raised to exp."),
            Map.entry("floor", "floor(x) → int — round toward -∞."),
            Map.entry("ceil", "ceil(x) → int — round toward +∞."),
            Map.entry("round", "round(x) → int — round half away from zero."),
            Map.entry("gather", "gather(list<task<T>>) → list<T> — await every task, in order."));

    @Override
    public @Nullable PsiElement getCustomDocumentationElement(@Nullable Editor editor,
                                                              @Nullable PsiFile file,
                                                              @Nullable PsiElement contextElement,
                                                              int targetOffset) {
        if (contextElement != null && contextElement.getNode() != null
                && contextElement.getNode().getElementType() == RoseGoldTokenTypes.IDENTIFIER) {
            return contextElement;
        }
        return null;
    }

    @Override
    public @Nullable String generateDoc(PsiElement element, @Nullable PsiElement originalElement) {
        PsiElement e = originalElement != null ? originalElement : element;
        if (e == null) {
            return null;
        }
        String name = e.getText();
        if (name == null || name.isEmpty()) {
            return null;
        }
        String builtin = DOCS.get(name);
        if (builtin != null) {
            return "<code>" + builtin + "</code>";
        }
        PsiFile file = e.getContainingFile();
        if (!(file instanceof RoseGoldFile)) {
            return null;
        }
        return declDoc(file.getViewProvider().getContents(), name);
    }

    /**
     * Documentation for a name declared in `text`: its header line (colon
     * trimmed) plus the consecutive `##` comment lines directly above it. Null if
     * the name isn't a top-level or member declaration.
     */
    private static @Nullable String declDoc(CharSequence text, String name) {
        for (RoseGoldDeclaration d : RoseGoldDeclarations.scanFlat(text)) {
            if (!d.name.equals(name)) {
                continue;
            }
            int lineStart = lineStartOffset(text, d.nameOffset);
            int lineEnd = lineEndOffset(text, d.nameOffset);
            String header = text.subSequence(lineStart, lineEnd).toString().trim();
            if (header.endsWith(":")) {
                header = header.substring(0, header.length() - 1);
            }
            List<String> comments = commentsAbove(text, lineStart);

            StringBuilder sb = new StringBuilder();
            sb.append("<code>").append(escape(header)).append("</code>");
            if (!comments.isEmpty()) {
                sb.append("<br><br>");
                for (int i = 0; i < comments.size(); i++) {
                    if (i > 0) {
                        sb.append("<br>");
                    }
                    sb.append(escape(comments.get(i)));
                }
            }
            return sb.toString();
        }
        return null;
    }

    /** The `##` comment lines (prefix stripped) immediately above `lineStart`. */
    private static List<String> commentsAbove(CharSequence text, int lineStart) {
        List<String> out = new ArrayList<>();
        int ls = lineStart;
        while (ls > 0) {
            int nl = ls - 1; // the '\n' ending the previous line
            int prevStart = lineStartOffset(text, nl);
            String prev = text.subSequence(prevStart, nl).toString().trim();
            if (!prev.startsWith("##")) {
                break;
            }
            out.add(0, stripPrefix(prev));
            ls = prevStart;
        }
        return out;
    }

    private static String stripPrefix(String comment) {
        String s = comment.startsWith("##") ? comment.substring(2) : comment;
        return s.startsWith(" ") ? s.substring(1) : s;
    }

    private static int lineStartOffset(CharSequence t, int off) {
        int i = off;
        while (i > 0 && t.charAt(i - 1) != '\n') {
            i--;
        }
        return i;
    }

    private static int lineEndOffset(CharSequence t, int off) {
        int i = off;
        int n = t.length();
        while (i < n && t.charAt(i) != '\n') {
            i++;
        }
        return i;
    }

    private static String escape(String s) {
        return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;");
    }
}
