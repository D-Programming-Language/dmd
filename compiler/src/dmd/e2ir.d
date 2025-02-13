/**
 * Converts expressions to Intermediate Representation (IR) for the backend.
 *
 * Copyright:   Copyright (C) 1999-2024 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 https://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/src/e2ir.d, _e2ir.d)
 * Documentation: https://dlang.org/phobos/dmd_e2ir.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/e2ir.d
 */

module dmd.e2ir;

import core.stdc.stdio;
import core.stdc.stddef;
import core.stdc.string;
import core.stdc.time;

import dmd.root.array;
import dmd.root.ctfloat;
import dmd.root.rmem;
import dmd.rootobject;
import dmd.root.stringtable;

import dmd.aggregate;
import dmd.arraytypes;
import dmd.astenums;
import dmd.attrib;
import dmd.canthrow;
import dmd.ctfeexpr;
import dmd.dcast : implicitConvTo;
import dmd.dclass;
import dmd.declaration;
import dmd.denum;
import dmd.dmdparams;
import dmd.dmodule;
import dmd.dscope;
import dmd.dstruct;
import dmd.dsymbol;
import dmd.dsymbolsem : include;
import dmd.dtemplate;
import dmd.expression;
import dmd.expressionsem : fill;
import dmd.func;
import dmd.glue;
import dmd.hdrgen;
import dmd.id;
import dmd.init;
import dmd.location;
import dmd.mtype;
import dmd.objc_glue;
import dmd.printast;
import dmd.s2ir;
import dmd.sideeffect;
import dmd.statement;
import dmd.target;
import dmd.tocsym;
import dmd.toctype;
import dmd.toir;
import dmd.tokens;
import dmd.toobj;
import dmd.typinf;
import dmd.typesem;
import dmd.visitor;

import dmd.backend.cc;
import dmd.backend.cdef;
import dmd.backend.cgcv;
import dmd.backend.code;
import dmd.backend.cv4;
import dmd.backend.dt;
import dmd.backend.el;
import dmd.backend.global;
import dmd.backend.obj;
import dmd.backend.oper;
import dmd.backend.rtlsym;
import dmd.backend.symtab;
import dmd.backend.ty;
import dmd.backend.type;

import dmd.backend.x86.code_x86;

alias Elems = Array!(elem *);

import dmd.backend.util2 : mem_malloc2;


private int registerSize() { return _tysize[TYnptr]; }

/*****
 * If variable var is a value that will actually be passed as a reference
 * Params:
 *      var = parameter variable
 * Returns:
 *      true if actually implicitly passed by reference
 */
bool ISX64REF(Declaration var)
{
    if (var.isReference())
    {
        return false; // it's not a value
    }

    if (var.isParameter())
    {
        if (target.os == Target.OS.Windows && target.isX86_64)
        {
            /* Use Microsoft C++ ABI
             * https://docs.microsoft.com/en-us/cpp/build/x64-calling-convention?view=msvc-170#parameter-passing
             * but watch out because the spec doesn't mention copy construction
             */
            return var.type.size(Loc.initial) > registerSize
                || (var.storage_class & STC.lazy_)
                || (var.type.isTypeStruct() && var.type.isTypeStruct().sym.hasCopyConstruction());
        }
        else if (target.os & Target.OS.Windows)
        {
            auto ts = var.type.isTypeStruct();
            return !(var.storage_class & STC.lazy_) && ts && ts.sym.hasMoveCtor && ts.sym.hasCopyCtor;
        }
        else if (target.os & Target.OS.Posix)
        {
            return !(var.storage_class & STC.lazy_) && var.type.isTypeStruct() && !var.type.isTypeStruct().sym.isPOD();
        }
    }

    return false;
}

/* If variable exp of type typ is a reference due to x64 calling conventions
 */
bool ISX64REF(ref IRState irs, Expression exp)
{
    if (irs.target.os == Target.OS.Windows && irs.target.isX86_64)
    {
        return exp.type.size(Loc.initial) > registerSize
               || (exp.type.isTypeStruct() && exp.type.isTypeStruct().sym.hasCopyConstruction());
    }
    else if (irs.target.os & Target.OS.Windows)
    {
        auto ts = exp.type.isTypeStruct();
        return ts && ts.sym.hasMoveCtor && ts.sym.hasCopyCtor;
    }
    else if (irs.target.os & Target.OS.Posix)
    {
        return exp.type.isTypeStruct() && !exp.type.isTypeStruct().sym.isPOD();
    }

    return false;
}

/**************************************************
 * Generate a copy from e2 to e1.
 * Params:
 *      e1 = lvalue
 *      e2 = rvalue
 *      t = value type
 *      tx = if !null, then t converted to C type
 * Returns:
 *      generated elem
 */
elem* elAssign(elem* e1, elem* e2, Type t, type* tx)
{
    //printf("e1:\n"); elem_print(e1);
    //printf("e2:\n"); elem_print(e2);
    //if (t) printf("t: %s\n", t.toChars());
    elem* e = el_bin(OPeq, e2.Ety, e1, e2);
    switch (tybasic(e2.Ety))
    {
        case TYarray:
            e.Ejty = e.Ety = TYstruct;
            goto case TYstruct;

        case TYstruct:
            e.Eoper = OPstreq;
            if (!tx)
                tx = Type_toCtype(t);
            //printf("tx:\n"); type_print(tx);
            e.ET = tx;
//            if (type_zeroCopy(tx))
//                e.Eoper = OPcomma;
            break;

        default:
            break;
    }
    return e;
}

/*************************************************
 * Determine if zero bits need to be copied for this backend type
 * Params:
 *      t = backend type
 * Returns:
 *      true if 0 bits
 */
bool type_zeroCopy(type* t)
{
    return type_size(t) == 0 ||
        (tybasic(t.Tty) == TYstruct &&
         (t.Ttag.Stype.Ttag.Sstruct.Sflags & STR0size));
}

/*******************************************************
 * Write read-only string to object file, create a local symbol for it.
 * Makes a copy of str's contents, does not keep a reference to it.
 * Params:
 *      str = string
 *      len = number of code units in string
 *      sz = number of bytes per code unit
 * Returns:
 *      Symbol
 */

Symbol* toStringSymbol(const(char)* str, size_t len, size_t sz)
{
    //printf("toStringSymbol() %p\n", stringTab);
    auto sv = stringTab.update(str, len * sz);
    if (sv.value)
        return sv.value;

    Symbol* si;

    if (target.os != Target.OS.Windows)
    {
        si = out_string_literal(str, cast(uint)len, cast(uint)sz);
        sv.value = si;
        return sv.value;
    }

    /* This should be in the back end, but mangleToBuffer() is
     * in the front end.
     */
    /* The stringTab pools common strings within an object file.
     * Win32 and Win64 use COMDATs to pool common strings across object files.
     */
    /* VC++ uses a name mangling scheme, for example, "hello" is mangled to:
     * ??_C@_05CJBACGMB@hello?$AA@
     *        ^ length
     *         ^^^^^^^^ 8 byte checksum
     * But the checksum algorithm is unknown. Just invent our own.
     */

    import dmd.common.outbuffer : OutBuffer;
    OutBuffer buf;
    buf.writestring("__");

    void printHash()
    {
        // Replace long string with hash of that string
        import dmd.common.blake3;
        //only use the first 16 bytes to match the length of md5
        const hash = blake3((cast(ubyte*)str)[0 .. len * sz]);
        foreach (u; hash[0 .. 16])
        {
            ubyte u1 = u >> 4;
            buf.writeByte((u1 < 10) ? u1 + '0' : u1 + 'A' - 10);
            u1 = u & 0xF;
            buf.writeByte((u1 < 10) ? u1 + '0' : u1 + 'A' - 10);
        }
    }

    const mangleMinLen = 14; // mangling: "__a14_(14*2 chars)" = 6+14*2 = 34

    if (len >= mangleMinLen) // long mangling for sure, use hash
        printHash();
    else
    {
        import dmd.mangle;
        scope StringExp se = new StringExp(Loc.initial, str[0 .. len], len, cast(ubyte)sz, 'c');
        mangleToBuffer(se, buf);   // recycle how strings are mangled for templates

        if (buf.length >= 32 + 2)   // long mangling, replace with hash
        {
            buf.setsize(2);
            printHash();
        }
    }

    si = symbol_calloc(buf[]);
    si.Sclass = SC.comdat;
    si.Stype = type_static_array(cast(uint)(len * sz), tstypes[TYchar]);
    si.Stype.Tcount++;
    type_setmangle(&si.Stype, Mangle.c);
    si.Sflags |= SFLnodebug | SFLartifical;
    si.Sfl = FL.data;
    si.Salignment = cast(ubyte)sz;
    out_readonly_comdat(si, str, cast(uint)(len * sz), cast(uint)sz);

    sv.value = si;
    return sv.value;
}

/*******************************************************
 * Turn StringExp into Symbol.
 */

Symbol* toStringSymbol(StringExp se)
{
    Symbol* si;
    const n = cast(int)se.numberOfCodeUnits();
    if (se.sz == 1)
    {
        const slice = se.peekString();
        si = toStringSymbol(slice.ptr, slice.length, 1);
    }
    else
    {
        auto p = cast(char *)mem.xmalloc(n * se.sz);
        se.writeTo(p, false);
        si = toStringSymbol(p, n, se.sz);
        mem.xfree(p);
    }
    return si;
}

/******************************************************
 * Replace call to GC allocator with call to tracing GC allocator.
 * Params:
 *      irs = to get function from
 *      e = elem to modify in place
 *      loc = to get file/line from
 */

void toTraceGC(ref IRState irs, elem* e, Loc loc)
{
    static immutable RTLSYM[2][25] map =
    [
        [ RTLSYM.NEWCLASS, RTLSYM.TRACENEWCLASS ],
        [ RTLSYM.NEWITEMT, RTLSYM.TRACENEWITEMT ],
        [ RTLSYM.NEWITEMIT, RTLSYM.TRACENEWITEMIT ],
        [ RTLSYM.NEWARRAYT, RTLSYM.TRACENEWARRAYT ],
        [ RTLSYM.NEWARRAYIT, RTLSYM.TRACENEWARRAYIT ],
        [ RTLSYM.NEWARRAYMTX, RTLSYM.TRACENEWARRAYMTX ],
        [ RTLSYM.NEWARRAYMITX, RTLSYM.TRACENEWARRAYMITX ],

        [ RTLSYM.CALLFINALIZER, RTLSYM.TRACECALLFINALIZER ],
        [ RTLSYM.CALLINTERFACEFINALIZER, RTLSYM.TRACECALLINTERFACEFINALIZER ],

        [ RTLSYM.ARRAYLITERALTX, RTLSYM.TRACEARRAYLITERALTX ],
        [ RTLSYM.ASSOCARRAYLITERALTX, RTLSYM.TRACEASSOCARRAYLITERALTX ],

        [ RTLSYM.ARRAYCATT, RTLSYM.TRACEARRAYCATT ],
        [ RTLSYM.ARRAYCATNTX, RTLSYM.TRACEARRAYCATNTX ],

        [ RTLSYM.ARRAYAPPENDCD, RTLSYM.TRACEARRAYAPPENDCD ],
        [ RTLSYM.ARRAYAPPENDWD, RTLSYM.TRACEARRAYAPPENDWD ],
        [ RTLSYM.ARRAYAPPENDT, RTLSYM.TRACEARRAYAPPENDT ],
        [ RTLSYM.ARRAYAPPENDCTX, RTLSYM.TRACEARRAYAPPENDCTX ],

        [ RTLSYM.ARRAYSETLENGTHT, RTLSYM.TRACEARRAYSETLENGTHT ],
        [ RTLSYM.ARRAYSETLENGTHIT, RTLSYM.TRACEARRAYSETLENGTHIT ],

        [ RTLSYM.ALLOCMEMORY, RTLSYM.TRACEALLOCMEMORY ],
    ];

    if (!irs.params.tracegc || !loc.filename)
        return;

    assert(e.Eoper == OPcall);
    elem* e1 = e.E1;
    assert(e1.Eoper == OPvar);

    auto s = e1.Vsym;
    /* In -dip1008 code the allocation of exceptions is no longer done by the
     * gc, but by a manual reference counting mechanism implementend in druntime.
     * If that is the case, then there is nothing to trace.
     */
    if (s == getRtlsym(RTLSYM.NEWTHROW))
        return;
    foreach (ref m; map)
    {
        if (s == getRtlsym(m[0]))
        {
            e1.Vsym = getRtlsym(m[1]);
            e.E2 = el_param(e.E2, filelinefunction(irs, loc));
            return;
        }
    }
    assert(0);
}

/*******************************************
 * Convert Expression to elem, then append destructors for any
 * temporaries created in elem.
 * Params:
 *      e = Expression to convert
 *      irs = context
 * Returns:
 *      generated elem tree
 */

elem* toElemDtor(Expression e, ref IRState irs)
{
    //printf("Expression.toElemDtor() %s\n", e.toChars());

    /* "may" throw may actually be false if we look at a subset of
     * the function. Here, the subset is `e`. If that subset is nothrow,
     * we can generate much better code for the destructors for that subset,
     * even if the rest of the function throws.
     * If mayThrow is false, it cannot be true for some subset of the function,
     * so no need to check.
     * If calling canThrow() here turns out to be too expensive,
     * it can be enabled only for optimized builds.
     */
    const mayThrowSave = irs.mayThrow;
    if (irs.mayThrow && !canThrow(e, irs.getFunc(), null))
        irs.mayThrow = false;

    const starti = irs.varsInScope.length;
    elem* er = toElem(e, irs);
    const endi = irs.varsInScope.length;

    irs.mayThrow = mayThrowSave;

    // Add destructors
    elem* ex = appendDtors(irs, er, starti, endi);
    return ex;
}

/*******************************************
 * Take address of an elem.
 * Accounts for e being an rvalue by assigning the rvalue
 * to a temp.
 * Params:
 *      e = elem to take address of
 *      t = Type of elem
 *      alwaysCopy = when true, always copy e to a tmp
 * Returns:
 *      the equivalent of &e
 */

elem* addressElem(elem* e, Type t, bool alwaysCopy = false)
{
    //printf("addressElem()\n");

    elem **pe  = el_scancommas(&e);

    // For conditional operator, both branches need conversion.
    if ((*pe).Eoper == OPcond)
    {
        elem* ec = (*pe).E2;

        ec.E1 = addressElem(ec.E1, t, alwaysCopy);
        ec.E2 = addressElem(ec.E2, t, alwaysCopy);

        (*pe).Ejty = (*pe).Ety = cast(ubyte)ec.E1.Ety;
        (*pe).ET = ec.E1.ET;

        e.Ety = TYnptr;
        return e;
    }

    if (alwaysCopy || ((*pe).Eoper != OPvar && (*pe).Eoper != OPind))
    {
        elem* e2 = *pe;
        type* tx;

        // Convert to ((tmp=e2),tmp)
        TY ty;
        if (t && ((ty = t.toBasetype().ty) == Tstruct || ty == Tsarray))
            tx = Type_toCtype(t);
        else if (tybasic(e2.Ety) == TYstruct)
        {
            assert(t);                  // don't know of a case where this can be null
            tx = Type_toCtype(t);
        }
        else
            tx = type_fake(e2.Ety);
        Symbol* stmp = symbol_genauto(tx);

        elem* eeq = elAssign(el_var(stmp), e2, t, tx);
        *pe = el_bin(OPcomma,e2.Ety,eeq,el_var(stmp));
    }
    tym_t typ = TYnptr;
    if (e.Eoper == OPind && tybasic(e.E1.Ety) == TYimmutPtr)
        typ = TYimmutPtr;
    e = el_una(OPaddr,typ,e);
    return e;
}

/********************************
 * Reset stringTab[] between object files being emitted, because the symbols are local.
 */
void clearStringTab()
{
    //printf("clearStringTab()\n");
    if (stringTab)
        stringTab.reset(1000);             // 1000 is arbitrary guess
    else
    {
        stringTab = new StringTable!(Symbol*)();
        stringTab._init(1000);
    }
}
private __gshared StringTable!(Symbol*) *stringTab;

/*********************************************
 * Figure out whether a data symbol should be dllimported
 * Params:
 *      var = declaration of the symbol
 * Returns:
 *      true if symbol should be imported from a DLL
 */
bool isDllImported(Dsymbol var)
{
    if (!(target.os & Target.OS.Windows))
        return false;
    if (var.isImportedSymbol())
        return true;
    if (driverParams.symImport == SymImport.none)
        return false;
    if (auto vd = var.isDeclaration())
        if (!vd.isDataseg() || vd.isThreadlocal())
            return false;
    if (var.isFuncDeclaration())
        return false; // can always jump through import table
    if (auto tid = var.isTypeInfoDeclaration())
    {
        if (builtinTypeInfo(tid.tinfo))
            return true;
        if (auto ad = isAggregate(tid.type))
            var = ad;
    }
    if (driverParams.symImport == SymImport.defaultLibsOnly)
    {
        auto m = var.getModule();
        if (!m || !m.md)
            return false;
        const id = m.md.packages.length ? m.md.packages[0] : null;
        if (id && id != Id.core && id != Id.std)
            return false;
        if (!id && m.md.id != Id.std && m.md.id != Id.object)
            return false;
    }
    else if (driverParams.symImport != SymImport.all)
        return false;
    if (auto mod = var.isModule())
        return !mod.isRoot(); // non-root ModuleInfo symbol
    if (var.inNonRoot())
        return true; // not instantiated, and defined in non-root
    if (auto ti = var.isInstantiated()) // && !defineOnDeclare(sym, false))
        return !ti.needsCodegen(); // instantiated but potentially culled (needsCodegen())
    if (auto vd = var.isVarDeclaration())
        if (vd.storage_class & STC.extern_)
            return true; // externally defined global variable
    return false;
}

/*********************************************
 * Generate a backend symbol for a frontend symbol
 * Params:
 *      s = frontend symbol
 * Returns:
 *      the backend symbol or the associated symbol in the
 *      import table if it is expected to be imported from a DLL
 */
Symbol* toExtSymbol(Dsymbol s)
{
    if (isDllImported(s))
        return toImport(s);
    else
        return toSymbol(s);
}

/*********************************************
 * Convert Expression to backend elem.
 * Params:
 *      e = expression tree
 *      irs = context
 * Returns:
 *      backend elem tree
 */
