package org.rosegold.ide;

import java.util.ArrayList;
import java.util.List;

/** A declaration found by a lightweight line scan (see {@link RoseGoldDeclarations}). */
public final class RoseGoldDeclaration {
    public enum Kind {
        FUNCTION, CLASS, STRUCT, ENUM, SIGNAL, CONST, VAR
    }

    public final Kind kind;
    public final String name;
    /** Offset of the declared name in the document (for navigation). */
    public final int nameOffset;
    /** Leading-whitespace width of the header line (for nesting). */
    public final int indent;
    public final List<RoseGoldDeclaration> children = new ArrayList<>();

    public RoseGoldDeclaration(Kind kind, String name, int nameOffset, int indent) {
        this.kind = kind;
        this.name = name;
        this.nameOffset = nameOffset;
        this.indent = indent;
    }
}
