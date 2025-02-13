/**
 * Convert a D symbol to a symbol the linker understands (with mangled name).
 *
 * Copyright:   Copyright (C) 1999-2024 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 https://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/src/tocsym.d, _tocsym.d)
 * Documentation:  https://dlang.org/phobos/dmd_tocsym.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/tocsym.d
 */

module dmd.tocsym;

import core.stdc.stdio;
import core.stdc.string;

import dmd.root.array;
import dmd.root.complex;
import dmd.root.rmem;

import dmd.aggregate;
import dmd.arraytypes;
import dmd.astenums;
import dmd.ctfeexpr;
import dmd.declaration;
import dmd.dclass;
import dmd.denum;
import dmd.dmdparams;
import dmd.dmodule;
import dmd.dstruct;
import dmd.dsymbol;
import dmd.dtemplate;
import dmd.e2ir;
import dmd.errors;
import dmd.expression;
import dmd.func;
import dmd.globals;
import dmd.glue;
import dmd.identifier;
import dmd.id;
import dmd.init;
import dmd.location;
import dmd.mangle;
import dmd.mtype;
import dmd.safe : isSafe;
import dmd.target;
import dmd.toctype;
import dmd.todt;
import dmd.toir;
import dmd.tokens;
import dmd.typesem : size;
import dmd.visitor;

import dmd.backend.cdef;
import dmd.backend.cc;
import dmd.backend.dt;
import dmd.backend.type;
import dmd.backend.global;
import dmd.backend.oper;
import dmd.backend.cgcv;
import dmd.backend.symtab;
import dmd.backend.ty;


/*************************************
 * Helper
 */

Symbol* toSymbolX(Dsymbol ds, const(char)* prefix, SC sclass, type* t, const(char)* suffix)
{
    //printf("Dsymbol::toSymbolX('%s')\n", prefix);
    import dmd.common.smallbuffer : SmallBuffer;
    import dmd.common.outbuffer : OutBuffer;

    OutBuffer buf;
    mangleToBuffer(ds, buf);
    size_t nlen = buf.length;
    const(char)* n = buf.peekChars();
    assert(n);

    import core.stdc.string : strlen;
    size_t prefixlen = strlen(prefix);
    size_t suffixlen = strlen(suffix);
    size_t idlen = 2 + nlen + size_t.sizeof * 3 + prefixlen + suffixlen + 1;

    char[64] idbuf = void;
    auto sb = SmallBuffer!(char)(idlen, idbuf[]);
    char* id = sb.ptr;

    int nwritten = snprintf(id, idlen, "_D%.*s%d%.*s%.*s",
        cast(int)nlen, n,
        cast(int)prefixlen, cast(int)prefixlen, prefix,
        cast(int)suffixlen, suffix);
    assert(cast(uint)nwritten < idlen);         // nwritten does not include the terminating 0 char

    Symbol* s = symbol_name(id[0 .. nwritten], sclass, t);

    //printf("-Dsymbol::toSymbolX() %s\n", id);
    return s;
}

/*************************************
 */