elem* toElem(Expression e, ref IRState irs)
{
    elem* visit(Expression e)
    {
        printf("[%s] %s: %s\n", e.loc.toChars(), EXPtoString(e.op).ptr, e.toChars());
        assert(0);
    }

    elem* visitSymbol(SymbolExp se) // VarExp and SymOffExp
    {
        elem* e;
        Type tb = (se.op == EXP.symbolOffset) ? se.var.type.toBasetype() : se.type.toBasetype();
        long offset = (se.op == EXP.symbolOffset) ? cast(long)(cast(SymOffExp)se).offset : 0;
        VarDeclaration v = se.var.isVarDeclaration();

        //printf("[%s] SymbolExp.toElem('%s') %p, %s\n", se.loc.toChars(), se.toChars(), se, se.type.toChars());
        //printf("\tparent = '%s'\n", se.var.parent ? se.var.parent.toChars() : "null");
        if (se.op == EXP.variable && se.var.needThis())
        {
            irs.eSink.error(se.loc, "need `this` to access member `%s`", se.toChars());
            return el_long(TYsize_t, 0);
        }

        /* The magic variable __ctfe is always false at runtime
         */
        if (se.op == EXP.variable && v && v.ident == Id.ctfe)
        {
            return el_long(totym(se.type), 0);
        }

        if (FuncLiteralDeclaration fld = se.var.isFuncLiteralDeclaration())
        {
            if (fld.tok == TOK.reserved)
            {
                // change to non-nested
                fld.tok = TOK.function_;
                fld.vthis = null;
            }
            if (!fld.deferToObj)
            {
                fld.deferToObj = true;
                irs.deferToObj.push(fld);
            }
        }

        Symbol* s = toSymbol(se.var);

        // VarExp generated for `__traits(initSymbol, Aggregate)`?
        if (auto symDec = se.var.isSymbolDeclaration())
        {
            if (se.type.isTypeDArray())
            {
                assert(se.type == Type.tvoid.arrayOf().constOf(), se.toString());

                // Generate s[0 .. Aggregate.sizeof] for non-zero initialised aggregates
                // Otherwise create (null, Aggregate.sizeof)
                auto ad = symDec.dsym;
                auto ptr = (ad.isStructDeclaration() && ad.type.isZeroInit(Loc.initial))
                        ? el_long(TYnptr, 0)
                        : el_ptr(s);
                auto length = el_long(TYsize_t, ad.structsize);
                auto slice = el_pair(TYdarray, length, ptr);
                elem_setLoc(slice, se.loc);
                return slice;
            }
        }

        FuncDeclaration fd = null;
        if (se.var.toParent2())
            fd = se.var.toParent2().isFuncDeclaration();

        const bool nrvo = fd && (fd.isNRVO() && fd.nrvo_var == se.var || se.var.nrvo && fd.shidden);
        if (nrvo)
            s = fd.shidden;

        if (s.Sclass == SC.auto_ || s.Sclass == SC.parameter || s.Sclass == SC.shadowreg)
        {
            if (fd && fd != irs.getFunc())
            {
                // 'var' is a variable in an enclosing function.
                elem* ethis = getEthis(se.loc, irs, fd, null, se.originalScope);
                ethis = el_una(OPaddr, TYnptr, ethis);

                /* https://issues.dlang.org/show_bug.cgi?id=9383
                 * If 's' is a virtual function parameter
                 * placed in closure, and actually accessed from in/out
                 * contract, instead look at the original stack data.
                 */
                bool forceStackAccess = false;
                if (fd.isVirtual() && (fd.fdrequire || fd.fdensure))
                {
                    Dsymbol sx = irs.getFunc();
                    while (sx != fd)
                    {
                        if (sx.ident == Id.require || sx.ident == Id.ensure)
                        {
                            forceStackAccess = true;
                            break;
                        }
                        sx = sx.toParent2();
                    }
                }

                int soffset;
                if (v && v.inClosure && !forceStackAccess)
                    soffset = v.offset;
                else if (v && v.inAlignSection)
                {
                    const vthisOffset = fd.vthis ? -toSymbol(fd.vthis).Soffset : 0;
                    ethis = el_bin(OPadd, TYnptr, ethis, el_long(TYnptr, vthisOffset + fd.salignSection.Soffset));
                    ethis = el_una(OPind, TYnptr, ethis);
                    soffset = v.offset;
                }
                else
                {
                    soffset = cast(int)s.Soffset;
                    /* If fd is a non-static member function of a class or struct,
                     * then ethis isn't the frame pointer.
                     * ethis is the 'this' pointer to the class/struct instance.
                     * We must offset it.
                     */
                    if (fd.vthis)
                    {
                        Symbol* vs = toSymbol(fd.vthis);
                        //printf("vs = %s, offset = x%x, %p\n", vs.Sident.ptr, cast(int)vs.Soffset, vs);
                        soffset -= vs.Soffset;
                    }
                    //printf("\tSoffset = x%x, sthis.Soffset = x%x\n", cast(uint)s.Soffset, cast(uint)irs.sthis.Soffset);
                }

                if (!nrvo)
                    soffset += offset;

                e = el_bin(OPadd, TYnptr, ethis, el_long(TYnptr, soffset));
                if (se.op == EXP.variable)
                    e = el_una(OPind, TYnptr, e);
                if ((se.var.isReference() || ISX64REF(se.var)) && !(ISX64REF(se.var) && v && v.offset && !forceStackAccess))
                    e = el_una(OPind, s.Stype.Tty, e);
                else if (se.op == EXP.symbolOffset && nrvo)
                {
                    e = el_una(OPind, TYnptr, e);
                    e = el_bin(OPadd, e.Ety, e, el_long(TYsize_t, offset));
                }
                goto L1;
            }
        }

        /* If var is a member of a closure or aligned section
         */
        if (v && (v.inClosure || v.inAlignSection))
        {
            assert(irs.sclosure || fd.salignSection);
            e = el_var(v.inClosure ? irs.sclosure : fd.salignSection);
            e = el_bin(OPadd, TYnptr, e, el_long(TYsize_t, v.offset));
            if (se.op == EXP.variable)
            {
                e = el_una(OPind, totym(se.type), e);
                if (tybasic(e.Ety) == TYstruct)
                    e.ET = Type_toCtype(se.type);
                elem_setLoc(e, se.loc);
            }
            if (se.var.isReference())
            {
                e.Ety = TYnptr;
                e = el_una(OPind, s.Stype.Tty, e);
            }
            else if (se.op == EXP.symbolOffset && nrvo)
            {
                e = el_una(OPind, TYnptr, e);
                e = el_bin(OPadd, e.Ety, e, el_long(TYsize_t, offset));
            }
            else if (se.op == EXP.symbolOffset)
            {
                e = el_bin(OPadd, e.Ety, e, el_long(TYsize_t, offset));
            }
            goto L1;
        }

        if (s.Sclass == SC.auto_ && s.Ssymnum == SYMIDX.max)
        {
            //printf("\tadding symbol %s\n", s.Sident);
            symbol_add(s);
        }

        if (se.op == EXP.variable && isDllImported(se.var))
        {
            assert(se.op == EXP.variable);
            if (target.os & Target.OS.Posix)
            {
                e = el_var(s);
            }
            else
            {
                e = el_var(toImport(se.var));
                e = el_una(OPind,s.Stype.Tty,e);
            }
        }
        else if (se.var.isReference() || ISX64REF(se.var))
        {
            // Out parameters are really references
            e = el_var(s);
            e.Ety = TYnptr;
            if (se.op == EXP.variable)
                e = el_una(OPind, s.Stype.Tty, e);
            else if (offset)
                e = el_bin(OPadd, TYnptr, e, el_long(TYsize_t, offset));
        }
        else if (se.op == EXP.variable)
            e = el_var(s);
        else
        {
            e = nrvo ? el_var(s) : el_ptr(s);
            e = el_bin(OPadd, e.Ety, e, el_long(TYsize_t, offset));
        }
    L1:
        if (se.op != EXP.variable)
        {
            elem_setLoc(e,se.loc);
            return e;
        }

        if (nrvo)
        {
            e.Ety = TYnptr;
            e = el_una(OPind, 0, e);
        }

        tym_t tym;
        if (se.var.storage_class & STC.lazy_)
            tym = TYdelegate;       // Tdelegate as C type
        else if (tb.ty == Tfunction)
            tym = s.Stype.Tty;
        else
            tym = totym(se.type);

        e.Ejty = cast(ubyte)(e.Ety = tym);

        if (tybasic(tym) == TYstruct)
        {
            e.ET = Type_toCtype(se.type);
        }
        else if (tybasic(tym) == TYarray)
        {
            e.Ejty = e.Ety = TYstruct;
            e.ET = Type_toCtype(se.type);
        }
        else if (tysimd(tym))
        {
            e.ET = Type_toCtype(se.type);
        }

        elem_setLoc(e,se.loc);
        return e;
    }

    elem* visitFunc(FuncExp fe)
    {
        //printf("FuncExp.toElem() %s\n", fe.toChars());
        FuncLiteralDeclaration fld = fe.fd;

        if (fld.tok == TOK.reserved && fe.type.ty == Tpointer)
        {
            // change to non-nested
            fld.tok = TOK.function_;
            fld.vthis = null;
        }
        if (!fld.deferToObj)
        {
            fld.deferToObj = true;
            irs.deferToObj.push(fld);
        }

        Symbol* s = toSymbol(fld);
        elem* e = el_ptr(s);
        if (fld.isNested())
        {
            elem* ethis;
            // Delegate literals report isNested() even if they are in global scope,
            // so we need to check that the parent is a function.
            if (!fld.toParent2().isFuncDeclaration())
                ethis = el_long(TYnptr, 0);
            else
                ethis = getEthis(fe.loc, irs, fld);
            e = el_pair(TYdelegate, ethis, e);
        }
        elem_setLoc(e, fe.loc);
        return e;
    }

    elem* visitDeclaration(DeclarationExp de)
    {
        //printf("DeclarationExp.toElem() %s\n", de.toChars());
        return Dsymbol_toElem(de.declaration, irs);
    }

    /***************************************
     */

    elem* visitTypeid(TypeidExp e)
    {
        //printf("TypeidExp.toElem() %s\n", e.toChars());
        if (Type t = isType(e.obj))
        {
            elem* result = getTypeInfo(e, t, irs);
            return el_bin(OPadd, result.Ety, result, el_long(TYsize_t, t.vtinfo.offset));
        }
        Expression ex = isExpression(e.obj);
        if (!ex)
            assert(0);

        if (auto ev = ex.isVarExp())
        {
            if (auto em = ev.var.isEnumMember())
                ex = em.value;
        }
        if (auto ecr = ex.isClassReferenceExp())
        {
            Type t = ecr.type;
            elem* result = getTypeInfo(ecr, t, irs);
            return el_bin(OPadd, result.Ety, result, el_long(TYsize_t, t.vtinfo.offset));
        }

        auto tc = ex.type.toBasetype().isTypeClass();
        assert(tc);
        // generate **classptr to get the classinfo
        elem* result = toElem(ex, irs);
        result = el_una(OPind,TYnptr,result);
        result = el_una(OPind,TYnptr,result);
        // Add extra indirection for interfaces
        if (tc.sym.isInterfaceDeclaration())
            result = el_una(OPind,TYnptr,result);
        return result;
    }

    /***************************************
     */

    elem* visitThis(ThisExp te)
    {
        //printf("ThisExp.toElem()\n");
        assert(irs.sthis);

        elem* ethis;
        if (te.var)
        {
            assert(te.var.parent);
            FuncDeclaration fd = te.var.toParent2().isFuncDeclaration();
            assert(fd);
            ethis = getEthis(te.loc, irs, fd);
            ethis = fixEthis2(ethis, fd);
        }
        else
        {
            ethis = el_var(irs.sthis);
            ethis = fixEthis2(ethis, irs.getFunc());
        }

        if (te.type.ty == Tstruct)
        {
            ethis = el_una(OPind, TYstruct, ethis);
            ethis.ET = Type_toCtype(te.type);
        }
        elem_setLoc(ethis,te.loc);
        return ethis;
    }

    /***************************************
     */

    elem* visitInteger(IntegerExp ie)
    {
        elem* e = el_long(totym(ie.type), ie.getInteger());
        elem_setLoc(e,ie.loc);
        return e;
    }

    /***************************************
     */

    elem* visitReal(RealExp re)
    {
        //printf("RealExp.toElem(%p) %s\n", re, re.toChars());
        elem* e = el_long(TYint, 0);
        tym_t ty = totym(re.type.toBasetype());
        switch (tybasic(ty))
        {
            case TYfloat:
            case TYifloat:
                e.Vfloat = cast(float) re.value;
                break;

            case TYdouble:
            case TYidouble:
                e.Vdouble = cast(double) re.value;
                break;

            case TYldouble:
            case TYildouble:
                e.Vldouble = re.value;
                break;

            default:
                printf("ty = %d, tym = %x, re=%s, re.type=%s, re.type.toBasetype=%s\n",
                       re.type.ty, ty, re.toChars(), re.type.toChars(), re.type.toBasetype().toChars());
                assert(0);
        }
        e.Ety = ty;
        return e;
    }

    /***************************************
     */

    elem* visitComplex(ComplexExp ce)
    {

        //printf("ComplexExp.toElem(%p) %s\n", ce, ce.toChars());

        elem* e = el_long(TYint, 0);
        real_t re = ce.value.re;
        real_t im = ce.value.im;

        tym_t ty = totym(ce.type);
        switch (tybasic(ty))
        {
            case TYcfloat:
                union UF { float f; uint i; }
                e.Vcfloat.re = cast(float) re;
                if (CTFloat.isSNaN(re))
                {
                    UF u;
                    u.f = e.Vcfloat.re;
                    u.i &= 0xFFBFFFFFL;
                    e.Vcfloat.re = u.f;
                }
                e.Vcfloat.im = cast(float) im;
                if (CTFloat.isSNaN(im))
                {
                    UF u;
                    u.f = e.Vcfloat.im;
                    u.i &= 0xFFBFFFFFL;
                    e.Vcfloat.im = u.f;
                }
                break;

            case TYcdouble:
                union UD { double d; ulong i; }
                e.Vcdouble.re = cast(double) re;
                if (CTFloat.isSNaN(re))
                {
                    UD u;
                    u.d = e.Vcdouble.re;
                    u.i &= 0xFFF7FFFFFFFFFFFFUL;
                    e.Vcdouble.re = u.d;
                }
                e.Vcdouble.im = cast(double) im;
                if (CTFloat.isSNaN(re))
                {
                    UD u;
                    u.d = e.Vcdouble.im;
                    u.i &= 0xFFF7FFFFFFFFFFFFUL;
                    e.Vcdouble.im = u.d;
                }
                break;

            case TYcldouble:
                e.Vcldouble.re = re;
                e.Vcldouble.im = im;
                break;

            default:
                assert(0);
        }
        e.Ety = ty;
        return e;
    }

    /***************************************
     */

    elem* visitNull(NullExp ne)
    {
        return el_long(totym(ne.type), 0);
    }

    /***************************************
     */

    elem* visitString(StringExp se)
    {
        //printf("StringExp.toElem() %s, type = %s\n", se.toChars(), se.type.toChars());

        elem* e;
        Type tb = se.type.toBasetype();
        if (tb.ty == Tarray)
        {
            Symbol* si = toStringSymbol(se);
            e = el_pair(TYdarray, el_long(TYsize_t, se.numberOfCodeUnits()), el_ptr(si));
        }
        else if (tb.ty == Tsarray)
        {
            Symbol* si = toStringSymbol(se);
            e = el_var(si);
            e.Ejty = e.Ety = TYstruct;
            e.ET = si.Stype;
            e.ET.Tcount++;
        }
        else if (tb.ty == Tpointer)
        {
            e = el_calloc();
            e.Eoper = OPstring;
            // freed in el_free
            const len = cast(size_t)((se.numberOfCodeUnits() + 1) * se.sz);
            e.Vstring = cast(char *)mem_malloc2(cast(uint) len);
            se.writeTo(e.Vstring, true);
            e.Vstrlen = len;
            e.Ety = TYnptr;
        }
        else
        {
            printf("type is %s\n", se.type.toChars());
            assert(0);
        }
        elem_setLoc(e,se.loc);
        return e;
    }

    elem* visitNew(NewExp ne)
    {
        //printf("NewExp.toElem() %s\n", ne.toChars());
        Type t = ne.type.toBasetype();
        //printf("\ttype = %s\n", t.toChars());
        //if (ne.member)
            //printf("\tmember = %s\n", ne.member.toChars());
        elem* e;
        Type ectype;
        if (t.ty == Tclass)
        {
            auto tclass = ne.newtype.toBasetype().isTypeClass();
            assert(tclass);
            ClassDeclaration cd = tclass.sym;

            /* Things to do:
             * 1) ex: call allocator
             * 2) ey: set vthis for nested classes
             * 2) ew: set vthis2 for nested classes
             * 3) ez: call constructor
             */

            elem* ex = null;
            elem* ey = null;
            elem* ew = null;
            elem* ezprefix = null;
            elem* ez = null;

            if (ne.onstack)
            {
                /* Create an instance of the class on the stack,
                 * and call it stmp.
                 * Set ex to be the &stmp.
                 */
                .type* tc = type_struct_class(tclass.sym.toChars(),
                        tclass.sym.alignsize, tclass.sym.structsize,
                        null, null,
                        false, false, true, false);
                tc.Tcount--;
                Symbol* stmp = symbol_genauto(tc);
                ex = el_ptr(stmp);

                Symbol* si = toInitializer(tclass.sym);
                elem* ei = el_var(si);

                if (cd.isNested())
                {
                    ey = el_same(ex);
                    ez = el_copytree(ey);
                    if (cd.vthis2)
                        ew = el_copytree(ey);
                }
                else if (ne.member)
                    ez = el_same(ex);

                ex = el_una(OPind, TYstruct, ex);
                ex = elAssign(ex, ei, null, Type_toCtype(tclass).Tnext);
                ex = el_una(OPaddr, TYnptr, ex);
                ectype = tclass;
            }
            else
            {
                // assert(!(irs.params.ehnogc && ne.thrownew),
                //     "This should have been rewritten to `_d_newThrowable` in the semantic phase.");

                ex = toElem(ne.lowering, irs);
                ectype = null;

                if (cd.isNested())
                {
                    ey = el_same(ex);
                    ez = el_copytree(ey);
                    if (cd.vthis2)
                        ew = el_copytree(ey);
                }
                else if (ne.member)
                    ez = el_same(ex);
                //elem_print(ex);
                //elem_print(ey);
                //elem_print(ez);
            }

            if (ne.thisexp)
            {
                ClassDeclaration cdthis = ne.thisexp.type.isClassHandle();
                assert(cdthis);
                //printf("cd = %s\n", cd.toChars());
                //printf("cdthis = %s\n", cdthis.toChars());
                assert(cd.isNested());
                int offset = 0;
                Dsymbol cdp = cd.toParentLocal();     // class we're nested in

                //printf("member = %p\n", member);
                //printf("cdp = %s\n", cdp.toChars());
                //printf("cdthis = %s\n", cdthis.toChars());
                if (cdp != cdthis)
                {
                    int i = cdp.isClassDeclaration().isBaseOf(cdthis, &offset);
                    assert(i);
                }
                elem* ethis = toElem(ne.thisexp, irs);
                if (offset)
                    ethis = el_bin(OPadd, TYnptr, ethis, el_long(TYsize_t, offset));

                if (!cd.vthis)
                {
                    irs.eSink.error(ne.loc, "forward reference to `%s`", cd.toChars());
                }
                else
                {
                    ey = el_bin(OPadd, TYnptr, ey, el_long(TYsize_t, cd.vthis.offset));
                    ey = el_una(OPind, TYnptr, ey);
                    ey = el_bin(OPeq, TYnptr, ey, ethis);
                }
                //printf("ex: "); elem_print(ex);
                //printf("ey: "); elem_print(ey);
                //printf("ez: "); elem_print(ez);
            }
            else if (cd.isNested())
            {
                /* Initialize cd.vthis:
                 *  *(ey + cd.vthis.offset) = this;
                 */
                ey = setEthis(ne.loc, irs, ey, cd);
            }

            if (cd.vthis2)
            {
                /* Initialize cd.vthis2:
                 *  *(ew + cd.vthis2.offset) = this;
                 */
                assert(ew);
                ew = setEthis(ne.loc, irs, ew, cd, true);
            }

            if (ne.member)
            {
                if (ne.argprefix)
                    ezprefix = toElem(ne.argprefix, irs);
                // Call constructor
                ez = callfunc(ne.loc, irs, 1, ne.type, ez, ectype, ne.member, ne.member.type, null, ne.arguments);
            }

            e = el_combine(ex, ey);
            e = el_combine(e, ew);
            e = el_combine(e, ezprefix);
            e = el_combine(e, ez);
        }
        else if (t.ty == Tpointer && t.nextOf().toBasetype().ty == Tstruct)
        {
            t = ne.newtype.toBasetype();
            TypeStruct tclass = t.isTypeStruct();
            StructDeclaration sd = tclass.sym;

            /* Things to do:
             * 1) ex: call allocator
             * 2) ey: set vthis for nested structs
             * 2) ew: set vthis2 for nested structs
             * 3) ez: call constructor
             */

            elem* ex = null;
            elem* ey = null;
            elem* ew = null;
            elem* ezprefix = null;
            elem* ez = null;

            // Call _d_newitemT()
            if (auto lowering = ne.lowering)
                ex = toElem(ne.lowering, irs);
            else
                assert(0, "This case should have been rewritten to `_d_newitemT` in the semantic phase");

            ectype = null;

            elem* ev = el_same(ex);

            if (ne.argprefix)
                    ezprefix = toElem(ne.argprefix, irs);
            if (ne.member)
            {
                if (sd.isNested())
                {
                    ey = el_copytree(ev);

                    /* Initialize sd.vthis:
                     *  *(ey + sd.vthis.offset) = this;
                     */
                    ey = setEthis(ne.loc, irs, ey, sd);
                    if (sd.vthis2)
                    {
                        /* Initialize sd.vthis2:
                         *  *(ew + sd.vthis2.offset) = this1;
                         */
                        ew = el_copytree(ev);
                        ew = setEthis(ne.loc, irs, ew, sd, true);
                    }
                }

                // Call constructor
                ez = callfunc(ne.loc, irs, 1, ne.type, ev, ectype, ne.member, ne.member.type, null, ne.arguments);
                /* Structs return a ref, which gets automatically dereferenced.
                 * But we want a pointer to the instance.
                 */
                ez = el_una(OPaddr, TYnptr, ez);
            }
            else
            {
                StructLiteralExp sle = StructLiteralExp.create(ne.loc, sd, ne.arguments, t);
                ez = toElemStructLit(sle, irs, EXP.construct, ev.Vsym, false);
            }
            //elem_print(ex);
            //elem_print(ey);
            //elem_print(ez);

            e = el_combine(ex, ey);
            e = el_combine(e, ew);
            e = el_combine(e, ezprefix);
            e = el_combine(e, ez);
        }
        else if (auto tda = t.isTypeDArray())
        {
            elem* ezprefix = ne.argprefix ? toElem(ne.argprefix, irs) : null;

            assert(ne.arguments && ne.arguments.length >= 1);
            assert(ne.lowering);
            e = toElem(ne.lowering, irs);
            e = el_combine(ezprefix, e);
        }
        else if (auto tp = t.isTypePointer())
        {
            elem* ezprefix = ne.argprefix ? toElem(ne.argprefix, irs) : null;

            // call _d_newitemT()
            e = toElem(ne.lowering, irs);

            if (ne.arguments && ne.arguments.length == 1)
            {
                /* ezprefix, ts=_d_newitemT(ti), *ts=arguments[0], ts
                 */
                elem* e2 = toElem((*ne.arguments)[0], irs);

                Symbol* ts = symbol_genauto(Type_toCtype(tp));
                elem* eeq1 = el_bin(OPeq, TYnptr, el_var(ts), e);

                elem* ederef = el_una(OPind, e2.Ety, el_var(ts));
                elem* eeq2 = el_bin(OPeq, e2.Ety, ederef, e2);

                e = el_combine(eeq1, eeq2);
                e = el_combine(e, el_var(ts));
                //elem_print(e);
            }
            e = el_combine(ezprefix, e);
        }
        else if (auto taa = t.isTypeAArray())
        {
            Symbol* s = getRtlsym(RTLSYM.AANEW);
            elem* ti = getTypeInfo(ne, t, irs);
            // aaNew(ti)
            elem* ep = el_params(ti, null);
            e = el_bin(OPcall, TYnptr, el_var(s), ep);
            elem_setLoc(e, ne.loc);
            return e;
        }
        else
        {
            irs.eSink.error(ne.loc, "internal compiler error: cannot new type `%s`\n", t.toChars());
            assert(0);
        }

        elem_setLoc(e,ne.loc);
        return e;
    }

    //////////////////////////// Unary ///////////////////////////////

    /***************************************
     */

    elem* visitNeg(NegExp ne)
    {
        elem* e = toElem(ne.e1, irs);
        Type tb1 = ne.e1.type.toBasetype();

        assert(tb1.ty != Tarray && tb1.ty != Tsarray);

        switch (tb1.ty)
        {
            case Tvector:
            {
                // rewrite (-e) as (0-e)
                elem* ez = el_calloc();
                ez.Eoper = OPconst;
                ez.Ety = e.Ety;
                foreach (ref v; ez.Vlong8)
                    v = 0;
                e = el_bin(OPmin, totym(ne.type), ez, e);
                break;
            }

            default:
                e = el_una(OPneg, totym(ne.type), e);
                break;
        }

        elem_setLoc(e,ne.loc);
        return e;
    }

    /***************************************
     */

    elem* visitCom(ComExp ce)
    {
        elem* e1 = toElem(ce.e1, irs);
        Type tb1 = ce.e1.type.toBasetype();
        tym_t ty = totym(ce.type);

        assert(tb1.ty != Tarray && tb1.ty != Tsarray);

        elem* e;
        switch (tb1.ty)
        {
            case Tbool:
                e = el_bin(OPxor, ty, e1, el_long(ty, 1));
                break;

            case Tvector:
            {
                // rewrite (~e) as (e^~0)
                elem* ec = el_calloc();
                ec.Eoper = OPconst;
                ec.Ety = e1.Ety;
                foreach (ref v; ec.Vlong8)
                    v = ~0L;
                e = el_bin(OPxor, ty, e1, ec);
                break;
            }

            default:
                e = el_una(OPcom,ty,e1);
                break;
        }

        elem_setLoc(e,ce.loc);
        return e;
    }

    /***************************************
     */

    elem* visitNot(NotExp ne)
    {
        elem* e = el_una(OPnot, totym(ne.type), toElem(ne.e1, irs));
        elem_setLoc(e,ne.loc);
        return e;
    }


    /***************************************
     */

    elem* visitHalt(HaltExp he)
    {
        return genHalt(he.loc);
    }

    /********************************************
     */

    elem* visitAssert(AssertExp ae)
    {
        // https://dlang.org/spec/expression.html#assert_expressions
        //printf("AssertExp.toElem() %s\n", ae.toChars());
        elem* e;
        if (irs.params.useAssert != CHECKENABLE.on)
        {
            // BUG: should replace assert(0); with a HLT instruction
            e = el_long(TYint, 0);
            elem_setLoc(e,ae.loc);
            return e;
        }

        if (irs.params.checkAction == CHECKACTION.C)
        {
            auto econd = toElem(ae.e1, irs);
            auto ea = callCAssert(irs, ae.loc, ae.e1, ae.msg, null);
            auto eo = el_bin(OPoror, TYvoid, econd, ea);
            elem_setLoc(eo, ae.loc);
            return eo;
        }

        if (irs.params.checkAction == CHECKACTION.halt)
        {
            /* Generate:
             *  ae.e1 || halt
             */
            auto econd = toElem(ae.e1, irs);
            auto ea = genHalt(ae.loc);
            auto eo = el_bin(OPoror, TYvoid, econd, ea);
            elem_setLoc(eo, ae.loc);
            return eo;
        }

        e = toElem(ae.e1, irs);
        Symbol* ts = null;
        elem* einv = null;
        Type t1 = ae.e1.type.toBasetype();

        FuncDeclaration inv;

        // If e1 is a class object, call the class invariant on it
        if (irs.params.useInvariants == CHECKENABLE.on && t1.ty == Tclass &&
            !t1.isTypeClass().sym.isInterfaceDeclaration() &&
            !t1.isTypeClass().sym.isCPPclass())
        {
            ts = symbol_genauto(Type_toCtype(t1));
            einv = el_bin(OPcall, TYvoid, el_var(getRtlsym(RTLSYM.DINVARIANT)), el_var(ts));
        }
        else if (irs.params.useInvariants == CHECKENABLE.on &&
            t1.ty == Tpointer &&
            t1.nextOf().ty == Tstruct &&
            (inv = t1.nextOf().isTypeStruct().sym.inv) !is null)
        {
            // If e1 is a struct object, call the struct invariant on it
            ts = symbol_genauto(Type_toCtype(t1));
            einv = callfunc(ae.loc, irs, 1, inv.type.nextOf(), el_var(ts), ae.e1.type, inv, inv.type, null, null);
        }

        // Construct: (e1 || ModuleAssert(line))
        Module m = cast(Module)irs.blx._module;
        char* mname = cast(char*)m.srcfile.toChars();

        //printf("filename = '%s'\n", ae.loc.filename);
        //printf("module = '%s'\n", m.srcfile.toChars());

        /* Determine if we are in a unittest
         */
        FuncDeclaration fd = irs.getFunc();
        UnitTestDeclaration ud = fd ? fd.isUnitTestDeclaration() : null;

        /* If the source file name has changed, probably due
         * to a #line directive.
         */
        elem* ea;
        if (ae.loc.filename && (ae.msg || strcmp(ae.loc.filename, mname) != 0))
        {
            const(char)* id = ae.loc.filename;
            size_t len = strlen(id);
            Symbol* si = toStringSymbol(id, len, 1);
            elem* efilename = el_pair(TYdarray, el_long(TYsize_t, len), el_ptr(si));
            if (irs.target.os == Target.OS.Windows && irs.target.isX86_64)
                efilename = addressElem(efilename, Type.tstring, true);

            if (ae.msg)
            {
                /* https://issues.dlang.org/show_bug.cgi?id=8360
                 * If the condition is evalated to true,
                 * msg is not evaluated at all. so should use
                 * toElemDtor(msg, irs) instead of toElem(msg, irs).
                 */
                elem* emsg = toElemDtor(ae.msg, irs);
                emsg = array_toDarray(ae.msg.type, emsg);
                if (irs.target.os == Target.OS.Windows && irs.target.isX86_64)
                    emsg = addressElem(emsg, Type.tvoid.arrayOf(), false);

                ea = el_var(getRtlsym(ud ? RTLSYM.DUNITTEST_MSG : RTLSYM.DASSERT_MSG));
                ea = el_bin(OPcall, TYnoreturn, ea, el_params(el_long(TYint, ae.loc.linnum), efilename, emsg, null));
            }
            else
            {
                ea = el_var(getRtlsym(ud ? RTLSYM.DUNITTEST : RTLSYM.DASSERT));
                ea = el_bin(OPcall, TYnoreturn, ea, el_param(el_long(TYint, ae.loc.linnum), efilename));
            }
        }
        else
        {
            auto eassert = el_var(getRtlsym(ud ? RTLSYM.DUNITTESTP : RTLSYM.DASSERTP));
            auto efile = toEfilenamePtr(m);
            auto eline = el_long(TYint, ae.loc.linnum);
            ea = el_bin(OPcall, TYnoreturn, eassert, el_param(eline, efile));
        }
        if (einv)
        {
            // tmp = e, e || assert, e.inv
            elem* eassign = el_bin(OPeq, e.Ety, el_var(ts), e);
            e = el_combine(eassign, el_bin(OPoror, TYvoid, el_var(ts), ea));
            e = el_combine(e, einv);
        }
        else
            e = el_bin(OPoror,TYvoid,e,ea);
        elem_setLoc(e,ae.loc);
        return e;
    }

    elem* visitThrow(ThrowExp te)
    {
        //printf("ThrowExp.toElem() '%s'\n", te.toChars());

        elem* e = toElemDtor(te.e1, irs);
        const rtlthrow = config.ehmethod == EHmethod.EH_DWARF ? RTLSYM.THROWDWARF : RTLSYM.THROWC;
        elem* sym = el_var(getRtlsym(rtlthrow));
        return el_bin(OPcall, TYnoreturn, sym, e);
    }

    elem* visitPost(PostExp pe)
    {
        //printf("PostExp.toElem() '%s'\n", pe.toChars());
        elem* e = toElem(pe.e1, irs);
        elem* einc = toElem(pe.e2, irs);
        e = el_bin((pe.op == EXP.plusPlus) ? OPpostinc : OPpostdec,
                    e.Ety,e,einc);
        elem_setLoc(e,pe.loc);
        return e;
    }

    //////////////////////////// Binary ///////////////////////////////

    /********************************************
     */
    elem* toElemBin(BinExp be, int op)
    {
        //printf("toElemBin() '%s'\n", be.toChars());

        Type tb1 = be.e1.type.toBasetype();
        Type tb2 = be.e2.type.toBasetype();

        assert(!((tb1.isStaticOrDynamicArray() || tb2.isStaticOrDynamicArray()) &&
                 tb2.ty != Tvoid &&
                 op != OPeq && op != OPandand && op != OPoror));

        tym_t tym = totym(be.type);

        elem* el = toElem(be.e1, irs);
        elem* er = toElem(be.e2, irs);
        elem* e = el_bin(op,tym,el,er);

        elem_setLoc(e,be.loc);
        return e;
    }

    elem* toElemBinAssign(BinAssignExp be, int op)
    {
        //printf("toElemBinAssign() '%s'\n", be.toChars());
        //printAST(be);

        Type tb1 = be.e1.type.toBasetype();
        Type tb2 = be.e2.type.toBasetype();

        assert(!((tb1.isStaticOrDynamicArray() || tb2.isStaticOrDynamicArray()) &&
                 tb2.ty != Tvoid &&
                 op != OPeq && op != OPandand && op != OPoror));

        tym_t tym = totym(be.type);

        elem* el;
        elem* ev;
        if (be.e1.op == EXP.cast_)
        {
            int depth = 0;
            Expression e1 = be.e1;
            while (e1.op == EXP.cast_)
            {
                ++depth;
                e1 = (cast(CastExp)e1).e1;
            }
            assert(depth > 0);

            el = toElem(e1, irs);
            el = addressElem(el, e1.type.pointerTo());
            ev = el_same(el);

            el = el_una(OPind, totym(e1.type), el);

            ev = el_una(OPind, tym, ev);

            foreach (d; 0 .. depth)
            {
                e1 = be.e1;
                foreach (i; 1 .. depth - d)
                    e1 = (cast(CastExp)e1).e1;

                el = toElemCast(cast(CastExp)e1, el, true, irs);
            }
        }
        else
        {
            el = toElem(be.e1, irs);

            if (el.Eoper == OPbit)
            {
                elem* er = toElem(be.e2, irs);
                elem* e = el_bin(op, tym, el, er);
                elem_setLoc(e,be.loc);
                return e;
            }

            el = addressElem(el, be.e1.type.pointerTo());
            ev = el_same(el);

            el = el_una(OPind, tym, el);
            ev = el_una(OPind, tym, ev);
        }
        elem* er = toElem(be.e2, irs);
        elem* e = el_bin(op, tym, el, er);
        e = el_combine(e, ev);

        elem_setLoc(e,be.loc);
        return e;
    }

    /***************************************
     */

    elem* visitAdd(AddExp e)
    {
        return toElemBin(e, OPadd);
    }

    /***************************************
     */

    elem* visitMin(MinExp e)
    {
        return toElemBin(e, OPmin);
    }

    /*****************************************
     * Evaluate elem and convert to dynamic array suitable for a function argument.
     */
    elem* eval_Darray(Expression e)
    {
        elem* ex = toElem(e, irs);
        ex = array_toDarray(e.type, ex);
        if (irs.target.os == Target.OS.Windows && irs.target.isX86_64)
        {
            ex = addressElem(ex, Type.tvoid.arrayOf(), false);
        }
        return ex;
    }

    /***************************************
     * https://dlang.org/spec/expression.html#cat_expressions
     */

    elem* visitCat(CatExp ce)
    {
        /* Do this check during code gen rather than semantic() because concatenation is
         * allowed in CTFE, and cannot distinguish that in semantic().
         */
        if (!irs.params.useGC)
        {
            irs.eSink.error(ce.loc, "array concatenation of expression `%s` requires the GC which is not available with -betterC", ce.toChars());
            return el_long(TYint, 0);
        }

        if (auto lowering = ce.lowering)
            return toElem(lowering, irs);

        assert(0, "This case should have been rewritten to `_d_arraycatnTX` in the semantic phase");
    }

    /***************************************
     */

    elem* visitMul(MulExp e)
    {
        return toElemBin(e, OPmul);
    }

    /************************************
     */

    elem* visitDiv(DivExp e)
    {
        return toElemBin(e, OPdiv);
    }

    /***************************************
     */

    elem* visitMod(ModExp e)
    {
        return toElemBin(e, OPmod);
    }

    /***************************************
     */

    elem* visitCmp(CmpExp ce)
    {
        //printf("CmpExp.toElem() %s\n", ce.toChars());

        OPER eop;
        Type t1 = ce.e1.type.toBasetype();
        Type t2 = ce.e2.type.toBasetype();

        switch (ce.op)
        {
            case EXP.lessThan:     eop = OPlt;     break;
            case EXP.greaterThan:     eop = OPgt;     break;
            case EXP.lessOrEqual:     eop = OPle;     break;
            case EXP.greaterOrEqual:     eop = OPge;     break;
            case EXP.equal:  eop = OPeqeq;   break;
            case EXP.notEqual: eop = OPne;   break;

            default:
                printf("%s\n", ce.toChars());
                assert(0);
        }
        if (!t1.isFloating())
        {
            // Convert from floating point compare to equivalent
            // integral compare
            eop = cast(OPER)rel_integral(eop);
        }
        elem* e;
        if (cast(int)eop > 1 && t1.ty == Tclass && t2.ty == Tclass)
        {
            // Should have already been lowered
            assert(0);
        }
        else if (cast(int)eop > 1 && t1.isStaticOrDynamicArray() && t2.isStaticOrDynamicArray())
        {
            // This codepath was replaced by lowering during semantic
            // to object.__cmp in druntime.
            assert(0);
        }
        else if (t1.ty == Tvector)
        {
            elem* e1 = toElem(ce.e1, irs);
            elem* e2 = toElem(ce.e2, irs);

            tym_t tym = totym(ce.type);
            elem* ex;  // store side effects in ex

            // swap operands
            void swapOps()
            {
                // put side effects of e1 into ex
                if (el_sideeffect(e1) && e2.Eoper != OPconst)
                {
                    ex = e1;
                    e1 = el_same(ex);
                }

                // swap
                auto tmp = e2;
                e2 = e1;
                e1 = tmp;
            }

            if (t1.isFloating())
            {
                /* Rewrite in terms of < or <= operator
                 */
                OPER op;
                switch (eop)
                {
                    case OPlt:   // x < y
                    case OPle:   // x <= y
                        op = eop;
                        break;

                    case OPgt: op = OPlt; goto Lswap; // y < x
                    case OPge: op = OPle; goto Lswap; // y <= x
                    Lswap:
                        swapOps();
                        break;

                    default:
                        assert(0);
                }

                e = el_bin(op, tym, e1, e2);
                elem_setLoc(e, ce.loc);
                e = el_combine(ex, e);
                return e;
            }

            /* Rewrite in terms of > operator
             */
            bool swap;       // swap operands
            bool comp;       // complement result
            switch (eop)
            {
                case OPgt:                           break; //   x > y
                case OPlt: swap = true;              break; //   y > x
                case OPle:              comp = true; break; // !(x > y)
                case OPge: swap = true; comp = true; break; // !(y > x)
                default:   assert(0);
            }

            if (swap)
                swapOps();

            if (t1.isUnsigned() || t2.isUnsigned())
            {
                /* only signed compare is available. Bias
                 * unsigned values by subtracting int.min
                 */
                ulong val;
                Type telement = t1.isTypeVector().basetype.nextOf().toBasetype();
                tym_t ty = totym(telement);
                switch (tysize(ty)) // vector element size
                {
                    case 1: val = byte.min;  break;
                    case 2: val = short.min; break;
                    case 4: val = int.min;   break;
                    case 8: val = long.min;  break;
                    default:
                        assert(0);
                }
                elem* ec1 = el_vectorConst(totym(t1), val);
                e1 = el_bin(OPmin, ec1.Ety, e1, ec1);

                elem* ec2 = el_calloc();
                el_copy(ec2, ec1);
                e2 = el_bin(OPmin, ec2.Ety, e2, ec2);
            }

            e = el_bin(OPgt, tym, e1, e2);

            if (comp)
            {
                // ex ^ ~0
                elem* ec = el_vectorConst(totym(t1), ~0L);
                e = el_bin(OPxor, ec.Ety, e, ec);
            }

            elem_setLoc(e, ce.loc);
            e = el_combine(ex, e);
        }
        else
        {
            if (cast(int)eop <= 1)
            {
                /* The result is determinate, create:
                 *   (e1 , e2) , eop
                 */
                e = toElemBin(ce,OPcomma);
                e = el_bin(OPcomma,e.Ety,e,el_long(e.Ety,cast(int)eop));
            }
            else
                e = toElemBin(ce,eop);
        }
        return e;
    }

    elem* visitEqual(EqualExp ee)
    {
        //printf("EqualExp.toElem() %s\n", ee.toChars());

        Type t1 = ee.e1.type.toBasetype();
        Type t2 = ee.e2.type.toBasetype();

        OPER eop;
        switch (ee.op)
        {
            case EXP.equal:          eop = OPeqeq;   break;
            case EXP.notEqual:       eop = OPne;     break;
            default:
                printf("%s\n", ee.toChars());
                assert(0);
        }

        //printf("EqualExp.toElem()\n");
        elem* e;
        if (t1.ty == Tstruct)
        {
            // Rewritten to IdentityExp or memberwise-compare
            assert(0);
        }
        else if (t1.isStaticOrDynamicArray() && t2.isStaticOrDynamicArray())
        {
            Type telement  = t1.nextOf().toBasetype();
            Type telement2 = t2.nextOf().toBasetype();

            if ((telement.isIntegral() || telement.ty == Tvoid) && telement.ty == telement2.ty)
            {
                // Optimize comparisons of arrays of basic types
                // For arrays of integers/characters, and void[],
                // replace druntime call with:
                // For a==b: a.length==b.length && (a.length == 0 || memcmp(a.ptr, b.ptr, size)==0)
                // For a!=b: a.length!=b.length || (a.length != 0 || memcmp(a.ptr, b.ptr, size)!=0)
                // size is a.length*sizeof(a[0]) for dynamic arrays, or sizeof(a) for static arrays.

                elem* earr1 = toElem(ee.e1, irs);
                elem* earr2 = toElem(ee.e2, irs);
                elem* eptr1, eptr2; // Pointer to data, to pass to memcmp
                elem* elen1, elen2; // Length, for comparison
                elem* esiz1, esiz2; // Data size, to pass to memcmp
                const sz = telement.size(); // Size of one element

                if (t1.ty == Tarray)
                {
                    elen1 = el_una(target.isX86_64 ? OP128_64 : OP64_32, TYsize_t, el_same(earr1));
                    esiz1 = el_bin(OPmul, TYsize_t, el_same(elen1), el_long(TYsize_t, sz));
                    eptr1 = array_toPtr(t1, el_same(earr1));
                }
                else
                {
                    elen1 = el_long(TYsize_t, (cast(TypeSArray)t1).dim.toInteger());
                    esiz1 = el_long(TYsize_t, t1.size());
                    earr1 = addressElem(earr1, t1);
                    eptr1 = el_same(earr1);
                }

                if (t2.ty == Tarray)
                {
                    elen2 = el_una(target.isX86_64 ? OP128_64 : OP64_32, TYsize_t, el_same(earr2));
                    esiz2 = el_bin(OPmul, TYsize_t, el_same(elen2), el_long(TYsize_t, sz));
                    eptr2 = array_toPtr(t2, el_same(earr2));
                }
                else
                {
                    elen2 = el_long(TYsize_t, (cast(TypeSArray)t2).dim.toInteger());
                    esiz2 = el_long(TYsize_t, t2.size());
                    earr2 = addressElem(earr2, t2);
                    eptr2 = el_same(earr2);
                }

                elem* esize = t2.ty == Tsarray ? esiz2 : esiz1;

                e = el_param(eptr1, eptr2);
                e = el_bin(OPmemcmp, TYint, e, esize);
                e = el_bin(eop, TYint, e, el_long(TYint, 0));

                elem* elen = t2.ty == Tsarray ? elen2 : elen1;
                elem* esizecheck = el_bin(eop, TYint, el_same(elen), el_long(TYsize_t, 0));
                e = el_bin(ee.op == EXP.equal ? OPoror : OPandand, TYint, esizecheck, e);

                if (t1.ty == Tsarray && t2.ty == Tsarray)
                    assert(t1.size() == t2.size());
                else
                {
                    elem* elencmp = el_bin(eop, TYint, elen1, elen2);
                    e = el_bin(ee.op == EXP.equal ? OPandand : OPoror, TYint, elencmp, e);
                }

                // Ensure left-to-right order of evaluation
                e = el_combine(earr2, e);
                e = el_combine(earr1, e);
                elem_setLoc(e, ee.loc);
                return e;
            }

            elem* ea1 = eval_Darray(ee.e1);
            elem* ea2 = eval_Darray(ee.e2);

            elem* ep = el_params(getTypeInfo(ee, telement.arrayOf(), irs),
                    ea2, ea1, null);
            const rtlfunc = RTLSYM.ARRAYEQ2;
            e = el_bin(OPcall, TYint, el_var(getRtlsym(rtlfunc)), ep);
            if (ee.op == EXP.notEqual)
                e = el_bin(OPxor, TYint, e, el_long(TYint, 1));
            elem_setLoc(e,ee.loc);
        }
        else if (t1.ty == Taarray && t2.ty == Taarray)
        {
            TypeAArray taa = cast(TypeAArray)t1;
            Symbol* s = getRtlsym(RTLSYM.AAEQUAL);
            elem* ti = getTypeInfo(ee, taa, irs);
            elem* ea1 = toElem(ee.e1, irs);
            elem* ea2 = toElem(ee.e2, irs);
            // aaEqual(ti, e1, e2)
            elem* ep = el_params(ea2, ea1, ti, null);
            e = el_bin(OPcall, TYint, el_var(s), ep);
            if (ee.op == EXP.notEqual)
                e = el_bin(OPxor, TYint, e, el_long(TYint, 1));
            elem_setLoc(e, ee.loc);
            return e;
        }
        else if (eop == OPne && t1.ty == Tvector)
        {
            /* (e1 == e2) ^ ~0
             */
            elem* ex = toElemBin(ee, OPeqeq);

            elem* ec = el_calloc();
            ec.Eoper = OPconst;
            ec.Ety = totym(t1);
            foreach (ref v; ec.Vlong8)
                v = ~0L;
            e = el_bin(OPxor, ec.Ety, ex, ec);
        }
        else
        {
            e = toElemBin(ee, eop);
        }
        return e;
    }

    elem* visitIdentity(IdentityExp ie)
    {
        Type t1 = ie.e1.type.toBasetype();
        Type t2 = ie.e2.type.toBasetype();

        OPER eop;
        switch (ie.op)
        {
            case EXP.identity:       eop = OPeqeq;   break;
            case EXP.notIdentity:    eop = OPne;     break;
            default:
                printf("%s\n", ie.toChars());
                assert(0);
        }

        //printf("IdentityExp.toElem() %s\n", ie.toChars());

        /* Fix Issue 18746 : https://issues.dlang.org/show_bug.cgi?id=18746
         * Before skipping the comparison for empty structs
         * it is necessary to check whether the expressions involved
         * have any sideeffects
         */

        const canSkipCompare = isTrivialExp(ie.e1) && isTrivialExp(ie.e2);
        elem* e;
        if (t1.ty == Tstruct && (cast(TypeStruct)t1).sym.fields.length == 0 && canSkipCompare)
        {
            // we can skip the compare if the structs are empty
            e = el_long(TYbool, ie.op == EXP.identity);
        }
        else if (t1.ty == Tstruct || t1.isFloating())
        {
            // Do bit compare of struct's
            elem* es1 = toElem(ie.e1, irs);
            es1 = addressElem(es1, ie.e1.type);
            elem* es2 = toElem(ie.e2, irs);
            es2 = addressElem(es2, ie.e2.type);
            e = el_param(es1, es2);
            elem* ecount;
            // In case of `real`, don't compare padding bits
            // https://issues.dlang.org/show_bug.cgi?id=3632
            ecount = el_long(TYsize_t, (t1.ty == TY.Tfloat80) ? (t1.size() - target.realpad) : t1.size());
            e = el_bin(OPmemcmp, TYint, e, ecount);
            e = el_bin(eop, TYint, e, el_long(TYint, 0));
            elem_setLoc(e, ie.loc);
        }
        else if (t1.isStaticOrDynamicArray() && t2.isStaticOrDynamicArray())
        {

            elem* ea1 = toElem(ie.e1, irs);
            ea1 = array_toDarray(t1, ea1);
            elem* ea2 = toElem(ie.e2, irs);
            ea2 = array_toDarray(t2, ea2);

            e = el_bin(eop, totym(ie.type), ea1, ea2);
            elem_setLoc(e, ie.loc);
        }
        else
            e = toElemBin(ie, eop);

        return e;
    }

    /***************************************
     */

    elem* visitIn(InExp ie)
    {
        elem* key = toElem(ie.e1, irs);
        elem* aa = toElem(ie.e2, irs);
        TypeAArray taa = cast(TypeAArray)ie.e2.type.toBasetype();

        // aaInX(aa, keyti, key);
        key = addressElem(key, ie.e1.type);
        Symbol* s = getRtlsym(RTLSYM.AAINX);
        elem* keyti = getTypeInfo(ie, taa.index, irs);
        elem* ep = el_params(key, keyti, aa, null);
        elem* e = el_bin(OPcall, totym(ie.type), el_var(s), ep);

        elem_setLoc(e, ie.loc);
        return e;
    }

    /***************************************
     */

    elem* visitRemove(RemoveExp re)
    {
        auto taa = re.e1.type.toBasetype().isTypeAArray();
        assert(taa);
        elem* ea = toElem(re.e1, irs);
        elem* ekey = toElem(re.e2, irs);

        ekey = addressElem(ekey, re.e2.type);
        Symbol* s = getRtlsym(RTLSYM.AADELX);
        elem* keyti = getTypeInfo(re, taa.index, irs);
        elem* ep = el_params(ekey, keyti, ea, null);
        elem* e = el_bin(OPcall, TYbool, el_var(s), ep);

        elem_setLoc(e, re.loc);
        return e;
    }

    /***************************************
     */

    elem* visitAssign(AssignExp ae)
    {
        version (none)
        {
            if (ae.op == EXP.blit)      printf("BlitExp.toElem('%s')\n", ae.toChars());
            if (ae.op == EXP.assign)    printf("AssignExp.toElem('%s')\n", ae.toChars());
            if (ae.op == EXP.construct) printf("ConstructExp.toElem('%s')\n", ae.toChars());
        }

        elem* setResult(elem* e)
        {
            elem_setLoc(e, ae.loc);
            return e;
        }

        /*
            https://issues.dlang.org/show_bug.cgi?id=23120

            If rhs is a noreturn expression, then there is no point
            to generate any code for the noreturen variable.
         */
        if (ae.e2.type.isTypeNoreturn())
            return setResult(toElem(ae.e2, irs));

        Type t1b = ae.e1.type.toBasetype();

        // Look for array.length = n
        if (auto ale = ae.e1.isArrayLengthExp())
        {
            assert(0, "This case should have been rewritten to `_d_arraysetlengthT` in the semantic phase");
        }

        // Look for array[]=n
        if (auto are = ae.e1.isSliceExp())
        {
            Type t1 = t1b;
            Type ta = are.e1.type.toBasetype();

            // which we do if the 'next' types match
            if (ae.memset == MemorySet.blockAssign)
            {
                // Do a memset for array[]=v
                //printf("Lpair %s\n", ae.toChars());
                Type tb = ta.nextOf().toBasetype();
                uint sz = cast(uint)tb.size();

                elem* n1 = toElem(are.e1, irs);
                elem* elwr = are.lwr ? toElem(are.lwr, irs) : null;
                elem* eupr = are.upr ? toElem(are.upr, irs) : null;

                elem* n1x = n1;

                elem* enbytes;
                elem* einit;
                // Look for array[]=n
                if (auto ts = ta.isTypeSArray())
                {
                    n1 = array_toPtr(ta, n1);
                    enbytes = toElem(ts.dim, irs);
                    n1x = n1;
                    n1 = el_same(n1x);
                    einit = resolveLengthVar(are.lengthVar, &n1, ta);
                }
                else if (ta.ty == Tarray)
                {
                    n1 = el_same(n1x);
                    einit = resolveLengthVar(are.lengthVar, &n1, ta);
                    enbytes = el_copytree(n1);
                    n1 = array_toPtr(ta, n1);
                    enbytes = el_una(target.isX86_64 ? OP128_64 : OP64_32, TYsize_t, enbytes);
                }
                else if (ta.ty == Tpointer)
                {
                    n1 = el_same(n1x);
                    enbytes = el_long(TYsize_t, -1);   // largest possible index
                    einit = null;
                }

                // Enforce order of evaluation of n1[elwr..eupr] as n1,elwr,eupr
                elem* elwrx = elwr;
                if (elwr) elwr = el_same(elwrx);
                elem* euprx = eupr;
                if (eupr) eupr = el_same(euprx);

                version (none)
                {
                    printf("sz = %d\n", sz);
                    printf("n1x\n");        elem_print(n1x);
                    printf("einit\n");      elem_print(einit);
                    printf("elwrx\n");      elem_print(elwrx);
                    printf("euprx\n");      elem_print(euprx);
                    printf("n1\n");         elem_print(n1);
                    printf("elwr\n");       elem_print(elwr);
                    printf("eupr\n");       elem_print(eupr);
                    printf("enbytes\n");    elem_print(enbytes);
                }
                einit = el_combine(n1x, einit);
                einit = el_combine(einit, elwrx);
                einit = el_combine(einit, euprx);

                elem* evalue = toElem(ae.e2, irs);

                version (none)
                {
                    printf("n1\n");         elem_print(n1);
                    printf("enbytes\n");    elem_print(enbytes);
                }

                if (irs.arrayBoundsCheck() && eupr && ta.ty != Tpointer)
                {
                    assert(elwr);
                    elem* enbytesx = enbytes;
                    enbytes = el_same(enbytesx);
                    elem* c1 = el_bin(OPle, TYint, el_copytree(eupr), enbytesx);
                    elem* c2 = el_bin(OPle, TYint, el_copytree(elwr), el_copytree(eupr));
                    c1 = el_bin(OPandand, TYint, c1, c2);

                    // Construct: (c1 || arrayBoundsError)
                    auto ea = buildArraySliceError(irs, ae.loc, el_copytree(elwr), el_copytree(eupr), el_copytree(enbytesx));
                    elem* eb = el_bin(OPoror,TYvoid,c1,ea);
                    einit = el_combine(einit, eb);
                }

                elem* elength;
                if (elwr)
                {
                    el_free(enbytes);
                    elem* elwr2 = el_copytree(elwr);
                    elwr2 = el_bin(OPmul, TYsize_t, elwr2, el_long(TYsize_t, sz));
                    n1 = el_bin(OPadd, TYnptr, n1, elwr2);
                    enbytes = el_bin(OPmin, TYsize_t, eupr, elwr);
                    elength = el_copytree(enbytes);
                }
                else
                    elength = el_copytree(enbytes);
                elem* e = setArray(are.e1, n1, enbytes, tb, evalue, irs, ae.op);
                e = el_pair(TYdarray, elength, e);
                e = el_combine(einit, e);
                //elem_print(e);
                return setResult(e);
            }
            else
            {
                /* It's array1[]=array2[]
                 * which is a memcpy
                 */
                elem* eto = toElem(ae.e1, irs);
                elem* efrom = toElem(ae.e2, irs);

                uint size = cast(uint)t1.nextOf().size();
                elem* esize = el_long(TYsize_t, size);

                /* Determine if we need to do postblit
                 */
                bool postblit = false;
                if (needsPostblit(t1.nextOf()) &&
                    (ae.e2.op == EXP.slice && (cast(UnaExp)ae.e2).e1.isLvalue() ||
                     ae.e2.op == EXP.cast_  && (cast(UnaExp)ae.e2).e1.isLvalue() ||
                     ae.e2.op != EXP.slice && ae.e2.isLvalue()))
                {
                    postblit = true;
                }
                bool destructor = needsDtor(t1.nextOf()) !is null;

                assert(ae.e2.type.ty != Tpointer);

                if (!postblit && !destructor)
                {
                    elem* ex = el_same(eto);

                    /* Returns: length of array ex
                     */
                    static elem* getDotLength(ref IRState irs, elem* eto, elem* ex)
                    {
                        if (eto.Eoper == OPpair &&
                            eto.E1.Eoper == OPconst)
                        {
                            // It's a constant, so just pull it from eto
                            return el_copytree(eto.E1);
                        }
                        else
                        {
                            // It's not a constant, so pull it from the dynamic array
                            return el_una(target.isX86_64 ? OP128_64 : OP64_32, TYsize_t, el_copytree(ex));
                        }
                    }

                    auto elen = getDotLength(irs, eto, ex);
                    auto nbytes = el_bin(OPmul, TYsize_t, elen, esize);  // number of bytes to memcpy
                    auto epto = array_toPtr(ae.e1.type, ex);

                    elem* epfr;
                    elem* echeck;
                    if (irs.arrayBoundsCheck()) // check array lengths match and do not overlap
                    {
                        auto ey = el_same(efrom);
                        auto eleny = getDotLength(irs, efrom, ey);
                        epfr = array_toPtr(ae.e2.type, ey);

                        // length check: (eleny == elen)
                        auto c = el_bin(OPeqeq, TYint, eleny, el_copytree(elen));

                        /* Don't check overlap if epto and epfr point to different symbols
                         */
                        if (!(epto.Eoper == OPaddr && epto.E1.Eoper == OPvar &&
                              epfr.Eoper == OPaddr && epfr.E1.Eoper == OPvar &&
                              epto.E1.Vsym != epfr.E1.Vsym))
                        {
                            // Add overlap check (c && (px + nbytes <= py || py + nbytes <= px))
                            auto c2 = el_bin(OPle, TYint, el_bin(OPadd, TYsize_t, el_copytree(epto), el_copytree(nbytes)), el_copytree(epfr));
                            auto c3 = el_bin(OPle, TYint, el_bin(OPadd, TYsize_t, el_copytree(epfr), el_copytree(nbytes)), el_copytree(epto));
                            c = el_bin(OPandand, TYint, c, el_bin(OPoror, TYint, c2, c3));
                        }

                        // Construct: (c || arrayBoundsError)
                        echeck = el_bin(OPoror, TYvoid, c, buildRangeError(irs, ae.loc));
                    }
                    else
                    {
                        epfr = array_toPtr(ae.e2.type, efrom);
                        efrom = null;
                        echeck = null;
                    }

                    /* Construct:
                     *   memcpy(ex.ptr, ey.ptr, nbytes)[0..elen]
                     */
                    elem* e = el_bin(OPmemcpy, TYnptr, epto, el_param(epfr, nbytes));
                    //elem* e = el_params(nbytes, epfr, epto, null);
                    //e = el_bin(OPcall,TYnptr,el_var(getRtlsym(RTLSYM.MEMCPY)),e);
                    e = el_pair(eto.Ety, el_copytree(elen), e);

                    /* Combine: eto, efrom, echeck, e
                     */
                    e = el_combine(el_combine(eto, efrom), el_combine(echeck, e));
                    return setResult(e);
                }
                else if ((postblit || destructor) &&
                    ae.op != EXP.blit &&
                    ae.op != EXP.construct)
                    assert(0, "Trying to reference `_d_arrayassign`, this should not happen!");
                else
                {
                    // Generate:
                    //      _d_arraycopy(eto, efrom, esize)

                    if (irs.target.os == Target.OS.Windows && irs.target.isX86_64)
                    {
                        eto   = addressElem(eto,   Type.tvoid.arrayOf());
                        efrom = addressElem(efrom, Type.tvoid.arrayOf());
                    }
                    elem* ep = el_params(eto, efrom, esize, null);
                    elem* e = el_bin(OPcall, totym(ae.type), el_var(getRtlsym(RTLSYM.ARRAYCOPY)), ep);
                    return setResult(e);
                }
            }
            assert(0);
        }

        /* Look for initialization of an `out` or `ref` variable
         */
        if (ae.memset == MemorySet.referenceInit)
        {
            assert(ae.op == EXP.construct || ae.op == EXP.blit);
            auto ve = ae.e1.isVarExp();
            assert(ve);
            assert(ve.var.storage_class & (STC.out_ | STC.ref_));

            // It'll be initialized to an address
            elem* e = toElem(ae.e2, irs);
            e = addressElem(e, ae.e2.type);
            elem* es = toElem(ae.e1, irs);
            if (es.Eoper == OPind)
                es = es.E1;
            else
                es = el_una(OPaddr, TYnptr, es);
            es.Ety = TYnptr;
            e = el_bin(OPeq, TYnptr, es, e);
            assert(!(t1b.ty == Tstruct && ae.e2.op == EXP.int64));

            return setResult(e);
        }

        tym_t tym = totym(ae.type);
        elem* e1 = toElem(ae.e1, irs);

        elem* e1x;

        elem* setResult2(elem* e)
        {
            return setResult(el_combine(e, e1x));
        }

        // Create a reference to e1.
        if (e1.Eoper == OPvar || e1.Eoper == OPbit)
            e1x = el_copytree(e1);
        else
        {
            /* Rewrite to:
             *  e1  = *((tmp = &e1), tmp)
             *  e1x = *tmp
             */
            e1 = addressElem(e1, null);
            e1x = el_same(e1);
            e1 = el_una(OPind, tym, e1);
            if (tybasic(tym) == TYstruct)
                e1.ET = Type_toCtype(ae.e1.type);
            e1x = el_una(OPind, tym, e1x);
            if (tybasic(tym) == TYstruct)
                e1x.ET = Type_toCtype(ae.e1.type);
            //printf("e1  = \n"); elem_print(e1);
            //printf("e1x = \n"); elem_print(e1x);
        }

        // inlining may generate lazy variable initialization
        if (auto ve = ae.e1.isVarExp())
            if (ve.var.storage_class & STC.lazy_)
            {
                assert(ae.op == EXP.construct || ae.op == EXP.blit);
                elem* e = el_bin(OPeq, tym, e1, toElem(ae.e2, irs));
                return setResult2(e);
            }

        /* This will work if we can distinguish an assignment from
         * an initialization of the lvalue. It'll work if the latter.
         * If the former, because of aliasing of the return value with
         * function arguments, it'll fail.
         */
        if (ae.op == EXP.construct && ae.e2.op == EXP.call)
        {
            CallExp ce = cast(CallExp)ae.e2;
            TypeFunction tf = cast(TypeFunction)ce.e1.type.toBasetype();
            if (tf.ty == Tfunction && retStyle(tf, ce.f && ce.f.needThis()) == RET.stack)
            {
                elem* ehidden = e1;
                ehidden = el_una(OPaddr, TYnptr, ehidden);
                assert(!irs.ehidden);
                irs.ehidden = ehidden;
                elem* e = toElem(ae.e2, irs);
                return setResult2(e);
            }

            /* Look for:
             *  v = structliteral.ctor(args)
             * and have the structliteral write into v, rather than create a temporary
             * and copy the temporary into v
             */
            if (e1.Eoper == OPvar && // no closure variables https://issues.dlang.org/show_bug.cgi?id=17622
                ae.e1.op == EXP.variable && ce.e1.op == EXP.dotVariable)
            {
                auto dve = cast(DotVarExp)ce.e1;
                auto fd = dve.var.isFuncDeclaration();
                if (fd && fd.isCtorDeclaration())
                {
                    if (auto sle = dve.e1.isStructLiteralExp())
                    {
                        sle.sym = toSymbol((cast(VarExp)ae.e1).var);
                        elem* e = toElem(ae.e2, irs);
                        return setResult2(e);
                    }
                }
            }
        }

        //if (ae.op == EXP.construct) printf("construct\n");
        if (auto t1s = t1b.isTypeStruct())
        {
            if (ae.e2.op == EXP.int64)
            {
                assert(ae.op == EXP.blit);

                /* Implement:
                 *  (struct = 0)
                 * with:
                 *  memset(&struct, 0, struct.sizeof)
                 */
                uint sz = cast(uint)ae.e1.type.size();

                elem* el = e1;
                elem* enbytes = el_long(TYsize_t, sz);
                elem* evalue = el_long(TYchar, 0);

                el = el_una(OPaddr, TYnptr, el);
                elem* e = el_param(enbytes, evalue);
                e = el_bin(OPmemset,TYnptr,el,e);
                return setResult2(e);
            }

            //printf("toElemBin() '%s'\n", ae.toChars());

            if (auto sle = ae.e2.isStructLiteralExp())
            {
                static bool allZeroBits(ref Expressions exps)
                {
                    foreach (e; exps[])
                    {
                        /* The expression types checked can be expanded to include
                         * floating point, struct literals, and array literals.
                         * Just be careful to return false for -0.0
                         */
                        if (!e ||
                            e.op == EXP.int64 && e.isIntegerExp().toInteger() == 0 ||
                            e.op == EXP.null_)
                            continue;
                        return false;
                    }
                    return true;
                }

                /* Use a memset to 0
                 */
                if ((sle.useStaticInit ||
                     sle.elements && _isZeroInit(sle) && !sle.sd.isNested()) &&
                    ae.e2.type.isZeroInit(ae.e2.loc))
                {
                    elem* enbytes = el_long(TYsize_t, ae.e1.type.size());
                    elem* evalue = el_long(TYchar, 0);
                    elem* el = el_una(OPaddr, TYnptr, e1);
                    elem* e = el_bin(OPmemset,TYnptr, el, el_param(enbytes, evalue));
                    return setResult2(e);
                }

                auto ex = e1.Eoper == OPind ? e1.E1 : e1;
                if (ex.Eoper == OPvar && ex.Voffset == 0 &&
                    (ae.op == EXP.construct || ae.op == EXP.blit))
                {
                    elem* e = toElemStructLit(sle, irs, ae.op, ex.Vsym, true);
                    el_free(e1);
                    return setResult2(e);
                }
            }

            /* Implement:
             *  (struct = struct)
             */
            elem* e2 = toElem(ae.e2, irs);

            elem* e = elAssign(e1, e2, ae.e1.type, null);
            return setResult2(e);
        }
        else if (t1b.ty == Tsarray)
        {
            if (ae.op == EXP.blit && ae.e2.op == EXP.int64)
            {
                /* Implement:
                 *  (sarray = 0)
                 * with:
                 *  memset(&sarray, 0, struct.sizeof)
                 */
                elem* ey = null;
                targ_size_t sz = ae.e1.type.size();

                elem* el = e1;
                elem* enbytes = el_long(TYsize_t, sz);
                elem* evalue = el_long(TYchar, 0);

                el = el_una(OPaddr, TYnptr, el);
                elem* e = el_param(enbytes, evalue);
                e = el_bin(OPmemset,TYnptr,el,e);
                e = el_combine(ey, e);
                return setResult2(e);
            }

            /* Implement:
             *  (sarray = sarray)
             */
            assert(ae.e2.type.toBasetype().ty == Tsarray);

            bool postblit = needsPostblit(t1b.nextOf()) !is null;
            bool destructor = needsDtor(t1b.nextOf()) !is null;

            /* Optimize static array assignment with array literal.
             * Rewrite:
             *      e1 = [a, b, ...];
             * as:
             *      e1[0] = a, e1[1] = b, ...;
             *
             * If the same values are contiguous, that will be rewritten
             * to block assignment.
             * Rewrite:
             *      e1 = [x, a, a, b, ...];
             * as:
             *      e1[0] = x, e1[1..2] = a, e1[3] = b, ...;
             */
            if (ae.op == EXP.construct &&   // https://issues.dlang.org/show_bug.cgi?id=11238
                                           // avoid aliasing issue
                ae.e2.op == EXP.arrayLiteral)
            {
                ArrayLiteralExp ale = cast(ArrayLiteralExp)ae.e2;
                elem* e;
                if (ale.elements.length == 0)
                {
                    e = e1;
                }
                else
                {
                    Symbol* stmp = symbol_genauto(TYnptr);
                    e1 = addressElem(e1, t1b);
                    e1 = el_bin(OPeq, TYnptr, el_var(stmp), e1);

                    // Eliminate _d_arrayliteralTX call in ae.e2.
                    e = ExpressionsToStaticArray(irs, ale.loc, ale.elements, &stmp, 0, ale.basis);
                    e = el_combine(e1, e);
                }
                return setResult2(e);
            }

            if (ae.op == EXP.assign)
            {
                if (auto ve1 = ae.e1.isVectorArrayExp())
                {
                    // Use an OPeq rather than an OPstreq
                    e1 = toElem(ve1.e1, irs);
                    elem* e2 = toElem(ae.e2, irs);
                    e2.Ety = e1.Ety;
                    elem* e = el_bin(OPeq, e2.Ety, e1, e2);
                    return setResult2(e);
                }
            }

            /* https://issues.dlang.org/show_bug.cgi?id=13661
             * Even if the elements in rhs are all rvalues and
             * don't have to call postblits, this assignment should call
             * destructors on old assigned elements.
             */
            bool lvalueElem = false;
            if (ae.e2.op == EXP.slice && (cast(UnaExp)ae.e2).e1.isLvalue() ||
                ae.e2.op == EXP.cast_  && (cast(UnaExp)ae.e2).e1.isLvalue() ||
                ae.e2.op != EXP.slice && ae.e2.isLvalue())
            {
                lvalueElem = true;
            }

            elem* e2 = toElem(ae.e2, irs);

            if (!postblit && !destructor ||
                ae.op == EXP.construct && !lvalueElem && postblit ||
                ae.op == EXP.blit ||
                type_size(e1.ET) == 0)
            {
                elem* e = elAssign(e1, e2, ae.e1.type, null);
                return setResult2(e);
            }
            else if (ae.op == EXP.construct)
            {
                assert(0, "Trying reference _d_arrayctor, this should not happen!");
            }
            else
            {
                if (ae.e2.isLvalue)
                    assert(0, "Trying to reference `_d_arrayassign_l`, this should not happen!");
                else
                    assert(0, "Trying to reference `_d_arrayassign_r`, this should not happen!");
            }
        }
        else
        {
            elem* e = el_bin(OPeq, tym, e1, toElem(ae.e2, irs));
            return setResult2(e);
        }
        assert(0);
    }

    elem* visitLoweredAssign(LoweredAssignExp e)
    {
        return toElem(e.lowering, irs);
    }

    /***************************************
     */

    elem* visitAddAssign(AddAssignExp e)
    {
        //printf("AddAssignExp.toElem() %s\n", e.toChars());
        return toElemBinAssign(e, OPaddass);
    }


    /***************************************
     */

    elem* visitMinAssign(MinAssignExp e)
    {
        return toElemBinAssign(e, OPminass);
    }

    /***************************************
     */

    elem* visitCatAssign(CatAssignExp ce)
    {
        //printf("CatAssignExp.toElem('%s')\n", ce.toChars());
        elem* e;

        switch (ce.op)
        {
            case EXP.concatenateDcharAssign:
            {
                Type tb1 = ce.e1.type.toBasetype();
                Type tb2 = ce.e2.type.toBasetype();
                assert(tb1.ty == Tarray);
                Type tb1n = tb1.nextOf().toBasetype();

                elem* e1 = toElem(ce.e1, irs);
                elem* e2 = toElem(ce.e2, irs);

                /* Because e1 is an lvalue, refer to it via a pointer to it in the form
                * of ev. Put any side effects into re1
                */
                elem* re1 = addressElem(e1, ce.e1.type.pointerTo(), false);
                elem* ev = el_same(re1);

                // Append dchar to char[] or wchar[]
                assert(tb2.ty == Tdchar &&
                      (tb1n.ty == Tchar || tb1n.ty == Twchar));

                elem* ep = el_params(e2, el_copytree(ev), null);
                const rtl = (tb1.nextOf().ty == Tchar)
                        ? RTLSYM.ARRAYAPPENDCD
                        : RTLSYM.ARRAYAPPENDWD;
                e = el_bin(OPcall, TYdarray, el_var(getRtlsym(rtl)), ep);
                toTraceGC(irs, e, ce.loc);

                /* Generate: (re1, e, *ev)
                */
                e = el_combine(re1, e);
                ev = el_una(OPind, e1.Ety, ev);
                e = el_combine(e, ev);

                break;
            }

            case EXP.concatenateAssign:
            case EXP.concatenateElemAssign:
            {
                /* Do this check during code gen rather than semantic because appending is
                * allowed during CTFE, and we cannot distinguish that in semantic.
                */
                if (!irs.params.useGC)
                {
                    irs.eSink.error(ce.loc,
                        "appending to array in `%s` requires the GC which is not available with -betterC",
                        ce.toChars());
                    return el_long(TYint, 0);
                }

                if (auto lowering = ce.lowering)
                    e = toElem(lowering, irs);
                else if (ce.op == EXP.concatenateAssign)
                    assert(0, "This case should have been rewritten to `_d_arrayappendT` in the semantic phase");
                else
                    assert(0, "This case should have been rewritten to `_d_arrayappendcTX` in the semantic phase");

                break;
            }

            default:
                assert(0);
        }

        elem_setLoc(e, ce.loc);
        return e;
    }

    /***************************************
     */

    elem* visitDivAssign(DivAssignExp e)
    {
        return toElemBinAssign(e, OPdivass);
    }

    /***************************************
     */

    elem* visitModAssign(ModAssignExp e)
    {
        return toElemBinAssign(e, OPmodass);
    }

    /***************************************
     */

    elem* visitMulAssign(MulAssignExp e)
    {
        return toElemBinAssign(e, OPmulass);
    }

    /***************************************
     */

    elem* visitShlAssign(ShlAssignExp e)
    {
        return toElemBinAssign(e, OPshlass);
    }

    /***************************************
     */

    elem* visitShrAssign(ShrAssignExp e)
    {
        //printf("ShrAssignExp.toElem() %s, %s\n", e.e1.type.toChars(), e.e1.toChars());
        Type t1 = e.e1.type;
        if (e.e1.op == EXP.cast_)
        {
            /* Use the type before it was integrally promoted to int
             */
            CastExp ce = cast(CastExp)e.e1;
            t1 = ce.e1.type;
        }
        return toElemBinAssign(e, t1.isUnsigned() ? OPshrass : OPashrass);
    }

    /***************************************
     */

    elem* visitUshrAssign(UshrAssignExp e)
    {
        //printf("UShrAssignExp.toElem() %s, %s\n", e.e1.type.toChars(), e.e1.toChars());
        return toElemBinAssign(e, OPshrass);
    }

    /***************************************
     */

    elem* visitAndAssign(AndAssignExp e)
    {
        return toElemBinAssign(e, OPandass);
    }

    /***************************************
     */

    elem* visitOrAssign(OrAssignExp e)
    {
        return toElemBinAssign(e, OPorass);
    }

    /***************************************
     */

    elem* visitXorAssign(XorAssignExp e)
    {
        return toElemBinAssign(e, OPxorass);
    }

    /***************************************
     */

    elem* visitLogical(LogicalExp aae)
    {
        tym_t tym = totym(aae.type);

        elem* el = toElem(aae.e1, irs);
        elem* er = toElemDtor(aae.e2, irs);
        elem* e = el_bin(aae.op == EXP.andAnd ? OPandand : OPoror,tym,el,er);

        elem_setLoc(e, aae.loc);

        if (irs.params.cov && aae.e2.loc.linnum)
            e.E2 = el_combine(incUsageElem(irs, aae.e2.loc), e.E2);

        return e;
    }

    /***************************************
     */

    elem* visitXor(XorExp e)
    {
        return toElemBin(e, OPxor);
    }

    /***************************************
     */

    elem* visitAnd(AndExp e)
    {
        return toElemBin(e, OPand);
    }

    /***************************************
     */

    elem* visitOr(OrExp e)
    {
        return toElemBin(e, OPor);
    }

    /***************************************
     */

    elem* visitShl(ShlExp e)
    {
        return toElemBin(e, OPshl);
    }

    /***************************************
     */

    elem* visitShr(ShrExp e)
    {
        return toElemBin(e, e.e1.type.isUnsigned() ? OPshr : OPashr);
    }

    /***************************************
     */

    elem* visitUshr(UshrExp se)
    {
        elem* eleft  = toElem(se.e1, irs);
        eleft.Ety = touns(eleft.Ety);
        elem* eright = toElem(se.e2, irs);
        elem* e = el_bin(OPshr, totym(se.type), eleft, eright);
        elem_setLoc(e, se.loc);
        return e;
    }

    /****************************************
     */

    elem* visitComma(CommaExp ce)
    {
        assert(ce.e1 && ce.e2);
        elem* eleft  = toElem(ce.e1, irs);
        elem* eright = toElem(ce.e2, irs);
        elem* e = el_combine(eleft, eright);
        if (e)
            elem_setLoc(e, ce.loc);
        return e;
    }

    /***************************************
     */

    elem* visitCond(CondExp ce)
    {
        elem* ec = toElem(ce.econd, irs);

        elem* eleft = toElem(ce.e1, irs);
        if (irs.params.cov && ce.e1.loc.linnum)
            eleft = el_combine(incUsageElem(irs, ce.e1.loc), eleft);

        elem* eright = toElem(ce.e2, irs);
        if (irs.params.cov && ce.e2.loc.linnum)
            eright = el_combine(incUsageElem(irs, ce.e2.loc), eright);

        tym_t ty = eleft.Ety;
        if (tybasic(ty) == TYnoreturn)
            ty = eright.Ety;
        if (ce.e1.type.toBasetype().ty == Tvoid ||
            ce.e2.type.toBasetype().ty == Tvoid)
            ty = TYvoid;

        elem* e;
        if (tybasic(eleft.Ety) == TYnoreturn &&
            tybasic(eright.Ety) != TYnoreturn)
        {
            /* ec ? eleft : eright => (ec && eleft),eright
             */
            e = el_bin(OPandand, TYvoid, ec, eleft);
            e = el_combine(e, eright);
            if (tybasic(ty) == TYstruct)
                e.ET = Type_toCtype(ce.e2.type);
        }
        else if (tybasic(eright.Ety) == TYnoreturn)
        {
            /* ec ? eleft : eright => (ec || eright),eleft
             */
            e = el_bin(OPoror, TYvoid, ec, eright);
            e = el_combine(e, eleft);
            if (tybasic(ty) == TYstruct)
                e.ET = Type_toCtype(ce.e1.type);
        }
        else
        {
            e = el_bin(OPcond, ty, ec, el_bin(OPcolon, ty, eleft, eright));
            if (tybasic(ty) == TYstruct)
                e.ET = Type_toCtype(ce.e1.type);
        }
        elem_setLoc(e, ce.loc);
        return e;
    }

    /***************************************
     */

    elem* visitType(TypeExp e)
    {
        //printf("TypeExp.toElem()\n");
        irs.eSink.error(e.loc, "type `%s` is not an expression", e.toChars());
        return el_long(TYint, 0);
    }

    elem* visitScope(ScopeExp e)
    {
        irs.eSink.error(e.loc, "`%s` is not an expression", e.sds.toChars());
        return el_long(TYint, 0);
    }

    elem* visitDotVar(DotVarExp dve)
    {
        // *(&e + offset)

        //printf("[%s] DotVarExp.toElem('%s')\n", dve.loc.toChars(), dve.toChars());

        VarDeclaration v = dve.var.isVarDeclaration();
        if (!v)
        {
            irs.eSink.error(dve.loc, "`%s` is not a field, but a %s", dve.var.toChars(), dve.var.kind());
            return el_long(TYint, 0);
        }

        // https://issues.dlang.org/show_bug.cgi?id=12900
        Type txb = dve.type.toBasetype();
        Type tyb = v.type.toBasetype();
        if (auto tv = txb.isTypeVector()) txb = tv.basetype;
        if (auto tv = tyb.isTypeVector()) tyb = tv.basetype;

        debug if (txb.ty != tyb.ty)
            printf("[%s] dve = %s, dve.type = %s, v.type = %s\n", dve.loc.toChars(), dve.toChars(), dve.type.toChars(), v.type.toChars());

        assert(txb.ty == tyb.ty);

        // https://issues.dlang.org/show_bug.cgi?id=14730
        if (v.offset == 0)
        {
            FuncDeclaration fd = v.parent.isFuncDeclaration();
            if (fd && fd.semanticRun < PASS.obj)
                setClosureVarOffset(fd);
        }

        elem* e = toElem(dve.e1, irs);
        Type tb1 = dve.e1.type.toBasetype();
        tym_t typ = TYnptr;
        if (tb1.ty != Tclass && tb1.ty != Tpointer)
        {
            e = addressElem(e, tb1);
            typ = tybasic(e.Ety);
        }

        const tym = totym(dve.type);
        auto voffset = v.offset;
        uint bitfieldarg = 0;
        auto bf = v.isBitFieldDeclaration();
        if (bf)
        {
            // adjust bit offset for bitfield so the type tym encloses the bitfield
            const szbits = tysize(tym) * 8;
            uint memalignsize = target.fieldalign(dve.type);
            auto bitOffset = bf.bitOffset;
            if (bitOffset + bf.fieldWidth > szbits)
            {
                const advance = bf.bitOffset / (memalignsize * 8);
                voffset += advance * memalignsize;
                bitOffset -= advance * memalignsize * 8;
                assert(bitOffset + bf.fieldWidth <= szbits);
            }
            //printf("voffset %u bitOffset %u fieldWidth %u bits %u\n", cast(uint)voffset, bitOffset, bf.fieldWidth, szbits);
            bitfieldarg = bf.fieldWidth * 256 + bitOffset;
        }

        auto eoffset = el_long(TYsize_t, voffset);
        e = el_bin(OPadd, typ, e, objc.getOffset(v, tb1, eoffset));
        if (v.storage_class & (STC.out_ | STC.ref_))
            e = el_una(OPind, TYnptr, e);
        e = el_una(OPind, tym, e);
        if (bf)
        {
            // Insert special bitfield operator
            auto mos = el_long(TYuint, bitfieldarg);
            e = el_bin(OPbit, e.Ety, e, mos);
        }
        if (tybasic(e.Ety) == TYstruct)
        {
            e.ET = Type_toCtype(dve.type);
        }
        elem_setLoc(e,dve.loc);
        return e;
    }

    elem* visitDelegate(DelegateExp de)
    {
        int directcall = 0;
        //printf("DelegateExp.toElem() '%s'\n", de.toChars());

        if (de.func.semanticRun == PASS.semantic3done)
        {
            // Bug 7745 - only include the function if it belongs to this module
            // ie, it is a member of this module, or is a template instance
            // (the template declaration could come from any module).
            Dsymbol owner = de.func.toParent();
            while (!owner.isTemplateInstance() && owner.toParent())
                owner = owner.toParent();
            if (owner.isTemplateInstance() || owner == irs.m )
            {
                irs.deferToObj.push(de.func);
            }
        }

        elem* eeq = null;
        elem* ethis;
        Symbol* sfunc = toSymbol(de.func);
        elem* ep;

        elem* ethis2 = null;
        if (de.vthis2)
        {
            // avoid using toSymbol directly because vthis2 may be a closure var
            Expression ve = new VarExp(de.loc, de.vthis2);
            ve.type = de.vthis2.type;
            ve = new AddrExp(de.loc, ve);
            ve.type = de.vthis2.type.pointerTo();
            ethis2 = toElem(ve, irs);
        }

        if (de.func.isNested() && !de.func.isThis())
        {
            ep = el_ptr(sfunc);
            if (de.e1.op == EXP.null_)
                ethis = toElem(de.e1, irs);
            else
                ethis = getEthis(de.loc, irs, de.func, de.func.toParentLocal());

            if (ethis2)
                ethis2 = setEthis2(de.loc, irs, de.func, ethis2, ethis, eeq);
        }
        else
        {
            ethis = toElem(de.e1, irs);
            if (de.e1.type.ty != Tclass && de.e1.type.ty != Tpointer)
                ethis = addressElem(ethis, de.e1.type);

            if (ethis2)
                ethis2 = setEthis2(de.loc, irs, de.func, ethis2, ethis, eeq);

            if (de.e1.op == EXP.super_ || de.e1.op == EXP.dotType)
                directcall = 1;

            if (!de.func.isThis())
                irs.eSink.error(de.loc, "delegates are only for non-static functions");

            if (!de.func.isVirtual() ||
                directcall ||
                de.func.isFinalFunc())
            {
                ep = el_ptr(sfunc);
            }
            else
            {
                // Get pointer to function out of virtual table

                assert(ethis);
                ep = el_same(ethis);
                ep = el_una(OPind, TYnptr, ep);
                uint vindex = de.func.vtblIndex;

                assert(cast(int)vindex >= 0);

                // Build *(ep + vindex * 4)
                ep = el_bin(OPadd,TYnptr,ep,el_long(TYsize_t, vindex * irs.target.ptrsize));
                ep = el_una(OPind,TYnptr,ep);
            }

            //if (func.tintro)
            //    func.error(loc, "cannot form delegate due to covariant return type");
        }

        elem* e;
        if (ethis2)
            ethis = ethis2;
        if (ethis.Eoper == OPcomma)
        {
            ethis.E2 = el_pair(TYdelegate, ethis.E2, ep);
            ethis.Ety = TYdelegate;
            e = ethis;
        }
        else
            e = el_pair(TYdelegate, ethis, ep);
        elem_setLoc(e, de.loc);
        if (eeq)
            e = el_combine(eeq, e);
        return e;
    }

    elem* visitDotType(DotTypeExp dte)
    {
        // Just a pass-thru to e1
        //printf("DotTypeExp.toElem() %s\n", dte.toChars());
        elem* e = toElem(dte.e1, irs);
        elem_setLoc(e, dte.loc);
        return e;
    }

    elem* visitCall(CallExp ce)
    {
        //printf("[%s] CallExp.toElem('%s') %p, %s\n", ce.loc.toChars(), ce.toChars(), ce, ce.type.toChars());
        assert(ce.e1.type);
        Type t1 = ce.e1.type.toBasetype();
        Type ectype = t1;
        elem* eeq = null;

        elem* ehidden = irs.ehidden;
        irs.ehidden = null;

        elem* ec;
        FuncDeclaration fd = null;
        bool dctor = false;
        if (ce.e1.op == EXP.dotVariable && t1.ty != Tdelegate)
        {
            DotVarExp dve = cast(DotVarExp)ce.e1;

            fd = dve.var.isFuncDeclaration();

            if (auto sle = dve.e1.isStructLiteralExp())
            {
                if (fd && fd.isCtorDeclaration() ||
                    fd.type.isMutable() ||
                    sle.type.size() <= 8)          // more efficient than fPIC
                    sle.useStaticInit = false;     // don't modify initializer, so make copy
            }

            ec = toElem(dve.e1, irs);
            ectype = dve.e1.type.toBasetype();

            /* Recognize:
             *   [1] ce:  ((S __ctmp = initializer),__ctmp).ctor(args)
             * where the left of the . was turned into [2] or [3] for EH_DWARF:
             *   [2] ec:  (dctor info ((__ctmp = initializer),__ctmp)), __ctmp
             *   [3] ec:  (dctor info ((_flag=0),((__ctmp = initializer),__ctmp))), __ctmp
             * The trouble
             * https://issues.dlang.org/show_bug.cgi?id=13095
             * is if ctor(args) throws, then __ctmp is destructed even though __ctmp
             * is not a fully constructed object yet. The solution is to move the ctor(args) itno the dctor tree.
             * But first, detect [1], then [2], then split up [2] into:
             *   eeq: (dctor info ((__ctmp = initializer),__ctmp))
             *   eeq: (dctor info ((_flag=0),((__ctmp = initializer),__ctmp)))   for EH_DWARF
             *   ec:  __ctmp
             */
            if (fd && fd.isCtorDeclaration())
            {
                //printf("test30 %s\n", dve.e1.toChars());
                if (dve.e1.op == EXP.comma)
                {
                    //printf("test30a\n");
                    if ((cast(CommaExp)dve.e1).e1.op == EXP.declaration && (cast(CommaExp)dve.e1).e2.op == EXP.variable)
                    {   // dve.e1: (declaration , var)

                        //printf("test30b\n");
                        if (ec.Eoper == OPcomma &&
                            ec.E1.Eoper == OPinfo &&
                            ec.E1.E1.Eoper == OPdctor &&
                            ec.E1.E2.Eoper == OPcomma)
                        {   // ec: ((dctor info (* , *)) , *)

                            //printf("test30c\n");
                            dctor = true;                   // remember we detected it

                            // Split ec into eeq and ec per comment above
                            eeq = ec.E1;                   // (dctor info (*, *))
                            ec.E1 = null;
                            ec = el_selecte2(ec);           // *
                        }
                    }
                }
            }


            if (dctor)
            {
            }
            else if (ce.arguments && ce.arguments.length && ec.Eoper != OPvar)
            {
                if (ec.Eoper == OPind && el_sideeffect(ec.E1))
                {
                    /* Rewrite (*exp)(arguments) as:
                     * tmp = exp, (*tmp)(arguments)
                     */
                    elem* ec1 = ec.E1;
                    Symbol* stmp = symbol_genauto(type_fake(ec1.Ety));
                    eeq = el_bin(OPeq, ec.Ety, el_var(stmp), ec1);
                    ec.E1 = el_var(stmp);
                }
                else if (tybasic(ec.Ety) != TYnptr)
                {
                    /* Rewrite (exp)(arguments) as:
                     * tmp=&exp, (*tmp)(arguments)
                     */
                    ec = addressElem(ec, ectype);

                    Symbol* stmp = symbol_genauto(type_fake(ec.Ety));
                    eeq = el_bin(OPeq, ec.Ety, el_var(stmp), ec);
                    ec = el_una(OPind, totym(ectype), el_var(stmp));
                }
            }
        }
        else if (ce.e1.op == EXP.variable)
        {
            fd = (cast(VarExp)ce.e1).var.isFuncDeclaration();
            version (none)
            {
                // This optimization is not valid if alloca can be called
                // multiple times within the same function, eg in a loop
                // see https://issues.dlang.org/show_bug.cgi?id=3822
                if (fd && fd.ident == Id.__alloca &&
                    !fd.fbody && fd._linkage == LINK.c &&
                    arguments && arguments.length == 1)
                {   Expression arg = (*arguments)[0];
                    arg = arg.optimize(WANTvalue);
                    if (arg.isConst() && arg.type.isIntegral())
                    {   const sz = arg.toInteger();
                        if (sz > 0 && sz < 0x40000)
                        {
                            // It's an alloca(sz) of a fixed amount.
                            // Replace with an array allocated on the stack
                            // of the same size: char[sz] tmp;

                            assert(!ehidden);
                            .type* t = type_static_array(sz, tschar);  // BUG: fix extra Tcount++
                            Symbol* stmp = symbol_genauto(t);
                            ec = el_ptr(stmp);
                            elem_setLoc(ec,loc);
                            return ec;
                        }
                    }
                }
            }

            ec = toElem(ce.e1, irs);
        }
        else
        {
            ec = toElem(ce.e1, irs);
            if (ce.arguments && ce.arguments.length)
            {
                /* The idea is to enforce expressions being evaluated left to right,
                 * even though call trees are evaluated parameters first.
                 * We just do a quick hack to catch the more obvious cases, though
                 * we need to solve this generally.
                 */
                if (ec.Eoper == OPind && el_sideeffect(ec.E1))
                {
                    /* Rewrite (*exp)(arguments) as:
                     * tmp=exp, (*tmp)(arguments)
                     */
                    elem* ec1 = ec.E1;
                    Symbol* stmp = symbol_genauto(type_fake(ec1.Ety));
                    eeq = el_bin(OPeq, ec.Ety, el_var(stmp), ec1);
                    ec.E1 = el_var(stmp);
                }
                else if (tybasic(ec.Ety) == TYdelegate && el_sideeffect(ec))
                {
                    /* Rewrite (exp)(arguments) as:
                     * tmp=exp, (tmp)(arguments)
                     */
                    Symbol* stmp = symbol_genauto(type_fake(ec.Ety));
                    eeq = el_bin(OPeq, ec.Ety, el_var(stmp), ec);
                    ec = el_var(stmp);
                }
            }
        }
        elem* ethis2 = null;
        if (ce.vthis2)
        {
            // avoid using toSymbol directly because vthis2 may be a closure var
            Expression ve = new VarExp(ce.loc, ce.vthis2);
            ve.type = ce.vthis2.type;
            ve = new AddrExp(ce.loc, ve);
            ve.type = ce.vthis2.type.pointerTo();
            ethis2 = toElem(ve, irs);
        }
        elem* ecall = callfunc(ce.loc, irs, ce.directcall, ce.type, ec, ectype, fd, t1, ehidden, ce.arguments, null, ethis2);

        if (dctor && ecall.Eoper == OPind)
        {
            /* Continuation of fix outlined above for moving constructor call into dctor tree.
             * Given:
             *   eeq:   (dctor info ((__ctmp = initializer),__ctmp))
             *   eeq:   (dctor info ((_flag=0),((__ctmp = initializer),__ctmp)))   for EH_DWARF
             *   ecall: * call(ce, args)
             * Rewrite ecall as:
             *    * (dctor info ((__ctmp = initializer),call(ce, args)))
             *    * (dctor info ((_flag=0),(__ctmp = initializer),call(ce, args)))
             */
            elem* ea = ecall.E1;           // ea: call(ce,args)
            tym_t ty = ea.Ety;
            ecall.E1 = eeq;
            assert(eeq.Eoper == OPinfo);
            elem* eeqcomma = eeq.E2;
            assert(eeqcomma.Eoper == OPcomma);
            while (eeqcomma.E2.Eoper == OPcomma)
            {
                eeqcomma.Ety = ty;
                eeqcomma = eeqcomma.E2;
            }
            eeq.Ety = ty;
            el_free(eeqcomma.E2);
            eeqcomma.E2 = ea;               // replace ,__ctmp with ,call(ce,args)
            eeqcomma.Ety = ty;
            eeq = null;
        }

        elem_setLoc(ecall, ce.loc);
        if (eeq)
            ecall = el_combine(eeq, ecall);
        return ecall;
    }

    elem* visitAddr(AddrExp ae)
    {
        //printf("AddrExp.toElem('%s')\n", ae.toChars());
        if (auto sle = ae.e1.isStructLiteralExp())
        {
            //printf("AddrExp.toElem('%s') %d\n", ae.toChars(), ae);
            //printf("StructLiteralExp(%p); origin:%p\n", sle, sle.origin);
            //printf("sle.toSymbol() (%p)\n", sle.toSymbol());
            if (irs.Cfile)
            {
                Symbol* stmp = symbol_genauto(Type_toCtype(sle.sd.type));
                elem* es = toElemStructLit(sle, irs, EXP.construct, stmp, true);
                elem* e = addressElem(el_var(stmp), ae.e1.type);
                e.Ety = totym(ae.type);
                e = el_bin(OPcomma, e.Ety, es, e);
                elem_setLoc(e, ae.loc);
                return e;
            }
            elem* e = el_ptr(toSymbol(sle.origin));
            e.ET = Type_toCtype(ae.type);
            elem_setLoc(e, ae.loc);
            return e;
        }
        else
        {
            elem* e = toElem(ae.e1, irs);
            e = addressElem(e, ae.e1.type);
            e.Ety = totym(ae.type);
            elem_setLoc(e, ae.loc);
            return e;
        }
    }

    elem* visitPtr(PtrExp pe)
    {
        //printf("PtrExp.toElem() %s\n", pe.toChars());
        elem* e = toElem(pe.e1, irs);
        if (tybasic(e.Ety) == TYnptr &&
            pe.e1.type.nextOf() &&
            pe.e1.type.nextOf().isImmutable())
        {
            e.Ety = TYimmutPtr;     // pointer to immutable
        }
        e = el_una(OPind,totym(pe.type),e);
        if (tybasic(e.Ety) == TYstruct)
        {
            e.ET = Type_toCtype(pe.type);
        }
        elem_setLoc(e, pe.loc);
        return e;
    }

    elem* visitDelete(DeleteExp de)
    {
        Type tb;

        //printf("DeleteExp.toElem()\n");
        if (de.e1.op == EXP.index)
        {
            IndexExp ae = cast(IndexExp)de.e1;
            tb = ae.e1.type.toBasetype();
            assert(tb.ty != Taarray);
        }
        //e1.type.print();
        elem* e = toElem(de.e1, irs);
        tb = de.e1.type.toBasetype();
        RTLSYM rtl;
        switch (tb.ty)
        {
            case Tclass:
                if (de.e1.op == EXP.variable)
                {
                    VarExp ve = cast(VarExp)de.e1;
                    if (ve.var.isVarDeclaration() &&
                        ve.var.isVarDeclaration().onstack)
                    {
                        rtl = RTLSYM.CALLFINALIZER;
                        if (tb.isClassHandle().isInterfaceDeclaration())
                            rtl = RTLSYM.CALLINTERFACEFINALIZER;
                        break;
                    }
                }
                goto default;

            default:
                assert(0);
        }
        e = el_bin(OPcall, TYvoid, el_var(getRtlsym(rtl)), e);
        toTraceGC(irs, e, de.loc);
        elem_setLoc(e, de.loc);
        return e;
    }

    elem* visitVector(VectorExp ve)
    {
        version (none)
        {
            printf("VectorExp.toElem()\n");
            printAST(ve);
            printf("\tfrom: %s\n", ve.e1.type.toChars());
            printf("\tto  : %s\n", ve.to.toChars());
        }

        elem* e;
        if (ve.e1.op == EXP.arrayLiteral)
        {
            e = el_calloc();
            e.Eoper = OPconst;
            e.Ety = totym(ve.type);

            foreach (const i; 0 .. ve.dim)
            {
                Expression elem = ve.e1.isArrayLiteralExp()[i];
                const complex = elem.toComplex();
                const integer = elem.toInteger();
                switch (elem.type.toBasetype().ty)
                {
                    case Tfloat32:
                        // Must not call toReal directly, to avoid dmd bug 14203 from breaking dmd
                        e.Vfloat8[i] = cast(float) complex.re;
                        break;

                    case Tfloat64:
                        // Must not call toReal directly, to avoid dmd bug 14203 from breaking dmd
                        e.Vdouble4[i] = cast(double) complex.re;
                        break;

                    case Tint64:
                    case Tuns64:
                        e.Vullong4[i] = integer;
                        break;

                    case Tint32:
                    case Tuns32:
                        e.Vulong8[i] = cast(uint)integer;
                        break;

                    case Tint16:
                    case Tuns16:
                        e.Vushort16[i] = cast(ushort)integer;
                        break;

                    case Tint8:
                    case Tuns8:
                        e.Vuchar32[i] = cast(ubyte)integer;
                        break;

                    default:
                        assert(0);
                }
            }
        }
        else if (ve.type.size() == ve.e1.type.size())
        {
            e = toElem(ve.e1, irs);
            e.Ety = totym(ve.type);  // paint vector type on it
        }
        else
        {
            // Create vecfill(e1)
            elem* e1 = toElem(ve.e1, irs);
            e = el_una(OPvecfill, totym(ve.type), e1);
        }
        elem_setLoc(e, ve.loc);
        return e;
    }

    elem* visitVectorArray(VectorArrayExp vae)
    {
        elem* result;
        // Generate code for `vec.array`
        if (auto ve = vae.e1.isVectorExp())
        {
            // https://issues.dlang.org/show_bug.cgi?id=19607
            // When viewing a vector literal as an array, build the underlying array directly.
            if (ve.e1.op == EXP.arrayLiteral)
                result = toElem(ve.e1, irs);
            else
            {
                // Generate: stmp[0 .. dim] = e1
                type* tarray = Type_toCtype(vae.type);
                Symbol* stmp = symbol_genauto(tarray);
                result = setArray(ve.e1, el_ptr(stmp), el_long(TYsize_t, tarray.Tdim),
                                  ve.e1.type, toElem(ve.e1, irs), irs, EXP.blit);
                result = el_combine(result, el_var(stmp));
                result.ET = tarray;
            }
        }
        else
        {
            // For other vector expressions this just a paint operation.
            elem* e = toElem(vae.e1, irs);
            type* tarray = Type_toCtype(vae.type);
            // Take the address then repaint,
            // this makes it swap to the right registers
            e = addressElem(e, vae.e1.type);
            e = el_una(OPind, tarray.Tty, e);
            e.ET = tarray;
            result = e;
        }
        result.Ety = totym(vae.type);
        elem_setLoc(result, vae.loc);
        return result;
    }

    elem* visitCast(CastExp ce)
    {
        version (none)
        {
            printf("CastExp.toElem()\n");
            ce.print();
            printf("\tfrom: %s\n", ce.e1.type.toChars());
            printf("\tto  : %s\n", ce.to.toChars());
        }
        elem* e = toElem(ce.e1, irs);

        return toElemCast(ce, e, false, irs);
    }

    elem* visitArrayLength(ArrayLengthExp ale)
    {
        elem* e = toElem(ale.e1, irs);
        e = el_una(target.isX86_64 ? OP128_64 : OP64_32, totym(ale.type), e);
        elem_setLoc(e, ale.loc);
        return e;
    }

    elem* visitDelegatePtr(DelegatePtrExp dpe)
    {
        // *cast(void**)(&dg)
        elem* e = toElem(dpe.e1, irs);
        Type tb1 = dpe.e1.type.toBasetype();
        e = addressElem(e, tb1);
        e = el_una(OPind, totym(dpe.type), e);
        elem_setLoc(e, dpe.loc);
        return e;
    }

    elem* visitDelegateFuncptr(DelegateFuncptrExp dfpe)
    {
        // *cast(void**)(&dg + size_t.sizeof)
        elem* e = toElem(dfpe.e1, irs);
        Type tb1 = dfpe.e1.type.toBasetype();
        e = addressElem(e, tb1);
        e = el_bin(OPadd, TYnptr, e, el_long(TYsize_t, target.isX86_64 ? 8 : 4));
        e = el_una(OPind, totym(dfpe.type), e);
        elem_setLoc(e, dfpe.loc);
        return e;
    }

    elem* visitSlice(SliceExp se)
    {
        //printf("SliceExp.toElem() se = %s %s\n", se.type.toChars(), se.toChars());
        Type tb = se.type.toBasetype();
        assert(tb.isStaticOrDynamicArray());
        Type t1 = se.e1.type.toBasetype();
        elem* e = toElem(se.e1, irs);
        if (se.lwr)
        {
            uint sz = cast(uint)t1.nextOf().size();

            elem* einit = resolveLengthVar(se.lengthVar, &e, t1);
            if (t1.ty == Tsarray)
                e = array_toPtr(se.e1.type, e);
            if (!einit)
            {
                einit = e;
                e = el_same(einit);
            }
            // e is a temporary, typed:
            //  TYdarray if t.ty == Tarray
            //  TYptr if t.ty == Tsarray or Tpointer

            elem* elwr = toElem(se.lwr, irs);
            elem* eupr = toElem(se.upr, irs);
            elem* elwr2 = el_sideeffect(eupr) ? el_copytotmp(elwr) : el_same(elwr);
            elem* eupr2 = eupr;

            //printf("upperIsInBounds = %d lowerIsLessThanUpper = %d\n", se.upperIsInBounds, se.lowerIsLessThanUpper);
            if (irs.arrayBoundsCheck())
            {
                // Checks (unsigned compares):
                //  upr <= array.length
                //  lwr <= upr

                elem* c1 = null;
                elem* elen;
                if (!se.upperIsInBounds)
                {
                    eupr2 = el_same(eupr);
                    eupr2.Ety = TYsize_t;  // make sure unsigned comparison

                    if (auto tsa = t1.isTypeSArray())
                    {
                        elen = el_long(TYsize_t, tsa.dim.toInteger());
                    }
                    else if (t1.ty == Tarray)
                    {
                        if (se.lengthVar && !(se.lengthVar.storage_class & STC.const_))
                            elen = el_var(toSymbol(se.lengthVar));
                        else
                        {
                            elen = e;
                            e = el_same(elen);
                            elen = el_una(target.isX86_64 ? OP128_64 : OP64_32, TYsize_t, elen);
                        }
                    }

                    c1 = el_bin(OPle, TYint, eupr, elen);

                    if (!se.lowerIsLessThanUpper)
                    {
                        c1 = el_bin(OPandand, TYint,
                            c1, el_bin(OPle, TYint, elwr2, eupr2));
                        elwr2 = el_copytree(elwr2);
                        eupr2 = el_copytree(eupr2);
                    }
                }
                else if (!se.lowerIsLessThanUpper)
                {
                    eupr2 = el_same(eupr);
                    eupr2.Ety = TYsize_t;  // make sure unsigned comparison

                    c1 = el_bin(OPle, TYint, elwr2, eupr);
                    elwr2 = el_copytree(elwr2);
                }

                if (c1)
                {
                    // Construct: (c1 || arrayBoundsError)
                    // if lowerIsLessThanUpper (e.g. arr[-1..0]), elen is null here
                    elen = elen ? elen : el_long(TYsize_t, 0);
                    auto ea = buildArraySliceError(irs, se.loc, el_copytree(elwr2), el_copytree(eupr2), el_copytree(elen));
                    elem* eb = el_bin(OPoror, TYvoid, c1, ea);

                    elwr = el_combine(elwr, eb);
                }
            }
            if (t1.ty != Tsarray)
                e = array_toPtr(se.e1.type, e);

            // Create an array reference where:
            // length is (upr - lwr)
            // pointer is (ptr + lwr*sz)
            // Combine as (length pair ptr)

            elem* eofs = el_bin(OPmul, TYsize_t, elwr2, el_long(TYsize_t, sz));
            elem* eptr = el_bin(OPadd, TYnptr, e, eofs);

            if (tb.ty == Tarray)
            {
                elem* elen = el_bin(OPmin, TYsize_t, eupr2, el_copytree(elwr2));
                e = el_pair(TYdarray, elen, eptr);
            }
            else
            {
                assert(tb.ty == Tsarray);
                e = el_una(OPind, totym(se.type), eptr);
                if (tybasic(e.Ety) == TYstruct)
                    e.ET = Type_toCtype(se.type);
            }
            e = el_combine(elwr, e);
            e = el_combine(einit, e);
            //elem_print(e);
        }
        else if (t1.ty == Tsarray && tb.ty == Tarray)
        {
            e = sarray_toDarray(se.loc, t1, null, e);
        }
        else
        {
            assert(t1.ty == tb.ty);   // Tarray or Tsarray

            // https://issues.dlang.org/show_bug.cgi?id=14672
            // If se is in left side operand of element-wise
            // assignment, the element type can be painted to the base class.
            int offset;
            import dmd.typesem : isBaseOf;
            assert(t1.nextOf().equivalent(tb.nextOf()) ||
                   tb.nextOf().isBaseOf(t1.nextOf(), &offset) && offset == 0);
        }
        elem_setLoc(e, se.loc);
        return e;
    }

    elem* visitIndex(IndexExp ie)
    {
        elem* e;
        elem* n1 = toElem(ie.e1, irs);
        elem* eb = null;

        //printf("IndexExp.toElem() %s\n", ie.toChars());
        Type t1 = ie.e1.type.toBasetype();
        if (auto taa = t1.isTypeAArray())
        {
            // set to:
            //      *aaGetY(aa, aati, valuesize, &key);
            // or
            //      *aaGetRvalueX(aa, keyti, valuesize, &key);

            uint vsize = cast(uint)taa.next.size();

            // n2 becomes the index, also known as the key
            elem* n2 = toElem(ie.e2, irs);

            /* Turn n2 into a pointer to the index.  If it's an lvalue,
             * take the address of it. If not, copy it to a temp and
             * take the address of that.
             */
            n2 = addressElem(n2, taa.index);

            elem* valuesize = el_long(TYsize_t, vsize);
            //printf("valuesize: "); elem_print(valuesize);
            Symbol* s;
            elem* ti;
            if (ie.modifiable)
            {
                n1 = el_una(OPaddr, TYnptr, n1);
                s = getRtlsym(RTLSYM.AAGETY);
                ti = getTypeInfo(ie.e1, taa.unSharedOf().mutableOf(), irs);
            }
            else
            {
                s = getRtlsym(RTLSYM.AAGETRVALUEX);
                ti = getTypeInfo(ie.e1, taa.index, irs);
            }
            //printf("taa.index = %s\n", taa.index.toChars());
            //printf("ti:\n"); elem_print(ti);
            elem* ep = el_params(n2, valuesize, ti, n1, null);
            e = el_bin(OPcall, TYnptr, el_var(s), ep);
            if (irs.arrayBoundsCheck())
            {
                elem* n = el_same(e);

                // Construct: ((e || arrayBoundsError), n)
                auto ea = buildRangeError(irs, ie.loc);
                e = el_bin(OPoror,TYvoid,e,ea);
                e = el_bin(OPcomma, TYnptr, e, n);
            }
            e = el_una(OPind, totym(ie.type), e);
            if (tybasic(e.Ety) == TYstruct)
                e.ET = Type_toCtype(ie.type);
            elem_setLoc(e, ie.loc);
            return e;
        }

        elem* einit = resolveLengthVar(ie.lengthVar, &n1, t1);
        elem* n2 = toElem(ie.e2, irs);

        if (irs.arrayBoundsCheck() && !ie.indexIsInBounds)
        {
            elem* elength;

            if (auto tsa = t1.isTypeSArray())
            {
                const length = tsa.dim.toInteger();

                elength = el_long(TYsize_t, length);
                goto L1;
            }
            else if (t1.ty == Tarray)
            {
                elength = n1;
                n1 = el_same(elength);
                elength = el_una(target.isX86_64 ? OP128_64 : OP64_32, TYsize_t, elength);
            L1:
                elem* n2x = n2;
                n2 = el_same(n2x);
                n2x = el_bin(OPlt, TYint, n2x, elength);

                // Construct: (n2x || arrayBoundsError)
                auto ea = buildArrayIndexError(irs, ie.loc, el_copytree(n2), el_copytree(elength));
                eb = el_bin(OPoror,TYvoid,n2x,ea);
            }
        }

        n1 = array_toPtr(t1, n1);

        {
            elem* escale = el_long(TYsize_t, t1.nextOf().size());
            n2 = el_bin(OPmul, TYsize_t, n2, escale);
            e = el_bin(OPadd, TYnptr, n1, n2);
            e = el_una(OPind, totym(ie.type), e);
            if (tybasic(e.Ety) == TYstruct || tybasic(e.Ety) == TYarray)
            {
                e.Ety = TYstruct;
                e.ET = Type_toCtype(ie.type);
            }
        }

        eb = el_combine(einit, eb);
        e = el_combine(eb, e);
        elem_setLoc(e, ie.loc);
        return e;
    }


    elem* visitTuple(TupleExp te)
    {
        //printf("TupleExp.toElem() %s\n", te.toChars());
        elem* e = null;
        if (te.e0)
            e = toElem(te.e0, irs);
        foreach (el; *te.exps)
        {
            elem* ep = toElem(el, irs);
            e = el_combine(e, ep);
        }
        return e;
    }

    static elem* tree_insert(Elems* args, size_t low, size_t high)
    {
        assert(low < high);
        if (low + 1 == high)
            return (*args)[low];
        int mid = cast(int)((low + high) >> 1);
        return el_param(tree_insert(args, low, mid),
                        tree_insert(args, mid, high));
    }

    elem* visitArrayLiteral(ArrayLiteralExp ale)
    {
        size_t dim = ale.elements ? ale.elements.length : 0;

        //printf("ArrayLiteralExp.toElem() %s, type = %s\n", ale.toChars(), ale.type.toChars());
        Type tb = ale.type.toBasetype();
        if (tb.ty == Tsarray && tb.nextOf().toBasetype().ty == Tvoid)
        {
            // Convert void[n] to ubyte[n]
            tb = Type.tuns8.sarrayOf((cast(TypeSArray)tb).dim.toUInteger());
        }

        elem* e;
        if (dim > 0)
        {
            if (ale.onstack || tb.ty == Tsarray ||
                irs.Cfile && tb.ty == Tpointer)
            {
                Symbol* stmp = null;
                e = ExpressionsToStaticArray(irs, ale.loc, ale.elements, &stmp, 0, ale.basis);
                e = el_combine(e, el_ptr(stmp));
            }
            else
            {
                /* Instead of passing the initializers on the stack, allocate the
                * array and assign the members inline.
                * Avoids the whole variadic arg mess.
                */

                // call _d_arrayliteralTX(ti, dim)
                e = el_bin(OPcall, TYnptr,
                    el_var(getRtlsym(RTLSYM.ARRAYLITERALTX)),
                    el_param(el_long(TYsize_t, dim), getTypeInfo(ale, ale.type, irs)));
                toTraceGC(irs, e, ale.loc);

                Symbol* stmp = symbol_genauto(Type_toCtype(Type.tvoid.pointerTo()));
                e = el_bin(OPeq, TYnptr, el_var(stmp), e);

                e = el_combine(e, ExpressionsToStaticArray(irs, ale.loc, ale.elements, &stmp, 0, ale.basis));

                e = el_combine(e, el_var(stmp));
            }
        }
        else
        {
            e = el_long(TYsize_t, 0);
        }

        if (tb.ty == Tarray)
        {
            e = el_pair(TYdarray, el_long(TYsize_t, dim), e);
        }
        else if (tb.ty == Tpointer)
        {
        }
        else
        {
            e = el_una(OPind, TYstruct, e);
            e.ET = Type_toCtype(ale.type);
        }

        elem_setLoc(e, ale.loc);
        return e;
    }

    elem* visitAssocArrayLiteral(AssocArrayLiteralExp aale)
    {
        //printf("AssocArrayLiteralExp.toElem() %s\n", aale.toChars());

        Type t = aale.type.toBasetype().mutableOf();

        size_t dim = aale.keys.length;
        if (!dim)
        {
            elem* e = el_long(TYnptr, 0);      // empty associative array is the null pointer
            if (t.ty != Taarray)
                e = addressElem(e, Type.tvoidptr);
            return e;
        }

        // call _d_assocarrayliteralTX(TypeInfo_AssociativeArray ti, void[] keys, void[] values)
        // Prefer this to avoid the varargs fiasco in 64 bit code

        assert(t.ty == Taarray);
        Type ta = t;

        Symbol* skeys = null;
        elem* ekeys = ExpressionsToStaticArray(irs, aale.loc, aale.keys, &skeys);

        Symbol* svalues = null;
        elem* evalues = ExpressionsToStaticArray(irs, aale.loc, aale.values, &svalues);

        elem* ev = el_pair(TYdarray, el_long(TYsize_t, dim), el_ptr(svalues));
        elem* ek = el_pair(TYdarray, el_long(TYsize_t, dim), el_ptr(skeys  ));
        if (irs.target.os == Target.OS.Windows && irs.target.isX86_64)
        {
            ev = addressElem(ev, Type.tvoid.arrayOf());
            ek = addressElem(ek, Type.tvoid.arrayOf());
        }
        elem* e = el_params(ev, ek,
                            getTypeInfo(aale, ta, irs),
                            null);

        // call _d_assocarrayliteralTX(ti, keys, values)
        e = el_bin(OPcall,TYnptr,el_var(getRtlsym(RTLSYM.ASSOCARRAYLITERALTX)),e);
        toTraceGC(irs, e, aale.loc);
        if (t != ta)
            e = addressElem(e, ta);
        elem_setLoc(e, aale.loc);

        e = el_combine(evalues, e);
        e = el_combine(ekeys, e);
        return e;
    }

    elem* visitStructLiteral(StructLiteralExp sle)
    {
        //printf("[%s] StructLiteralExp.toElem() %s\n", sle.loc.toChars(), sle.toChars());
        return toElemStructLit(sle, irs, EXP.construct, cast(Symbol*)sle.sym, true);
    }

    elem* visitObjcClassReference(ObjcClassReferenceExp e)
    {
        return objc.toElem(e);
    }

    /*****************************************************/
    /*                   CTFE stuff                      */
    /*****************************************************/

    elem* visitClassReference(ClassReferenceExp e)
    {
        //printf("ClassReferenceExp.toElem() %p, value=%p, %s\n", e, e.value, e.toChars());
        return el_ptr(toSymbol(e));
    }

    switch (e.op)
    {
        default:                return visit(e);

        case EXP.negate:        return visitNeg(e.isNegExp());
        case EXP.tilde:         return visitCom(e.isComExp());
        case EXP.not:           return visitNot(e.isNotExp());
        case EXP.plusPlus:
        case EXP.minusMinus:    return visitPost(e.isPostExp());
        case EXP.add:           return visitAdd(e.isAddExp());
        case EXP.min:           return visitMin(e.isMinExp());
        case EXP.concatenate:   return visitCat(e.isCatExp());
        case EXP.mul:           return visitMul(e.isMulExp());
        case EXP.div:           return visitDiv(e.isDivExp());
        case EXP.mod:           return visitMod(e.isModExp());
        case EXP.lessThan:
        case EXP.lessOrEqual:
        case EXP.greaterThan:
        case EXP.greaterOrEqual: return visitCmp(cast(CmpExp) e);
        case EXP.notEqual:
        case EXP.equal:         return visitEqual(e.isEqualExp());
        case EXP.notIdentity:
        case EXP.identity:      return visitIdentity(e.isIdentityExp());
        case EXP.in_:           return visitIn(e.isInExp());
        case EXP.assign:        return visitAssign(e.isAssignExp());
        case EXP.construct:     return visitAssign(e.isConstructExp());
        case EXP.blit:          return visitAssign(e.isBlitExp());
        case EXP.loweredAssignExp: return visitLoweredAssign(e.isLoweredAssignExp());
        case EXP.addAssign:     return visitAddAssign(e.isAddAssignExp());
        case EXP.minAssign:     return visitMinAssign(e.isMinAssignExp());
        case EXP.concatenateDcharAssign: return visitCatAssign(e.isCatDcharAssignExp());
        case EXP.concatenateElemAssign:  return visitCatAssign(e.isCatElemAssignExp());
        case EXP.concatenateAssign:      return visitCatAssign(e.isCatAssignExp());
        case EXP.divAssign:     return visitDivAssign(e.isDivAssignExp());
        case EXP.modAssign:     return visitModAssign(e.isModAssignExp());
        case EXP.mulAssign:     return visitMulAssign(e.isMulAssignExp());
        case EXP.leftShiftAssign: return visitShlAssign(e.isShlAssignExp());
        case EXP.rightShiftAssign: return visitShrAssign(e.isShrAssignExp());
        case EXP.unsignedRightShiftAssign: return visitUshrAssign(e.isUshrAssignExp());
        case EXP.andAssign:     return visitAndAssign(e.isAndAssignExp());
        case EXP.orAssign:      return visitOrAssign(e.isOrAssignExp());
        case EXP.xorAssign:     return visitXorAssign(e.isXorAssignExp());
        case EXP.andAnd:
        case EXP.orOr:          return visitLogical(e.isLogicalExp());
        case EXP.xor:           return visitXor(e.isXorExp());
        case EXP.and:           return visitAnd(e.isAndExp());
        case EXP.or:            return visitOr(e.isOrExp());
        case EXP.leftShift:     return visitShl(e.isShlExp());
        case EXP.rightShift:    return visitShr(e.isShrExp());
        case EXP.unsignedRightShift: return visitUshr(e.isUshrExp());
        case EXP.address:       return visitAddr(e.isAddrExp());
        case EXP.variable:      return visitSymbol(e.isVarExp());
        case EXP.symbolOffset:  return visitSymbol(e.isSymOffExp());
        case EXP.int64:         return visitInteger(e.isIntegerExp());
        case EXP.float64:       return visitReal(e.isRealExp());
        case EXP.complex80:     return visitComplex(e.isComplexExp());
        case EXP.this_:         return visitThis(e.isThisExp());
        case EXP.super_:        return visitThis(e.isSuperExp());
        case EXP.null_:         return visitNull(e.isNullExp());
        case EXP.string_:       return visitString(e.isStringExp());
        case EXP.arrayLiteral:  return visitArrayLiteral(e.isArrayLiteralExp());
        case EXP.assocArrayLiteral:     return visitAssocArrayLiteral(e.isAssocArrayLiteralExp());
        case EXP.structLiteral: return visitStructLiteral(e.isStructLiteralExp());
        case EXP.type:          return visitType(e.isTypeExp());
        case EXP.scope_:        return visitScope(e.isScopeExp());
        case EXP.new_:          return visitNew(e.isNewExp());
        case EXP.tuple:         return visitTuple(e.isTupleExp());
        case EXP.function_:     return visitFunc(e.isFuncExp());
        case EXP.declaration:   return visitDeclaration(e.isDeclarationExp());
        case EXP.typeid_:       return visitTypeid(e.isTypeidExp());
        case EXP.halt:          return visitHalt(e.isHaltExp());
        case EXP.comma:         return visitComma(e.isCommaExp());
        case EXP.assert_:       return visitAssert(e.isAssertExp());
        case EXP.throw_:        return visitThrow(e.isThrowExp());
        case EXP.dotVariable:   return visitDotVar(e.isDotVarExp());
        case EXP.delegate_:     return visitDelegate(e.isDelegateExp());
        case EXP.dotType:       return visitDotType(e.isDotTypeExp());
        case EXP.call:          return visitCall(e.isCallExp());
        case EXP.star:          return visitPtr(e.isPtrExp());
        case EXP.delete_:       return visitDelete(e.isDeleteExp());
        case EXP.cast_:         return visitCast(e.isCastExp());
        case EXP.vector:        return visitVector(e.isVectorExp());
        case EXP.vectorArray:   return visitVectorArray(e.isVectorArrayExp());
        case EXP.slice:         return visitSlice(e.isSliceExp());
        case EXP.arrayLength:   return visitArrayLength(e.isArrayLengthExp());
        case EXP.delegatePointer:       return visitDelegatePtr(e.isDelegatePtrExp());
        case EXP.delegateFunctionPointer:       return visitDelegateFuncptr(e.isDelegateFuncptrExp());
        case EXP.index:         return visitIndex(e.isIndexExp());
        case EXP.remove:        return visitRemove(e.isRemoveExp());
        case EXP.question:      return visitCond(e.isCondExp());
        case EXP.objcClassReference:    return visitObjcClassReference(e.isObjcClassReferenceExp());
        case EXP.classReference:        return visitClassReference(e.isClassReferenceExp());
    }
}

