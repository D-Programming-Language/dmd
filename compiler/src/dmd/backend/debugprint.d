/**
 * Pretty print data structures
 *
 * Compiler implementation of the
 * $(LINK2 https://www.dlang.org, D programming language).
 *
 * Copyright:   Copyright (C) 1985-1998 by Symantec
 *              Copyright (C) 2000-2024 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 https://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/src/dmd/backend/debug.c, backend/debugprint.d)
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/backend/debug.c
 */

module dmd.backend.debugprint;

import core.stdc.stdio;
import core.stdc.stdlib;
import core.stdc.string;

import dmd.backend.cdef;
import dmd.backend.cc;
import dmd.backend.el;
import dmd.backend.global;
import dmd.backend.code;
import dmd.backend.x86.code_x86;
import dmd.backend.goh;
import dmd.backend.oper;
import dmd.backend.symtab;
import dmd.backend.ty;
import dmd.backend.type;

import dmd.backend.dlist;
import dmd.backend.dvec;


nothrow:
@safe:

@trusted
void ferr(const(char)* p) { printf("%s", p); }

/*******************************
 * Write out storage class.
 */

@trusted
const(char)* class_str(SC c)
{
    __gshared const char[10][SCMAX] sc =
    [
        "unde",
        "auto",
        "static",
        "thread",
        "extern",
        "register",
        "pseudo",
        "global",
        "comdat",
        "parameter",
        "regpar",
        "fastpar",
        "shadowreg",
        "typedef",
        "explicit",
        "mutable",
        "label",
        "struct",
        "enum",
        "field",
        "const",
        "member",
        "anon",
        "inline",
        "sinline",
        "einline",
        "overload",
        "friend",
        "virtual",
        "locstat",
        "template",
        "functempl",
        "ftexpspec",
        "linkage",
        "public",
        "comdef",
        "bprel",
        "namespace",
        "alias",
        "funcalias",
        "memalias",
        "stack",
        "adl",
    ];
    __gshared char[9 + 3] buffer;

    static assert(sc.length == SCMAX);
    if (cast(uint) c < SCMAX)
        snprintf(buffer.ptr,buffer.length,"SC%s",sc[c].ptr);
    else
        snprintf(buffer.ptr,buffer.length,"SC%u",cast(uint)c);
    assert(strlen(buffer.ptr) < buffer.length);
    return buffer.ptr;
}

/***************************
 * Convert OPER to string.
 * Params:
 *      oper = operator number
 * Returns:
 *      pointer to string
 */

const(char)* oper_str(uint oper) pure
{
    assert(oper < OPMAX);
    return &debtab[oper][0];
}

/*******************************
 * Convert tym_t to string.
 * Params:
 *      ty = type number
 * Returns:
 *      pointer to malloc'd string
 */
@trusted
const(char)* tym_str(tym_t ty)
{
    enum MAX = 100;
    __gshared char[MAX + 1] buf;

    char* pstart = &buf[0];
    char* p = pstart;
    *p = 0;
    if (ty & mTYnear)
        strcat(p, "mTYnear|");
    if (ty & mTYfar)
        strcat(p, "mTYfar|");
    if (ty & mTYcs)
        strcat(p, "mTYcs|");
    if (ty & mTYconst)
        strcat(p, "mTYconst|");
    if (ty & mTYvolatile)
        strcat(p, "mTYvolatile|");
    if (ty & mTYshared)
        strcat(p, "mTYshared|");
    if (ty & mTYxmmgpr)
        strcat(p, "mTYxmmgpr|");
    if (ty & mTYgprxmm)
        strcat(p, "mTYgprxmm|");
    const tyb = tybasic(ty);
    if (tyb >= TYMAX)
    {
        printf("TY %x\n",cast(int)ty);
        assert(0);
    }
    strcat(p, "TY");
    strcat(p, tystring[tyb]);
    assert(strlen(p) <= MAX);
    return strdup(p);
}

/*******************************
 * Convert BC to string.
 * Params:
 *      bc = block exit code
 * Returns:
 *      pointer to string
 */
@trusted
const(char)* bc_str(uint bc)
{
    __gshared const char[9][BCMAX] bcs =
        ["BCunde  ","BCgoto  ","BCtrue  ","BCret   ","BCretexp",
         "BCexit  ","BCasm   ","BCswitch","BCifthen","BCjmptab",
         "BCtry   ","BCcatch ","BCjump  ",
         "BC_try  ","BC_filte","BC_final","BC_ret  ","BC_excep",
         "BCjcatch","BC_lpad ",
        ];

    return bcs[bc].ptr;
}

