package org.rosegold.ide.debug;

import com.intellij.icons.AllIcons;
import com.intellij.xdebugger.frame.XValue;
import com.intellij.xdebugger.frame.XValueNode;
import com.intellij.xdebugger.frame.XValuePlace;
import org.jetbrains.annotations.NotNull;

/** A single local variable in the Variables view (name + stringified value). */
public final class RoseGoldValue extends XValue {
    private final String value;

    public RoseGoldValue(String value) {
        this.value = value;
    }

    @Override
    public void computePresentation(@NotNull XValueNode node, @NotNull XValuePlace place) {
        node.setPresentation(AllIcons.Nodes.Variable, null, value, false);
    }
}
