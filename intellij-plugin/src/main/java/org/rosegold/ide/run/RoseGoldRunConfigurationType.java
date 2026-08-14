package org.rosegold.ide.run;

import com.intellij.execution.configurations.ConfigurationTypeBase;
import com.intellij.execution.configurations.ConfigurationTypeUtil;
import com.intellij.openapi.util.NotNullLazyValue;
import org.rosegold.ide.RoseGoldIcons;

public final class RoseGoldRunConfigurationType extends ConfigurationTypeBase {
    static final String ID = "RoseGoldRunConfiguration";

    public RoseGoldRunConfigurationType() {
        super(ID, "RoseGold", "Run a RoseGold program",
                NotNullLazyValue.createValue(() -> RoseGoldIcons.FILE));
        addFactory(new RoseGoldConfigurationFactory(this));
    }

    public static RoseGoldRunConfigurationType getInstance() {
        return ConfigurationTypeUtil.findConfigurationType(RoseGoldRunConfigurationType.class);
    }
}
