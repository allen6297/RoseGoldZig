package org.rosegold.ide;

import com.intellij.execution.lineMarker.RunLineMarkerContributor;
import com.intellij.psi.PsiElement;
import com.intellij.testFramework.fixtures.BasePlatformTestCase;

/** Verifies the gutter Run icon appears only on a top-level `func main()`. */
public class RoseGoldRunLineMarkerTest extends BasePlatformTestCase {

    private RunLineMarkerContributor.Info infoAtCaret() {
        PsiElement leaf = myFixture.getFile().findElementAt(myFixture.getCaretOffset());
        return new RoseGoldRunLineMarkerContributor().getInfo(leaf);
    }

    public void testGutterOnMainDeclaration() {
        myFixture.configureByText("a.rg", "func ma<caret>in():\n    print(1)\n");
        assertNotNull("main() declaration should get a run gutter icon", infoAtCaret());
    }

    public void testGutterOnPubMainDeclaration() {
        myFixture.configureByText("b.rg", "pub func ma<caret>in():\n    print(1)\n");
        assertNotNull(infoAtCaret());
    }

    public void testNoGutterOnMainCall() {
        myFixture.configureByText("c.rg",
                "func main():\n" +
                "    pass\n" +
                "func other():\n" +
                "    ma<caret>in()\n");
        assertNull("a call to main() is not a declaration", infoAtCaret());
    }

    public void testNoGutterOnOtherFunction() {
        myFixture.configureByText("d.rg", "func hel<caret>per():\n    pass\n");
        assertNull(infoAtCaret());
    }
}
