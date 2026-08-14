package org.rosegold.ide;

import com.intellij.lexer.Lexer;
import com.intellij.openapi.editor.DefaultLanguageHighlighterColors;
import com.intellij.openapi.editor.HighlighterColors;
import com.intellij.openapi.editor.colors.TextAttributesKey;
import com.intellij.openapi.fileTypes.SyntaxHighlighterBase;
import com.intellij.psi.TokenType;
import com.intellij.psi.tree.IElementType;
import org.jetbrains.annotations.NotNull;

import static com.intellij.openapi.editor.colors.TextAttributesKey.createTextAttributesKey;

public final class RoseGoldSyntaxHighlighter extends SyntaxHighlighterBase {
    public static final TextAttributesKey KEYWORD =
            createTextAttributesKey("ROSEGOLD_KEYWORD", DefaultLanguageHighlighterColors.KEYWORD);
    public static final TextAttributesKey TYPE =
            createTextAttributesKey("ROSEGOLD_TYPE", DefaultLanguageHighlighterColors.CLASS_NAME);
    public static final TextAttributesKey IDENTIFIER =
            createTextAttributesKey("ROSEGOLD_IDENTIFIER", DefaultLanguageHighlighterColors.IDENTIFIER);
    public static final TextAttributesKey NUMBER =
            createTextAttributesKey("ROSEGOLD_NUMBER", DefaultLanguageHighlighterColors.NUMBER);
    public static final TextAttributesKey STRING =
            createTextAttributesKey("ROSEGOLD_STRING", DefaultLanguageHighlighterColors.STRING);
    public static final TextAttributesKey COMMENT =
            createTextAttributesKey("ROSEGOLD_COMMENT", DefaultLanguageHighlighterColors.LINE_COMMENT);
    public static final TextAttributesKey OPERATOR =
            createTextAttributesKey("ROSEGOLD_OPERATOR", DefaultLanguageHighlighterColors.OPERATION_SIGN);
    public static final TextAttributesKey PARENS =
            createTextAttributesKey("ROSEGOLD_PARENS", DefaultLanguageHighlighterColors.PARENTHESES);
    public static final TextAttributesKey BRACKETS =
            createTextAttributesKey("ROSEGOLD_BRACKETS", DefaultLanguageHighlighterColors.BRACKETS);
    public static final TextAttributesKey BRACES =
            createTextAttributesKey("ROSEGOLD_BRACES", DefaultLanguageHighlighterColors.BRACES);
    public static final TextAttributesKey BAD_CHARACTER =
            createTextAttributesKey("ROSEGOLD_BAD_CHARACTER", HighlighterColors.BAD_CHARACTER);
    public static final TextAttributesKey FUN_DEF =
            createTextAttributesKey("ROSEGOLD_FUN_DEF", DefaultLanguageHighlighterColors.FUNCTION_DECLARATION);
    public static final TextAttributesKey FUN_CALL =
            createTextAttributesKey("ROSEGOLD_FUN_CALL", DefaultLanguageHighlighterColors.FUNCTION_CALL);

    private static final TextAttributesKey[] EMPTY = new TextAttributesKey[0];

    @Override
    public @NotNull Lexer getHighlightingLexer() {
        return new RoseGoldLexer();
    }

    @Override
    public TextAttributesKey @NotNull [] getTokenHighlights(IElementType t) {
        if (t.equals(RoseGoldTokenTypes.KEYWORD)) return one(KEYWORD);
        if (t.equals(RoseGoldTokenTypes.TYPE)) return one(TYPE);
        if (t.equals(RoseGoldTokenTypes.IDENTIFIER)) return one(IDENTIFIER);
        if (t.equals(RoseGoldTokenTypes.NUMBER)) return one(NUMBER);
        if (t.equals(RoseGoldTokenTypes.STRING)) return one(STRING);
        if (t.equals(RoseGoldTokenTypes.COMMENT)) return one(COMMENT);
        if (t.equals(RoseGoldTokenTypes.OPERATOR)) return one(OPERATOR);
        if (t.equals(RoseGoldTokenTypes.LPAREN) || t.equals(RoseGoldTokenTypes.RPAREN)) return one(PARENS);
        if (t.equals(RoseGoldTokenTypes.LBRACKET) || t.equals(RoseGoldTokenTypes.RBRACKET)) return one(BRACKETS);
        if (t.equals(RoseGoldTokenTypes.LBRACE) || t.equals(RoseGoldTokenTypes.RBRACE)) return one(BRACES);
        if (t.equals(TokenType.BAD_CHARACTER)) return one(BAD_CHARACTER);
        return EMPTY;
    }

    private static TextAttributesKey[] one(TextAttributesKey key) {
        return new TextAttributesKey[]{key};
    }
}