Symbol* toSymbol(Dsymbol s)
{
    //printf("toSymbol() %s\n", s.toChars());

    extern (C++) static final class ToSymbol : Visitor
    {
        alias visit = Visitor.visit;

        Symbol* result;

        this() scope @safe
        {
            result = null;
        }

        override void visit(Dsymbol s)
        {
            printf("Dsymbol.toSymbol() '%s', kind = '%s'\n", s.toChars(), s.kind());
            assert(0);          // BUG: implement
        }

        override void visit(SymbolDeclaration sd)
        {
            result = toInitializer(sd.dsym);
        }

        override void visit(VarDeclaration vd)
        {
            //printf("VarDeclaration.toSymbol(%s)\n", vd.toChars());
            if (vd.needThis())
                fprintf(stderr, "VarDeclaration.toSymbol(%s) needThis kind: %s\n", vd.toPrettyChars(), vd.kind());
            assert(!vd.needThis());

            import dmd.common.outbuffer : OutBuffer;
            OutBuffer buf;
            bool isNRVO = false;
            const(char)[] id = vd.ident.toString();
            if (vd.isDataseg())
            {
                mangleToBuffer(vd, buf);
                id = buf[];
            }
            else
            {
                if (FuncDeclaration fd = vd.toParent2().isFuncDeclaration())
                {
                    if (fd.isNRVO() && fd.nrvo_var == vd)
                    {
                        buf.writestring("__nrvo_");
                        buf.writestring(id);
                        id = buf[];
                        isNRVO = true;
                    }
                }
            }
            Symbol* s = symbol_calloc(id);
            s.Salignment = vd.alignment.isDefault() ? -1 : vd.alignment.get();
            if (vd.storage_class & STC.temp)
                s.Sflags |= SFLartifical;
            if (isNRVO)
                s.Sflags |= SFLnodebug;
            if (vd.noUnderscore)
                s.Sflags |= SFLnounderscore;

            TYPE* t;
            if (vd.storage_class & (STC.out_ | STC.ref_))
            {
                t = type_allocn(TYnref, Type_toCtype(vd.type));
                t.Tcount++;
            }
            else if (vd.storage_class & STC.lazy_)
            {
                if (target.os == Target.OS.Windows && target.isX86_64 && vd.isParameter())
                    t = type_fake(TYnptr);
                else
                    t = type_fake(TYdelegate);          // Tdelegate as C type
                t.Tcount++;
            }
            else if (vd.isParameter() && ISX64REF(vd))
            {
                t = type_allocn(TYnref, Type_toCtype(vd.type));
                t.Tcount++;
            }
            else
            {
                t = Type_toCtype(vd.type);
                t.Tcount++;
            }

            /* Even if a symbol is immutable, if it has a constructor then
             * the constructor mutates it. Remember that constructors can
             * be inlined into other code.
             * Just can't rely on it being immutable.
             */
            if (t.Tty & (mTYimmutable | mTYconst))
            {
                if (vd.ctorinit)
                {
                    /* It was initialized in a constructor, so not really immutable
                     * as far as the optimizer is concerned, as in this case:
                     *   immutable int x;
                     *   shared static this() { x += 3; }
                     */
                    t = type_setty(&t, t.Tty & ~(mTYimmutable | mTYconst));
                }
                else if (auto ts = vd.type.isTypeStruct())
                {
                    if (!ts.isMutable() && ts.sym.ctor)
                    {
                        t = type_setty(&t, t.Tty & ~(mTYimmutable | mTYconst));
                    }
                }
                else if (auto tc = vd.type.isTypeClass())
                {
                    if (!tc.isMutable() && tc.sym.ctor)
                    {
                        t = type_setty(&t, t.Tty & ~(mTYimmutable | mTYconst));
                    }
                }
            }

            if (vd.isDataseg())
            {
                if (vd.isThreadlocal() && !(vd.storage_class & STC.temp))
                {
                    /* Thread local storage
                     */
                    auto ts = t;
                    ts.Tcount++;   // make sure a different t is allocated
                    type_setty(&t, t.Tty | mTYthread);
                    ts.Tcount--;

                    if (config.objfmt == OBJ_MACH && _tysize[TYnptr] == 8)
                        s.Salignment = 2;

                    if (global.params.v.tls)
                    {
                        message(vd.loc, "`%s` is thread local", vd.toChars());
                    }
                }
                s.Sclass = SC.extern_;
                s.Sfl = FL.extern_;

                /* Make C static variables SCstatic
                 */
                if (vd.storage_class & STC.static_ && vd.isCsymbol())
                {
                    s.Sclass = SC.static_;
                    s.Sfl = FL.data;
                }

                /* if it's global or static, then it needs to have a qualified but unmangled name.
                 * This gives some explanation of the separation in treating name mangling.
                 * It applies to PDB format, but should apply to CV as PDB derives from CV.
                 *    https://msdn.microsoft.com/en-us/library/ff553493%28VS.85%29.aspx
                 */
                s.prettyIdent = vd.toPrettyChars(true);
            }
            else
            {
                s.Sclass = SC.auto_;
                s.Sfl = FL.auto_;

                if (vd.nestedrefs.length)
                {
                    /* Symbol is accessed by a nested function. Make sure
                     * it is not put in a register, and that the optimizer
                     * assumes it is modified across function calls and pointer
                     * dereferences.
                     */
                    //printf("\tnested ref, not register\n");
                    type_setcv(&t, t.Tty | mTYvolatile);
                }
            }

            if (vd.storage_class & STC.volatile_)
            {
                type_setcv(&t, t.Tty | mTYvolatile);
            }

            Mangle m = Mangle.none;
            final switch (vd.resolvedLinkage())
            {
                case LINK.windows:
                    m = target.isX86 ? Mangle.stdcall : Mangle.c;
                    break;

                case LINK.objc:
                case LINK.c:
                    m = Mangle.c;
                    break;

                case LINK.d:
                    m = Mangle.d;
                    break;

                case LINK.cpp:
                    s.Sflags |= SFLpublic;
                    m = Mangle.cpp;
                    break;

                case LINK.default_:
                case LINK.system:
                    printf("linkage = %d, vd = %s %s @ [%s]\n",
                        vd._linkage, vd.kind(), vd.toChars(), vd.loc.toChars());
                    assert(0);
            }

            type_setmangle(&t, m);
            s.Stype = t;

            s.lposscopestart = toSrcpos(vd.loc);
            s.lnoscopeend = vd.endlinnum;
            result = s;
        }

        override void visit(TypeInfoDeclaration tid)
        {
            //printf("TypeInfoDeclaration.toSymbol(%s), linkage = %d\n", tid.toChars(), tid.linkage);
            assert(tid.tinfo.ty != Terror);
            visit(tid.isVarDeclaration());
        }

        override void visit(TypeInfoClassDeclaration ticd)
        {
            //printf("TypeInfoClassDeclaration.toSymbol(%s), linkage = %d\n", ticd.toChars(), ticd.linkage);
            ticd.tinfo.isTypeClass().sym.accept(this);
        }

        override void visit(FuncAliasDeclaration fad)
        {
            fad.funcalias.accept(this);
        }

        override void visit(FuncDeclaration fd)
        {
            const(char)* id = mangleExact(fd);

            //printf("FuncDeclaration.toSymbol(%s %s)\n", fd.kind(), fd.toChars());

            /* MS-LINK cannot handle multiple COMDATs with the same name.
             * This can happen with two .c files that define the same function.
             * They get compiled into one .obj file with the `oneobj` setting.
             * https://issues.dlang.org/show_bug.cgi?id=24129
             */
            if (driverParams.oneobj)
            {
                auto mod = fd.getModule();
                if (mod &&
                    mod.isRoot() &&               // included on command line
                    mod.filetype == FileType.c && // a C file
                    fd.fbody &&                   // a function definition
                    fd._linkage == LINK.c &&
                    !fd.skipCodegen)              // code gen is desired
                {
                    __gshared DsymbolTable Csymtab;  // sorry about another global variable
                    if (Csymtab is null)
                        Csymtab = new DsymbolTable();

                    if (!Csymtab.insert(fd))    // if code was already generated for same-named function
                    {
                        /* Use the C symbol for the previously generated function
                         */
                        fd.csym = Csymtab.lookup(fd.ident).csym;
                        result = fd.csym;

                        fd.skipCodegen = true;
                        return;
                    }
                }
            }

            //printf("\tid = '%s'\n", id);
            //printf("\ttype = %s\n", fd.type.toChars());
            auto s = symbol_calloc(id[0 .. strlen(id)]);

            s.prettyIdent = fd.toPrettyChars(true);

            /* Make C static functions SCstatic
             */
            s.Sclass = (fd.storage_class & STC.static_ && fd.isCsymbol())
                ? SC.static_
                : SC.global;

            symbol_func(*s);
            func_t* f = s.Sfunc;
            if (fd.isVirtual() && fd.vtblIndex != -1)
                f.Fflags |= Fvirtual;
            else if (fd.isMember2() && fd.isStatic())
                f.Fflags |= Fstatic;

            if (fd.isSafe())
                f.Fflags3 |= F3safe;

            if (fd.inlining == PINLINE.default_ && global.params.useInline ||
                fd.inlining == PINLINE.always)
            {
                // this is copied from inline.d
                if (!fd.fbody ||
                    fd.ident == Id.ensure ||
                    fd.skipCodegen ||
                    (fd.ident == Id.require &&
                     fd.toParent().isFuncDeclaration() &&
                     fd.toParent().isFuncDeclaration().needThis()) ||
                                (fd.isSynchronized() ||
                                 fd.isImportedSymbol() ||
                                 fd.hasNestedFrameRefs() ||
                                 (fd.isVirtual() && !fd.isFinalFunc())))
                { }
                else
                    f.Fflags |= Finline;    // inline this function if possible
            }

            if (fd.type.toBasetype().isTypeFunction().nextOf().isTypeNoreturn() || fd.noreturn)
                s.Sflags |= SFLexit;    // the function never returns

            f.Fstartline = toSrcpos(fd.loc);
            f.Fendline = fd.endloc.linnum ? toSrcpos(fd.endloc) : f.Fstartline;

            auto t = Type_toCtype(fd.type);
            if (fd.isNaked)
                type_setty(&t, t.Tty | mTYnaked);

            const msave = t.Tmangle;
            if (fd.isMain())
            {
                t.Tty = TYnfunc;
                t.Tmangle = Mangle.c;
                f.Fflags3 |= Fmain;
            }
            else
            {
                final switch (fd.resolvedLinkage())
                {
                    case LINK.windows:
                        t.Tmangle = target.isX86 ? Mangle.stdcall : Mangle.c;
                        break;

                    case LINK.c:
                        if (fd.noUnderscore)
                            s.Sflags |= SFLnounderscore;
                        goto case;
                    case LINK.objc:
                        t.Tmangle = Mangle.c;
                        break;

                    case LINK.d:
                        t.Tmangle = Mangle.d;
                        break;
                    case LINK.cpp:
                        s.Sflags |= SFLpublic;
                        /* Nested functions use the same calling convention as
                         * member functions, because both can be used as delegates. */
                        if ((fd.isThis() || fd.isNested()) && target.isX86 && target.os == Target.OS.Windows)
                        {
                            if ((cast(TypeFunction)fd.type).parameterList.varargs == VarArg.variadic)
                            {
                                t.Tty = TYnfunc;
                            }
                            else
                            {
                                t.Tty = TYmfunc;
                            }
                        }
                        t.Tmangle = Mangle.cpp;
                        break;
                    case LINK.default_:
                    case LINK.system:
                        printf("linkage = %d\n", fd._linkage);
                        assert(0);
                }
            }

            if (msave)
                assert(msave == t.Tmangle);
            //printf("Tty = %x, mangle = x%x\n", t.Tty, t.Tmangle);
            t.Tcount++;
            s.Stype = t;
            //s.Sfielddef = this;

            result = s;
        }

        static type* getClassInfoCType()
        {
            __gshared Symbol* scc;
            if (!scc)
                scc = fake_classsym(Id.ClassInfo);
            return scc.Stype;
        }

        /*************************************
         * Create the "ClassInfo" symbol
         */

        override void visit(ClassDeclaration cd)
        {
            auto s = toSymbolX(cd, "__Class", SC.extern_, getClassInfoCType(), "Z");
            s.Sfl = FL.extern_;
            s.Sflags |= SFLnodebug;
            result = s;
        }

        /*************************************
         * Create the "InterfaceInfo" symbol
         */

        override void visit(InterfaceDeclaration id)
        {
            auto s = toSymbolX(id, "__Interface", SC.extern_, getClassInfoCType(), "Z");
            s.Sfl = FL.extern_;
            s.Sflags |= SFLnodebug;
            result = s;
        }

        /*************************************
         * Create the "ModuleInfo" symbol
         */

        override void visit(Module m)
        {
            auto s = toSymbolX(m, "__ModuleInfo", SC.extern_, getClassInfoCType(), "Z");
            s.Sfl = FL.extern_;
            s.Sflags |= SFLnodebug;
            result = s;
        }
    }

    if (s.csym)
        return s.csym;

    scope ToSymbol v = new ToSymbol();
    s.accept(v);
    s.csym = v.result;

    if (isDllImported(s))
        s.csym.Sisym = createImport(s.csym, s.loc);

    return v.result;
}


