package org.rosegold.ide;

import org.junit.Test;

import java.util.Set;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;

/** Unit tests for the inferred-type heuristic behind the type inlay hints. */
public class RoseGoldTypeHintsTest {
    private static String infer(String init) {
        return RoseGoldTypeHintsProvider.inferType(init, Set.of("Point"), Set.of("Color"));
    }

    @Test
    public void literals() {
        assertEquals("int", infer("5"));
        assertEquals("int", infer("1_000"));
        assertEquals("int", infer("0xFF"));
        assertEquals("float", infer("3.5"));
        assertEquals("str", infer("\"hi\""));
        assertEquals("bool", infer("true"));
        assertEquals("bool", infer("false"));
        assertEquals("list", infer("[1, 2, 3]"));
        assertEquals("map", infer("{1: 2}"));
        assertEquals("list", infer("0..10")); // a range is a list<int>
        assertEquals("tuple", infer("(1, 2)"));
    }

    @Test
    public void constructorsAndEnums() {
        assertEquals("Point", infer("Point(1, 2)"));
        assertEquals("Color", infer("Color.RED"));
    }

    @Test
    public void ambiguousGetsNoHint() {
        assertNull(infer("nil"));
        assertNull(infer("foo()")); // an unknown call
        assertNull(infer("x")); // a bare identifier
        assertNull(infer("func(): 1")); // a lambda
        assertNull(infer("(x)")); // grouping, not a tuple
        assertNull(infer("truthy")); // has a 'true' prefix but is a longer word
        assertNull(infer("Unknown(1)")); // not a known class/struct
        assertNull(infer("Color(1)")); // an enum isn't constructed with ()
    }
}
