package org.rosegold.ide;

import com.intellij.psi.tree.IElementType;
import com.intellij.psi.tree.TokenSet;

/** Lexer token categories, tuned for highlighting rather than a full grammar. */
public interface RoseGoldTokenTypes {
    IElementType KEYWORD = new RoseGoldTokenType("KEYWORD");
    IElementType TYPE = new RoseGoldTokenType("TYPE");
    IElementType IDENTIFIER = new RoseGoldTokenType("IDENTIFIER");
    // Highlighting-only refinements of IDENTIFIER: an identifier right after
    // `func` (a declaration) and one immediately before `(` (a call). Emitted only
    // by the highlighting lexer, so the parser's PSI still sees plain IDENTIFIERs
    // (keeping references, quick-doc, and find-usages working).
    IElementType FUNC_DECL = new RoseGoldTokenType("FUNC_DECL");
    IElementType FUNC_CALL = new RoseGoldTokenType("FUNC_CALL");
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
    TokenSet IDENTIFIERS = TokenSet.create(IDENTIFIER);
}
