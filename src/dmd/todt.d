/**
 * Put initializers and objects created from CTFE into a `dt_t` data structure
 * so the backend puts them into the data segment.
 *
 * Copyright:   Copyright (C) 1999-2020 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 http://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/src/dmd/todt.d, _todt.d)
 * Documentation:  https://dlang.org/phobos/dmd_todt.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/todt.d
 */

module dmd.todt;

import core.stdc.stdio;
import core.stdc.string;

import dmd.root.array;
import dmd.root.rmem;

import dmd.aggregate;
import dmd.arraytypes;
import dmd.backend.type;
import dmd.complex;
import dmd.ctfeexpr;
import dmd.declaration;
import dmd.dclass;
import dmd.denum;
import dmd.dstruct;
import dmd.dsymbol;
import dmd.dtemplate;
import dmd.errors;
import dmd.expression;
import dmd.func;
import dmd.globals;
import dmd.init;
import dmd.mtype;
import dmd.target;
import dmd.tokens;
import dmd.tocsym;
import dmd.toobj;
import dmd.typesem;
import dmd.typinf;
import dmd.visitor;

import dmd.backend.cc;
import dmd.backend.dt;

alias toSymbol = dmd.tocsym.toSymbol;
alias toSymbol = dmd.glue.toSymbol;

/* A dt_t is a simple structure representing data to be added
 * to the data segment of the output object file. As such,
 * it is a list of initialized bytes, 0 data, and offsets from
 * other symbols.
 * Each D symbol and type can be converted into a dt_t so it can
 * be written to the data segment.
 */

alias Dts = Array!(dt_t*);

/* ================================================================ */

extern (C++) void Initializer_toDt(Initializer init, ref DtBuilder dtb)
{
    void visitError(ErrorInitializer)
    {
        assert(0);
    }

    void visitVoid(VoidInitializer vi)
    {
        /* Void initializers are set to 0, just because we need something
         * to set them to in the static data segment.
         */
        dtb.nzeros(cast(uint)vi.type.size());
    }

    void visitStruct(StructInitializer si)
    {
        //printf("StructInitializer.toDt('%s')\n", si.toChars());
        assert(0);
    }

    void visitArray(ArrayInitializer ai)
    {
        //printf("ArrayInitializer.toDt('%s')\n", ai.toChars());
        Type tb = ai.type.toBasetype();
        if (tb.ty == Tvector)
            tb = (cast(TypeVector)tb).basetype;

        Type tn = tb.nextOf().toBasetype();

        //printf("\tdim = %d\n", ai.dim);
        Dts dts;
        dts.setDim(ai.dim);
        dts.zero();

        uint size = cast(uint)tn.size();

        uint length = 0;
        foreach (i, idx; ai.index)
        {
            if (idx)
                length = cast(uint)idx.toInteger();
            //printf("\tindex[%d] = %p, length = %u, dim = %u\n", i, idx, length, ai.dim);

            assert(length < ai.dim);
            auto dtb = DtBuilder(0);
            Initializer_toDt(ai.value[i], dtb);
            if (dts[length])
                error(ai.loc, "duplicate initializations for index `%d`", length);
            dts[length] = dtb.finish();
            length++;
        }

        Expression edefault = tb.nextOf().defaultInit(Loc.initial);

        const n = tn.numberOfElems(ai.loc);

        dt_t* dtdefault = null;

        auto dtbarray = DtBuilder(0);
        foreach (dt; dts)
        {
            if (dt)
                dtbarray.cat(dt);
            else
            {
                if (!dtdefault)
                {
                    auto dtb = DtBuilder(0);
                    Expression_toDt(edefault, dtb);
                    dtdefault = dtb.finish();
                }
                dtbarray.repeat(dtdefault, n);
            }
        }
        switch (tb.ty)
        {
            case Tsarray:
            {
                TypeSArray ta = cast(TypeSArray)tb;
                size_t tadim = cast(size_t)ta.dim.toInteger();
                if (ai.dim < tadim)
                {
                    if (edefault.isBool(false))
                    {
                        // pad out end of array
                        dtbarray.nzeros(cast(uint)(size * (tadim - ai.dim)));
                    }
                    else
                    {
                        if (!dtdefault)
                        {
                            auto dtb = DtBuilder(0);
                            Expression_toDt(edefault, dtb);
                            dtdefault = dtb.finish();
                        }

                        const m = n * (tadim - ai.dim);
                        assert(m <= uint.max);
                        dtbarray.repeat(dtdefault, cast(uint)m);
                    }
                }
                else if (ai.dim > tadim)
                {
                    error(ai.loc, "too many initializers, %u, for array[%llu]", ai.dim, cast(ulong) tadim);
                }
                dtb.cat(dtbarray);
                break;
            }

            case Tpointer:
            case Tarray:
            {
                if (tb.ty == Tarray)
                    dtb.size(ai.dim);
                Symbol* s = dtb.dtoff(dtbarray.finish(), 0);
                if (tn.isMutable())
                    foreach (i; 0 .. ai.dim)
                        write_pointers(tn, s, size * cast(int)i);
                break;
            }

            default:
                assert(0);
        }
        dt_free(dtdefault);
    }

    void visitExp(ExpInitializer ei)
    {
        //printf("ExpInitializer.toDt() %s\n", ei.exp.toChars());
        ei.exp = ei.exp.optimize(WANTvalue);
        Expression_toDt(ei.exp, dtb);
    }

    final switch (init.kind)
    {
        case InitKind.void_:   return visitVoid  (cast(  VoidInitializer)init);
        case InitKind.error:   return visitError (cast( ErrorInitializer)init);
        case InitKind.struct_: return visitStruct(cast(StructInitializer)init);
        case InitKind.array:   return visitArray (cast( ArrayInitializer)init);
        case InitKind.exp:     return visitExp   (cast(   ExpInitializer)init);
    }
}