private:

/**************************************
 * Mirrors logic in Dsymbol_canThrow().
 */
elem* Dsymbol_toElem(Dsymbol s, ref IRState irs)
{
    elem* e = null;

    void symbolDg(Dsymbol s)
    {
        e = el_combine(e, Dsymbol_toElem(s, irs));
    }

    //printf("Dsymbol_toElem() %s\n", s.toChars());
    if (auto vd = s.isVarDeclaration())
    {
        s = s.toAlias();
        if (s != vd)
            return Dsymbol_toElem(s, irs);
        if (vd.storage_class & STC.manifest)
            return null;
        if (vd.isStatic() || vd.storage_class & (STC.extern_ | STC.tls | STC.gshared))
            toObjFile(vd, false);
        else
        {
            Symbol* sp = toSymbol(s);
            symbol_add(sp);
            //printf("\tadding symbol '%s'\n", sp.Sident);
            if (vd._init)
            {
                if (auto ie = vd._init.isExpInitializer())
                    e = toElem(ie.exp, irs);
            }

            /* Mark the point of construction of a variable that needs to be destructed.
             */
            if (vd.needsScopeDtor())
            {
                elem* edtor = toElem(vd.edtor, irs);
                elem* ed = null;
                if (irs.isNothrow())
                {
                    ed = edtor;
                }
                else
                {
                    // Construct special elems to deal with exceptions
                    e = el_ctor_dtor(e, edtor, ed);
                }

                // ed needs to be inserted into the code later
                irs.varsInScope.push(ed);
            }
        }
    }
    else if (auto cd = s.isClassDeclaration())
    {
        irs.deferToObj.push(s);
    }
    else if (auto sd = s.isStructDeclaration())
    {
        irs.deferToObj.push(sd);
    }
    else if (auto fd = s.isFuncDeclaration())
    {
        //printf("function %s\n", fd.toChars());
        irs.deferToObj.push(fd);
    }
    else if (auto ad = s.isAttribDeclaration())
    {
        ad.include(null).foreachDsymbol(&symbolDg);
    }
    else if (auto tm = s.isTemplateMixin())
    {
        //printf("%s\n", tm.toChars());
        tm.members.foreachDsymbol(&symbolDg);
    }
    else if (auto td = s.isTupleDeclaration())
    {
        td.foreachVar(&symbolDg);
    }
    else if (auto ed = s.isEnumDeclaration())
    {
        irs.deferToObj.push(ed);
    }
    else if (auto ti = s.isTemplateInstance())
    {
        irs.deferToObj.push(ti);
    }
    return e;
}