/*************************************
 * Create Windows import symbol from backend Symbol.
 * Params:
 *      sym = backend symbol
 *      loc = location for error message purposes
 * Returns:
 *      import symbol
 */

private Symbol* createImport(Symbol* sym, Loc loc)
{
    //printf("Dsymbol.createImport('%s')\n", sym.Sident.ptr);
    const char* n = sym.Sident.ptr;
    import core.stdc.stdlib : alloca;
    const allocLen = 6 + strlen(n) + 1 + type_paramsize(sym.Stype).sizeof*3 + 1;
    char* id = cast(char *) alloca(allocLen);
    int idlen;
    if (target.os & Target.OS.Posix)
    {
        error(loc, "cannot generate import symbol `%s` for Posix platform", n);
        assert(0);
    }
    else if (target.os & Target.OS.Windows && sym.Stype.Tty & mTYthread)
    {
        error(loc, "cannot generate import symbol for thread local symbol `%s`", n);
        assert(0);
    }
    else if (sym.Stype.Tmangle == Mangle.stdcall && tyfunc(sym.Stype.Tty))
    {
        if (target.os == Target.OS.Windows && target.isX86_64)
            idlen = snprintf(id, allocLen, "__imp_%s",n);
        else
            idlen = snprintf(id, allocLen, "_imp__%s@%u",n,cast(uint)type_paramsize(sym.Stype));
    }
    else
    {
        idlen = snprintf(id, allocLen, (target.os == Target.OS.Windows && target.isX86_64) ? "__imp_%s" : (sym.Stype.Tmangle == Mangle.cpp) ? "_imp_%s" : "_imp__%s",n);
    }
    auto t = type_alloc(TYnptr | mTYconst);
    t.Tnext = sym.Stype;
    t.Tnext.Tcount++;
    t.Tmangle = Mangle.c;
    t.Tcount++;
    auto s = symbol_calloc(id[0 .. idlen]);
    s.Stype = t;
    s.Sclass = SC.extern_;
    s.Sfl = FL.extern_;
    s.Sflags |= SFLimported;

    return s;
}

