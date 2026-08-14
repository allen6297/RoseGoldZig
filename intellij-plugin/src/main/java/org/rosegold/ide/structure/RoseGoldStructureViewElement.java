package org.rosegold.ide.structure;

import com.intellij.icons.AllIcons;
import com.intellij.ide.projectView.PresentationData;
import com.intellij.ide.structureView.StructureViewTreeElement;
import com.intellij.ide.util.treeView.smartTree.SortableTreeElement;
import com.intellij.ide.util.treeView.smartTree.TreeElement;
import com.intellij.navigation.ItemPresentation;
import com.intellij.pom.Navigatable;
import com.intellij.psi.PsiElement;
import com.intellij.psi.PsiFile;
import org.jetbrains.annotations.NotNull;
import org.rosegold.ide.RoseGoldDeclaration;
import org.rosegold.ide.RoseGoldDeclarations;

import javax.swing.Icon;
import java.util.ArrayList;
import java.util.List;

public final class RoseGoldStructureViewElement implements StructureViewTreeElement, SortableTreeElement {
    private final PsiFile file;
    private final RoseGoldDeclaration decl; // null → the file root

    public RoseGoldStructureViewElement(PsiFile file, RoseGoldDeclaration decl) {
        this.file = file;
        this.decl = decl;
    }

    /** The value used for selection sync and navigation — a navigable leaf. */
    @Override
    public Object getValue() {
        if (decl == null) {
            return file;
        }
        PsiElement leaf = file.findElementAt(decl.nameOffset);
        return leaf != null ? leaf : file;
    }

    @Override
    public @NotNull ItemPresentation getPresentation() {
        if (decl == null) {
            return new PresentationData(file.getName(), null, file.getFileType().getIcon(), null);
        }
        return new PresentationData(decl.name, null, iconFor(decl.kind), null);
    }

    @Override
    public TreeElement @NotNull [] getChildren() {
        List<RoseGoldDeclaration> source = (decl == null) ? RoseGoldDeclarations.scan(file.getText()) : decl.children;
        List<TreeElement> children = new ArrayList<>(source.size());
        for (RoseGoldDeclaration c : source) {
            children.add(new RoseGoldStructureViewElement(file, c));
        }
        return children.toArray(TreeElement.EMPTY_ARRAY);
    }

    @Override
    public @NotNull String getAlphaSortKey() {
        return decl == null ? file.getName() : decl.name;
    }

    public void navigateIfPossible(boolean requestFocus) {
        Object v = getValue();
        if (v instanceof Navigatable n && n.canNavigate()) {
            n.navigate(requestFocus);
        }
    }

    private static Icon iconFor(RoseGoldDeclaration.Kind kind) {
        return switch (kind) {
            case FUNCTION -> AllIcons.Nodes.Method;
            case CLASS -> AllIcons.Nodes.Class;
            case STRUCT -> AllIcons.Nodes.Class;
            case ENUM -> AllIcons.Nodes.Enum;
            case SIGNAL -> AllIcons.Nodes.Interface;
            case CONST -> AllIcons.Nodes.Constant;
            case VAR -> AllIcons.Nodes.Variable;
        };
    }
}