/*************************************************
 * Allocate a static array, and initialize its members with elems[].
 * Return the initialization expression, and the symbol for the static array in *psym.
 */
elem* ElemsToStaticArray(Loc loc, Type telem, Elems* elems, Symbol **psym)
{
    // Create a static array of type telem[dim]
    const dim = elems.length;
    assert(dim);

    Type tsarray = telem.sarrayOf(dim);
    const szelem = telem.size();
    .type* te = Type_toCtype(telem);   // stmp[] element type

    Symbol* stmp = symbol_genauto(Type_toCtype(tsarray));
    *psym = stmp;

    elem* e = null;
    foreach (i, ep; *elems)
    {
        /* Generate: *(&stmp + i * szelem) = element[i]
         */
        elem* ev = el_ptr(stmp);
        ev = el_bin(OPadd, TYnptr, ev, el_long(TYsize_t, i * szelem));
        ev = el_una(OPind, te.Tty, ev);
        elem* eeq = elAssign(ev, ep, null, te);
        e = el_combine(e, eeq);
    }
    return e;
}

/*************************************************
 * Allocate a static array, and initialize its members with
 * exps[].
 * Return the initialization expression, and the symbol for the static array in *psym.
 */
elem* ExpressionsToStaticArray(ref IRState irs, Loc loc, Expressions* exps, Symbol **psym, size_t offset = 0, Expression basis = null)
{
    // Create a static array of type telem[dim]
    const dim = exps.length;
    assert(dim);

    Type telem = ((*exps)[0] ? (*exps)[0] : basis).type;
    const szelem = telem.size();
    .type* te = Type_toCtype(telem);   // stmp[] element type

    if (!*psym)
    {
        Type tsarray2 = telem.sarrayOf(dim);
        *psym = symbol_genauto(Type_toCtype(tsarray2));
        offset = 0;
    }
    Symbol* stmp = *psym;

    elem* e = null;
    for (size_t i = 0; i < dim; )
    {
        Expression el = (*exps)[i];
        if (!el)
            el = basis;
        if (el.op == EXP.arrayLiteral &&
            el.type.toBasetype().ty == Tsarray)
        {
            ArrayLiteralExp ale = cast(ArrayLiteralExp)el;
            if (ale.elements && ale.elements.length)
            {
                elem* ex = ExpressionsToStaticArray(irs,
                    ale.loc, ale.elements, &stmp, cast(uint)(offset + i * szelem), ale.basis);
                e = el_combine(e, ex);
            }
            i++;
            continue;
        }

        size_t j = i + 1;
        if (el.isConst() || el.op == EXP.null_)
        {
            // If the trivial elements are same values, do memcpy.
            while (j < dim)
            {
                Expression en = (*exps)[j];
                if (!en)
                    en = basis;
                if (!el.isIdentical(en))
                    break;
                j++;
            }
        }

        /* Generate: *(&stmp + i * szelem) = element[i]
         */
        elem* ep = toElem(el, irs);
        elem* ev = tybasic(stmp.Stype.Tty) == TYnptr ? el_var(stmp) : el_ptr(stmp);
        ev = el_bin(OPadd, TYnptr, ev, el_long(TYsize_t, offset + i * szelem));

        elem* eeq;
        if (j == i + 1)
        {
            ev = el_una(OPind, te.Tty, ev);
            eeq = elAssign(ev, ep, null, te);
        }
        else
        {
            elem* edim = el_long(TYsize_t, j - i);
            eeq = setArray(el, ev, edim, telem, ep, irs, EXP.blit);
        }
        e = el_combine(e, eeq);
        i = j;
    }
    return e;
}