/*********************************
 * Generate import symbol from symbol.
 */

Symbol* toImport(Dsymbol ds)
{
    if (!ds.csym)
        toSymbol(ds);
    return ds.csym.Sisym;
}

/*************************************
 * Thunks adjust the incoming 'this' pointer by 'offset'.
 */

Symbol* toThunkSymbol(FuncDeclaration fd, int offset)
{
    Symbol* s = toSymbol(fd);
    if (!offset)
        return s;

    if (retStyle(fd.type.isTypeFunction(), fd.needThis()) == RET.stack)
        s.Sfunc.Fflags3 |= F3hiddenPtr;

    s.Sfunc.Fflags &= ~Finline;  // thunks are not real functions, don't inline them

    __gshared int tmpnum;
    const nameLen = 6 + tmpnum.sizeof * 3 + 1;
    char[nameLen] name = void;

    const len = snprintf(name.ptr,nameLen,"_THUNK%d",tmpnum++);
    auto sthunk = symbol_name(name[0 .. len],SC.static_,fd.csym.Stype);
    sthunk.Sflags |= SFLnodebug | SFLartifical;
    sthunk.Sflags |= SFLimplem;
    outthunk(sthunk, fd.csym, 0, TYnptr, -offset, -1, 0);
    return sthunk;
}


