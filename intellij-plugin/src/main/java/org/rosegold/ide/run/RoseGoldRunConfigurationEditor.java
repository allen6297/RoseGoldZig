package org.rosegold.ide.run;

import com.intellij.openapi.fileChooser.FileChooserDescriptorFactory;
import com.intellij.openapi.options.SettingsEditor;
import com.intellij.openapi.ui.TextFieldWithBrowseButton;
import com.intellij.ui.components.JBCheckBox;
import com.intellij.ui.components.JBLabel;
import com.intellij.util.ui.FormBuilder;
import org.jetbrains.annotations.NotNull;

import javax.swing.JComponent;
import javax.swing.JPanel;

public final class RoseGoldRunConfigurationEditor extends SettingsEditor<RoseGoldRunConfiguration> {
    private final JPanel panel;
    private final TextFieldWithBrowseButton fileField = new TextFieldWithBrowseButton();
    private final JBCheckBox vmCheck = new JBCheckBox("Run on the bytecode VM (--vm)");

    public RoseGoldRunConfigurationEditor() {
        fileField.addBrowseFolderListener(null,
                FileChooserDescriptorFactory.createSingleFileDescriptor("rg")
                        .withTitle("RoseGold File")
                        .withDescription("Select the .rg file to run"));
        panel = FormBuilder.createFormBuilder()
                .addLabeledComponent(new JBLabel("RoseGold file:"), fileField, 1, false)
                .addComponent(vmCheck)
                .getPanel();
    }

    @Override
    protected void resetEditorFrom(@NotNull RoseGoldRunConfiguration s) {
        fileField.setText(s.getFilePath());
        vmCheck.setSelected(s.isUseVm());
    }

    @Override
    protected void applyEditorTo(@NotNull RoseGoldRunConfiguration s) {
        s.setFilePath(fileField.getText().trim());
        s.setUseVm(vmCheck.isSelected());
    }

    @Override
    protected @NotNull JComponent createEditor() {
        return panel;
    }
}