/***************************************************
 */
elem* toElemCast(CastExp ce, elem* e, bool isLvalue, ref IRState irs)
{
    tym_t ftym;
    tym_t ttym;
    OPER eop;

    Type tfrom = ce.e1.type.toBasetype();
    Type t = ce.to.toBasetype();         // skip over typedef's

    TY fty;
    TY tty;
    if (t.equals(tfrom) ||
        t.equals(Type.tvoid)) // https://issues.dlang.org/show_bug.cgi?id=18573
                              // Remember to pop value left on FPU stack
        return e;

    fty = tfrom.ty;
    tty = t.ty;
    //printf("fty = %d\n", fty);

    static elem* Lret(CastExp ce, elem* e)
    {
        // Adjust for any type paints
        Type t = ce.type.toBasetype();
        e.Ety = totym(t);
        if (tyaggregate(e.Ety))
            e.ET = Type_toCtype(t);

        elem_setLoc(e, ce.loc);
        return e;
    }

    static elem* Lpaint(CastExp ce, elem* e, tym_t ttym)
    {
        e.Ety = ttym;
        return Lret(ce, e);
    }

    static elem* Lzero(CastExp ce, elem* e, tym_t ttym)
    {
        e = el_bin(OPcomma, ttym, e, el_long(ttym, 0));
        return Lret(ce, e);
    }

    static elem* Leop(CastExp ce, elem* e, OPER eop, tym_t ttym)
    {
        e = el_una(eop, ttym, e);
        return Lret(ce, e);
    }

    if (tty == Tpointer && fty == Tarray)
    {
        if (e.Eoper == OPvar)
        {
            // e1 . *(&e1 + 4)
            e = el_una(OPaddr, TYnptr, e);
            e = el_bin(OPadd, TYnptr, e, el_long(TYsize_t, tysize(TYnptr)));
            e = el_una(OPind,totym(t),e);
        }
        else
        {
            // e1 . (uint)(e1 >> 32)
            if (target.isX86_64)
            {
                e = el_bin(OPshr, TYucent, e, el_long(TYint, 64));
                e = el_una(OP128_64, totym(t), e);
            }
            else
            {
                e = el_bin(OPshr, TYullong, e, el_long(TYint, 32));
                e = el_una(OP64_32, totym(t), e);
            }
        }
        return Lret(ce, e);
    }

    if (tty == Tpointer && fty == Tsarray)
    {
        // e1 . &e1
        e = el_una(OPaddr, TYnptr, e);
        return Lret(ce, e);
    }

    // Convert from static array to dynamic array
    if (tty == Tarray && fty == Tsarray)
    {
        e = sarray_toDarray(ce.loc, tfrom, t, e);
        return Lret(ce, e);
    }

    // Convert from dynamic array to dynamic array
    if (tty == Tarray && fty == Tarray)
    {
        uint fsize = cast(uint)tfrom.nextOf().size();
        uint tsize = cast(uint)t.nextOf().size();

        if (fsize != tsize)
        {   // Array element sizes do not match, so we must adjust the dimensions
            if (tsize != 0 && fsize % tsize == 0)
            {
                // Set array dimension to (length * (fsize / tsize))
                // Generate pair(e.length * (fsize/tsize), es.ptr)

                elem* es = el_same(e);

                elem* eptr = el_una(OPmsw, TYnptr, es);
                elem* elen = el_una(target.isX86_64 ? OP128_64 : OP64_32, TYsize_t, e);
                elem* elen2 = el_bin(OPmul, TYsize_t, elen, el_long(TYsize_t, fsize / tsize));
                e = el_pair(totym(ce.type), elen2, eptr);
            }
            else
            {
                assert(false, "This case should have been rewritten to `__ArrayCast` in the semantic phase");
            }
        }
        return Lret(ce, e);
    }

    // Casting between class/interface may require a runtime check
    if (fty == Tclass && tty == Tclass)
    {
        ClassDeclaration cdfrom = tfrom.isClassHandle();
        ClassDeclaration cdto   = t.isClassHandle();

        int offset;
        if (cdto.isBaseOf(cdfrom, &offset) && offset != ClassDeclaration.OFFSET_RUNTIME)
        {
            /* The offset from cdfrom => cdto is known at compile time.
             * Cases:
             *  - class => base class (upcast)
             *  - class => base interface (upcast)
             */

            //printf("offset = %d\n", offset);
            if (offset == ClassDeclaration.OFFSET_FWDREF)
            {
                assert(0, "unexpected forward reference");
            }
            else if (offset)
            {
                /* Rewrite cast as (e ? e + offset : null)
                 */
                if (ce.e1.op == EXP.this_)
                {
                    // Assume 'this' is never null, so skip null check
                    e = el_bin(OPadd, TYnptr, e, el_long(TYsize_t, offset));
                }
                else
                {
                    elem* etmp = el_same(e);
                    elem* ex = el_bin(OPadd, TYnptr, etmp, el_long(TYsize_t, offset));
                    ex = el_bin(OPcolon, TYnptr, ex, el_long(TYnptr, 0));
                    e = el_bin(OPcond, TYnptr, e, ex);
                }
            }
            else
            {
                // Casting from derived class to base class is a no-op
            }
        }
        else if (cdfrom.classKind == ClassKind.cpp)
        {
            if (cdto.classKind == ClassKind.cpp)
            {
                /* Casting from a C++ interface to a C++ interface
                 * is always a 'paint' operation
                 */
                return Lret(ce, e);                  // no-op
            }

            /* Casting from a C++ interface to a class
             * always results in null because there is no runtime
             * information available to do it.
             *
             * Casting from a C++ interface to a non-C++ interface
             * always results in null because there's no way one
             * can be derived from the other.
             */
            e = el_bin(OPcomma, TYnptr, e, el_long(TYnptr, 0));
            return Lret(ce, e);
        }
        else
        {
            /* The offset from cdfrom => cdto can only be determined at runtime.
             * Cases:
             *  - class     => derived class (downcast)
             *  - interface => derived class (downcast)
             *  - class     => foreign interface (cross cast)
             *  - interface => base or foreign interface (cross cast)
             */
            auto rtl = cdfrom.isInterfaceDeclaration()
                        ? RTLSYM.INTERFACE_CAST
                        : RTLSYM.DYNAMIC_CAST;

            /* Check for:
             *  class A { }
             *  final class B : A { }
             *  ... cast(B) A ...
             */
            if (rtl == RTLSYM.DYNAMIC_CAST &&
                cdto.storage_class & STC.final_ &&
                cdto.baseClass == cdfrom &&
                (!cdto.interfaces || cdto.interfaces.length == 0) &&
                (!cdfrom.interfaces || cdfrom.interfaces.length == 0))
            {
                /* do shortcut cast: if e is an instance of B, then it's just a type paint
                 */
                //printf("cdfrom: %s cdto: %s\n", cdfrom.toChars(), cdto.toChars());
                rtl = RTLSYM.PAINT_CAST;
            }
            else if (rtl == RTLSYM.DYNAMIC_CAST &&
                     !cdto.isInterfaceDeclaration())
            {
                //printf("cdfrom: %s cdto: %s\n", cdfrom.toChars(), cdto.toChars());
                int level = 0;
                auto b = cdto;
                while (1)
                {
                    if (b == cdfrom)
                        break;
                    b = b.baseClass;
                    if (!b)
                    {
                        // did not find cdfrom, so cast fails, return null
                        e = el_long(TYnptr, 0);
                        return Lret(ce, e);
                    }
                    ++level;
                }
                if (level == 0)
                {
                    return Lret(ce, e); // cast to self
                }
                // _d_class_cast(e, cdto);
                rtl = RTLSYM.CLASS_CAST;
            }
            elem* ep = el_param(el_ptr(toExtSymbol(cdto)), e);
            e = el_bin(OPcall, TYnptr, el_var(getRtlsym(rtl)), ep);
        }
        return Lret(ce, e);
    }

    if (fty == Tvector && tty == Tsarray)
    {
        if (tfrom.size() == t.size())
        {
            if (e.Eoper != OPvar && e.Eoper != OPind)
            {
                // can't perform array ops on it unless it's in memory
                e = addressElem(e, tfrom);
                e = el_una(OPind, TYarray, e);
                e.ET = Type_toCtype(t);
            }
            return Lret(ce, e);
        }
    }

    ftym = tybasic(e.Ety);
    ttym = tybasic(totym(t));
    if (ftym == ttym)
        return Lret(ce, e);

    /* Reduce combinatorial explosion by rewriting the 'to' and 'from' types to a
     * generic equivalent (as far as casting goes)
     */
    switch (tty)
    {
        case Tpointer:
            if (fty == Tdelegate)
                return Lpaint(ce, e, ttym);
            tty = target.isX86_64 ? Tuns64 : Tuns32;
            break;

        case Tchar:     tty = Tuns8;    break;
        case Twchar:    tty = Tuns16;   break;
        case Tdchar:    tty = Tuns32;   break;
        case Tvoid:     return Lpaint(ce, e, ttym);

        case Tbool:
        {
            // Construct e?true:false
            e = el_una(OPbool, ttym, e);
            return Lret(ce, e);
        }
        default:
            break;
    }

    switch (fty)
    {
        case Tnull:
        {
            // typeof(null) is same with void* in binary level.
            return Lzero(ce, e, ttym);
        }
        case Tpointer:  fty = target.isX86_64 ? Tuns64 : Tuns32;  break;
        case Tchar:     fty = Tuns8;    break;
        case Twchar:    fty = Tuns16;   break;
        case Tdchar:    fty = Tuns32;   break;

        // noreturn expression will throw/abort and never produce a
        //  value to cast, hence we discard the cast
        case Tnoreturn:
            return Lret(ce, e);

        default:
            break;
    }

    static int X(int fty, int tty) { return fty * TMAX + tty; }

    while (true)
    {
        switch (X(fty,tty))
        {
            /* ============================= */

            case X(Tbool,Tint8):
            case X(Tbool,Tuns8):
                return Lpaint(ce, e, ttym);
            case X(Tbool,Tint16):
            case X(Tbool,Tuns16):
            case X(Tbool,Tint32):
            case X(Tbool,Tuns32):
                if (isLvalue)
                {
                    eop = OPu8_16;
                    return Leop(ce, e, eop, ttym);
                }
                else
                {
                    e = el_bin(OPand, TYuchar, e, el_long(TYuchar, 1));
                    fty = Tuns8;
                    continue;
                }

            case X(Tbool,Tint64):
            case X(Tbool,Tuns64):
            case X(Tbool,Tint128):
            case X(Tbool,Tuns128):
            case X(Tbool,Tfloat32):
            case X(Tbool,Tfloat64):
            case X(Tbool,Tfloat80):
            case X(Tbool,Tcomplex32):
            case X(Tbool,Tcomplex64):
            case X(Tbool,Tcomplex80):
                e = el_bin(OPand, TYuchar, e, el_long(TYuchar, 1));
                fty = Tuns8;
                continue;

            case X(Tbool,Timaginary32):
            case X(Tbool,Timaginary64):
            case X(Tbool,Timaginary80):
                return Lzero(ce, e, ttym);

                /* ============================= */

            case X(Tint8,Tuns8):    return Lpaint(ce, e, ttym);
            case X(Tint8,Tint16):
            case X(Tint8,Tuns16):
            case X(Tint8,Tint32):
            case X(Tint8,Tuns32):   eop = OPs8_16;  return Leop(ce, e, eop, ttym);
            case X(Tint8,Tint64):
            case X(Tint8,Tuns64):
            case X(Tint8,Tint128):
            case X(Tint8,Tuns128):
            case X(Tint8,Tfloat32):
            case X(Tint8,Tfloat64):
            case X(Tint8,Tfloat80):
            case X(Tint8,Tcomplex32):
            case X(Tint8,Tcomplex64):
            case X(Tint8,Tcomplex80):
                e = el_una(OPs8_16, TYint, e);
                fty = Tint32;
                continue;
            case X(Tint8,Timaginary32):
            case X(Tint8,Timaginary64):
            case X(Tint8,Timaginary80): return Lzero(ce, e, ttym);

                /* ============================= */

            case X(Tuns8,Tint8):    return Lpaint(ce, e, ttym);
            case X(Tuns8,Tint16):
            case X(Tuns8,Tuns16):
            case X(Tuns8,Tint32):
            case X(Tuns8,Tuns32):   eop = OPu8_16;  return Leop(ce, e, eop, ttym);
            case X(Tuns8,Tint64):
            case X(Tuns8,Tuns64):
            case X(Tuns8,Tint128):
            case X(Tuns8,Tuns128):
            case X(Tuns8,Tfloat32):
            case X(Tuns8,Tfloat64):
            case X(Tuns8,Tfloat80):
            case X(Tuns8,Tcomplex32):
            case X(Tuns8,Tcomplex64):
            case X(Tuns8,Tcomplex80):
                e = el_una(OPu8_16, TYuint, e);
                fty = Tuns32;
                continue;
            case X(Tuns8,Timaginary32):
            case X(Tuns8,Timaginary64):
            case X(Tuns8,Timaginary80): return Lzero(ce, e, ttym);

                /* ============================= */

            case X(Tint16,Tint8):
            case X(Tint16,Tuns8):   eop = OP16_8;   return Leop(ce, e, eop, ttym);
            case X(Tint16,Tuns16):  return Lpaint(ce, e, ttym);
            case X(Tint16,Tint32):
            case X(Tint16,Tuns32):  eop = OPs16_32; return Leop(ce, e, eop, ttym);
            case X(Tint16,Tint64):
            case X(Tint16,Tuns64):
            case X(Tint16,Tint128):
            case X(Tint16,Tuns128):
                e = el_una(OPs16_32, TYint, e);
                fty = Tint32;
                continue;
            case X(Tint16,Tfloat32):
            case X(Tint16,Tfloat64):
            case X(Tint16,Tfloat80):
            case X(Tint16,Tcomplex32):
            case X(Tint16,Tcomplex64):
            case X(Tint16,Tcomplex80):
                e = el_una(OPs16_d, TYdouble, e);
                fty = Tfloat64;
                continue;
            case X(Tint16,Timaginary32):
            case X(Tint16,Timaginary64):
            case X(Tint16,Timaginary80): return Lzero(ce, e, ttym);

                /* ============================= */

            case X(Tuns16,Tint8):
            case X(Tuns16,Tuns8):   eop = OP16_8;   return Leop(ce, e, eop, ttym);
            case X(Tuns16,Tint16):  return Lpaint(ce, e, ttym);
            case X(Tuns16,Tint32):
            case X(Tuns16,Tuns32):  eop = OPu16_32; return Leop(ce, e, eop, ttym);
            case X(Tuns16,Tint64):
            case X(Tuns16,Tuns64):
            case X(Tuns16,Tint128):
            case X(Tuns16,Tuns128):
            case X(Tuns16,Tfloat64):
            case X(Tuns16,Tfloat32):
            case X(Tuns16,Tfloat80):
            case X(Tuns16,Tcomplex32):
            case X(Tuns16,Tcomplex64):
            case X(Tuns16,Tcomplex80):
                e = el_una(OPu16_32, TYuint, e);
                fty = Tuns32;
                continue;
            case X(Tuns16,Timaginary32):
            case X(Tuns16,Timaginary64):
            case X(Tuns16,Timaginary80): return Lzero(ce, e, ttym);

                /* ============================= */

            case X(Tint32,Tint8):
            case X(Tint32,Tuns8):   e = el_una(OP32_16, TYshort, e);
                fty = Tint16;
                continue;
            case X(Tint32,Tint16):
            case X(Tint32,Tuns16):  eop = OP32_16;  return Leop(ce, e, eop, ttym);
            case X(Tint32,Tuns32):  return Lpaint(ce, e, ttym);
            case X(Tint32,Tint64):
            case X(Tint32,Tuns64):  eop = OPs32_64; return Leop(ce, e, eop, ttym);
            case X(Tint32,Tint128):
            case X(Tint32,Tuns128):
                e = el_una(OPs32_64, TYullong, e);
                fty = Tint64;
                continue;
            case X(Tint32,Tfloat32):
            case X(Tint32,Tfloat64):
            case X(Tint32,Tfloat80):
            case X(Tint32,Tcomplex32):
            case X(Tint32,Tcomplex64):
            case X(Tint32,Tcomplex80):
                e = el_una(OPs32_d, TYdouble, e);
                fty = Tfloat64;
                continue;
            case X(Tint32,Timaginary32):
            case X(Tint32,Timaginary64):
            case X(Tint32,Timaginary80): return Lzero(ce, e, ttym);

                /* ============================= */

            case X(Tuns32,Tint8):
            case X(Tuns32,Tuns8):   e = el_una(OP32_16, TYshort, e);
                fty = Tuns16;
                continue;
            case X(Tuns32,Tint16):
            case X(Tuns32,Tuns16):  eop = OP32_16;  return Leop(ce, e, eop, ttym);
            case X(Tuns32,Tint32):  return Lpaint(ce, e, ttym);
            case X(Tuns32,Tint64):
            case X(Tuns32,Tuns64):  eop = OPu32_64; return Leop(ce, e, eop, ttym);
            case X(Tuns32,Tint128):
            case X(Tuns32,Tuns128):
                e = el_una(OPs32_64, TYullong, e);
                fty = Tuns64;
                continue;
            case X(Tuns32,Tfloat32):
            case X(Tuns32,Tfloat64):
            case X(Tuns32,Tfloat80):
            case X(Tuns32,Tcomplex32):
            case X(Tuns32,Tcomplex64):
            case X(Tuns32,Tcomplex80):
                e = el_una(OPu32_d, TYdouble, e);
                fty = Tfloat64;
                continue;
            case X(Tuns32,Timaginary32):
            case X(Tuns32,Timaginary64):
            case X(Tuns32,Timaginary80): return Lzero(ce, e, ttym);

                /* ============================= */

            case X(Tint64,Tint8):
            case X(Tint64,Tuns8):
            case X(Tint64,Tint16):
            case X(Tint64,Tuns16):  e = el_una(OP64_32, TYint, e);
                fty = Tint32;
                continue;
            case X(Tint64,Tint32):
            case X(Tint64,Tuns32):  eop = OP64_32; return Leop(ce, e, eop, ttym);
            case X(Tint64,Tuns64):  return Lpaint(ce, e, ttym);
            case X(Tint64,Tint128):
            case X(Tint64,Tuns128):  eop = OPs64_128; return Leop(ce, e, eop, ttym);
            case X(Tint64,Tfloat32):
            case X(Tint64,Tfloat64):
            case X(Tint64,Tfloat80):
            case X(Tint64,Tcomplex32):
            case X(Tint64,Tcomplex64):
            case X(Tint64,Tcomplex80):
                e = el_una(OPs64_d, TYdouble, e);
                fty = Tfloat64;
                continue;
            case X(Tint64,Timaginary32):
            case X(Tint64,Timaginary64):
            case X(Tint64,Timaginary80): return Lzero(ce, e, ttym);

                /* ============================= */

            case X(Tuns64,Tint8):
            case X(Tuns64,Tuns8):
            case X(Tuns64,Tint16):
            case X(Tuns64,Tuns16):  e = el_una(OP64_32, TYint, e);
                fty = Tint32;
                continue;
            case X(Tuns64,Tint32):
            case X(Tuns64,Tuns32):  eop = OP64_32;  return Leop(ce, e, eop, ttym);
            case X(Tuns64,Tint64):  return Lpaint(ce, e, ttym);
            case X(Tuns64,Tint128):
            case X(Tuns64,Tuns128):  eop = OPu64_128; return Leop(ce, e, eop, ttym);
            case X(Tuns64,Tfloat32):
            case X(Tuns64,Tfloat64):
            case X(Tuns64,Tfloat80):
            case X(Tuns64,Tcomplex32):
            case X(Tuns64,Tcomplex64):
            case X(Tuns64,Tcomplex80):
                e = el_una(OPu64_d, TYdouble, e);
                fty = Tfloat64;
                continue;
            case X(Tuns64,Timaginary32):
            case X(Tuns64,Timaginary64):
            case X(Tuns64,Timaginary80): return Lzero(ce, e, ttym);

                /* ============================= */

            case X(Tint128,Tint8):
            case X(Tint128,Tuns8):
            case X(Tint128,Tint16):
            case X(Tint128,Tuns16):
            case X(Tint128,Tint32):
            case X(Tint128,Tuns32):
                e = el_una(OP128_64, TYllong, e);
                fty = Tint64;
                continue;
            case X(Tint128,Tint64):
            case X(Tint128,Tuns64):  eop = OP128_64; return Leop(ce, e, eop, ttym);
            case X(Tint128,Tuns128): return Lpaint(ce, e, ttym);
        static if (0)       // cent <=> floating point not supported yet
        {
            case X(Tint128,Tfloat32):
            case X(Tint128,Tfloat64):
            case X(Tint128,Tfloat80):
            case X(Tint128,Tcomplex32):
            case X(Tint128,Tcomplex64):
            case X(Tint128,Tcomplex80):
                e = el_una(OPs64_d, TYdouble, e);
                fty = Tfloat64;
                continue;
        }
            case X(Tint128,Timaginary32):
            case X(Tint128,Timaginary64):
            case X(Tint128,Timaginary80): return Lzero(ce, e, ttym);

                /* ============================= */

            case X(Tuns128,Tint8):
            case X(Tuns128,Tuns8):
            case X(Tuns128,Tint16):
            case X(Tuns128,Tuns16):
            case X(Tuns128,Tint32):
            case X(Tuns128,Tuns32):
                e = el_una(OP128_64, TYllong, e);
                fty = Tint64;
                continue;
            case X(Tuns128,Tint64):
            case X(Tuns128,Tuns64):  eop = OP128_64;  return Leop(ce, e, eop, ttym);
            case X(Tuns128,Tint128):  return Lpaint(ce, e, ttym);
        static if (0)       // cent <=> floating point not supported yet
        {
            case X(Tuns128,Tfloat32):
            case X(Tuns128,Tfloat64):
            case X(Tuns128,Tfloat80):
            case X(Tuns128,Tcomplex32):
            case X(Tuns128,Tcomplex64):
            case X(Tuns128,Tcomplex80):
                e = el_una(OPu64_d, TYdouble, e);
                fty = Tfloat64;
                continue;
        }
            case X(Tuns128,Timaginary32):
            case X(Tuns128,Timaginary64):
            case X(Tuns128,Timaginary80): return Lzero(ce, e, ttym);

                /* ============================= */

            case X(Tfloat32,Tint8):
            case X(Tfloat32,Tuns8):
            case X(Tfloat32,Tint16):
            case X(Tfloat32,Tuns16):
            case X(Tfloat32,Tint32):
            case X(Tfloat32,Tuns32):
            case X(Tfloat32,Tint64):
            case X(Tfloat32,Tuns64):
        static if (0)       // cent <=> floating point not supported yet
        {
            case X(Tfloat32,Tint128):
            case X(Tfloat32,Tuns128):
        }
            case X(Tfloat32,Tfloat80):
                e = el_una(OPf_d, TYdouble, e);
                fty = Tfloat64;
                continue;
            case X(Tfloat32,Tfloat64): eop = OPf_d; return Leop(ce, e, eop, ttym);
            case X(Tfloat32,Timaginary32):
            case X(Tfloat32,Timaginary64):
            case X(Tfloat32,Timaginary80): return Lzero(ce, e, ttym);
            case X(Tfloat32,Tcomplex32):
            case X(Tfloat32,Tcomplex64):
            case X(Tfloat32,Tcomplex80):
                e = el_bin(OPadd,TYcfloat,el_long(TYifloat,0),e);
                fty = Tcomplex32;
                continue;

                /* ============================= */

            case X(Tfloat64,Tint8):
            case X(Tfloat64,Tuns8):    e = el_una(OPd_s16, TYshort, e);
                fty = Tint16;
                continue;
            case X(Tfloat64,Tint16):   eop = OPd_s16; return Leop(ce, e, eop, ttym);
            case X(Tfloat64,Tuns16):   eop = OPd_u16; return Leop(ce, e, eop, ttym);
            case X(Tfloat64,Tint32):   eop = OPd_s32; return Leop(ce, e, eop, ttym);
            case X(Tfloat64,Tuns32):   eop = OPd_u32; return Leop(ce, e, eop, ttym);
            case X(Tfloat64,Tint64):   eop = OPd_s64; return Leop(ce, e, eop, ttym);
            case X(Tfloat64,Tuns64):   eop = OPd_u64; return Leop(ce, e, eop, ttym);
        static if (0)       // cent <=> floating point not supported yet
        {
            case X(Tfloat64,Tint128):
            case X(Tfloat64,Tuns128):
        }
            case X(Tfloat64,Tfloat32): eop = OPd_f;   return Leop(ce, e, eop, ttym);
            case X(Tfloat64,Tfloat80): eop = OPd_ld;  return Leop(ce, e, eop, ttym);
            case X(Tfloat64,Timaginary32):
            case X(Tfloat64,Timaginary64):
            case X(Tfloat64,Timaginary80):  return Lzero(ce, e, ttym);
            case X(Tfloat64,Tcomplex32):
            case X(Tfloat64,Tcomplex64):
            case X(Tfloat64,Tcomplex80):
                e = el_bin(OPadd,TYcdouble,el_long(TYidouble,0),e);
                fty = Tcomplex64;
                continue;

                /* ============================= */

            case X(Tfloat80,Tint8):
            case X(Tfloat80,Tuns8):
            case X(Tfloat80,Tint16):
            case X(Tfloat80,Tuns16):
            case X(Tfloat80,Tint32):
            case X(Tfloat80,Tuns32):
            case X(Tfloat80,Tint64):
        static if (0)       // cent <=> floating point not supported yet
        {
            case X(Tfloat80,Tint128):
            case X(Tfloat80,Tuns128):
        }
            case X(Tfloat80,Tfloat32): e = el_una(OPld_d, TYdouble, e);
                fty = Tfloat64;
                continue;
            case X(Tfloat80,Tuns64):
                eop = OPld_u64; return Leop(ce, e, eop, ttym);
            case X(Tfloat80,Tfloat64): eop = OPld_d; return Leop(ce, e, eop, ttym);
            case X(Tfloat80,Timaginary32):
            case X(Tfloat80,Timaginary64):
            case X(Tfloat80,Timaginary80): return Lzero(ce, e, ttym);
            case X(Tfloat80,Tcomplex32):
            case X(Tfloat80,Tcomplex64):
            case X(Tfloat80,Tcomplex80):
                e = el_bin(OPadd,TYcldouble,e,el_long(TYildouble,0));
                fty = Tcomplex80;
                continue;

                /* ============================= */

            case X(Timaginary32,Tint8):
            case X(Timaginary32,Tuns8):
            case X(Timaginary32,Tint16):
            case X(Timaginary32,Tuns16):
            case X(Timaginary32,Tint32):
            case X(Timaginary32,Tuns32):
            case X(Timaginary32,Tint64):
            case X(Timaginary32,Tuns64):
            case X(Timaginary32,Tfloat32):
            case X(Timaginary32,Tfloat64):
        static if (0)       // cent <=> floating point not supported yet
        {
            case X(Timaginary32,Tint128):
            case X(Timaginary32,Tuns128):
        }
            case X(Timaginary32,Tfloat80):  return Lzero(ce, e, ttym);
            case X(Timaginary32,Timaginary64): eop = OPf_d; return Leop(ce, e, eop, ttym);
            case X(Timaginary32,Timaginary80):
                e = el_una(OPf_d, TYidouble, e);
                fty = Timaginary64;
                continue;
            case X(Timaginary32,Tcomplex32):
            case X(Timaginary32,Tcomplex64):
            case X(Timaginary32,Tcomplex80):
                e = el_bin(OPadd,TYcfloat,el_long(TYfloat,0),e);
                fty = Tcomplex32;
                continue;

                /* ============================= */

            case X(Timaginary64,Tint8):
            case X(Timaginary64,Tuns8):
            case X(Timaginary64,Tint16):
            case X(Timaginary64,Tuns16):
            case X(Timaginary64,Tint32):
            case X(Timaginary64,Tuns32):
            case X(Timaginary64,Tint64):
            case X(Timaginary64,Tuns64):
        static if (0)       // cent <=> floating point not supported yet
        {
            case X(Timaginary64,Tint128):
            case X(Timaginary64,Tuns128):
        }
            case X(Timaginary64,Tfloat32):
            case X(Timaginary64,Tfloat64):
            case X(Timaginary64,Tfloat80):  return Lzero(ce, e, ttym);
            case X(Timaginary64,Timaginary32): eop = OPd_f;   return Leop(ce, e, eop, ttym);
            case X(Timaginary64,Timaginary80): eop = OPd_ld;  return Leop(ce, e, eop, ttym);
            case X(Timaginary64,Tcomplex32):
            case X(Timaginary64,Tcomplex64):
            case X(Timaginary64,Tcomplex80):
                e = el_bin(OPadd,TYcdouble,el_long(TYdouble,0),e);
                fty = Tcomplex64;
                continue;

                /* ============================= */

            case X(Timaginary80,Tint8):
            case X(Timaginary80,Tuns8):
            case X(Timaginary80,Tint16):
            case X(Timaginary80,Tuns16):
            case X(Timaginary80,Tint32):
            case X(Timaginary80,Tuns32):
            case X(Timaginary80,Tint64):
            case X(Timaginary80,Tuns64):
        static if (0)       // cent <=> floating point not supported yet
        {
            case X(Timaginary80,Tint128):
            case X(Timaginary80,Tuns128):
        }
            case X(Timaginary80,Tfloat32):
            case X(Timaginary80,Tfloat64):
            case X(Timaginary80,Tfloat80):  return Lzero(ce, e, ttym);
            case X(Timaginary80,Timaginary32): e = el_una(OPld_d, TYidouble, e);
                fty = Timaginary64;
                continue;
            case X(Timaginary80,Timaginary64): eop = OPld_d; return Leop(ce, e, eop, ttym);
            case X(Timaginary80,Tcomplex32):
            case X(Timaginary80,Tcomplex64):
            case X(Timaginary80,Tcomplex80):
                e = el_bin(OPadd,TYcldouble,el_long(TYldouble,0),e);
                fty = Tcomplex80;
                continue;

                /* ============================= */

            case X(Tcomplex32,Tint8):
            case X(Tcomplex32,Tuns8):
            case X(Tcomplex32,Tint16):
            case X(Tcomplex32,Tuns16):
            case X(Tcomplex32,Tint32):
            case X(Tcomplex32,Tuns32):
            case X(Tcomplex32,Tint64):
            case X(Tcomplex32,Tuns64):
        static if (0)       // cent <=> floating point not supported yet
        {
            case X(Tcomplex32,Tint128):
            case X(Tcomplex32,Tuns128):
        }
            case X(Tcomplex32,Tfloat32):
            case X(Tcomplex32,Tfloat64):
            case X(Tcomplex32,Tfloat80):
                e = el_una(OPc_r, TYfloat, e);
                fty = Tfloat32;
                continue;
            case X(Tcomplex32,Timaginary32):
            case X(Tcomplex32,Timaginary64):
            case X(Tcomplex32,Timaginary80):
                e = el_una(OPc_i, TYifloat, e);
                fty = Timaginary32;
                continue;
            case X(Tcomplex32,Tcomplex64):
            case X(Tcomplex32,Tcomplex80):
                e = el_una(OPf_d, TYcdouble, e);
                fty = Tcomplex64;
                continue;

                /* ============================= */

            case X(Tcomplex64,Tint8):
            case X(Tcomplex64,Tuns8):
            case X(Tcomplex64,Tint16):
            case X(Tcomplex64,Tuns16):
            case X(Tcomplex64,Tint32):
            case X(Tcomplex64,Tuns32):
            case X(Tcomplex64,Tint64):
            case X(Tcomplex64,Tuns64):
        static if (0)       // cent <=> floating point not supported yet
        {
            case X(Tcomplex64,Tint128):
            case X(Tcomplex64,Tuns128):
        }
            case X(Tcomplex64,Tfloat32):
            case X(Tcomplex64,Tfloat64):
            case X(Tcomplex64,Tfloat80):
                e = el_una(OPc_r, TYdouble, e);
                fty = Tfloat64;
                continue;
            case X(Tcomplex64,Timaginary32):
            case X(Tcomplex64,Timaginary64):
            case X(Tcomplex64,Timaginary80):
                e = el_una(OPc_i, TYidouble, e);
                fty = Timaginary64;
                continue;
            case X(Tcomplex64,Tcomplex32):   eop = OPd_f;   return Leop(ce, e, eop, ttym);
            case X(Tcomplex64,Tcomplex80):   eop = OPd_ld;  return Leop(ce, e, eop, ttym);

                /* ============================= */

            case X(Tcomplex80,Tint8):
            case X(Tcomplex80,Tuns8):
            case X(Tcomplex80,Tint16):
            case X(Tcomplex80,Tuns16):
            case X(Tcomplex80,Tint32):
            case X(Tcomplex80,Tuns32):
            case X(Tcomplex80,Tint64):
            case X(Tcomplex80,Tuns64):
        static if (0)       // cent <=> floating point not supported yet
        {
            case X(Tcomplex80,Tint128):
            case X(Tcomplex80,Tuns128):
        }
            case X(Tcomplex80,Tfloat32):
            case X(Tcomplex80,Tfloat64):
            case X(Tcomplex80,Tfloat80):
                e = el_una(OPc_r, TYldouble, e);
                fty = Tfloat80;
                continue;
            case X(Tcomplex80,Timaginary32):
            case X(Tcomplex80,Timaginary64):
            case X(Tcomplex80,Timaginary80):
                e = el_una(OPc_i, TYildouble, e);
                fty = Timaginary80;
                continue;
            case X(Tcomplex80,Tcomplex32):
            case X(Tcomplex80,Tcomplex64):
                e = el_una(OPld_d, TYcdouble, e);
                fty = Tcomplex64;
                continue;

                /* ============================= */

            default:
                if (fty == tty)
                    return Lpaint(ce, e, ttym);
                //dump(0);
                //printf("fty = %d, tty = %d, %d\n", fty, tty, t.ty);
                // This error should really be pushed to the front end
                irs.eSink.error(ce.loc, "e2ir: cannot cast `%s` of type `%s` to type `%s`", ce.e1.toChars(), ce.e1.type.toChars(), t.toChars());
                e = el_long(TYint, 0);
                return e;

        }
    }
}