/**************************************
 * Fake a struct symbol.
 */

Classsym* fake_classsym(Identifier id)
{
    auto t = type_struct_class(id.toChars(),8,0,
        null,null,
        false, false, true, false);

    t.Ttag.Sstruct.Sflags = STRglobal;
    t.Tflags |= TFsizeunknown | TFforward;
    assert(t.Tmangle == 0);
    t.Tmangle = Mangle.d;
    return t.Ttag;
}

/*************************************
 * This is accessible via the ClassData, but since it is frequently
 * needed directly (like for rtti comparisons), make it directly accessible.
 */

Symbol* toVtblSymbol(ClassDeclaration cd, bool genCsymbol = true)
{
    if (!cd.vtblsym || !cd.vtblsym.csym)
    {
        if (!cd.csym && genCsymbol)
            toSymbol(cd);

        auto t = type_allocn(TYnptr | mTYconst, tstypes[TYvoid]);
        t.Tmangle = Mangle.d;
        auto s = toSymbolX(cd, "__vtbl", SC.extern_, t, "Z");
        s.Sflags |= SFLnodebug;
        s.Sfl = FL.extern_;

        auto vtbl = cd.vtblSymbol();
        vtbl.csym = s;
    }
    return cd.vtblsym.csym;
}

/**********************************
 * Create the static initializer for the struct/class.
 */

