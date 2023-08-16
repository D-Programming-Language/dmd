/**
 * Inline assembler for the D programming language compiler.
 *
 * Specification: $(LINK2 https://dlang.org/spec/iasm.html, Inline Assembler)
 *
 *              Copyright (C) 2018-2023 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 https://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/src/dmd/iasm.d, _iasm.d)
 * Documentation:  https://dlang.org/phobos/dmd_iasm.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/iasm.d
 */

module dmd.iasm;

import core.stdc.stdio;

import dmd.dscope;
import dmd.expression;
import dmd.func;
import dmd.mtype;
import dmd.tokens;
import dmd.statement;
import dmd.statementsem;

version (IN_GCC)
{
    import dmd.iasmgcc;
}
else
{
    import dmd.iasmdmd;
    version = MARS;
}

/************************ AsmStatement ***************************************/

extern(C++) Statement asmSemantic(AsmStatement s, Scope *sc) nothrow
{
    //printf("AsmStatement.semantic()\n");

    FuncDeclaration fd = sc.parent.isFuncDeclaration();
    assert(fd);

    if (!s.tokens)
        return null;

    // Assume assembler code takes care of setting the return value
    sc.func.hasReturnExp |= 8;

    version (MARS)
    {
        /* If it starts with a string literal, it's gcc inline asm
         */
        if (s.tokens.value == TOK.string_)
        {
            /* Replace the asm statement with an assert(0, msg) that trips at runtime.
             */
            const loc = s.loc;
            auto e = new IntegerExp(loc, 0, Type.tint32);
            auto msg = new StringExp(loc, "Gnu Asm not supported - compile this function with gcc or clang");
            auto ae = new AssertExp(loc, e, msg);
            auto se = new ExpStatement(loc, ae);
            return statementSemantic(se, sc);
        }
        auto ias = new InlineAsmStatement(s.loc, s.tokens);
        return inlineAsmSemantic(ias, sc);
    }
    else version (IN_GCC)
    {
        auto eas = new GccAsmStatement(s.loc, s.tokens);
        return gccAsmSemantic(eas, sc);
    }
    else
    {
        s.error("D inline assembler statements are not supported");
        return new ErrorStatement();
    }
}
