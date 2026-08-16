package org.rosegold.ide;

import com.intellij.psi.PsiElement;
import com.intellij.testFramework.fixtures.BasePlatformTestCase;

/**
 * Resolution logic of {@link RoseGoldReference} (go-to-definition), including
 * across imported modules. The reference is constructed directly on the
 * identifier leaf under the caret (as {@link RoseGoldReferenceContributor} does).
 */
public class RoseGoldReferenceTest extends BasePlatformTestCase {

    private PsiElement resolveAtCaret() {
        PsiElement leaf = myFixture.getFile().findElementAt(myFixture.getCaretOffset());
        assertNotNull("no leaf under caret", leaf);
        return new RoseGoldReference(leaf).resolve();
    }

    /** `mod.member` resolves to the `pub` declaration in the imported module's file. */
    public void testCrossModuleGoto() {
        myFixture.addFileToProject("util.rg",
                "## Doubles n.\n" +
                "pub func twice(n: int) -> int:\n" +
                "    return n + n\n");
        myFixture.configureByText("main.rg",
                "import util\n" +
                "\n" +
                "func main():\n" +
                "    print(util.tw<caret>ice(21))\n");
        PsiElement target = resolveAtCaret();
        assertNotNull("cross-module reference should resolve", target);
        assertEquals("util.rg", target.getContainingFile().getName());
    }

    /** A private (non-pub) module member is not exported, so it doesn't resolve. */
    public void testPrivateModuleMemberDoesNotResolve() {
        myFixture.addFileToProject("util.rg",
                "func secret() -> int:\n" +
                "    return 1\n");
        myFixture.configureByText("main.rg",
                "import util\n" +
                "\n" +
                "func main():\n" +
                "    print(util.sec<caret>ret())\n");
        assertNull(resolveAtCaret());
    }

    /** Same-file go-to still works: a call resolves to the local declaration. */
    public void testSameFileGoto() {
        myFixture.configureByText("a.rg",
                "func helper() -> int:\n" +
                "    return 1\n" +
                "func main():\n" +
                "    print(hel<caret>per())\n");
        PsiElement target = resolveAtCaret();
        assertNotNull(target);
        assertEquals("a.rg", target.getContainingFile().getName());
    }
}