/* ================================================================ */

extern (C++) void Expression_toDt(Expression e, ref DtBuilder dtb)
{
    void nonConstExpError(Expression e)
    {
        version (none)
        {
            printf("Expression.toDt() %d\n", e.op);
        }
        e.error("non-constant expression `%s`", e.toChars());
        dtb.nzeros(1);
    }

    void visitCast(CastExp e)
    {
        version (none)
        {
            printf("CastExp.toDt() %d from %s to %s\n", e.op, e.e1.type.toChars(), e.type.toChars());
        }
        if (e.e1.type.ty == Tclass)
        {
            if (auto toc = e.type.isTypeClass())
            {
                if (auto toi = toc.sym.isInterfaceDeclaration()) // casting from class to interface
                {
                    auto cre1 = e.e1.isClassReferenceExp();
                    ClassDeclaration from = cre1.originalClass();
                    int off = 0;
                    const isbase = toi.isBaseOf(from, &off);
                    assert(isbase);
                    ClassReferenceExp_toDt(cre1, dtb, off);
                }
                else //casting from class to class
                {
                    Expression_toDt(e.e1, dtb);
                }
                return;
            }
        }
        nonConstExpError(e);
    }

    void visitAddr(AddrExp e)
    {
        version (none)
        {
            printf("AddrExp.toDt() %d\n", e.op);
        }
        if (auto sl = e.e1.isStructLiteralExp())
        {
            Symbol* s = toSymbol(sl);
            dtb.xoff(s, 0);
            if (sl.type.isMutable())
                write_pointers(sl.type, s, 0);
            return;
        }
        nonConstExpError(e);
    }

    void visitInteger(IntegerExp e)
    {
        //printf("IntegerExp.toDt() %d\n", e.op);
        const sz = cast(uint)e.type.size();
        if (auto value = e.getInteger())
            dtb.nbytes(sz, cast(char*)&value);
        else
            dtb.nzeros(sz);
    }

    void visitReal(RealExp e)
    {
        //printf("RealExp.toDt(%Lg)\n", e.value);
        switch (e.type.toBasetype().ty)
        {
            case Tfloat32:
            case Timaginary32:
            {
                auto fvalue = cast(float)e.value;
                dtb.nbytes(4, cast(char*)&fvalue);
                break;
            }

            case Tfloat64:
            case Timaginary64:
            {
                auto dvalue = cast(double)e.value;
                dtb.nbytes(8, cast(char*)&dvalue);
                break;
            }

            case Tfloat80:
            case Timaginary80:
            {
                auto evalue = e.value;
                dtb.nbytes(target.realsize - target.realpad, cast(char*)&evalue);
                dtb.nzeros(target.realpad);
                break;
            }

            default:
                printf("%s, e.type=%s\n", e.toChars(), e.type.toChars());
                assert(0);
        }
    }

    void visitComplex(ComplexExp e)
    {
        //printf("ComplexExp.toDt() '%s'\n", e.toChars());
        switch (e.type.toBasetype().ty)
        {
            case Tcomplex32:
            {
                auto fvalue = cast(float)creall(e.value);
                dtb.nbytes(4, cast(char*)&fvalue);
                fvalue = cast(float)cimagl(e.value);
                dtb.nbytes(4, cast(char*)&fvalue);
                break;
            }

            case Tcomplex64:
            {
                auto dvalue = cast(double)creall(e.value);
                dtb.nbytes(8, cast(char*)&dvalue);
                dvalue = cast(double)cimagl(e.value);
                dtb.nbytes(8, cast(char*)&dvalue);
                break;
            }

            case Tcomplex80:
            {
                auto evalue = creall(e.value);
                dtb.nbytes(target.realsize - target.realpad, cast(char*)&evalue);
                dtb.nzeros(target.realpad);
                evalue = cimagl(e.value);
                dtb.nbytes(target.realsize - target.realpad, cast(char*)&evalue);
                dtb.nzeros(target.realpad);
                break;
            }

            default:
                assert(0);
        }
    }

    void visitNull(NullExp e)
    {
        assert(e.type);
        dtb.nzeros(cast(uint)e.type.size());
    }

    void visitString(StringExp e)
    {
        //printf("StringExp.toDt() '%s', type = %s\n", e.toChars(), e.type.toChars());
        Type t = e.type.toBasetype();

        // BUG: should implement some form of static string pooling
        const n = cast(int)e.numberOfCodeUnits();
        const(char)* p;
        char* q;
        if (e.sz == 1)
            p = e.peekString().ptr;
        else
        {
            q = cast(char*)mem.xmalloc(n * e.sz);
            e.writeTo(q, false);
            p = q;
        }

        switch (t.ty)
        {
            case Tarray:
                dtb.size(n);
                goto case Tpointer;

            case Tpointer:
                if (e.sz == 1)
                {
                    import dmd.e2ir : toStringSymbol;
                    import dmd.glue : totym;
                    Symbol* s = toStringSymbol(p, n, e.sz);
                    dtb.xoff(s, 0);
                }
                else
                {
                    ubyte pow2 = e.sz == 4 ? 2 : 1;
                    dtb.abytes(0, n * e.sz, p, cast(uint)e.sz, pow2);
                }
                break;

            case Tsarray:
            {
                auto tsa = t.isTypeSArray();

                dtb.nbytes(n * e.sz, p);
                if (tsa.dim)
                {
                    dinteger_t dim = tsa.dim.toInteger();
                    if (n < dim)
                    {
                        // Pad remainder with 0
                        dtb.nzeros(cast(uint)((dim - n) * tsa.next.size()));
                    }
                }
                break;
            }

            default:
                printf("StringExp.toDt(type = %s)\n", e.type.toChars());
                assert(0);
        }
        mem.xfree(q);
    }

    void visitArrayLiteral(ArrayLiteralExp e)
    {
        //printf("ArrayLiteralExp.toDt() '%s', type = %s\n", e.toChars(), e.type.toChars());

        auto dtbarray = DtBuilder(0);
        foreach (i; 0 .. e.elements.dim)
        {
            Expression_toDt(e[i], dtbarray);
        }

        Type t = e.type.toBasetype();
        switch (t.ty)
        {
            case Tsarray:
                dtb.cat(dtbarray);
                break;

            case Tarray:
                dtb.size(e.elements.dim);
                goto case Tpointer;

            case Tpointer:
            {
                if (auto d = dtbarray.finish())
                    dtb.dtoff(d, 0);
                else
                    dtb.size(0);

                break;
            }

            default:
                assert(0);
        }
    }

    void visitStructLiteral(StructLiteralExp sle)
    {
        //printf("StructLiteralExp.toDt() %s, ctfe = %d\n", sle.toChars(), sle.ownedByCtfe);
        assert(sle.sd.nonHiddenFields() <= sle.elements.dim);
        membersToDt(sle.sd, dtb, sle.elements, 0, null);
    }

    void visitSymOff(SymOffExp e)
    {
        //printf("SymOffExp.toDt('%s')\n", e.var.toChars());
        assert(e.var);
        if (!(e.var.isDataseg() || e.var.isCodeseg()) ||
            e.var.needThis() ||
            e.var.isThreadlocal())
        {
            return nonConstExpError(e);
        }
        dtb.xoff(toSymbol(e.var), cast(uint)e.offset);
    }

    void visitVar(VarExp e)
    {
        //printf("VarExp.toDt() %d\n", e.op);

        if (auto v = e.var.isVarDeclaration())
        {
            if ((v.isConst() || v.isImmutable()) &&
                e.type.toBasetype().ty != Tsarray && v._init)
            {
                e.error("recursive reference `%s`", e.toChars());
                return;
            }
            v.inuse++;
            Initializer_toDt(v._init, dtb);
            v.inuse--;
            return;
        }

        if (auto sd = e.var.isSymbolDeclaration())
            if (sd.dsym)
            {
                StructDeclaration_toDt(sd.dsym, dtb);
                return;
            }

        return nonConstExpError(e);
    }

    void visitFunc(FuncExp e)
    {
        //printf("FuncExp.toDt() %d\n", e.op);
        if (e.fd.tok == TOK.reserved && e.type.ty == Tpointer)
        {
            // change to non-nested
            e.fd.tok = TOK.function_;
            e.fd.vthis = null;
        }
        Symbol *s = toSymbol(e.fd);
        toObjFile(e.fd, false);
        if (e.fd.tok == TOK.delegate_)
            dtb.size(0);
        dtb.xoff(s, 0);
    }

    void visitVector(VectorExp e)
    {
        //printf("VectorExp.toDt() %s\n", e.toChars());
        foreach (i; 0 .. e.dim)
        {
            Expression elem;
            if (auto ale = e.e1.isArrayLiteralExp())
                elem = ale[i];
            else
                elem = e.e1;
            Expression_toDt(elem, dtb);
        }
    }

    void visitClassReference(ClassReferenceExp e)
    {
        auto to = e.type.toBasetype().isTypeClass().sym.isInterfaceDeclaration();

        if (to) //Static typeof this literal is an interface. We must add offset to symbol
        {
            ClassDeclaration from = e.originalClass();
            int off = 0;
            const isbase = to.isBaseOf(from, &off);
            assert(isbase);
            ClassReferenceExp_toDt(e, dtb, off);
        }
        else
            ClassReferenceExp_toDt(e, dtb, 0);
    }

    void visitTypeid(TypeidExp e)
    {
        if (Type t = isType(e.obj))
        {
            genTypeInfo(e.loc, t, null);
            Symbol *s = toSymbol(t.vtinfo);
            dtb.xoff(s, 0);
            return;
        }
        assert(0);
    }

    switch (e.op)
    {
        default:                 return nonConstExpError(e);
        case TOK.cast_:          return visitCast          (e.isCastExp());
        case TOK.address:        return visitAddr          (e.isAddrExp());
        case TOK.int64:          return visitInteger       (e.isIntegerExp());
        case TOK.float64:        return visitReal          (e.isRealExp());
        case TOK.complex80:      return visitComplex       (e.isComplexExp());
        case TOK.null_:          return visitNull          (e.isNullExp());
        case TOK.string_:        return visitString        (e.isStringExp());
        case TOK.arrayLiteral:   return visitArrayLiteral  (e.isArrayLiteralExp());
        case TOK.structLiteral:  return visitStructLiteral (e.isStructLiteralExp());
        case TOK.symbolOffset:   return visitSymOff        (e.isSymOffExp());
        case TOK.variable:       return visitVar           (e.isVarExp());
        case TOK.function_:      return visitFunc          (e.isFuncExp());
        case TOK.vector:         return visitVector        (e.isVectorExp());
        case TOK.classReference: return visitClassReference(e.isClassReferenceExp());
        case TOK.typeid_:        return visitTypeid        (e.isTypeidExp());
    }
}

