package org.rosegold.ide;

import com.intellij.psi.tree.IElementType;
import com.intellij.psi.tree.TokenSet;

/** Lexer token categories, tuned for highlighting rather than a full grammar. */
public interface RoseGoldTokenTypes {
    IElementType KEYWORD = new RoseGoldTokenType("KEYWORD");
    IElementType TYPE = new RoseGoldTokenType("TYPE");
    IElementType IDENTIFIER = new RoseGoldTokenType("IDENTIFIER");
    IElementType NUMBER = new RoseGoldTokenType("NUMBER");
    IElementType STRING = new RoseGoldTokenType("STRING");
    IElementType COMMENT = new RoseGoldTokenType("COMMENT");
    IElementType OPERATOR = new RoseGoldTokenType("OPERATOR");
    IElementType PUNCTUATION = new RoseGoldTokenType("PUNCTUATION");

    IElementType LPAREN = new RoseGoldTokenType("LPAREN");
    IElementType RPAREN = new RoseGoldTokenType("RPAREN");
    IElementType LBRACKET = new RoseGoldTokenType("LBRACKET");
    IElementType RBRACKET = new RoseGoldTokenType("RBRACKET");
    IElementType LBRACE = new RoseGoldTokenType("LBRACE");
    IElementType RBRACE = new RoseGoldTokenType("RBRACE");

    TokenSet COMMENTS = TokenSet.create(COMMENT);
    TokenSet STRINGS = TokenSet.create(STRING);
}