Symbol* toInitializer(AggregateDeclaration ad)
{
    //printf("toInitializer() %s\n", ad.toChars());
    if (!ad.sinit)
    {
        static structalign_t alignOf(Type t)
        {
            const explicitAlignment = t.alignment();
            if (!explicitAlignment.isDefault()) // if overriding default alignment
                return explicitAlignment;

            // Use the default alignment for type t
            structalign_t sa;
            sa.set(t.alignsize());
            return sa;
        }

        auto sd = ad.isStructDeclaration();
        if (sd &&
            alignOf(sd.type).get() <= 16 &&
            sd.type.size() <= 128 &&
            sd.zeroInit &&
            config.objfmt != OBJ_MACH && // same reason as in toobj.d toObjFile()
            !(config.objfmt == OBJ_MSCOFF && target.isX86)) // -m32mscoff relocations are wrong
        {
            auto bzsave = bzeroSymbol;
            ad.sinit = getBzeroSymbol();

            // Ensure emitted only once per object file
            if (bzsave && bzeroSymbol != bzsave)
                assert(0);
        }
        else
        {
            auto stag = fake_classsym(Id.ClassInfo);

            Symbol* s;

            Module m = ad.getModule();
            if (m.filetype == FileType.c)
            {
                /* For ImportC structs, the module names are stripped from the mangled name.
                 * This leads to name collisions. Add the module name back in.
                 */
                import dmd.common.outbuffer : OutBuffer;
                OutBuffer buf;
                buf.writestring("__init");
                buf.writestring(m.toChars());
                s = toSymbolX(ad, buf.peekChars(), SC.extern_, stag.Stype, "Z");
            }
            else
                s = toSymbolX(ad, "__init", SC.extern_, stag.Stype, "Z");

            s.Sfl = FL.extern_;
            s.Sflags |= SFLnodebug;
            if (sd)
                s.Salignment = sd.alignment.isDefault() ? -1 : sd.alignment.get();
            if (isDllImported(ad))
                s.Sisym = createImport(s, ad.loc);
            ad.sinit = s;
        }
    }
    return cast(Symbol*)ad.sinit;
}

Symbol* toInitializer(EnumDeclaration ed)
{
    if (!ed.sinit)
    {
        auto stag = fake_classsym(Id.ClassInfo);
        assert(ed.ident);
        auto s = toSymbolX(ed, "__init", SC.extern_, stag.Stype, "Z");
        s.Sfl = FL.extern_;
        s.Sflags |= SFLnodebug;
        if (isDllImported(ed))
            s.Sisym = createImport(s, ed.loc);
        ed.sinit = s;
    }
    return ed.sinit;
}