/* ================================================================= */

// Generate the data for the static initializer.

extern (C++) void ClassDeclaration_toDt(ClassDeclaration cd, ref DtBuilder dtb)
{
    //printf("ClassDeclaration.toDt(this = '%s')\n", cd.toChars());

    membersToDt(cd, dtb, null, 0, cd);

    //printf("-ClassDeclaration.toDt(this = '%s')\n", cd.toChars());
}

extern (C++) void StructDeclaration_toDt(StructDeclaration sd, ref DtBuilder dtb)
{
    //printf("+StructDeclaration.toDt(), this='%s'\n", sd.toChars());
    membersToDt(sd, dtb, null, 0, null);

    //printf("-StructDeclaration.toDt(), this='%s'\n", sd.toChars());
}

/******************************
 * Generate data for instance of __cpp_type_info_ptr that refers
 * to the C++ RTTI symbol for cd.
 * Params:
 *      cd = C++ class
 *      dtb = data table builder
 */
extern (C++) void cpp_type_info_ptr_toDt(ClassDeclaration cd, ref DtBuilder dtb)
{
    //printf("cpp_type_info_ptr_toDt(this = '%s')\n", cd.toChars());
    assert(cd.isCPPclass());

    // Put in first two members, the vtbl[] and the monitor
    dtb.xoff(toVtblSymbol(ClassDeclaration.cpp_type_info_ptr), 0);
    if (ClassDeclaration.cpp_type_info_ptr.hasMonitor())
        dtb.size(0);             // monitor

    // Create symbol for C++ type info
    Symbol *s = toSymbolCppTypeInfo(cd);

    // Put in address of cd's C++ type info
    dtb.xoff(s, 0);

    //printf("-cpp_type_info_ptr_toDt(this = '%s')\n", cd.toChars());
}