/******************************************
 * If argument to a function should use OPstrpar,
 * fix it so it does and return it.
 */
elem* useOPstrpar(elem* e)
{
    tym_t ty = tybasic(e.Ety);
    if (ty == TYstruct || ty == TYarray)
    {
        e = el_una(OPstrpar, TYstruct, e);
        e.ET = e.E1.ET;
        assert(e.ET);
    }
    return e;
}

/************************************
 * Call a function.
 */

elem* callfunc(Loc loc,
        ref IRState irs,
        int directcall,         // 1: don't do virtual call
        Type tret,              // return type
        elem* ec,               // evaluates to function address
        Type ectype,            // original type of ec
        FuncDeclaration fd,     // if !=NULL, this is the function being called
        Type t,                 // TypeDelegate or TypeFunction for this function
        elem* ehidden,          // if !=null, this is the 'hidden' argument
        Expressions* arguments,
        elem* esel = null,      // selector for Objective-C methods (when not provided by fd)
        elem* ethis2 = null)    // multi-context array
{
    elem* ethis = null;
    elem* eside = null;
    elem* eresult = ehidden;

    version (none)
    {
        printf("callfunc(directcall = %d, tret = '%s', ec = %p, fd = %p)\n",
            directcall, tret.toChars(), ec, fd);
        printf("ec: "); elem_print(ec);
        if (fd)
            printf("fd = '%s', vtblIndex = %d, isVirtual() = %d\n", fd.toChars(), fd.vtblIndex, fd.isVirtual());
        if (ehidden)
        {   printf("ehidden: "); elem_print(ehidden); }
    }

    t = t.toBasetype();
    TypeFunction tf = t.isTypeFunction();
    if (!tf)
    {
        assert(t.ty == Tdelegate);
        // A delegate consists of:
        //      { Object *this; Function *funcptr; }
        assert(!fd);
        tf = t.nextOf().isTypeFunction();
        assert(tf);
        ethis = ec;
        ec = el_same(ethis);
        ethis = el_una(target.isX86_64 ? OP128_64 : OP64_32, TYnptr, ethis); // get this
        ec = array_toPtr(t, ec);                // get funcptr
        tym_t tym;
        /* Delegates use the same calling convention as member functions.
         * For extern(C++) on Win32 this differs from other functions.
         */
        if (tf.linkage == LINK.cpp && target.isX86 && target.os == Target.OS.Windows)
            tym = (tf.parameterList.varargs == VarArg.variadic) ? TYnfunc : TYmfunc;
        else
            tym = totym(tf);
        ec = el_una(OPind, tym, ec);
    }

    const ty = fd ? toSymbol(fd).Stype.Tty : ec.Ety;
    const left_to_right = tyrevfunc(ty);   // left-to-right parameter evaluation
                                           // (TYnpfunc, TYjfunc, TYfpfunc, TYf16func)
    elem* ep = null;
    const op = fd ? intrinsic_op(fd) : NotIntrinsic;

    // Check for noreturn expression pretending to yield function/delegate pointers
    if (tybasic(ec.Ety) == TYnoreturn)
    {
        // Discard unreachable argument evaluation + function call
        return ec;
    }
    if (arguments && arguments.length)
    {
        if (op == OPvector)
        {
            Expression arg = (*arguments)[0];
            if (arg.op != EXP.int64)
                irs.eSink.error(arg.loc, "simd operator must be an integer constant, not `%s`", arg.toChars());
        }

        /* Convert arguments[] to elems[] in left-to-right order
         */
        const n = arguments.length;
        debug
            elem*[2] elems_array = void;
        else
            elem*[10] elems_array = void;

        import dmd.common.smallbuffer : SmallBuffer;
        auto pe = SmallBuffer!(elem*)(n, elems_array[]);
        elem*[] elems = pe[];

        /* Fill elems[] with arguments converted to elems
         */

        // j=1 if _arguments[] is first argument
        const int j = tf.isDstyleVariadic();

        foreach (const i, arg; *arguments)
        {
            elem* ea = toElem(arg, irs);

            //printf("\targ[%d]: %s\n", cast(int)i, arg.toChars());

            if (i - j < tf.parameterList.length &&
                i >= j &&
                tf.parameterList[i - j].isReference())
            {
                /* `ref` and `out` parameters mean convert
                 * corresponding argument to a pointer
                 */
                elems[i] = addressElem(ea, arg.type.pointerTo());
                continue;
            }

            if (ISX64REF(irs, arg) && op == NotIntrinsic)
            {
                /* if the argument is a function call which returns a pointer
                 * to where the return value goes, that pointer is the pointer
                 * to the return value
                 */
                elem** pea;
                for (pea = &ea; (*pea).Eoper == OPcomma; pea = &(*pea).E2) // skip past OPcomma's
                {
                }
                if ((*pea).Eoper == OPind &&
                    (*pea).Ety == TYstruct &&
                    ((*pea).E1.Eoper == OPcall || (*pea).E1.Eoper == OPucall))
                {
                    *pea = (*pea).E1; // remove the OPind
                    elems[i] = ea;

                    tym_t eaty = (*pea).Ety;
                    for (elem* ex = ea; ex.Eoper == OPcomma; ex = ex.E2)
                        ex.Ety = eaty;

                    continue;
                }

                /* Copy to a temporary, and make the argument a pointer
                 * to that temporary.
                 */
                VarDeclaration v;
                if (VarExp ve = arg.lastComma().isVarExp())
                    v = ve.var.isVarDeclaration();
                bool copy = !(v && (v.isArgDtorVar || v.storage_class & STC.rvalue)); // copy unless the destructor is going to be run on it
                                                    // then assume the frontend took care of the copying and pass it by ref
                if (arg.rvalue)                     // marked with __rvalue
                    copy = false;

                elems[i] = addressElem(ea, arg.type, copy);
                continue;
            }

            if (irs.target.os == Target.OS.Windows && irs.target.isX86_64 && tybasic(ea.Ety) == TYcfloat)
            {
                /* Treat a cfloat like it was a struct { float re,im; }
                 */
                ea.Ety = TYllong;
            }

            /* Do integral promotions. This is not necessary per the C ABI, but
             * some code from the C world seems to rely on it.
             */
            if (op == NotIntrinsic && tyintegral(ea.Ety) && arg.type.size(arg.loc) < 4)
            {
                if (ea.Eoper == OPconst)
                {
                    ea.Vullong = el_tolong(ea);
                    ea.Ety = TYint;
                }
                else
                {
                    OPER opc;
                    switch (tybasic(ea.Ety))
                    {
                        case TYbool:
                        case TYchar:
                        case TYuchar:
                        case TYchar8:
                            opc = OPu8_16;
                            goto L1;

                        case TYschar:
                            opc = OPs8_16;
                            goto L1;

                        case TYchar16:
                        case TYwchar_t:
                        case TYushort:
                            opc = OPu16_32;
                            goto L1;

                        case TYshort:
                            opc = OPs16_32;
                        L1:
                            ea = el_una(opc, TYint, ea);
                            ea.Esrcpos = ea.E1.Esrcpos;
                            break;

                        default:
                            break;
                    }
                }
            }

            elems[i] = ea;

            // Passing an expression of noreturn, meaning that the argument
            // evaluation will throw / abort / loop indefinetly. Hence skip the
            // call and only evaluate up to the current argument
            if (tybasic(ea.Ety) == TYnoreturn)
            {
                return el_combines(cast(void**) elems.ptr, cast(int) i + 1);
            }

        }
        if (!left_to_right &&
            !irs.Cfile)     // C11 leaves evaluation order implementation-defined, but
                            // try to match evaluation order of other C compilers
        {
            eside = fixArgumentEvaluationOrder(elems);
        }

        foreach (ref e; elems)
        {
            e = useOPstrpar(e);
        }

        if (!left_to_right)   // swap order if right-to-left
            reverse(elems);

        ep = el_params(cast(void**)elems.ptr, cast(int)n);
    }

    objc.setupMethodSelector(fd, &esel);
    objc.setupEp(esel, &ep, left_to_right);

    const retmethod = retStyle(tf, fd && fd.needThis());
    if (retmethod == RET.stack)
    {
        if (!ehidden)
        {
            // Don't have one, so create one
            type* tc;

            Type tret2 = tf.next;
            if (tret2.toBasetype().ty == Tstruct ||
                tret2.toBasetype().ty == Tsarray)
                tc = Type_toCtype(tret2);
            else
                tc = type_fake(totym(tret2));
            Symbol* stmp = symbol_genauto(tc);
            ehidden = el_ptr(stmp);
            eresult = ehidden;
        }
        if (irs.target.isPOSIX && tf.linkage != LINK.d)
        {
                // ehidden goes last on Linux/OSX C++
        }
        else
        {
            if (ep)
            {
                /* // BUG: implement
                if (left_to_right && type_mangle(tfunc) == Mangle.cpp)
                    ep = el_param(ehidden,ep);
                else
                */
                    ep = el_param(ep,ehidden);
            }
            else
                ep = ehidden;
            ehidden = null;
        }
    }

    if (fd && fd.isMemberLocal())
    {
        assert(op == NotIntrinsic);       // members should not be intrinsics

        AggregateDeclaration ad = fd.isThis();
        if (ad)
        {
            ethis = ec;
            if (ad.isStructDeclaration() && tybasic(ec.Ety) != TYnptr)
            {
                ethis = addressElem(ec, ectype);
            }
            if (ethis2)
            {
                ethis2 = setEthis2(loc, irs, fd, ethis2, ethis, eside);
            }
            if (el_sideeffect(ethis))
            {
                elem* ex = ethis;
                ethis = el_copytotmp(ex);
                eside = el_combine(ex, eside);
            }
        }
        else
        {
            // Evaluate ec for side effects
            eside = el_combine(ec, eside);
        }
        Symbol* sfunc = toSymbol(fd);

        if (esel)
        {
            auto result = objc.setupMethodCall(fd, tf, directcall != 0, ec, ehidden, ethis);
            ec = result.ec;
            ethis = result.ethis;
        }
        else if (!fd.isVirtual() ||
            directcall ||               // BUG: fix
            fd.isFinalFunc()
           /* Future optimization: || (whole program analysis && not overridden)
            */
           )
        {
            // make static call
            ec = el_var(sfunc);
        }
        else
        {
            // make virtual call
            assert(ethis);
            elem* ev = el_same(ethis);
            ev = el_una(OPind, TYnptr, ev);
            uint vindex = fd.vtblIndex;
            assert(cast(int)vindex >= 0);

            // Build *(ev + vindex * 4)
            if (target.isX86)
                assert(tysize(TYnptr) == 4);
            ec = el_bin(OPadd,TYnptr,ev,el_long(TYsize_t, vindex * tysize(TYnptr)));
            ec = el_una(OPind,TYnptr,ec);
            ec = el_una(OPind,tybasic(sfunc.Stype.Tty),ec);
        }
    }
    else if (fd && fd.isNested())
    {
        assert(!ethis);
        ethis = getEthis(loc, irs, fd, fd.toParentLocal());
        if (ethis2)
            ethis2 = setEthis2(loc, irs, fd, ethis2, ethis, eside);
    }

    ep = el_param(ep, ethis2 ? ethis2 : ethis);
    if (ehidden)
        ep = el_param(ep, ehidden);     // if ehidden goes last

    const tyret = totym(tret);

    // Look for intrinsic functions and construct result into e
    elem* e;
    if (ec.Eoper == OPvar && op != NotIntrinsic)
    {
        el_free(ec);
        if (op != OPtoPrec && OTbinary(op))
        {
            ep.Eoper = cast(ubyte)op;
            ep.Ety = tyret;
            e = ep;
            if (op == OPeq)
            {   /* This was a volatileStore(ptr, value) operation, rewrite as:
                 *   *ptr = value
                 */
                e.E1 = el_una(OPind, e.E2.Ety | mTYvolatile, e.E1);
            }
            if (op == OPscale)
            {
                elem* et = e.E1;
                e.E1 = el_una(OPs32_d, TYdouble, e.E2);
                e.E1 = el_una(OPd_ld, TYldouble, e.E1);
                e.E2 = et;
            }
            else if (op == OPyl2x || op == OPyl2xp1)
            {
                elem* et = e.E1;
                e.E1 = e.E2;
                e.E2 = et;
            }
        }
        else if (op == OPvector)
        {
            e = ep;
            /* Recognize store operations as:
             *  (op OPparam (op1 OPparam op2))
             * Rewrite as:
             *  (op1 OPvecsto (op OPparam op2))
             * A separate operation is used for stores because it
             * has a side effect, and so takes a different path through
             * the optimizer.
             */
            if (e.Eoper == OPparam &&
                e.E1.Eoper == OPconst &&
                isXMMstore(cast(uint)el_tolong(e.E1)))
            {
                //printf("OPvecsto\n");
                elem* tmp = e.E1;
                e.E1 = e.E2.E1;
                e.E2.E1 = tmp;
                e.Eoper = OPvecsto;
                e.Ety = tyret;
            }
            else
                e = el_una(op,tyret,ep);
        }
        else if (op == OPind)
            e = el_una(op,mTYvolatile | tyret,ep);
        else if (op == OPva_start)
            e = constructVa_start(ep);
        else if (op == OPtoPrec)
        {
            static int X(int fty, int tty) { return fty * TMAX + tty; }

            final switch (X(tybasic(ep.Ety), tybasic(tyret)))
            {
            case X(TYfloat, TYfloat):     // float -> float
            case X(TYdouble, TYdouble):   // double -> double
            case X(TYldouble, TYldouble): // real -> real
                e = ep;
                break;

            case X(TYfloat, TYdouble):    // float -> double
                e = el_una(OPf_d, tyret, ep);
                break;

            case X(TYfloat, TYldouble):   // float -> real
                e = el_una(OPf_d, TYdouble, ep);
                e = el_una(OPd_ld, tyret, e);
                break;

            case X(TYdouble, TYfloat):    // double -> float
                e = el_una(OPd_f, tyret, ep);
                break;

            case X(TYdouble, TYldouble):  // double -> real
                e = el_una(OPd_ld, tyret, ep);
                break;

            case X(TYldouble, TYfloat):   // real -> float
                e = el_una(OPld_d, TYdouble, ep);
                e = el_una(OPd_f, tyret, e);
                break;

            case X(TYldouble, TYdouble):  // real -> double
                e = el_una(OPld_d, tyret, ep);
                break;
            }
        }
        else
            e = el_una(op,tyret,ep);
    }
    else
    {
        // `OPcallns` used to be passed here for certain pure functions,
        // but optimizations based on pure have to be retought, see:
        // https://issues.dlang.org/show_bug.cgi?id=22277
        if (ep)
            e = el_bin(OPcall, tyret, ec, ep);
        else
            e = el_una(OPucall, tyret, ec);

        if (tf.parameterList.varargs != VarArg.none)
            e.Eflags |= EFLAGS_variadic;
    }

    const isCPPCtor = fd && fd._linkage == LINK.cpp && fd.isCtorDeclaration();
    if (isCPPCtor && irs.target.isPOSIX)
    {
        // CPP constructor returns void on Posix
        // https://itanium-cxx-abi.github.io/cxx-abi/abi.html#return-value-ctor
        e.Ety = TYvoid;
        e = el_combine(e, el_same(ethis));
    }
    else if (retmethod == RET.stack)
    {
        if (irs.target.os == Target.OS.OSX && eresult)
        {
            /* ABI quirk: hidden pointer is not returned in registers
             */
            if (tyaggregate(tyret))
                e.ET = Type_toCtype(tret);
            e = el_combine(e, el_copytree(eresult));
        }
        e.Ety = TYnptr;
        e = el_una(OPind, tyret, e);
    }

    if (tf.isRef)
    {
        e.Ety = TYnptr;
        e = el_una(OPind, tyret, e);
    }

    if (tybasic(tyret) == TYstruct)
    {
        e.ET = Type_toCtype(tret);
    }
    e = el_combine(eside, e);
    return e;
}

