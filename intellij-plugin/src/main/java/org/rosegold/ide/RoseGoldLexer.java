package org.rosegold.ide;

import com.intellij.lexer.LexerBase;
import com.intellij.psi.TokenType;
import com.intellij.psi.tree.IElementType;
import org.jetbrains.annotations.NotNull;

import java.util.Set;

/**
 * A small hand-written lexer for highlighting. It classifies the source into
 * coarse categories (keywords, types, strings, numbers, comments, punctuation,
 * brackets) — enough for coloring, comment toggling, and brace matching. It does
 * not model indentation; the real compiler owns the authoritative grammar.
 */
public final class RoseGoldLexer extends LexerBase {

    private static final Set<String> KEYWORDS = Set.of(
            "import", "class", "struct", "extends", "uses", "func", "var", "const",
            "enum", "if", "elif", "else", "match", "for", "in", "while", "break",
            "continue", "return", "pass", "nil", "pub", "private", "static", "true",
            "false", "and", "or", "not", "signal", "try", "catch", "raise");

    private static final Set<String> TYPES = Set.of(
            "int", "float", "str", "bool", "void", "any", "list", "map");

    private CharSequence buffer = "";
    private int endOffset = 0;
    private int tokenStart = 0;
    private int tokenEnd = 0;
    private IElementType tokenType = null;

    @Override
    public void start(@NotNull CharSequence buffer, int startOffset, int endOffset, int initialState) {
        this.buffer = buffer;
        this.endOffset = endOffset;
        this.tokenStart = startOffset;
        scanToken();
    }

    @Override
    public int getState() {
        return 0;
    }

    @Override
    public IElementType getTokenType() {
        return tokenType;
    }

    @Override
    public int getTokenStart() {
        return tokenStart;
    }

    @Override
    public int getTokenEnd() {
        return tokenEnd;
    }

    @Override
    public void advance() {
        tokenStart = tokenEnd;
        scanToken();
    }

    @Override
    public @NotNull CharSequence getBufferSequence() {
        return buffer;
    }

    @Override
    public int getBufferEnd() {
        return endOffset;
    }

    private void scanToken() {
        if (tokenStart >= endOffset) {
            tokenType = null;
            tokenEnd = tokenStart;
            return;
        }
        final char c = buffer.charAt(tokenStart);
        int i = tokenStart;

        if (isWhitespace(c)) {
            i++;
            while (i < endOffset && isWhitespace(buffer.charAt(i))) i++;
            set(TokenType.WHITE_SPACE, i);
            return;
        }
        if (c == '#') { // ## line comment (a lone # is invalid anyway)
            i++;
            while (i < endOffset && buffer.charAt(i) != '\n') i++;
            set(RoseGoldTokenTypes.COMMENT, i);
            return;
        }
        if (c == '"') {
            i++;
            while (i < endOffset) {
                final char d = buffer.charAt(i);
                if (d == '\\' && i + 1 < endOffset) {
                    i += 2;
                    continue;
                }
                if (d == '"') {
                    i++;
                    break;
                }
                if (d == '\n') break; // unterminated: stop at the line end
                i++;
            }
            set(RoseGoldTokenTypes.STRING, i);
            return;
        }
        if (isDigit(c)) {
            i++;
            while (i < endOffset && isDigit(buffer.charAt(i))) i++;
            if (i + 1 < endOffset && buffer.charAt(i) == '.' && isDigit(buffer.charAt(i + 1))) {
                i += 2;
                while (i < endOffset && isDigit(buffer.charAt(i))) i++;
            }
            set(RoseGoldTokenTypes.NUMBER, i);
            return;
        }
        if (isIdentStart(c)) {
            i++;
            while (i < endOffset && isIdentPart(buffer.charAt(i))) i++;
            final String word = buffer.subSequence(tokenStart, i).toString();
            if (KEYWORDS.contains(word)) set(RoseGoldTokenTypes.KEYWORD, i);
            else if (TYPES.contains(word)) set(RoseGoldTokenTypes.TYPE, i);
            else set(RoseGoldTokenTypes.IDENTIFIER, i);
            return;
        }
        switch (c) {
            case '(': set(RoseGoldTokenTypes.LPAREN, i + 1); return;
            case ')': set(RoseGoldTokenTypes.RPAREN, i + 1); return;
            case '[': set(RoseGoldTokenTypes.LBRACKET, i + 1); return;
            case ']': set(RoseGoldTokenTypes.RBRACKET, i + 1); return;
            case '{': set(RoseGoldTokenTypes.LBRACE, i + 1); return;
            case '}': set(RoseGoldTokenTypes.RBRACE, i + 1); return;
            case ',': set(RoseGoldTokenTypes.PUNCTUATION, i + 1); return;
            default: break;
        }
        if (i + 1 < endOffset) {
            final String two = buffer.subSequence(i, i + 2).toString();
            if (two.equals("->") || two.equals("==") || two.equals("!=") || two.equals("<=")
                    || two.equals(">=") || two.equals("+=") || two.equals("-=") || two.equals("*=")
                    || two.equals("/=") || two.equals("%=") || two.equals("..")) {
                set(RoseGoldTokenTypes.OPERATOR, i + 2);
                return;
            }
        }
        if ("+-*/%=<>!&|".indexOf(c) >= 0) {
            set(RoseGoldTokenTypes.OPERATOR, i + 1);
            return;
        }
        if (c == ':' || c == '.' || c == '?') {
            set(RoseGoldTokenTypes.PUNCTUATION, i + 1);
            return;
        }
        set(TokenType.BAD_CHARACTER, i + 1);
    }

    private void set(IElementType type, int end) {
        this.tokenType = type;
        this.tokenEnd = end;
    }

    private static boolean isWhitespace(char c) {
        return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\f';
    }

    private static boolean isDigit(char c) {
        return c >= '0' && c <= '9';
    }

    private static boolean isIdentStart(char c) {
        return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
    }

    private static boolean isIdentPart(char c) {
        return isIdentStart(c) || isDigit(c);
    }
}