/************************
 * Write arglst
 */

@trusted
void WRarglst(list_t a)
{ int n = 1;

  if (!a) printf("0 args\n");
  while (a)
  {     const(char)* c = cast(const(char)*)list_ptr(a);
        printf("arg %d: '%s'\n", n, c ? c : "NULL");
        a = a.next;
        n++;
  }
}

/***************************
 * Write out equation elem.
 */

@trusted
void WReqn(elem *e)
{ __gshared int nest;

  if (!e)
        return;
  if (OTunary(e.Eoper))
  {
        ferr(oper_str(e.Eoper));
        ferr(" ");
        if (OTbinary(e.E1.Eoper))
        {       nest++;
                ferr("(");
                WReqn(e.E1);
                ferr(")");
                nest--;
        }
        else
                WReqn(e.E1);
  }
  else if (e.Eoper == OPcomma && !nest)
  {     WReqn(e.E1);
        printf(";\n\t");
        WReqn(e.E2);
  }
  else if (OTbinary(e.Eoper))
  {
        if (OTbinary(e.E1.Eoper))
        {       nest++;
                ferr("(");
                WReqn(e.E1);
                ferr(")");
                nest--;
        }
        else
                WReqn(e.E1);
        ferr(" ");
        ferr(oper_str(e.Eoper));
        ferr(" ");
        if (e.Eoper == OPstreq)
            printf("%d", cast(int)type_size(e.ET));
        ferr(" ");
        if (OTbinary(e.E2.Eoper))
        {       nest++;
                ferr("(");
                WReqn(e.E2);
                ferr(")");
                nest--;
        }
        else
                WReqn(e.E2);
  }
  else
  {
        switch (e.Eoper)
        {   case OPconst:
                elem_print_const(e);
                break;
            case OPrelconst:
                ferr("#");
                goto case OPvar;

            case OPvar:
                printf("%s",e.Vsym.Sident.ptr);
                if (e.Vsym.Ssymnum != SYMIDX.max)
                    printf("(%d)", cast(int) e.Vsym.Ssymnum);
                if (e.Voffset != 0)
                {
                    if (e.Voffset.sizeof == 8)
                        printf(".x%llx", cast(ulong)e.Voffset);
                    else
                        printf(".%d",cast(int)e.Voffset);
                }
                break;
            case OPasm:
            case OPstring:
                printf("\"%s\"",e.Vstring);
                if (e.Voffset)
                    printf("+%lld",cast(long)e.Voffset);
                break;
            case OPmark:
            case OPgot:
            case OPframeptr:
            case OPhalt:
            case OPdctor:
            case OPddtor:
                ferr(oper_str(e.Eoper));
                ferr(" ");
                break;
            case OPstrthis:
                break;
            default:
                ferr(oper_str(e.Eoper));
                assert(0);
        }
  }
}

@trusted
void WRblocklist(list_t bl)
{
    foreach (bl2; ListRange(bl))
    {
        block *b = list_block(bl2);

        if (b && b.Bweight)
            printf("B%d (%p) ",b.Bdfoidx,b);
        else
            printf("%p ",b);
    }
    ferr("\n");
}

@trusted
void WRdefnod(ref GlobalOptimizer go)
{ int i;

  for (i = 0; i < go.defnod.length; i++)
  {     printf("defnod[%d] in B%d = (", go.defnod[i].DNblock.Bdfoidx, i);
        WReqn(go.defnod[i].DNelem);
        printf(");\n");
  }
}

const(char)* fl_str(FL fl)
{
    immutable char*[FLMAX] fls =
    [   "FLunde",
        "FLconst",
        "FLoper",
        "FLfunc",
        "FLdata",
        "FLreg",
        "FLpseudo",
        "FLauto",
        "FLfast",
        "FLpara",
        "FLextern",
        "FLcode",
        "FLblock",
        "FLudata",
        "FLcs",
        "FLswitch",
        "FLfltrg",
        "FLoffset",
        "FLdatseg",
        "FLctor",
        "FLdtor",
        "FLregsave",
        "FLasm",
        "FLndp",
        "FLfardata",
        "FLcsdat",
        "FLlocalsize",
        "FLtlsdata",
        "FLbprel",
        "FLframehandler",
        "FLblockoff",
        "FLallocatmp",
        "FLstack",
        "FLdsymbol",
        "FLgot",
        "FLgotoff",
        "FLfuncarg",
    ];
    return fls[fl];
}