/*****************************************************/
/*                   CTFE stuff                      */
/*****************************************************/

Symbol* toSymbol(StructLiteralExp sle)
{
    //printf("toSymbol() %p.sym: %p\n", sle, sle.sym);
    if (sle.sym)
        return cast(Symbol*)sle.sym;
    auto t = type_alloc(TYint);
    t.Tcount++;
    auto s = symbol_calloc("internal");
    s.Sclass = SC.static_;
    s.Sfl = FL.extern_;
    s.Sflags |= SFLnodebug;
    s.Stype = t;
    sle.sym = s;
    auto dtb = DtBuilder(0);
    Expression_toDt(sle, dtb);
    s.Sdt = dtb.finish();
    outdata(s);
    return cast(Symbol*)sle.sym;
}

Symbol* toSymbol(ClassReferenceExp cre)
{
    //printf("toSymbol() %p.value.sym: %p\n", cre, cre.value.sym);
    if (cre.value.origin.sym)
        return cast(Symbol*)cre.value.origin.sym;
    auto t = type_alloc(TYint);
    t.Tcount++;
    auto s = symbol_calloc("internal");
    s.Sclass = SC.static_;
    s.Sfl = FL.extern_;
    s.Sflags |= SFLnodebug;
    s.Stype = t;
    cre.value.sym = s;
    cre.value.origin.sym = s;
    auto dtb = DtBuilder(0);
    ClassReferenceExp_toInstanceDt(cre, dtb);
    s.Sdt = dtb.finish();
    outdata(s);
    return cast(Symbol*)cre.value.sym;
}

/**************************************
 * For C++ class cd, generate an instance of __cpp_type_info_ptr
 * and populate it with a pointer to the C++ type info.
 * Params:
 *      cd = C++ class
 * Returns:
 *      symbol of instance of __cpp_type_info_ptr
 */
Symbol* toSymbolCpp(ClassDeclaration cd)
{
    assert(cd.isCPPclass());

    /* For the symbol std::exception, the type info is _ZTISt9exception
     */
    if (!cd.cpp_type_info_ptr_sym)
    {
        __gshared Symbol* scpp;
        if (!scpp)
            scpp = fake_classsym(Id.cpp_type_info_ptr);
        Symbol* s = toSymbolX(cd, "_cpp_type_info_ptr", SC.comdat, scpp.Stype, "");
        s.Sfl = FL.data;
        s.Sflags |= SFLnodebug;
        auto dtb = DtBuilder(0);
        cpp_type_info_ptr_toDt(cd, dtb);
        s.Sdt = dtb.finish();
        outdata(s);
        cd.cpp_type_info_ptr_sym = s;
    }
    return cd.cpp_type_info_ptr_sym;
}

/**********************************
 * Generate Symbol of C++ type info for C++ class cd.
 * Params:
 *      cd = C++ class
 * Returns:
 *      Symbol of cd's rtti type info
 */
Symbol* toSymbolCppTypeInfo(ClassDeclaration cd)
{
    const id = target.cpp.typeInfoMangle(cd);
    auto s = symbol_calloc(id[0 .. strlen(id)]);
    s.Sclass = SC.extern_;
    s.Sfl = FL.extern_;          // C++ code will provide the definition
    s.Sflags |= SFLnodebug;
    auto t = type_fake(TYnptr);
    t.Tcount++;
    s.Stype = t;
    return s;
}

/**************************************
 * Turn a class type into a C Symbol.
 * Params:
 *      t = class type
 * Returns:
 *      corresponding Symbol
 */

Symbol* toSymbol(Type t)
{
    auto tc = t.isTypeClass();
    assert(tc);
    return toSymbol(tc.sym);
}

/**********************************
 * Converts a Loc to backend Srcpos
 * Params:
 *      loc = Source code location
 * Returns:
 *      Srcpos backend struct corresponding to the given location
 */
Srcpos toSrcpos(Loc loc)
{
    SourceLoc sl = SourceLoc(loc);
    return Srcpos.create(sl.filename.ptr, sl.line, sl.column);
}
