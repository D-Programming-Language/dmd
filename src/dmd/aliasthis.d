/**
 * Implements the `alias this` symbol.
 *
 * Specification: $(LINK2 https://dlang.org/spec/class.html#alias-this, Alias This)
 *
 * Copyright:   Copyright (C) 1999-2020 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 http://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/src/dmd/aliasthis.d, _aliasthis.d)
 * Documentation:  https://dlang.org/phobos/dmd_aliasthis.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/aliasthis.d
 */

module dmd.aliasthis;

import dmd.dsymbol : Dsymbol;
import dmd.globals : Loc;
import dmd.identifier : Identifier;
import dmd.visitor : Visitor;

/***********************************************************
 * alias ident this;
 */
extern (C++) final class AliasThis : Dsymbol
{
    Identifier ident;
    /// The symbol this `alias this` resolves to
    Dsymbol sym;
    /// Whether this `alias this` is deprecated or not
    bool isDeprecated_;

    extern (D) this(const ref Loc loc, Identifier ident)
    {
        super(loc, null);    // it's anonymous (no identifier)
        this.ident = ident;
    }

    override Dsymbol syntaxCopy(Dsymbol s)
    {
        assert(!s);
        auto at = new AliasThis(loc, ident);
        at.comment = comment;
        return at;
    }

    override const(char)* kind() const
    {
        return "alias this";
    }

    AliasThis isAliasThis()
    {
        return this;
    }

    override void accept(Visitor v)
    {
        v.visit(this);
    }

    override bool isDeprecated() const
    {
        return this.isDeprecated_;
    }
}