/****************************************************
 * Put out initializers of ad.fields[].
 * Although this is consistent with the elements[] version, we
 * have to use this optimized version to reduce memory footprint.
 * Params:
 *      ad = aggregate with members
 *      pdt = tail of initializer list to start appending initialized data to
 *      elements = values to use as initializers, null means use default initializers
 *      firstFieldIndex = starting place is elements[firstFieldIndex]
 *      concreteType = structs: null, classes: most derived class
 *      ppb = pointer that moves through BaseClass[] from most derived class
 * Returns:
 *      updated tail of dt_t list
 */

private void membersToDt(AggregateDeclaration ad, ref DtBuilder dtb,
        Expressions* elements, size_t firstFieldIndex,
        ClassDeclaration concreteType,
        BaseClass*** ppb = null)
{
    //printf("membersToDt(ad = '%s', concrete = '%s', ppb = %p)\n", ad.toChars(), concreteType ? concreteType.toChars() : "null", ppb);
    ClassDeclaration cd = ad.isClassDeclaration();
    version (none)
    {
        printf(" interfaces.length = %d\n", cast(int)cd.interfaces.length);
        foreach (i, b; cd.vtblInterfaces[])
        {
            printf("  vbtblInterfaces[%d] b = %p, b.sym = %s\n", cast(int)i, b, b.sym.toChars());
        }
    }

    /* Order:
     *  { base class } or { __vptr, __monitor }
     *  interfaces
     *  fields
     */

    uint offset;
    if (cd)
    {
        if (ClassDeclaration cdb = cd.baseClass)
        {
            size_t index = 0;
            for (ClassDeclaration c = cdb.baseClass; c; c = c.baseClass)
                index += c.fields.dim;
            membersToDt(cdb, dtb, elements, index, concreteType);
            offset = cdb.structsize;
        }
        else if (InterfaceDeclaration id = cd.isInterfaceDeclaration())
        {
            offset = (**ppb).offset;
            if (id.vtblInterfaces.dim == 0)
            {
                BaseClass* b = **ppb;
                //printf("  Interface %s, b = %p\n", id.toChars(), b);
                ++(*ppb);
                for (ClassDeclaration cd2 = concreteType; 1; cd2 = cd2.baseClass)
                {
                    assert(cd2);
                    uint csymoffset = baseVtblOffset(cd2, b);
                    //printf("    cd2 %s csymoffset = x%x\n", cd2 ? cd2.toChars() : "null", csymoffset);
                    if (csymoffset != ~0)
                    {
                        dtb.xoff(toSymbol(cd2), csymoffset);
                        offset += target.ptrsize;
                        break;
                    }
                }
            }
        }
        else
        {
            dtb.xoff(toVtblSymbol(concreteType), 0);  // __vptr
            offset = target.ptrsize;
            if (cd.hasMonitor())
            {
                dtb.size(0);              // __monitor
                offset += target.ptrsize;
            }
        }

        // Interface vptr initializations
        toSymbol(cd);                                         // define csym

        BaseClass** pb;
        if (!ppb)
        {
            pb = (*cd.vtblInterfaces)[].ptr;
            ppb = &pb;
        }

        foreach (si; cd.interfaces[])
        {
            BaseClass* b = **ppb;
            if (offset < b.offset)
                dtb.nzeros(b.offset - offset);
            membersToDt(si.sym, dtb, elements, firstFieldIndex, concreteType, ppb);
            //printf("b.offset = %d, b.sym.structsize = %d\n", (int)b.offset, (int)b.sym.structsize);
            offset = b.offset + b.sym.structsize;
        }
    }
    else
        offset = 0;

    assert(!elements ||
           firstFieldIndex <= elements.dim &&
           firstFieldIndex + ad.fields.dim <= elements.dim);

    foreach (i, field; ad.fields)
    {
        if (elements && !(*elements)[firstFieldIndex + i])
            continue;

        if (!elements || !(*elements)[firstFieldIndex + i])
        {
            if (field._init && field._init.isVoidInitializer())
                continue;
        }

        VarDeclaration vd;
        size_t k;
        foreach (j; i .. ad.fields.length)
        {
            VarDeclaration v2 = ad.fields[j];
            if (v2.offset < offset)
                continue;

            if (elements && !(*elements)[firstFieldIndex + j])
                continue;

            if (!elements || !(*elements)[firstFieldIndex + j])
            {
                if (v2._init && v2._init.isVoidInitializer())
                    continue;
            }

            // find the nearest field
            if (!vd || v2.offset < vd.offset)
            {
                vd = v2;
                k = j;
                assert(vd == v2 || !vd.isOverlappedWith(v2));
            }
        }
        if (!vd)
            continue;

        assert(offset <= vd.offset);
        if (offset < vd.offset)
            dtb.nzeros(vd.offset - offset);

        auto dtbx = DtBuilder(0);
        if (elements)
        {
            Expression e = (*elements)[firstFieldIndex + k];
            if (auto tsa = vd.type.toBasetype().isTypeSArray())
                toDtElem(tsa, dtbx, e);
            else
                Expression_toDt(e, dtbx);    // convert e to an initializer dt
        }
        else
        {
            if (Initializer init = vd._init)
            {
                //printf("\t\t%s has initializer %s\n", vd.toChars(), init.toChars());
                if (init.isVoidInitializer())
                    continue;

                assert(vd.semanticRun >= PASS.semantic2done);

                auto ei = init.isExpInitializer();
                auto tsa = vd.type.toBasetype().isTypeSArray();
                if (ei && tsa)
                    toDtElem(tsa, dtbx, ei.exp);
                else
                    Initializer_toDt(init, dtbx);
            }
            else if (offset <= vd.offset)
            {
                //printf("\t\tdefault initializer\n");
                Type_toDt(vd.type, dtbx);
            }
            if (dtbx.isZeroLength())
                continue;
        }

        dtb.cat(dtbx);
        offset = cast(uint)(vd.offset + vd.type.size());
    }

    if (offset < ad.structsize)
        dtb.nzeros(ad.structsize - offset);
}


