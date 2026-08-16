package org.rosegold.ide;

import com.intellij.psi.PsiElement;
import com.intellij.testFramework.fixtures.BasePlatformTestCase;

/**
 * Drives the quick-doc / hover pipeline (the registered
 * {@link RoseGoldDocumentationProvider}) through the fixture — resolving the doc
 * target the same way the platform does, then generating its doc.
 */
public class RoseGoldDocumentationTest extends BasePlatformTestCase {

    private String docAtCaret() {
        PsiElement original = myFixture.getFile().findElementAt(myFixture.getCaretOffset());
        RoseGoldDocumentationProvider provider = new RoseGoldDocumentationProvider();
        PsiElement target = provider.getCustomDocumentationElement(
                myFixture.getEditor(), myFixture.getFile(), original, myFixture.getCaretOffset());
        return provider.generateDoc(target != null ? target : original, original);
    }

    /** Hovering a user function shows its signature and the `##` block above it. */
    public void testDocForUserFunction() {
        myFixture.configureByText("a.rg",
                "## Add two ints.\n" +
                "## Returns their sum.\n" +
                "func ad<caret>d(a: int, b: int) -> int:\n" +
                "    return a + b\n");
        String doc = docAtCaret();
        assertNotNull(doc);
        assertTrue(doc, doc.contains("func add(a: int, b: int) -&gt; int"));
        assertTrue(doc, doc.contains("Add two ints."));
        assertTrue(doc, doc.contains("Returns their sum."));
    }

    /** Hovering a call site resolves to the declaration's doc. */
    public void testDocAtCallSite() {
        myFixture.configureByText("b.rg",
                "## The greeting.\n" +
                "func greet() -> str:\n" +
                "    return \"hi\"\n" +
                "\n" +
                "func main():\n" +
                "    print(gr<caret>eet())\n");
        String doc = docAtCaret();
        assertNotNull(doc);
        assertTrue(doc, doc.contains("func greet() -&gt; str"));
        assertTrue(doc, doc.contains("The greeting."));
    }

    /** A class shows its header (with extends) even without a doc comment. */
    public void testDocForClassWithoutComment() {
        myFixture.configureByText("c.rg",
                "class Base:\n" +
                "    pass\n" +
                "\n" +
                "class Deri<caret>ved extends Base:\n" +
                "    var x: int = 0\n");
        String doc = docAtCaret();
        assertNotNull(doc);
        assertTrue(doc, doc.contains("class Derived extends Base"));
    }

    /** Builtins still resolve from the table. */
    public void testDocForBuiltin() {
        myFixture.configureByText("d.rg",
                "func main():\n" +
                "    print(le<caret>n([1, 2, 3]))\n");
        String doc = docAtCaret();
        assertNotNull(doc);
        assertTrue(doc, doc.contains("length of a list"));
    }
}
