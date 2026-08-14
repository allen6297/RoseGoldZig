package org.rosegold.ide;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Deque;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * A lightweight line scanner that finds declarations (functions, classes,
 * structs, enums, signals, top-level consts/vars) and nests them by indentation.
 * It avoids maintaining a second full grammar — enough for the structure view,
 * folding, and name-based navigation.
 */
public final class RoseGoldDeclarations {
    private RoseGoldDeclarations() {
    }

    private static final Pattern DECL = Pattern.compile(
            "^\\s*(?:pub\\s+|private\\s+)?(?:static\\s+)?" +
                    "(func|class|struct|enum|signal|const|var)\\s+([A-Za-z_][A-Za-z0-9_]*)");

    /** All declarations, nested (top-level list; class members under their class). */
    public static List<RoseGoldDeclaration> scan(CharSequence text) {
        List<RoseGoldDeclaration> roots = new ArrayList<>();
        Deque<RoseGoldDeclaration> stack = new ArrayDeque<>();

        int n = text.length();
        int lineStart = 0;
        for (int i = 0; i <= n; i++) {
            if (i < n && text.charAt(i) != '\n') {
                continue;
            }
            int end = i;
            if (end > lineStart && text.charAt(end - 1) == '\r') {
                end--; // drop a trailing CR without shifting the start offset
            }
            String line = text.subSequence(lineStart, end).toString();
            RoseGoldDeclaration decl = match(line, lineStart);
            if (decl != null) {
                while (!stack.isEmpty() && stack.peek().indent >= decl.indent) {
                    stack.pop();
                }
                if (stack.isEmpty()) {
                    roots.add(decl);
                } else {
                    stack.peek().children.add(decl);
                }
                stack.push(decl);
            }
            lineStart = i + 1;
        }
        return roots;
    }

    /** Every declaration in the tree, flattened (roots first, then descendants). */
    public static List<RoseGoldDeclaration> scanFlat(CharSequence text) {
        List<RoseGoldDeclaration> out = new ArrayList<>();
        collect(scan(text), out);
        return out;
    }

    private static void collect(List<RoseGoldDeclaration> decls, List<RoseGoldDeclaration> out) {
        for (RoseGoldDeclaration d : decls) {
            out.add(d);
            collect(d.children, out);
        }
    }

    private static RoseGoldDeclaration match(String line, int lineStartOffset) {
        Matcher m = DECL.matcher(line);
        if (!m.find()) {
            return null;
        }
        RoseGoldDeclaration.Kind kind = switch (m.group(1)) {
            case "func" -> RoseGoldDeclaration.Kind.FUNCTION;
            case "class" -> RoseGoldDeclaration.Kind.CLASS;
            case "struct" -> RoseGoldDeclaration.Kind.STRUCT;
            case "enum" -> RoseGoldDeclaration.Kind.ENUM;
            case "signal" -> RoseGoldDeclaration.Kind.SIGNAL;
            case "const" -> RoseGoldDeclaration.Kind.CONST;
            case "var" -> RoseGoldDeclaration.Kind.VAR;
            default -> null;
        };
        if (kind == null) {
            return null;
        }
        int indent = 0;
        while (indent < line.length() && Character.isWhitespace(line.charAt(indent))) {
            indent++;
        }
        return new RoseGoldDeclaration(kind, m.group(2), lineStartOffset + m.start(2), indent);
    }
}