/* ================================================================= */

extern (C++) void Type_toDt(Type t, ref DtBuilder dtb)
{
    switch (t.ty)
    {
        case Tvector:
            toDtElem(t.isTypeVector().basetype.isTypeSArray(), dtb, null);
            break;

        case Tsarray:
            toDtElem(t.isTypeSArray(), dtb, null);
            break;

        case Tstruct:
            StructDeclaration_toDt(t.isTypeStruct().sym, dtb);
            break;

        default:
            Expression_toDt(t.defaultInit(Loc.initial), dtb);
            break;
    }
}

private void toDtElem(TypeSArray tsa, ref DtBuilder dtb, Expression e)
{
    //printf("TypeSArray.toDtElem() tsa = %s\n", tsa.toChars());
    if (tsa.size(Loc.initial) == 0)
    {
        dtb.nzeros(0);
    }
    else
    {
        size_t len = cast(size_t)tsa.dim.toInteger();
        assert(len);
        Type tnext = tsa.next;
        Type tbn = tnext.toBasetype();
        Type ten = e ? e.type : null;
        if (ten && (ten.ty == Tsarray || ten.ty == Tarray))
            ten = ten.nextOf();
        while (tbn.ty == Tsarray && (!e || !tbn.equivalent(ten)))
        {
            len *= tbn.isTypeSArray().dim.toInteger();
            tnext = tbn.nextOf();
            tbn = tnext.toBasetype();
        }
        if (!e)                             // if not already supplied
            e = tsa.defaultInit(Loc.initial);    // use default initializer

        if (!e.type.implicitConvTo(tnext))    // https://issues.dlang.org/show_bug.cgi?id=14996
        {
            // https://issues.dlang.org/show_bug.cgi?id=1914
            // https://issues.dlang.org/show_bug.cgi?id=3198
            if (auto se = e.isStringExp())
                len /= se.numberOfCodeUnits();
            else if (auto ae = e.isArrayLiteralExp())
                len /= ae.elements.dim;
        }

        auto dtb2 = DtBuilder(0);
        Expression_toDt(e, dtb2);
        dt_t* dt2 = dtb2.finish();
        assert(len <= uint.max);
        dtb.repeat(dt2, cast(uint)len);
    }
}

/*****************************************************/
/*                   CTFE stuff                      */
/*****************************************************/

private void ClassReferenceExp_toDt(ClassReferenceExp e, ref DtBuilder dtb, int off)
{
    //printf("ClassReferenceExp.toDt() %d\n", e.op);
    Symbol* s = toSymbol(e);
    dtb.xoff(s, off);
    if (e.type.isMutable())
        write_instance_pointers(e.type, s, 0);
}

extern (C++) void ClassReferenceExp_toInstanceDt(ClassReferenceExp ce, ref DtBuilder dtb)
{
    //printf("ClassReferenceExp.toInstanceDt() %d\n", ce.op);
    ClassDeclaration cd = ce.originalClass();

    // Put in the rest
    size_t firstFieldIndex = 0;
    for (ClassDeclaration c = cd.baseClass; c; c = c.baseClass)
        firstFieldIndex += c.fields.dim;
    membersToDt(cd, dtb, ce.value.elements, firstFieldIndex, cd);
}

/****************************************************
 */