/**********************************
 * D presumes left-to-right argument evaluation, but we're evaluating things
 * right-to-left here.
 * 1. determine if this matters
 * 2. fix it if it does
 * Params:
 *      arguments = function arguments, these will get rewritten in place
 * Returns:
 *      elem that evaluates the side effects
 */
extern (D) elem* fixArgumentEvaluationOrder(elem*[] elems)
{
    /* It matters if all are true:
     * 1. at least one argument has side effects
     * 2. at least one other argument may depend on side effects
     */
    if (elems.length <= 1)
        return null;

    size_t ifirstside = 0;      // index-1 of first side effect
    size_t ifirstdep = 0;       // index-1 of first dependency on side effect
    foreach (i, e; elems)
    {
        switch (e.Eoper)
        {
            case OPconst:
            case OPrelconst:
            case OPstring:
                continue;

            default:
                break;
        }

        if (el_sideeffect(e))
        {
            if (!ifirstside)
                ifirstside = i + 1;
            else if (!ifirstdep)
                ifirstdep = i + 1;
        }
        else
        {
            if (!ifirstdep)
                ifirstdep = i + 1;
        }
        if (ifirstside && ifirstdep)
            break;
    }

    if (!ifirstdep || !ifirstside)
        return null;

    /* Now fix by appending side effects and dependencies to eside and replacing
     * argument with a temporary.
     * Rely on the optimizer removing some unneeded ones using flow analysis.
     */
    elem* eside = null;
    foreach (i, e; elems)
    {
        while (e.Eoper == OPcomma)
        {
            eside = el_combine(eside, e.E1);
            e = e.E2;
            elems[i] = e;
        }

        switch (e.Eoper)
        {
            case OPconst:
            case OPrelconst:
            case OPstring:
                continue;

            default:
                break;
        }

        elem* es = e;
        elems[i] = el_copytotmp(es);
        eside = el_combine(eside, es);
    }

    return eside;
}

/***************************************
 * Return `true` if elem is a an lvalue.
 * Lvalue elems are OPvar and OPind.
 */

bool elemIsLvalue(elem* e)
{
    while (e.Eoper == OPcomma || e.Eoper == OPinfo)
        e = e.E2;

    // For conditional operator, both branches need to be lvalues.
    if (e.Eoper == OPcond)
    {
        elem* ec = e.E2;
        return elemIsLvalue(ec.E1) && elemIsLvalue(ec.E2);
    }

    if (e.Eoper == OPvar)
        return true;

    /* Match *(&__tmpfordtor+0) which is being destroyed
     */
    elem* ev;
    if (e.Eoper == OPind &&
        e.E1.Eoper == OPadd &&
        e.E1.E2.Eoper == OPconst &&
        e.E1.E1.Eoper == OPaddr &&
        (ev = e.E1.E1.E1).Eoper == OPvar)
    {
        if (strncmp(ev.Vsym.Sident.ptr, Id.__tmpfordtor.toChars(), 12) == 0)
        {
            return false; // don't make reference to object being destroyed
        }
    }

    return e.Eoper == OPind && !OTcall(e.E1.Eoper);
}

/*****************************************
 * Convert array to a pointer to the data.
 * Params:
 *      t = array type
 *      e = array to convert, it is "consumed" by the function
 * Returns:
 *      e rebuilt into a pointer to the data
 */

elem* array_toPtr(Type t, elem* e)
{
    //printf("array_toPtr()\n");
    //elem_print(e);
    t = t.toBasetype();
    switch (t.ty)
    {
        case Tpointer:
            break;

        case Tarray:
        case Tdelegate:
            if (e.Eoper == OPcomma)
            {
                e.Ety = TYnptr;
                e.E2 = array_toPtr(t, e.E2);
            }
            else if (e.Eoper == OPpair)
            {
                if (el_sideeffect(e.E1))
                {
                    e.Eoper = OPcomma;
                    e.Ety = TYnptr;
                }
                else
                {
                    auto r = e;
                    e = e.E2;
                    e.Ety = TYnptr;
                    r.E2 = null;
                    el_free(r);
                }
            }
            else
            {
version (all)
                e = el_una(OPmsw, TYnptr, e);
else
{
                e = el_una(OPaddr, TYnptr, e);
                e = el_bin(OPadd, TYnptr, e, el_long(TYsize_t, 4));
                e = el_una(OPind, TYnptr, e);
}
            }
            break;

        case Tsarray:
            //e = el_una(OPaddr, TYnptr, e);
            e = addressElem(e, t);
            break;

        default:
            printf("%s\n", t.toChars());
            assert(0);
    }
    return e;
}

/*****************************************
 * Convert array to a dynamic array.
 */

elem* array_toDarray(Type t, elem* e)
{
    uint dim;
    elem* ef = null;
    elem* ex;

    //printf("array_toDarray(t = %s)\n", t.toChars());
    //elem_print(e);
    t = t.toBasetype();
    if(t.ty == Tarray)
        return el_combine(ef, e);
    if (t.ty == Tsarray)
    {
        e = addressElem(e, t);
        dim = cast(uint)(cast(TypeSArray)t).dim.toInteger();
        e = el_pair(TYdarray, el_long(TYsize_t, dim), e);
        return el_combine(ef, e);
    }

    L1:
    switch (e.Eoper)
    {
    case OPconst:
    {
        const size_t len = tysize(e.Ety);
        elem* es = el_calloc();
        es.Eoper = OPstring;

        // freed in el_free
        es.Vstring = cast(char*)mem_malloc2(cast(uint) len);
        memcpy(es.Vstring, &e.EV, len);

        es.Vstrlen = len;
        es.Ety = TYnptr;
        e = es;
        break;
    }

    case OPvar:
        e = el_una(OPaddr, TYnptr, e);
        break;

    case OPcomma:
        ef = el_combine(ef, e.E1);
        ex = e;
        e = e.E2;
        ex.E1 = null;
        ex.E2 = null;
        el_free(ex);
        goto L1;

    case OPind:
        ex = e;
        e = e.E1;
        ex.E1 = null;
        ex.E2 = null;
        el_free(ex);
        break;

    default:
        // Copy expression to a variable and take the
        // address of that variable.
        e = addressElem(e, t);
        break;
    }
    dim = 1;
    e = el_pair(TYdarray, el_long(TYsize_t, dim), e);
    return el_combine(ef, e);
}

/************************************
 */

elem* sarray_toDarray(Loc loc, Type tfrom, Type tto, elem* e)
{
    //printf("sarray_toDarray()\n");
    //elem_print(e);

    auto dim = tfrom.isTypeSArray().dim.toInteger();

    if (tto)
    {
        uint fsize = cast(uint)tfrom.nextOf().size();
        uint tsize = cast(uint)tto.nextOf().size();

        // Should have been caught by Expression::castTo
        assert(tsize != 0 && (dim * fsize) % tsize == 0);
        dim = (dim * fsize) / tsize;
    }
    elem* elen = el_long(TYsize_t, dim);
    e = addressElem(e, tfrom);
    e = el_pair(TYdarray, elen, e);
    return e;
}

/****************************************
 * Get the TypeInfo for type `t`
 * Params:
 *      e = for error reporting
 *      t = type for which we need TypeInfo
 *      irs = context
 * Returns:
 *      TypeInfo
 */
private
elem* getTypeInfo(Expression e, Type t, ref IRState irs)
{
    assert(t.ty != Terror);
    TypeInfo_toObjFile(e, e.loc, t);
    elem* result = el_ptr(toExtSymbol(t.vtinfo));
    return result;
}

/********************************************
 * Determine if t is a struct that has postblit.
 */
StructDeclaration needsPostblit(Type t)
{
    if (auto ts = t.baseElemOf().isTypeStruct())
    {
        StructDeclaration sd = ts.sym;
        if (sd.postblit)
            return sd;
    }
    return null;
}

/********************************************
 * Determine if t is a struct that has destructor.
 */
StructDeclaration needsDtor(Type t)
{
    if (auto ts = t.baseElemOf().isTypeStruct())
    {
        StructDeclaration sd = ts.sym;
        if (sd.dtor)
            return sd;
    }
    return null;
}

/*******************************************
 * Set an array pointed to by eptr to evalue:
 *      eptr[0..edim] = evalue;
 * Params:
 *      exp    = the expression for which this operation is performed
 *      eptr   = where to write the data to
 *      edim   = number of times to write evalue to eptr[]
 *      tb     = type of evalue
 *      evalue = value to write
 *      irs    = context
 *      op     = EXP.blit, EXP.assign, or EXP.construct
 * Returns:
 *      created IR code
 */
