package org.rosegold.ide;

import com.intellij.testFramework.fixtures.BasePlatformTestCase;

import java.util.List;

/**
 * Drives the real completion pipeline (the registered
 * {@link RoseGoldCompletionContributor}) through the platform test fixture, so
 * member completion is verified end-to-end without an IDE.
 */
public class RoseGoldCompletionTest extends BasePlatformTestCase {

    /** `p.` on a local typed by annotation offers the type's fields and methods. */
    public void testMemberCompletionFromAnnotation() {
        myFixture.configureByText("a.rg",
                "struct Point:\n" +
                "    var x: int = 0\n" +
                "    var y: int = 0\n" +
                "    func dist() -> float:\n" +
                "        return 0.0\n" +
                "\n" +
                "func main():\n" +
                "    var p: Point = Point()\n" +
                "    print(p.<caret>)\n");
        myFixture.completeBasic();
        List<String> items = myFixture.getLookupElementStrings();
        assertNotNull("expected a completion popup for a typed local", items);
        assertTrue("fields should be offered: " + items, items.contains("x") && items.contains("y"));
        assertTrue("methods should be offered: " + items, items.contains("dist"));
    }

    /** The type can be inferred from a constructor call (`var s = Set()`). */
    public void testMemberCompletionFromConstructor() {
        myFixture.configureByText("b.rg",
                "class Box:\n" +
                "    var value: int = 0\n" +
                "    func get() -> int:\n" +
                "        return value\n" +
                "\n" +
                "func main():\n" +
                "    var b = Box()\n" +
                "    print(b.<caret>)\n");
        myFixture.completeBasic();
        List<String> items = myFixture.getLookupElementStrings();
        assertNotNull(items);
        assertTrue("expected get/value: " + items, items.contains("get") && items.contains("value"));
    }

    /** A method parameter's type drives completion inside the method body too. */
    public void testMemberCompletionFromParameter() {
        myFixture.configureByText("c.rg",
                "struct Vec:\n" +
                "    var dx: int = 0\n" +
                "\n" +
                "func use(v: Vec):\n" +
                "    print(v.<caret>)\n");
        myFixture.completeBasic();
        List<String> items = myFixture.getLookupElementStrings();
        assertNotNull(items);
        assertTrue("expected dx: " + items, items.contains("dx"));
    }

    /** An untyped/unknown receiver offers no members (no false suggestions). */
    public void testUnknownReceiverOffersNoMembers() {
        myFixture.configureByText("d.rg",
                "struct Point:\n" +
                "    var x: int = 0\n" +
                "\n" +
                "func main():\n" +
                "    var q = 5\n" +
                "    print(q.<caret>)\n");
        myFixture.completeBasic();
        List<String> items = myFixture.getLookupElementStrings();
        // Either no popup, or one that doesn't contain the unrelated type's field.
        assertTrue("an int local must not get Point's members: " + items,
                items == null || !items.contains("x"));
    }
}
