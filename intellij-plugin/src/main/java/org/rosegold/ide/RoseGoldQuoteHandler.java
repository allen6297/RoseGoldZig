package org.rosegold.ide;

import com.intellij.codeInsight.editorActions.SimpleTokenSetQuoteHandler;

/**
 * Auto-closes and skips over {@code "} string quotes (typing {@code "} inserts a
 * matching {@code "}; typing over the closing quote steps past it).
 */
public final class RoseGoldQuoteHandler extends SimpleTokenSetQuoteHandler {
    public RoseGoldQuoteHandler() {
        super(RoseGoldTokenTypes.STRING);
    }
}
