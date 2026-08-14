package org.rosegold.ide;

import com.intellij.openapi.editor.colors.TextAttributesKey;
import com.intellij.openapi.fileTypes.SyntaxHighlighter;
import com.intellij.openapi.options.colors.AttributesDescriptor;
import com.intellij.openapi.options.colors.ColorDescriptor;
import com.intellij.openapi.options.colors.ColorSettingsPage;
import org.jetbrains.annotations.NotNull;
import org.jetbrains.annotations.Nullable;

import javax.swing.Icon;
import java.util.Map;

public final class RoseGoldColorSettingsPage implements ColorSettingsPage {
    private static final AttributesDescriptor[] DESCRIPTORS = new AttributesDescriptor[]{
            new AttributesDescriptor("Keyword", RoseGoldSyntaxHighlighter.KEYWORD),
            new AttributesDescriptor("Type", RoseGoldSyntaxHighlighter.TYPE),
            new AttributesDescriptor("Identifier", RoseGoldSyntaxHighlighter.IDENTIFIER),
            new AttributesDescriptor("Number", RoseGoldSyntaxHighlighter.NUMBER),
            new AttributesDescriptor("String", RoseGoldSyntaxHighlighter.STRING),
            new AttributesDescriptor("Line comment", RoseGoldSyntaxHighlighter.COMMENT),
            new AttributesDescriptor("Operator", RoseGoldSyntaxHighlighter.OPERATOR),
            new AttributesDescriptor("Parentheses", RoseGoldSyntaxHighlighter.PARENS),
            new AttributesDescriptor("Brackets", RoseGoldSyntaxHighlighter.BRACKETS),
            new AttributesDescriptor("Braces", RoseGoldSyntaxHighlighter.BRACES),
            new AttributesDescriptor("Function call", RoseGoldSyntaxHighlighter.FUN_CALL),
            new AttributesDescriptor("Function declaration", RoseGoldSyntaxHighlighter.FUN_DEF)
    };

    @Override
    public @Nullable Icon getIcon() {
        return RoseGoldIcons.FILE;
    }

    @Override
    public @NotNull SyntaxHighlighter getHighlighter() {
        return new RoseGoldSyntaxHighlighter();
    }

    @Override
    public @NotNull String getDemoText() {
        return "## RoseGold sample\n" +
                "import mathutil\n\n" +
                "enum Color { RED, GREEN }\n\n" +
                "class Circle extends Shape:\n" +
                "    var r: float = 1.0\n" +
                "    func <fdef>area</fdef>() -> float:\n" +
                "        return 3.14 * r * r\n\n" +
                "func <fdef>main</fdef>():\n" +
                "    var c = <fcall>Circle</fcall>()\n" +
                "    <fcall>print</fcall>(\"area = ${c.<fcall>area</fcall>()}\")\n" +
                "    for i in 0..5:\n" +
                "        <fcall>print</fcall>(i)\n";
    }

    @Override
    public @Nullable Map<String, TextAttributesKey> getAdditionalHighlightingTagToDescriptorMap() {
        return Map.of(
                "fdef", RoseGoldSyntaxHighlighter.FUN_DEF,
                "fcall", RoseGoldSyntaxHighlighter.FUN_CALL);
    }

    @Override
    public AttributesDescriptor @NotNull [] getAttributeDescriptors() {
        return DESCRIPTORS;
    }

    @Override
    public ColorDescriptor @NotNull [] getColorDescriptors() {
        return ColorDescriptor.EMPTY_ARRAY;
    }

    @Override
    public @NotNull String getDisplayName() {
        return "RoseGold";
    }
}