elem* setArray(Expression exp, elem* eptr, elem* edim, Type tb, elem* evalue, ref IRState irs, int op)
{
    //elem_print(evalue);
    assert(op == EXP.blit || op == EXP.assign || op == EXP.construct);
    const sz = cast(uint)tb.size();
    Type tb2 = tb;

Lagain:
    RTLSYM r;
    switch (tb2.ty)
    {
        case Tfloat80:
        case Timaginary80:
            r = RTLSYM.MEMSET80;
            break;
        case Tcomplex80:
            r = RTLSYM.MEMSET160;
            break;
        case Tcomplex64:
            r = RTLSYM.MEMSET128;
            break;
        case Tfloat32:
        case Timaginary32:
            if (target.isX86)
                goto default;          // legacy binary compatibility
            r = RTLSYM.MEMSETFLOAT;
            break;
        case Tfloat64:
        case Timaginary64:
            if (target.isX86)
                goto default;          // legacy binary compatibility
            r = RTLSYM.MEMSETDOUBLE;
            break;

        case Tstruct:
        {
            if (target.isX86)
                goto default;

            TypeStruct tc = cast(TypeStruct)tb2;
            StructDeclaration sd = tc.sym;
            if (sd.numArgTypes() == 1)
            {
                tb2 = sd.argType(0);
                goto Lagain;
            }
            goto default;
        }

        case Tvector:
            r = RTLSYM.MEMSETSIMD;
            break;

        default:
            switch (sz)
            {
                case 1:      r = RTLSYM.MEMSET8;    break;
                case 2:      r = RTLSYM.MEMSET16;   break;
                case 4:      r = RTLSYM.MEMSET32;   break;
                case 8:      r = RTLSYM.MEMSET64;   break;
                case 16:     r = target.isX86_64 ? RTLSYM.MEMSET128ii : RTLSYM.MEMSET128; break;
                default:     r = RTLSYM.MEMSETN;    break;
            }

            /* Determine if we need to do postblit
             */
            if (op != EXP.blit)
            {
                if (needsPostblit(tb) || needsDtor(tb))
                {
                    if (op == EXP.construct)
                        assert(0, "Trying to reference _d_arraysetctor, this should not happen!");
                    else
                        assert(0, "Trying to reference _d_arraysetassign, this should not happen!");
                }
            }

            if (target.isX86_64 && tybasic(evalue.Ety) == TYstruct && r != RTLSYM.MEMSETN)
            {
                /* If this struct is in-memory only, i.e. cannot necessarily be passed as
                 * a gp register parameter.
                 * The trouble is that memset() is expecting the argument to be in a gp
                 * register, but the argument pusher may have other ideas on I64.
                 * MEMSETN is inefficient, though.
                 */
                if (tybasic(evalue.ET.Tty) == TYstruct)
                {
                    type* t1 = evalue.ET.Ttag.Sstruct.Sarg1type;
                    type* t2 = evalue.ET.Ttag.Sstruct.Sarg2type;
                    if (!t1 && !t2)
                    {
                        if (irs.target.os & Target.OS.Posix || sz > 8)
                            r = RTLSYM.MEMSETN;
                    }
                    else if (irs.target.os & Target.OS.Posix &&
                             r == RTLSYM.MEMSET128ii &&
                             tyfloating(t1.Tty) &&
                             tyfloating(t2.Tty))
                        r = RTLSYM.MEMSET128;
                }
            }

            if (r == RTLSYM.MEMSETN)
            {
                // void* _memsetn(void* p, void* value, int dim, int sizelem)
                evalue = addressElem(evalue, tb);
                elem* esz = el_long(TYsize_t, sz);
                elem* e = el_params(esz, edim, evalue, eptr, null);
                e = el_bin(OPcall,TYnptr,el_var(getRtlsym(r)),e);
                return e;
            }
            break;
    }
    if (sz > 1 && sz <= 8 &&
        evalue.Eoper == OPconst && el_allbits(evalue, 0))
    {
        r = RTLSYM.MEMSET8;
        edim = el_bin(OPmul, TYsize_t, edim, el_long(TYsize_t, sz));
    }

    if (irs.target.os == Target.OS.Windows && irs.target.isX86_64 && sz > registerSize)
    {
        evalue = addressElem(evalue, tb);
    }
    // cast to the proper parameter type
    else if (r != RTLSYM.MEMSETN)
    {
        tym_t tym;
        switch (r)
        {
            case RTLSYM.MEMSET8:      tym = TYchar;     break;
            case RTLSYM.MEMSET16:     tym = TYshort;    break;
            case RTLSYM.MEMSET32:     tym = TYlong;     break;
            case RTLSYM.MEMSET64:     tym = TYllong;    break;
            case RTLSYM.MEMSET80:     tym = TYldouble;  break;
            case RTLSYM.MEMSET160:    tym = TYcldouble; break;
            case RTLSYM.MEMSET128:    tym = TYcdouble;  break;
            case RTLSYM.MEMSET128ii:  tym = TYucent;    break;
            case RTLSYM.MEMSETFLOAT:  tym = TYfloat;    break;
            case RTLSYM.MEMSETDOUBLE: tym = TYdouble;   break;
            case RTLSYM.MEMSETSIMD:   tym = TYfloat4;   break;
            default:
                assert(0);
        }
        // do a cast to tym
        tym = tym | (evalue.Ety & ~mTYbasic);
        if (evalue.Eoper == OPconst)
        {
            evalue = el_copytree(evalue);
            evalue.Ety = tym;
        }
        else
        {
            evalue = addressElem(evalue, tb);
            evalue = el_una(OPind, tym, evalue);
        }
    }

    evalue = useOPstrpar(evalue);

    // Be careful about parameter side effect ordering
    if (r == RTLSYM.MEMSET8 ||
        r == RTLSYM.MEMSET16 ||
        r == RTLSYM.MEMSET32 ||
        r == RTLSYM.MEMSET64)
    {
        elem* e = el_param(edim, evalue);
        return el_bin(OPmemset,TYnptr,eptr,e);
    }
    else
    {
        elem* e = el_params(edim, evalue, eptr, null);
        return el_bin(OPcall,TYnptr,el_var(getRtlsym(r)),e);
    }
}

/*******************************************
 * Generate elem to zero fill contents of Symbol stmp
 * from poffset..offset2.
 * May store anywhere from 0..maxoff, as this function
 * tries to use aligned int stores whereever possible.
 * Update *poffset to end of initialized hole; *poffset will be >= offset2.
 */
private
elem* fillHole(Symbol* stmp, size_t poffset, size_t offset2, size_t maxoff)
{
    elem* e = null;
    bool basealign = true;

    while (poffset < offset2)
    {
        elem* e1;
        if (tybasic(stmp.Stype.Tty) == TYnptr)
            e1 = el_var(stmp);
        else
            e1 = el_ptr(stmp);
        if (basealign)
            poffset &= ~3;
        basealign = true;
        size_t sz = maxoff - poffset;
        tym_t ty;
        switch (sz)
        {
            case 1: ty = TYchar;        break;
            case 2: ty = TYshort;       break;
            case 3:
                ty = TYshort;
                basealign = false;
                break;
            default:
                ty = TYlong;
                // TODO: OPmemset is better if sz is much bigger than 4?
                break;
        }
        e1 = el_bin(OPadd, TYnptr, e1, el_long(TYsize_t, poffset));
        e1 = el_una(OPind, ty, e1);
        e1 = el_bin(OPeq, ty, e1, el_long(ty, 0));
        e = el_combine(e, e1);
        poffset += tysize(ty);
    }
    return e;
}

/*************************************************
 * Params:
 *      op = EXP.assign, EXP.construct, EXP.blit
 *      sym = struct symbol to initialize with the literal. If null, an auto is created
 *      fillHoles = Fill in alignment holes with zero. Set to
 *                  false if allocated by operator new, as the holes are already zeroed.
 */

elem* toElemStructLit(StructLiteralExp sle, ref IRState irs, EXP op, Symbol* sym, bool fillHoles)
{
    //printf("[%s] StructLiteralExp.toElem() %s\n", sle.loc.toChars(), sle.toChars());
    //printf("\tblit = %s, sym = %p fillHoles = %d\n", op == EXP.blit, sym, fillHoles);

    Type forcetype = null;
    if (sle.stype)
    {
        if (TypeEnum te = sle.stype.isTypeEnum())
        {
            // Reinterpret the struct literal as a complex type.
            if (te.sym.isSpecial() &&
                (te.sym.ident == Id.__c_complex_float ||
                 te.sym.ident == Id.__c_complex_double ||
                 te.sym.ident == Id.__c_complex_real))
            {
                forcetype = sle.stype;
            }
        }
    }

    static elem* Lreinterpret(Loc loc, elem* e, Type type)
    {
        elem* ep = el_una(OPind, totym(type), el_una(OPaddr, TYnptr, e));
        elem_setLoc(ep, loc);
        return ep;
    }

    if (sle.useStaticInit)
    {
        /* Use the struct declaration's init symbol
         */
        elem* e = el_var(toInitializer(sle.sd));
        e.ET = Type_toCtype(sle.sd.type);
        elem_setLoc(e, sle.loc);

        if (sym)
        {
            elem* ev = el_var(sym);
            if (tybasic(ev.Ety) == TYnptr)
                ev = el_una(OPind, e.Ety, ev);
            ev.ET = e.ET;
            e = elAssign(ev, e, null, ev.ET);

            //ev = el_var(sym);
            //ev.ET = e.ET;
            //e = el_combine(e, ev);
            elem_setLoc(e, sle.loc);
        }
        if (forcetype)
            return Lreinterpret(sle.loc, e, forcetype);
        return e;
    }

    // struct symbol to initialize with the literal
    Symbol* stmp = sym ? sym : symbol_genauto(Type_toCtype(sle.sd.type));

    elem* e = null;

    /* If a field has explicit initializer (*sle.elements)[i] != null),
     * any other overlapped fields won't have initializer. It's asserted by
     * StructDeclaration.fill() function.
     *
     *  union U { int x; long y; }
     *  U u1 = U(1);        // elements = [`1`, null]
     *  U u2 = {y:2};       // elements = [null, `2`];
     *  U u3 = U(1, 2);     // error
     *  U u4 = {x:1, y:2};  // error
     */
    size_t dim = sle.elements ? sle.elements.length : 0;
    assert(dim <= sle.sd.fields.length);

    if (fillHoles)
    {
        /* Initialize all alignment 'holes' to zero.
         * Do before initializing fields, as the hole filling process
         * can spill over into the fields.
         */
        const size_t structsize = sle.sd.structsize;
        size_t offset = 0;
        //printf("-- %s - fillHoles, structsize = %d\n", sle.toChars(), structsize);
        for (size_t i = 0; i < sle.sd.fields.length && offset < structsize; )
        {
            VarDeclaration v = sle.sd.fields[i];

            /* If the field v has explicit initializer, [offset .. v.offset]
             * is a hole divided by the initializer.
             * However if the field size is zero (e.g. int[0] v;), we can merge
             * the two holes in the front and the back of the field v.
             */
            if (i < dim && (*sle.elements)[i] && v.type.size())
            {
                //if (offset != v.offset) printf("  1 fillHole, %d .. %d\n", offset, v.offset);
                e = el_combine(e, fillHole(stmp, offset, v.offset, structsize));
                offset = cast(uint)(v.offset + v.type.size());
                i++;
                continue;
            }
            if (!v.overlapped)
            {
                i++;
                continue;
            }

            /* AggregateDeclaration.fields holds the fields by the lexical order.
             * This code will minimize each hole sizes. For example:
             *
             *  struct S {
             *    union { uint f1; ushort f2; }   // f1: 0..4,  f2: 0..2
             *    union { uint f3; ulong f4; }    // f3: 8..12, f4: 8..16
             *  }
             *  S s = {f2:x, f3:y};     // filled holes: 2..8 and 12..16
             */
            size_t vend = sle.sd.fields.length;
            size_t holeEnd = structsize;
            size_t offset2 = structsize;
            foreach (j; i + 1 .. vend)
            {
                VarDeclaration vx = sle.sd.fields[j];
                if (!vx.overlapped)
                {
                    vend = j;
                    break;
                }
                if (j < dim && (*sle.elements)[j] && vx.type.size())
                {
                    // Find the lowest end offset of the hole.
                    if (offset <= vx.offset && vx.offset < holeEnd)
                    {
                        holeEnd = vx.offset;
                        offset2 = cast(uint)(vx.offset + vx.type.size());
                    }
                }
            }
            if (holeEnd < structsize)
            {
                //if (offset != holeEnd) printf("  2 fillHole, %d .. %d\n", offset, holeEnd);
                e = el_combine(e, fillHole(stmp, offset, holeEnd, structsize));
                offset = offset2;
                continue;
            }
            i = vend;
        }
        //if (offset != sle.sd.structsize) printf("  3 fillHole, %d .. %d\n", offset, sle.sd.structsize);
        e = el_combine(e, fillHole(stmp, offset, sle.sd.structsize, sle.sd.structsize));
    }

    // CTFE may fill the hidden pointer by NullExp.
    VarDeclaration vbf;
    foreach (i, element; *sle.elements)
    {
        if (!element)
            continue;

        VarDeclaration v = sle.sd.fields[i];
        assert(!v.isThisDeclaration() || element.op == EXP.null_);

        elem* e1;
        if (tybasic(stmp.Stype.Tty) == TYnptr)
        {
            e1 = el_var(stmp);
        }
        else
        {
            e1 = el_ptr(stmp);
        }

        elem* ep = toElem(element, irs);

        Type t1b = v.type.toBasetype();
        Type t2b = element.type.toBasetype();
        if (t1b.ty == Tsarray)
        {
            e1 = el_bin(OPadd, TYnptr, e1, el_long(TYsize_t, v.offset));
            if (t2b.implicitConvTo(t1b))
            {
                elem* esize = el_long(TYsize_t, t1b.size());
                ep = array_toPtr(element.type, ep);
                e1 = el_bin(OPmemcpy, TYnptr, e1, el_param(ep, esize));
            }
            else
            {
                elem* edim = el_long(TYsize_t, t1b.size() / t2b.size());
                e1 = setArray(element, e1, edim, t2b, ep, irs, op == EXP.construct ? EXP.blit : op);
            }
            e = el_combine(e, e1);
            continue;
        }

        const tym_t tym = totym(v.type);
        auto voffset = v.offset;
        uint bitfieldArg;
        uint bitOffset;
        auto bf = v.isBitFieldDeclaration();
        if (bf)
        {
            const szbits = tysize(tym) * 8;
            bitOffset = bf.bitOffset;
            if (bitOffset + bf.fieldWidth > szbits)
            {
                const advance = bitOffset / szbits;
                voffset += advance;
                bitOffset -= advance * 8;
                assert(bitOffset + bf.fieldWidth <= szbits);
            }
            bitfieldArg = bf.fieldWidth * 256 + bitOffset;

            //printf("2bitOffset %u fieldWidth %u bits %u\n", bitOffset, bf.fieldWidth, szbits);
            assert(bitOffset + bf.fieldWidth <= szbits);
        }

        e1 = el_bin(OPadd, TYnptr, e1, el_long(TYsize_t, voffset));
        e1 = el_una(OPind, tym, e1);
        if (tybasic(tym) == TYstruct)
        {
            e1.ET = Type_toCtype(v.type);
            assert(!bf);
        }
        if (bf)
        {
            if (!vbf || vbf.offset + vbf.type.size() <= v.offset)
            {
                /* Initialize entire location the bitfield is in
                 * ep = (ep & ((1 << bf.fieldWidth) - 1)) << bf.bitOffset
                 */
                auto ex = el_bin(OPand, tym, ep, el_long(tym, (1L << bf.fieldWidth) - 1));
                ep = el_bin(OPshl, tym, ex, el_long(tym, bitOffset));
                vbf = v;
            }
            else
            {
                //printf("2bitOffset %u fieldWidth %u bits %u\n", bf.bitOffset, bf.fieldWidth, tysize(e1.Ety) * 8);
                // Insert special bitfield operator
                auto mos = el_long(TYuint, bitfieldArg);
                e1 = el_bin(OPbit, e1.Ety, e1, mos);
            }
        }
        else
            vbf = null;
        e1 = elAssign(e1, ep, v.type, e1.ET);

        e = el_combine(e, e1);
    }

    if (sle.sd.isNested() && dim != sle.sd.fields.length)
    {
        // Initialize the hidden 'this' pointer
        assert(sle.sd.fields.length);

        elem* e1, e2;
        if (tybasic(stmp.Stype.Tty) == TYnptr)
        {
            e1 = el_var(stmp);
        }
        else
        {
            e1 = el_ptr(stmp);
        }
        if (sle.sd.vthis2)
        {
            /* Initialize sd.vthis2:
             *  *(e2 + sd.vthis2.offset) = this1;
             */
            e2 = el_copytree(e1);
            e2 = setEthis(sle.loc, irs, e2, sle.sd, true);
        }
        /* Initialize sd.vthis:
         *  *(e1 + sd.vthis.offset) = this;
         */
        e1 = setEthis(sle.loc, irs, e1, sle.sd);

        e = el_combine(e, e1);
        e = el_combine(e, e2);
    }

    elem* ev = el_var(stmp);
    ev.ET = Type_toCtype(sle.sd.type);
    e = el_combine(e, ev);
    elem_setLoc(e, sle.loc);
    if (forcetype)
        return Lreinterpret(sle.loc, e, forcetype);
    return e;
}

/********************************************
 * Append destructors for varsInScope[starti..endi] to er.
 * Params:
 *      irs = context
 *      er = elem to append destructors to
 *      starti = starting index in varsInScope[]
 *      endi = ending index in varsInScope[]
 * Returns:
 *      er with destructors appended
 */

elem* appendDtors(ref IRState irs, elem* er, size_t starti, size_t endi)
{
    //printf("appendDtors(%d .. %d)\n", cast(int)starti, cast(int)endi);

    /* Code gen can be improved by determining if no exceptions can be thrown
     * between the OPdctor and OPddtor, and eliminating the OPdctor and OPddtor.
     */

    /* Build edtors, an expression that calls destructors on all the variables
     * going out of the scope starti..endi
     */
    elem* edtors = null;
    foreach (i; starti .. endi)
    {
        elem* ed = (*irs.varsInScope)[i];
        if (ed)                                 // if not skipped
        {
            //printf("appending dtor\n");
            (*irs.varsInScope)[i] = null;       // so these are skipped by outer scopes
            edtors = el_combine(ed, edtors);    // execute in reverse order
        }
    }

    if (!edtors)
        return er;
    if (irs.target.os == Target.OS.Windows && !irs.target.isX86_64) // Win32
    {
        BlockState* blx = irs.blx;
        nteh_declarvars(blx);
    }

    /* Append edtors to er, while preserving the value of er
     */
    if (tybasic(er.Ety) == TYvoid)
    {
        /* No value to preserve, so simply append
         */
        er = el_combine(er, edtors);
        return er;
    }

    elem **pe;
    for (pe = &er; (*pe).Eoper == OPcomma; pe = &(*pe).E2)
    {
    }
    elem* erx = *pe;

    if (erx.Eoper == OPconst || erx.Eoper == OPrelconst)
    {
        *pe = el_combine(edtors, erx);
    }
    else if (elemIsLvalue(erx))
    {
        /* Lvalue, take a pointer to it
         */
        elem* ep = el_una(OPaddr, TYnptr, erx);
        elem* e = el_same(ep);
        ep = el_combine(ep, edtors);
        ep = el_combine(ep, e);
        e = el_una(OPind, erx.Ety, ep);
        e.ET = erx.ET;
        *pe = e;
    }
    else
    {
        elem* e = el_copytotmp(erx);
        erx = el_combine(erx, edtors);
        *pe = el_combine(erx, e);
    }
    return er;
}

/******************************************************
 * Return an elem that is the file, line, and function suitable
 * for insertion into the parameter list.
 */

elem* filelinefunction(ref IRState irs, Loc loc)
{
    const(char)* id = loc.filename;
    size_t len = strlen(id);
    Symbol* si = toStringSymbol(id, len, 1);
    elem* efilename = el_pair(TYdarray, el_long(TYsize_t, len), el_ptr(si));
    if (irs.target.os == Target.OS.Windows && irs.target.isX86_64)
        efilename = addressElem(efilename, Type.tstring, true);

    elem* elinnum = el_long(TYint, loc.linnum);

    const(char)* s = "";
    FuncDeclaration fd = irs.getFunc();
    if (fd)
    {
        s = fd.toPrettyChars();
    }

    len = strlen(s);
    si = toStringSymbol(s, len, 1);
    elem* efunction = el_pair(TYdarray, el_long(TYsize_t, len), el_ptr(si));
    if (irs.target.os == Target.OS.Windows && irs.target.isX86_64)
        efunction = addressElem(efunction, Type.tstring, true);

    return el_params(efunction, elinnum, efilename, null);
}

/******************************************************
 * Construct elem to run when an array bounds check fails. (Without additional context)
 * Params:
 *      irs = to get function from
 *      loc = to get file/line from
 * Returns:
 *      elem generated
 */
elem* buildRangeError(ref IRState irs, Loc loc)
{
    final switch (irs.params.checkAction)
    {
    case CHECKACTION.C:
        return callCAssert(irs, loc, null, null, "array overflow");
    case CHECKACTION.halt:
        return genHalt(loc);
    case CHECKACTION.context:
    case CHECKACTION.D:
        const efile = irs.locToFileElem(loc);
        return el_bin(OPcall, TYvoid, el_var(getRtlsym(RTLSYM.DARRAYP)), el_params(el_long(TYint, loc.linnum), efile, null));
    }
}

/******************************************************
 * Construct elem to run when an array slice is created that is out of bounds
 * Params:
 *      irs = to get function from
 *      loc = to get file/line from
 *      lower = lower bound in slice
 *      upper = upper bound in slice
 *      elength = length of array
 * Returns:
 *      elem generated
 */
elem* buildArraySliceError(ref IRState irs, Loc loc, elem* lower, elem* upper, elem* length) {
    final switch (irs.params.checkAction)
    {
    case CHECKACTION.C:
        return callCAssert(irs, loc, null, null, "array slice out of bounds");
    case CHECKACTION.halt:
        return genHalt(loc);
    case CHECKACTION.context:
    case CHECKACTION.D:
        assert(upper);
        assert(lower);
        assert(length);
        const efile = irs.locToFileElem(loc);
        return el_bin(OPcall, TYvoid, el_var(getRtlsym(RTLSYM.DARRAY_SLICEP)), el_params(length, upper, lower, el_long(TYint, loc.linnum), efile, null));
    }
}

/******************************************************
 * Construct elem to run when an out of bounds array index is accessed
 * Params:
 *      irs = to get function from
 *      loc = to get file/line from
 *      index = index in the array
 *      elength = length of array
 * Returns:
 *      elem generated
 */
elem* buildArrayIndexError(ref IRState irs, Loc loc, elem* index, elem* length) {
    final switch (irs.params.checkAction)
    {
    case CHECKACTION.C:
        return callCAssert(irs, loc, null, null, "array index out of bounds");
    case CHECKACTION.halt:
        return genHalt(loc);
    case CHECKACTION.context:
    case CHECKACTION.D:
        assert(length);
        const efile = irs.locToFileElem(loc);
        return el_bin(OPcall, TYvoid, el_var(getRtlsym(RTLSYM.DARRAY_INDEXP)), el_params(length, index, el_long(TYint, loc.linnum), efile, null));
    }
}

/// Returns: elem representing a C-string (char*) to the filename
elem* locToFileElem(const ref IRState irs, Loc loc) {
    elem* efile;
    if (loc.filename)
    {
        const len = strlen(loc.filename);
        Symbol* s = toStringSymbol(loc.filename, len, 1);
        efile = el_ptr(s);
    }
    else
        efile = toEfilenamePtr(cast(Module)irs.blx._module);
    return efile;
}

/****************************************
 * Generate call to C's assert failure function.
 * One of exp, emsg, or str must not be null.
 * Params:
 *      irs = context
 *      loc = location to use for assert message
 *      exp = if not null expression to test (not evaluated, but converted to a string)
 *      emsg = if not null then informative message to be computed at run time
 *      str = if not null then informative message string
 * Returns:
 *      generated call
 */
elem* callCAssert(ref IRState irs, Loc loc, Expression exp, Expression emsg, const(char)* str)
{
    //printf("callCAssert.toElem() %s\n", e.toChars());
    Module m = cast(Module)irs.blx._module;
    const(char)* mname = m.srcfile.toChars();

    elem* getFuncName()
    {
        const(char)* id = "";
        FuncDeclaration fd = irs.getFunc();
        if (fd)
            id = fd.toPrettyChars();
        const len = strlen(id);
        Symbol* si = toStringSymbol(id, len, 1);
        return el_ptr(si);
    }

    //printf("filename = '%s'\n", loc.filename);
    //printf("module = '%s'\n", mname);

    /* If the source file name has changed, probably due
     * to a #line directive.
     */
    elem* efilename;
    if (loc.filename && strcmp(loc.filename, mname) != 0)
    {
        const(char)* id = loc.filename;
        size_t len = strlen(id);
        Symbol* si = toStringSymbol(id, len, 1);
        efilename = el_ptr(si);
    }
    else
    {
        efilename = toEfilenamePtr(m);
    }

    elem* elmsg;
    if (emsg)
    {
        // Assuming here that emsg generates a 0 terminated string
        auto e = toElemDtor(emsg, irs);
        elmsg = array_toPtr(Type.tvoid.arrayOf(), e);
    }
    else if (exp)
    {
        // Generate a message out of the assert expression
        const(char)* id = exp.toChars();
        const len = strlen(id);
        Symbol* si = toStringSymbol(id, len, 1);
        elmsg = el_ptr(si);
    }
    else
    {
        assert(str);
        const len = strlen(str);
        Symbol* si = toStringSymbol(str, len, 1);
        elmsg = el_ptr(si);
    }

    auto eline = el_long(TYint, loc.linnum);

    elem* ea;
    if (irs.target.os == Target.OS.OSX)
    {
        // __assert_rtn(func, file, line, msg);
        elem* efunc = getFuncName();
        auto eassert = el_var(getRtlsym(RTLSYM.C__ASSERT_RTN));
        ea = el_bin(OPcall, TYvoid, eassert, el_params(elmsg, eline, efilename, efunc, null));
        return ea;
    }

    Symbol* assertSym;
    elem* params;
    with (TargetC.Runtime) switch (irs.target.c.runtime)
    {
        case Musl:
        case Glibc:
            // __assert_fail(exp, file, line, func);
            assertSym = getRtlsym(RTLSYM.C__ASSERT_FAIL);
            elem* efunc = getFuncName();
            params = el_params(efunc, eline, efilename, elmsg, null);
            break;
        default:
            // [_]_assert(msg, file, line);
            const rtlsym = (irs.target.os == Target.OS.Windows) ? RTLSYM.C_ASSERT : RTLSYM.C__ASSERT;
            assertSym = getRtlsym(rtlsym);
            params = el_params(eline, efilename, elmsg, null);
            break;
    }
    auto eassert = el_var(assertSym);
    ea = el_bin(OPcall, TYvoid, eassert, params);
    return ea;
}

/********************************************
 * Generate HALT instruction.
 * Params:
 *      loc = location to use for debug info
 * Returns:
 *      generated instruction
 */
elem* genHalt(Loc loc)
{
    elem* e = el_calloc();
    e.Ety = TYnoreturn;
    e.Eoper = OPhalt;
    elem_setLoc(e, loc);
    return e;
}

/**************************************************
 * Initialize the dual-context array with the context pointers.
 * Params:
 *      loc = line and file of what line to show usage for
 *      irs = current context to get the second context from
 *      fd = the target function
 *      ethis2 = dual-context array
 *      ethis = the first context, updated
 *      eside = where to store the assignment expressions, updated
 * Returns:
 *      `ethis2` if successful, null otherwise
 */
private
elem* setEthis2(Loc loc, ref IRState irs, FuncDeclaration fd, elem* ethis2, ref elem* ethis, ref elem* eside)
{
    if (!fd.hasDualContext())
        return null;

    assert(ethis2 && ethis);

    elem* ectx0 = el_una(OPind, ethis.Ety, el_copytree(ethis2));
    elem* eeq0 = el_bin(OPeq, ethis.Ety, ectx0, ethis);
    ethis = el_copytree(ectx0);
    eside = el_combine(eeq0, eside);

    elem* ethis1 = getEthis(loc, irs, fd, fd.toParent2());
    elem* ectx1 = el_bin(OPadd, TYnptr, el_copytree(ethis2), el_long(TYsize_t, tysize(TYnptr)));
    ectx1 = el_una(OPind, TYnptr, ectx1);
    elem* eeq1 = el_bin(OPeq, ethis1.Ety, ectx1, ethis1);
    eside = el_combine(eeq1, eside);

    return ethis2;
}

/*******************************
 * Construct OPva_start node
 * Params:
 *      e = function parameters
 * Returns:
 *      OPva_start node
 */
private
elem* constructVa_start(elem* e)
{
    assert(e.Eoper == OPparam);

    e.Eoper = OPva_start;
    e.Ety = TYvoid;
    if (target.isX86_64)
    {
        // (OPparam &va &arg)
        // call as (OPva_start &va)
    }
    else // 32 bit
    {
        // (OPparam &arg &va)  note arguments are swapped from 64 bit path
        // call as (OPva_start &va)
        auto earg = e.E1;
        e.E1 = e.E2;
        e.E2 = earg;
    }
    return e;
}
