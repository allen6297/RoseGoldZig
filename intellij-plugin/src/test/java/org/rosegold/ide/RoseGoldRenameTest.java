package org.rosegold.ide;

import com.intellij.openapi.command.WriteCommandAction;
import com.intellij.openapi.editor.Document;
import com.intellij.testFramework.fixtures.BasePlatformTestCase;

/**
 * Verifies {@link RoseGoldRenameHandler}'s core rename logic through the fixture,
 * bypassing the modal input dialog by calling {@code applyRename} directly.
 */
public class RoseGoldRenameTest extends BasePlatformTestCase {

    /** Rename a local from its declaration to another name. */
    private void rename(String newName) {
        int offset = myFixture.getCaretOffset();
        WriteCommandAction.runWriteCommandAction(getProject(), () -> {
            Document doc = myFixture.getEditor().getDocument();
            RoseGoldRenameHandler.applyRename(doc, offset, newName);
        });
    }

    /**
     * Every occurrence in code is renamed — including inside a `${…}` hole — while
     * the surrounding string text and a `##` comment keep the old name.
     */
    public void testRenamesCodeAndHolesButNotStringsOrComments() {
        myFixture.configureByText("a.rg",
                "func main():\n" +
                "    var <caret>count = 1\n" +
                "    count = count + 1\n" +
                "    print(\"count=${count}\")  ## count note\n");
        rename("total");
        myFixture.checkResult(
                "func main():\n" +
                "    var total = 1\n" +
                "    total = total + 1\n" +
                "    print(\"count=${total}\")  ## count note\n");
    }

    /** Renaming from a use site (not the declaration) still updates every occurrence. */
    public void testRenamesFromUseSite() {
        myFixture.configureByText("b.rg",
                "func add(n: int) -> int:\n" +
                "    return <caret>n + n\n");
        rename("x");
        myFixture.checkResult(
                "func add(x: int) -> int:\n" +
                "    return x + x\n");
    }

    /** A caret that isn't on an identifier leaves the document unchanged. */
    public void testNoIdentifierUnderCaretIsNoOp() {
        myFixture.configureByText("c.rg",
                "func main():\n" +
                "    var a = 1 <caret>+ 2\n");
        rename("b");
        myFixture.checkResult(
                "func main():\n" +
                "    var a = 1 + 2\n");
    }

    /** The new-name validator accepts identifiers and rejects keywords / junk. */
    public void testNameValidator() {
        assertTrue(RoseGoldRenameHandler.isValidNewName("total"));
        assertTrue(RoseGoldRenameHandler.isValidNewName("_x2"));
        assertFalse(RoseGoldRenameHandler.isValidNewName("func"));   // keyword
        assertFalse(RoseGoldRenameHandler.isValidNewName("2nd"));    // starts with a digit
        assertFalse(RoseGoldRenameHandler.isValidNewName("a b"));    // space
        assertFalse(RoseGoldRenameHandler.isValidNewName(""));       // empty
    }
}