/***********************
 * Write out block.
 */

@trusted
void WRblock(block *b)
{
    if (OPTIMIZER)
    {
        if (b && b.Bweight)
                printf("B%d: (%p), weight=%d",b.Bdfoidx,b,b.Bweight);
        else
                printf("block %p",b);
        if (!b)
        {       ferr("\n");
                return;
        }
        printf(" flags=x%x weight=%d",b.Bflags,b.Bweight);
        //printf("\tfile %p, line %d",b.Bfilptr,b.Blinnum);
        printf(" %s Btry=%p Bindex=%d",bc_str(b.BC),b.Btry,b.Bindex);
        if (b.BC == BCtry)
            printf(" catchvar = %p",b.catchvar);
        printf("\n");
        printf("\tBpred: "); WRblocklist(b.Bpred);
        printf("\tBsucc: "); WRblocklist(b.Bsucc);
        if (b.Belem)
        {       if (debugf)                     /* if full output       */
                        elem_print(b.Belem);
                else
                {       ferr("\t");
                        WReqn(b.Belem);
                        printf(";\n");
                }
        }
        if (b.Bcode)
            b.Bcode.print();
        ferr("\n");
    }
    else
    {
        assert(b);
        printf("%2d: %s", b.Bnumber, bc_str(b.BC));
        if (b.Btry)
            printf(" Btry=B%d",b.Btry ? b.Btry.Bnumber : 0);
        if (b.Bindex)
            printf(" Bindex=%d",b.Bindex);
        if (b.BC == BC_finally)
            printf(" b_ret=B%d", b.b_ret ? b.b_ret.Bnumber : 0);
        if (b.Bsrcpos.Sfilename)
            printf(" %s(%u)", b.Bsrcpos.Sfilename, b.Bsrcpos.Slinnum);
        printf("\n");
        if (b.Belem)
        {
            if (debugf)
                elem_print(b.Belem);
            else
            {
                ferr("\t");
                WReqn(b.Belem);
                printf(";\n");
            }
        }
        if (b.Bpred)
        {
            printf("\tBpred:");
            foreach (bl; ListRange(b.Bpred))
                printf(" B%d",list_block(bl).Bnumber);
            printf("\n");
        }

        switch (b.BC)
        {
            case BCswitch:
                printf("\tncases = %d\n", cast(int)b.Bswitch.length);
                list_t bl = b.Bsucc;
                printf("\tdefault: B%d\n",list_block(bl) ? list_block(bl).Bnumber : 0);
                foreach (val; b.Bswitch)
                {
                    bl = list_next(bl);
                    printf("\tcase %lld: B%d\n", cast(long)val, list_block(bl).Bnumber);
                }
                break;

            case BCiftrue:
            case BCgoto:
            case BCasm:
            case BCtry:
            case BCcatch:
            case BCjcatch:
            case BC_try:
            case BC_filter:
            case BC_finally:
            case BC_lpad:
            case BC_ret:
            case BC_except:
                if (list_t bl = b.Bsucc)
                {
                    printf("\tBsucc:");
                    for ( ; bl; bl = list_next(bl))
                        printf(" B%d",list_block(bl).Bnumber);
                    printf("\n");
                }
                break;

            case BCret:
            case BCretexp:
            case BCexit:
                break;

            default:
                printf("bc = %d\n", b.BC);
                assert(0);
        }
    }
}

/*****************************
 * Number the blocks starting at 1.
 * So much more convenient than pointer values.
 */
void numberBlocks(block *startblock)
{
    uint number = 0;
    for (block *b = startblock; b; b = b.Bnext)
        b.Bnumber = ++number;
}

/**************************************
 * Print out the intermediate code for a function.
 * Params:
 *      msg = label for the print
 *      sfunc = function to print
 *      startblock = intermediate code
 */
@trusted
void WRfunc(const char* msg, Symbol* sfunc, block* startblock)
{
    printf("............%s...%s()\n", msg, sfunc.Sident.ptr);
    numberBlocks(startblock);
    for (block *b = startblock; b; b = b.Bnext)
        WRblock(b);
}
