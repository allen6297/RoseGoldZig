package org.rosegold.ide;

import com.intellij.lang.documentation.AbstractDocumentationProvider;
import com.intellij.openapi.editor.Editor;
import com.intellij.psi.PsiElement;
import com.intellij.psi.PsiFile;
import org.jetbrains.annotations.Nullable;

import java.util.Map;

/** Quick-documentation (Ctrl-Q / hover) for the standard-library builtins. */
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
        String name = null;
        if (originalElement != null) {
            name = originalElement.getText();
        } else if (element != null) {
            name = element.getText();
        }
        if (name == null) {
            return null;
        }
        String doc = DOCS.get(name);
        return doc == null ? null : "<code>" + doc + "</code>";
    }
}
