package org.rosegold.ide;

import com.intellij.lang.Language;

public final class RoseGoldLanguage extends Language {
    public static final RoseGoldLanguage INSTANCE = new RoseGoldLanguage();

    private RoseGoldLanguage() {
        super("RoseGold");
    }
}