private extern (C++) class TypeInfoDtVisitor : Visitor
{
    DtBuilder* dtb;

    /*
     * Used in TypeInfo*.toDt to verify the runtime TypeInfo sizes
     */
    static void verifyStructSize(ClassDeclaration typeclass, size_t expected)
    {
        if (typeclass.structsize != expected)
        {
            debug
            {
                printf("expected = x%x, %s.structsize = x%x\n", cast(uint)expected,
                    typeclass.toChars(), cast(uint)typeclass.structsize);
            }
            error(typeclass.loc, "`%s`: mismatch between compiler (%d bytes) and object.d or object.di (%d bytes) found. Check installation and import paths with -v compiler switch.",
                typeclass.toChars(), cast(uint)expected, cast(uint)typeclass.structsize);
            fatal();
        }
    }

    this(ref DtBuilder dtb)
    {
        this.dtb = &dtb;
    }

    alias visit = Visitor.visit;

    override void visit(TypeInfoDeclaration d)
    {
        //printf("TypeInfoDeclaration.toDt() %s\n", toChars());
        verifyStructSize(Type.dtypeinfo, 2 * target.ptrsize);

        dtb.xoff(toVtblSymbol(Type.dtypeinfo), 0);        // vtbl for TypeInfo
        if (Type.dtypeinfo.hasMonitor())
            dtb.size(0);                                  // monitor
    }

    override void visit(TypeInfoConstDeclaration d)
    {
        //printf("TypeInfoConstDeclaration.toDt() %s\n", toChars());
        verifyStructSize(Type.typeinfoconst, 3 * target.ptrsize);

        dtb.xoff(toVtblSymbol(Type.typeinfoconst), 0);    // vtbl for TypeInfo_Const
        if (Type.typeinfoconst.hasMonitor())
            dtb.size(0);                                  // monitor
        Type tm = d.tinfo.mutableOf();
        tm = tm.merge();
        genTypeInfo(d.loc, tm, null);
        dtb.xoff(toSymbol(tm.vtinfo), 0);
    }

    override void visit(TypeInfoInvariantDeclaration d)
    {
        //printf("TypeInfoInvariantDeclaration.toDt() %s\n", toChars());
        verifyStructSize(Type.typeinfoinvariant, 3 * target.ptrsize);

        dtb.xoff(toVtblSymbol(Type.typeinfoinvariant), 0);    // vtbl for TypeInfo_Invariant
        if (Type.typeinfoinvariant.hasMonitor())
            dtb.size(0);                                      // monitor
        Type tm = d.tinfo.mutableOf();
        tm = tm.merge();
        genTypeInfo(d.loc, tm, null);
        dtb.xoff(toSymbol(tm.vtinfo), 0);
    }

    override void visit(TypeInfoSharedDeclaration d)
    {
        //printf("TypeInfoSharedDeclaration.toDt() %s\n", toChars());
        verifyStructSize(Type.typeinfoshared, 3 * target.ptrsize);

        dtb.xoff(toVtblSymbol(Type.typeinfoshared), 0);   // vtbl for TypeInfo_Shared
        if (Type.typeinfoshared.hasMonitor())
            dtb.size(0);                                 // monitor
        Type tm = d.tinfo.unSharedOf();
        tm = tm.merge();
        genTypeInfo(d.loc, tm, null);
        dtb.xoff(toSymbol(tm.vtinfo), 0);
    }

    override void visit(TypeInfoWildDeclaration d)
    {
        //printf("TypeInfoWildDeclaration.toDt() %s\n", toChars());
        verifyStructSize(Type.typeinfowild, 3 * target.ptrsize);

        dtb.xoff(toVtblSymbol(Type.typeinfowild), 0); // vtbl for TypeInfo_Wild
        if (Type.typeinfowild.hasMonitor())
            dtb.size(0);                              // monitor
        Type tm = d.tinfo.mutableOf();
        tm = tm.merge();
        genTypeInfo(d.loc, tm, null);
        dtb.xoff(toSymbol(tm.vtinfo), 0);
    }

    override void visit(TypeInfoEnumDeclaration d)
    {
        //printf("TypeInfoEnumDeclaration.toDt()\n");
        verifyStructSize(Type.typeinfoenum, 7 * target.ptrsize);

        dtb.xoff(toVtblSymbol(Type.typeinfoenum), 0); // vtbl for TypeInfo_Enum
        if (Type.typeinfoenum.hasMonitor())
            dtb.size(0);                              // monitor

        assert(d.tinfo.ty == Tenum);

        TypeEnum tc = cast(TypeEnum)d.tinfo;
        EnumDeclaration sd = tc.sym;

        /* Put out:
         *  TypeInfo base;
         *  string name;
         *  void[] m_init;
         */

        // TypeInfo for enum members
        if (sd.memtype)
        {
            genTypeInfo(d.loc, sd.memtype, null);
            dtb.xoff(toSymbol(sd.memtype.vtinfo), 0);
        }
        else
            dtb.size(0);

        // string name;
        const(char)* name = sd.toPrettyChars();
        size_t namelen = strlen(name);
        dtb.size(namelen);
        dtb.xoff(d.csym, Type.typeinfoenum.structsize);

        // void[] init;
        if (!sd.members || d.tinfo.isZeroInit(Loc.initial))
        {
            // 0 initializer, or the same as the base type
            dtb.size(0);                     // init.length
            dtb.size(0);                     // init.ptr
        }
        else
        {
            dtb.size(sd.type.size());      // init.length
            dtb.xoff(toInitializer(sd), 0);    // init.ptr
        }

        // Put out name[] immediately following TypeInfo_Enum
        dtb.nbytes(cast(uint)(namelen + 1), name);
    }

    override void visit(TypeInfoPointerDeclaration d)
    {
        //printf("TypeInfoPointerDeclaration.toDt()\n");
        verifyStructSize(Type.typeinfopointer, 3 * target.ptrsize);

        dtb.xoff(toVtblSymbol(Type.typeinfopointer), 0);  // vtbl for TypeInfo_Pointer
        if (Type.typeinfopointer.hasMonitor())
            dtb.size(0);                                  // monitor

        auto tc = d.tinfo.isTypePointer();

        genTypeInfo(d.loc, tc.next, null);
        dtb.xoff(toSymbol(tc.next.vtinfo), 0); // TypeInfo for type being pointed to
    }

    override void visit(TypeInfoArrayDeclaration d)
    {
        //printf("TypeInfoArrayDeclaration.toDt()\n");
        verifyStructSize(Type.typeinfoarray, 3 * target.ptrsize);

        dtb.xoff(toVtblSymbol(Type.typeinfoarray), 0);    // vtbl for TypeInfo_Array
        if (Type.typeinfoarray.hasMonitor())
            dtb.size(0);                                  // monitor

        auto tc = d.tinfo.isTypeDArray();

        genTypeInfo(d.loc, tc.next, null);
        dtb.xoff(toSymbol(tc.next.vtinfo), 0); // TypeInfo for array of type
    }

    override void visit(TypeInfoStaticArrayDeclaration d)
    {
        //printf("TypeInfoStaticArrayDeclaration.toDt()\n");
        verifyStructSize(Type.typeinfostaticarray, 4 * target.ptrsize);

        dtb.xoff(toVtblSymbol(Type.typeinfostaticarray), 0);  // vtbl for TypeInfo_StaticArray
        if (Type.typeinfostaticarray.hasMonitor())
            dtb.size(0);                                      // monitor

        auto tc = d.tinfo.isTypeSArray();

        genTypeInfo(d.loc, tc.next, null);
        dtb.xoff(toSymbol(tc.next.vtinfo), 0);   // TypeInfo for array of type

        dtb.size(tc.dim.toInteger());          // length
    }

    override void visit(TypeInfoVectorDeclaration d)
    {
        //printf("TypeInfoVectorDeclaration.toDt()\n");
        verifyStructSize(Type.typeinfovector, 3 * target.ptrsize);

        dtb.xoff(toVtblSymbol(Type.typeinfovector), 0);   // vtbl for TypeInfo_Vector
        if (Type.typeinfovector.hasMonitor())
            dtb.size(0);                                  // monitor

        auto tc = d.tinfo.isTypeVector();

        genTypeInfo(d.loc, tc.basetype, null);
        dtb.xoff(toSymbol(tc.basetype.vtinfo), 0); // TypeInfo for equivalent static array
    }

    override void visit(TypeInfoAssociativeArrayDeclaration d)
    {
        //printf("TypeInfoAssociativeArrayDeclaration.toDt()\n");
        verifyStructSize(Type.typeinfoassociativearray, 4 * target.ptrsize);

        dtb.xoff(toVtblSymbol(Type.typeinfoassociativearray), 0); // vtbl for TypeInfo_AssociativeArray
        if (Type.typeinfoassociativearray.hasMonitor())
            dtb.size(0);                    // monitor

        auto tc = d.tinfo.isTypeAArray();

        genTypeInfo(d.loc, tc.next, null);
        dtb.xoff(toSymbol(tc.next.vtinfo), 0);   // TypeInfo for array of type

        genTypeInfo(d.loc, tc.index, null);
        dtb.xoff(toSymbol(tc.index.vtinfo), 0);  // TypeInfo for array of type
    }

    override void visit(TypeInfoFunctionDeclaration d)
    {
        //printf("TypeInfoFunctionDeclaration.toDt()\n");
        verifyStructSize(Type.typeinfofunction, 5 * target.ptrsize);

        dtb.xoff(toVtblSymbol(Type.typeinfofunction), 0); // vtbl for TypeInfo_Function
        if (Type.typeinfofunction.hasMonitor())
            dtb.size(0);                                  // monitor

        auto tc = d.tinfo.isTypeFunction();

        genTypeInfo(d.loc, tc.next, null);
        dtb.xoff(toSymbol(tc.next.vtinfo), 0); // TypeInfo for function return value

        const name = d.tinfo.deco;
        assert(name);
        const namelen = strlen(name);
        dtb.size(namelen);
        dtb.xoff(d.csym, Type.typeinfofunction.structsize);

        // Put out name[] immediately following TypeInfo_Function
        dtb.nbytes(cast(uint)(namelen + 1), name);
    }

    override void visit(TypeInfoDelegateDeclaration d)
    {
        //printf("TypeInfoDelegateDeclaration.toDt()\n");
        verifyStructSize(Type.typeinfodelegate, 5 * target.ptrsize);

        dtb.xoff(toVtblSymbol(Type.typeinfodelegate), 0); // vtbl for TypeInfo_Delegate
        if (Type.typeinfodelegate.hasMonitor())
            dtb.size(0);                                  // monitor

        auto tc = d.tinfo.isTypeDelegate();

        genTypeInfo(d.loc, tc.next.nextOf(), null);
        dtb.xoff(toSymbol(tc.next.nextOf().vtinfo), 0); // TypeInfo for delegate return value

        const name = d.tinfo.deco;
        assert(name);
        const namelen = strlen(name);
        dtb.size(namelen);
        dtb.xoff(d.csym, Type.typeinfodelegate.structsize);

        // Put out name[] immediately following TypeInfo_Delegate
        dtb.nbytes(cast(uint)(namelen + 1), name);
    }

    override void visit(TypeInfoStructDeclaration d)
    {
        //printf("TypeInfoStructDeclaration.toDt() '%s'\n", d.toChars());
        if (global.params.is64bit)
            verifyStructSize(Type.typeinfostruct, 17 * target.ptrsize);
        else
            verifyStructSize(Type.typeinfostruct, 15 * target.ptrsize);

        dtb.xoff(toVtblSymbol(Type.typeinfostruct), 0); // vtbl for TypeInfo_Struct
        if (Type.typeinfostruct.hasMonitor())
            dtb.size(0);                                // monitor

        auto tc = d.tinfo.isTypeStruct();
        StructDeclaration sd = tc.sym;

        if (!sd.members)
            return;

        if (TemplateInstance ti = sd.isInstantiated())
        {
            if (!ti.needsCodegen())
            {
                assert(ti.minst || sd.requestTypeInfo);

                /* ti.toObjFile() won't get called. So, store these
                 * member functions into object file in here.
                 */
                if (sd.xeq && sd.xeq != StructDeclaration.xerreq)
                    toObjFile(sd.xeq, global.params.multiobj);
                if (sd.xcmp && sd.xcmp != StructDeclaration.xerrcmp)
                    toObjFile(sd.xcmp, global.params.multiobj);
                if (FuncDeclaration ftostr = search_toString(sd))
                    toObjFile(ftostr, global.params.multiobj);
                if (sd.xhash)
                    toObjFile(sd.xhash, global.params.multiobj);
                if (sd.postblit)
                    toObjFile(sd.postblit, global.params.multiobj);
                if (sd.dtor)
                    toObjFile(sd.dtor, global.params.multiobj);
            }
        }

        /* Put out:
         *  char[] name;
         *  void[] init;
         *  hash_t function(in void*) xtoHash;
         *  bool function(in void*, in void*) xopEquals;
         *  int function(in void*, in void*) xopCmp;
         *  string function(const(void)*) xtoString;
         *  StructFlags m_flags;
         *  //xgetMembers;
         *  xdtor;
         *  xpostblit;
         *  uint m_align;
         *  version (X86_64)
         *      TypeInfo m_arg1;
         *      TypeInfo m_arg2;
         *  xgetRTInfo
         */

        const name = sd.toPrettyChars();
        const namelen = strlen(name);
        dtb.size(namelen);
        dtb.xoff(d.csym, Type.typeinfostruct.structsize);

        // void[] init;
        dtb.size(sd.structsize);            // init.length
        if (sd.isZeroInit())
            dtb.size(0);                     // null for 0 initialization
        else
            dtb.xoff(toInitializer(sd), 0);    // init.ptr

        if (FuncDeclaration fd = sd.xhash)
        {
            dtb.xoff(toSymbol(fd), 0);
            TypeFunction tf = cast(TypeFunction)fd.type;
            assert(tf.ty == Tfunction);
            /* I'm a little unsure this is the right way to do it. Perhaps a better
             * way would to automatically add these attributes to any struct member
             * function with the name "toHash".
             * So I'm leaving this here as an experiment for the moment.
             */
            if (!tf.isnothrow || tf.trust == TRUST.system /*|| tf.purity == PURE.impure*/)
                warning(fd.loc, "toHash() must be declared as extern (D) size_t toHash() const nothrow @safe, not %s", tf.toChars());
        }
        else
            dtb.size(0);

        if (sd.xeq)
            dtb.xoff(toSymbol(sd.xeq), 0);
        else
            dtb.size(0);

        if (sd.xcmp)
            dtb.xoff(toSymbol(sd.xcmp), 0);
        else
            dtb.size(0);

        if (FuncDeclaration fd = search_toString(sd))
        {
            dtb.xoff(toSymbol(fd), 0);
        }
        else
            dtb.size(0);

        // StructFlags m_flags;
        StructFlags m_flags = StructFlags.none;
        if (tc.hasPointers()) m_flags |= StructFlags.hasPointers;
        dtb.size(m_flags);

        version (none)
        {
            // xgetMembers
            if (auto sgetmembers = sd.findGetMembers())
                dtb.xoff(toSymbol(sgetmembers), 0);
            else
                dtb.size(0);                     // xgetMembers
        }

        // xdtor
        if (auto sdtor = sd.tidtor)
            dtb.xoff(toSymbol(sdtor), 0);
        else
            dtb.size(0);                     // xdtor

        // xpostblit
        FuncDeclaration spostblit = sd.postblit;
        if (spostblit && !(spostblit.storage_class & STC.disable))
            dtb.xoff(toSymbol(spostblit), 0);
        else
            dtb.size(0);                     // xpostblit

        // uint m_align;
        dtb.size(tc.alignsize());

        if (global.params.is64bit)
        {
            foreach (i; 0 .. 2)
            {
                // m_argi
                if (auto t = sd.argType(i))
                {
                    genTypeInfo(d.loc, t, null);
                    dtb.xoff(toSymbol(t.vtinfo), 0);
                }
                else
                    dtb.size(0);
            }
        }

        if (Type.rtinfo && !sd.getRTInfo)
            error(sd.loc, "ICE: RTInfo not evaluated for %s", sd.toPrettyChars(true));

        // xgetRTInfo
        if (sd.getRTInfo)
        {
            Expression_toDt(sd.getRTInfo, *dtb);
        }
        else if (m_flags & StructFlags.hasPointers)
            dtb.size(1);
        else
            dtb.size(0);

        // Put out name[] immediately following TypeInfo_Struct
        dtb.nbytes(cast(uint)(namelen + 1), name);
    }

    override void visit(TypeInfoClassDeclaration d)
    {
        //printf("TypeInfoClassDeclaration.toDt() %s\n", tinfo.toChars());
        assert(0);
    }

    override void visit(TypeInfoInterfaceDeclaration d)
    {
        //printf("TypeInfoInterfaceDeclaration.toDt() %s\n", tinfo.toChars());
        verifyStructSize(Type.typeinfointerface, 3 * target.ptrsize);

        dtb.xoff(toVtblSymbol(Type.typeinfointerface), 0);    // vtbl for TypeInfoInterface
        if (Type.typeinfointerface.hasMonitor())
            dtb.size(0);                                  // monitor

        auto tc = d.tinfo.isTypeClass();

        if (!tc.sym.vclassinfo)
            tc.sym.vclassinfo = TypeInfoClassDeclaration.create(tc);
        auto s = toSymbol(tc.sym.vclassinfo);
        dtb.xoff(s, 0);    // ClassInfo for tinfo
    }

    override void visit(TypeInfoTupleDeclaration d)
    {
        //printf("TypeInfoTupleDeclaration.toDt() %s\n", tinfo.toChars());
        verifyStructSize(Type.typeinfotypelist, 4 * target.ptrsize);

        dtb.xoff(toVtblSymbol(Type.typeinfotypelist), 0); // vtbl for TypeInfoInterface
        if (Type.typeinfotypelist.hasMonitor())
            dtb.size(0);                                  // monitor

        auto tu = d.tinfo.isTypeTuple();

        const dim = tu.arguments.dim;
        dtb.size(dim);                       // elements.length

        auto dtbargs = DtBuilder(0);
        foreach (arg; *tu.arguments)
        {
            genTypeInfo(d.loc, arg.type, null);
            Symbol* s = toSymbol(arg.type.vtinfo);
            dtbargs.xoff(s, 0);
        }

        dtb.dtoff(dtbargs.finish(), 0);                  // elements.ptr
    }
}

extern (C++) void TypeInfo_toDt(ref DtBuilder dtb, TypeInfoDeclaration d)
{
    scope v = new TypeInfoDtVisitor(dtb);
    d.accept(v);
}
