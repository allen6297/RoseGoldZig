package org.rosegold.ide;

import com.intellij.openapi.fileChooser.FileChooserDescriptorFactory;
import com.intellij.openapi.options.Configurable;
import com.intellij.openapi.ui.TextFieldWithBrowseButton;
import com.intellij.ui.components.JBLabel;
import com.intellij.util.ui.FormBuilder;
import org.jetbrains.annotations.Nls;
import org.jetbrains.annotations.Nullable;

import javax.swing.JComponent;
import javax.swing.JPanel;

public final class RoseGoldConfigurable implements Configurable {
    private TextFieldWithBrowseButton pathField;

    @Override
    public @Nls(capitalization = Nls.Capitalization.Title) String getDisplayName() {
        return "RoseGold";
    }

    @Override
    public @Nullable JComponent createComponent() {
        pathField = new TextFieldWithBrowseButton();
        pathField.addBrowseFolderListener(
                "RoseGold Executable", "Select the RoseGold_Zig executable", null,
                FileChooserDescriptorFactory.createSingleFileDescriptor());
        return FormBuilder.createFormBuilder()
                .addLabeledComponent(new JBLabel("RoseGold_Zig executable:"), pathField, 1, false)
                .addComponentFillVertically(new JPanel(), 0)
                .getPanel();
    }

    @Override
    public boolean isModified() {
        return !pathField.getText().trim().equals(RoseGoldSettings.getInstance().executablePath);
    }

    @Override
    public void apply() {
        RoseGoldSettings.getInstance().executablePath = pathField.getText().trim();
    }

    @Override
    public void reset() {
        pathField.setText(RoseGoldSettings.getInstance().executablePath);
    }
}
