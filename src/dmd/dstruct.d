/**
 * Struct and union declarations.
 *
 * Specification: $(LINK2 https://dlang.org/spec/struct.html, Structs, Unions)
 *
 * Copyright:   Copyright (C) 1999-2020 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 http://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/src/dmd/dstruct.d, _dstruct.d)
 * Documentation:  https://dlang.org/phobos/dmd_dstruct.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/dstruct.d
 */

module dmd.dstruct;

import dmd.aggregate;
import dmd.arraytypes;
import dmd.declaration;
import dmd.dmodule;
import dmd.dscope;
import dmd.dsymbol;
import dmd.dsymbolsem;
import dmd.dtemplate;
import dmd.errors;
import dmd.expression;
import dmd.expressionsem;
import dmd.func;
import dmd.globals;
import dmd.id;
import dmd.identifier;
import dmd.mtype;
import dmd.opover;
import dmd.semantic3;
import dmd.target;
import dmd.tokens;
import dmd.typesem;
import dmd.typinf;
import dmd.visitor;

/***************************************
 * Search sd for a member function of the form:
 *   `extern (D) string toString();`
 * Params:
 *   sd = struct declaration to search
 * Returns:
 *   FuncDeclaration of `toString()` if found, `null` if not
 */
extern (C++) FuncDeclaration search_toString(StructDeclaration sd)
{
    Dsymbol s = search_function(sd, Id.tostring);
    FuncDeclaration fd = s ? s.isFuncDeclaration() : null;
    if (fd)
    {
        __gshared TypeFunction tftostring;
        if (!tftostring)
        {
            tftostring = new TypeFunction(ParameterList(), Type.tstring, LINK.d);
            tftostring = tftostring.merge().toTypeFunction();
        }
        fd = fd.overloadExactMatch(tftostring);
    }
    return fd;
}

/***************************************
 * Request additional semantic analysis for TypeInfo generation.
 * Params:
 *      sc = context
 *      t = type that TypeInfo is being generated for
 */
extern (C++) void semanticTypeInfo(Scope* sc, Type t)
{
    if (!global.params.useTypeInfo || !Type.dtypeinfo)
        return; // not expected to be used with -betterC

    if (sc)
    {
        if (sc.intypeof)
            return;
        if (sc.flags & (SCOPE.ctfe | SCOPE.compile))
            return;
    }

    if (!t)
        return;

    void visitVector(TypeVector t)
    {
        semanticTypeInfo(sc, t.basetype);
    }

    void visitAArray(TypeAArray t)
    {
        semanticTypeInfo(sc, t.index);
        semanticTypeInfo(sc, t.next);
    }

    void visitStruct(TypeStruct t)
    {
        //printf("semanticTypeInfo.visit(TypeStruct = %s)\n", t.toChars());
        StructDeclaration sd = t.sym;

        /* Step 1: create TypeInfoDeclaration
         */
        if (!sc) // inline may request TypeInfo.
        {
            Scope scx;
            scx._module = sd.getModule();
            getTypeInfoType(sd.loc, t, &scx);
            sd.requestTypeInfo = true;
        }
        else if (!sc.minst)
        {
            // don't yet have to generate TypeInfo instance if
            // the typeid(T) expression exists in speculative scope.
        }
        else
        {
            getTypeInfoType(sd.loc, t, sc);
            sd.requestTypeInfo = true;

            // https://issues.dlang.org/show_bug.cgi?id=15149
            // if the typeid operand type comes from a
            // result of auto function, it may be yet speculative.
            // unSpeculative(sc, sd);
        }

        /* Step 2: If the TypeInfo generation requires sd.semantic3, run it later.
         * This should be done even if typeid(T) exists in speculative scope.
         * Because it may appear later in non-speculative scope.
         */
        if (!sd.members)
            return; // opaque struct
        if (!Type.rtinfo && !sd.xeq && !sd.xcmp && !sd.postblit && !sd.dtor && !sd.xhash && !search_toString(sd))
            return; // none of TypeInfo-specific members

        // If the struct is in a non-root module, run semantic3 to get
        // correct symbols for the member function.
        if (sd.semanticRun >= PASS.semantic3)
        {
            // semantic3 is already done
        }
        else if (TemplateInstance ti = sd.isInstantiated())
        {
            if (ti.minst && !ti.minst.isRoot())
                Module.addDeferredSemantic3(sd);
        }
        else
        {
            if (sd.inNonRoot())
            {
                //printf("deferred sem3 for TypeInfo - sd = %s, inNonRoot = %d\n", sd.toChars(), sd.inNonRoot());
                Module.addDeferredSemantic3(sd);
            }
        }
    }

    void visitTuple(TypeTuple t)
    {
        if (t.arguments)
        {
            foreach (arg; *t.arguments)
            {
                semanticTypeInfo(sc, arg.type);
            }
        }
    }

    /* Note structural similarity of this Type walker to that in isSpeculativeType()
     */

    Type tb = t.toBasetype().mutableOf().unSharedOf(); // remove modifiers
    switch (tb.ty)
    {
        case Tvector:   visitVector(tb.isTypeVector()); break;
        case Taarray:   visitAArray(tb.isTypeAArray()); break;
        case Tstruct:   visitStruct(tb.isTypeStruct()); break;
        case Ttuple:    visitTuple (tb.isTypeTuple());  break;

        case Tclass:
        case Tenum:     break;

        default:        semanticTypeInfo(sc, tb.nextOf()); break;
    }
}

enum StructFlags : int
{
    none        = 0x0,
    hasPointers = 0x1, // NB: should use noPointers as in ClassFlags
}

enum StructPOD : int
{
    no,    // struct is not POD
    yes,   // struct is POD
    fwd,   // POD not yet computed
}

private enum ZeroInit : byte
{
    unknown = -1,  // not computed yet
    no = 0,        // struct is not all zeroes
    yes = 1,       // struct is all zeroes
};

/***********************************************************
 * All `struct` declarations are an instance of this.
 */
extern (C++) class StructDeclaration : AggregateDeclaration
{
    ZeroInit zeroInit;          // if struct is initialized to all zeroes
    bool hasIdentityAssign;     // true if has identity opAssign
    bool hasBlitAssign;         // true if opAssign is a blit
    bool hasIdentityEquals;     // true if has identity opEquals
    bool hasNoFields;           // has no fields
    bool hasCopyCtor;           // copy constructor
    // Even if struct is defined as non-root symbol, some built-in operations
    // (e.g. TypeidExp, NewExp, ArrayLiteralExp, etc) request its TypeInfo.
    // For those, today TypeInfo_Struct is generated in COMDAT.
    bool requestTypeInfo;

    FuncDeclarations postblits; // Array of postblit functions
    FuncDeclaration postblit;   // aggregate postblit

    FuncDeclaration xeq;        // TypeInfo_Struct.xopEquals
    FuncDeclaration xcmp;       // TypeInfo_Struct.xopCmp
    FuncDeclaration xhash;      // TypeInfo_Struct.xtoHash
    extern (C++) __gshared FuncDeclaration xerreq;   // object.xopEquals
    extern (C++) __gshared FuncDeclaration xerrcmp;  // object.xopCmp

    structalign_t alignment;    // alignment applied outside of the struct
    StructPOD ispod;            // if struct is POD

    // ABI-specific type(s) if the struct can be passed in registers
    TypeTuple argTypes;

    extern (D) this(const ref Loc loc, Identifier id, bool inObject)
    {
        super(loc, id);
        zeroInit = ZeroInit.unknown;
        ispod = StructPOD.fwd;
        // For forward references
        type = new TypeStruct(this);

        if (inObject)
        {
            if (id == Id.ModuleInfo && !Module.moduleinfo)
                Module.moduleinfo = this;
        }
    }

    static StructDeclaration create(Loc loc, Identifier id, bool inObject)
    {
        return new StructDeclaration(loc, id, inObject);
    }

    override Dsymbol syntaxCopy(Dsymbol s)
    {
        StructDeclaration sd =
            s ? cast(StructDeclaration)s
              : new StructDeclaration(loc, ident, false);
        return ScopeDsymbol.syntaxCopy(sd);
    }

    final void semanticTypeInfoMembers()
    {
        if (xeq &&
            xeq._scope &&
            xeq.semanticRun < PASS.semantic3done)
        {
            uint errors = global.startGagging();
            xeq.semantic3(xeq._scope);
            if (global.endGagging(errors))
                xeq = xerreq;
        }

        if (xcmp &&
            xcmp._scope &&
            xcmp.semanticRun < PASS.semantic3done)
        {
            uint errors = global.startGagging();
            xcmp.semantic3(xcmp._scope);
            if (global.endGagging(errors))
                xcmp = xerrcmp;
        }

        FuncDeclaration ftostr = search_toString(this);
        if (ftostr &&
            ftostr._scope &&
            ftostr.semanticRun < PASS.semantic3done)
        {
            ftostr.semantic3(ftostr._scope);
        }

        if (xhash &&
            xhash._scope &&
            xhash.semanticRun < PASS.semantic3done)
        {
            xhash.semantic3(xhash._scope);
        }

        if (postblit &&
            postblit._scope &&
            postblit.semanticRun < PASS.semantic3done)
        {
            postblit.semantic3(postblit._scope);
        }

        if (dtor &&
            dtor._scope &&
            dtor.semanticRun < PASS.semantic3done)
        {
            dtor.semantic3(dtor._scope);
        }
    }

    override final Dsymbol search(const ref Loc loc, Identifier ident, int flags = SearchLocalsOnly)
    {
        //printf("%s.StructDeclaration::search('%s', flags = x%x)\n", toChars(), ident.toChars(), flags);
        if (_scope && !symtab)
            dsymbolSemantic(this, _scope);

        if (!members || !symtab) // opaque or semantic() is not yet called
        {
            // .stringof is always defined (but may be hidden by some other symbol)
            if(ident != Id.stringof)
                error("is forward referenced when looking for `%s`", ident.toChars());
            return null;
        }

        return ScopeDsymbol.search(loc, ident, flags);
    }

    override const(char)* kind() const
    {
        return "struct";
    }

    override final void finalizeSize()
    {
        //printf("StructDeclaration::finalizeSize() %s, sizeok = %d\n", toChars(), sizeok);
        assert(sizeok != Sizeok.done);

        if (sizeok == Sizeok.inProcess)
        {
            return;
        }
        sizeok = Sizeok.inProcess;

        //printf("+StructDeclaration::finalizeSize() %s, fields.dim = %d, sizeok = %d\n", toChars(), fields.dim, sizeok);

        fields.setDim(0);   // workaround

        // Set the offsets of the fields and determine the size of the struct
        uint offset = 0;
        bool isunion = isUnionDeclaration() !is null;
        for (size_t i = 0; i < members.dim; i++)
        {
            Dsymbol s = (*members)[i];
            s.setFieldOffset(this, &offset, isunion);
        }
        if (type.ty == Terror)
        {
            errors = true;
            return;
        }

        // 0 sized struct's are set to 1 byte
        if (structsize == 0)
        {
            hasNoFields = true;
            structsize = 1;
            alignsize = 1;
        }

        // Round struct size up to next alignsize boundary.
        // This will ensure that arrays of structs will get their internals
        // aligned properly.
        if (alignment == STRUCTALIGN_DEFAULT)
            structsize = (structsize + alignsize - 1) & ~(alignsize - 1);
        else
            structsize = (structsize + alignment - 1) & ~(alignment - 1);

        sizeok = Sizeok.done;

        //printf("-StructDeclaration::finalizeSize() %s, fields.dim = %d, structsize = %d\n", toChars(), fields.dim, structsize);

        if (errors)
            return;

        // Calculate fields[i].overlapped
        if (checkOverlappedFields())
        {
            errors = true;
            return;
        }

        if (zeroInit == ZeroInit.unknown)
            zeroInit = calcZeroInit();

        argTypes = target.toArgTypes(type);
    }

    /***************************************
     * Fit elements[] to the corresponding types of the struct's fields.
     *
     * Params:
     *      loc = location to use for error messages
     *      sc = context
     *      elements = explicit arguments used to construct object
     *      stype = the constructed object type.
     * Returns:
     *      false if any errors occur,
     *      otherwise true and elements[] are rewritten for the output.
     */
    final bool fit(const ref Loc loc, Scope* sc, Expressions* elements, Type stype)
    {
        if (!elements)
            return true;

        const nfields = nonHiddenFields();
        size_t offset = 0;
        for (size_t i = 0; i < elements.dim; i++)
        {
            Expression e = (*elements)[i];
            if (!e)
                continue;

            e = resolveProperties(sc, e);
            if (i >= nfields)
            {
                if (i <= fields.dim && e.op == TOK.null_)
                {
                    // CTFE sometimes creates null as hidden pointer; we'll allow this.
                    continue;
                }
                .error(loc, "more initializers than fields (%zu) of `%s`", nfields, toChars());
                return false;
            }
            VarDeclaration v = fields[i];
            if (v.offset < offset)
            {
                .error(loc, "overlapping initialization for `%s`", v.toChars());
                if (!isUnionDeclaration())
                {
                    enum errorMsg = "`struct` initializers that contain anonymous unions" ~
                                        " must initialize only the first member of a `union`. All subsequent" ~
                                        " non-overlapping fields are default initialized";
                    .errorSupplemental(loc, errorMsg);
                }
                return false;
            }
            offset = cast(uint)(v.offset + v.type.size());

            Type t = v.type;
            if (stype)
                t = t.addMod(stype.mod);
            Type origType = t;
            Type tb = t.toBasetype();

            const hasPointers = tb.hasPointers();
            if (hasPointers)
            {
                if ((stype.alignment() < target.ptrsize ||
                     (v.offset & (target.ptrsize - 1))) &&
                    (sc.func && sc.func.setUnsafe()))
                {
                    .error(loc, "field `%s.%s` cannot assign to misaligned pointers in `@safe` code",
                        toChars(), v.toChars());
                    return false;
                }
            }

            /* Look for case of initializing a static array with a too-short
             * string literal, such as:
             *  char[5] foo = "abc";
             * Allow this by doing an explicit cast, which will lengthen the string
             * literal.
             */
            if (e.op == TOK.string_ && tb.ty == Tsarray)
            {
                StringExp se = cast(StringExp)e;
                Type typeb = se.type.toBasetype();
                TY tynto = tb.nextOf().ty;
                if (!se.committed &&
                    (typeb.ty == Tarray || typeb.ty == Tsarray) && tynto.isSomeChar &&
                    se.numberOfCodeUnits(tynto) < (cast(TypeSArray)tb).dim.toInteger())
                {
                    e = se.castTo(sc, t);
                    goto L1;
                }
            }

            while (!e.implicitConvTo(t) && tb.ty == Tsarray)
            {
                /* Static array initialization, as in:
                 *  T[3][5] = e;
                 */
                t = tb.nextOf();
                tb = t.toBasetype();
            }
            if (!e.implicitConvTo(t))
                t = origType; // restore type for better diagnostic

            e = e.implicitCastTo(sc, t);
        L1:
            if (e.op == TOK.error)
                return false;

            (*elements)[i] = doCopyOrMove(sc, e);
        }
        return true;
    }

    /***************************************
     * Determine if struct is POD (Plain Old Data).
     *
     * POD is defined as:
     *      $(OL
     *      $(LI not nested)
     *      $(LI no postblits, destructors, or assignment operators)
     *      $(LI no `ref` fields or fields that are themselves non-POD)
     *      )
     * The idea being these are compatible with C structs.
     *
     * Returns:
     *     true if struct is POD
     */
    final bool isPOD()
    {
        // If we've already determined whether this struct is POD.
        if (ispod != StructPOD.fwd)
            return (ispod == StructPOD.yes);

        ispod = StructPOD.yes;

        if (enclosing || postblit || dtor || hasCopyCtor)
        {
            ispod = StructPOD.no;
            return false;
        }

        // Recursively check all fields are POD.
        for (size_t i = 0; i < fields.dim; i++)
        {
            VarDeclaration v = fields[i];
            if (v.storage_class & STC.ref_)
            {
                ispod = StructPOD.no;
                return false;
            }

            Type tv = v.type.baseElemOf();
            if (tv.ty == Tstruct)
            {
                TypeStruct ts = cast(TypeStruct)tv;
                StructDeclaration sd = ts.sym;
                if (!sd.isPOD())
                {
                    ispod = StructPOD.no;
                    return false;
                }
            }
        }

        return (ispod == StructPOD.yes);
    }

    /***************************************
     * Lazily determine whether a struct init value is a chunk of zeroes
     *
     * Returns:
     *     true if struct is all zeroes
     */
    final bool isZeroInit()
    {
        if (zeroInit == ZeroInit.unknown)
            if (semanticRun < PASS.semanticdone && _scope)
                dsymbolSemantic(this, null);
        if (zeroInit == ZeroInit.unknown)
            zeroInit = calcZeroInit();
        return zeroInit == ZeroInit.yes;
    }

    private final ZeroInit calcZeroInit()
    {
        // Determine if struct is all zeros or not
        foreach (vd; fields)
        {
            if (vd._init)
            {
                if (vd._init.isVoidInitializer())
                    /* Treat as 0 for the purposes of putting the initializer
                     * in the BSS segment, or doing a mass set to 0
                     */
                    continue;

                // Zero size fields are zero initialized
                if (vd.type.size(vd.loc) == 0)
                    continue;

                // Examine init to see if it is all 0s.
                auto exp = vd.getConstInitializer();
                if (!exp || !_isZeroInit(exp))
                    return ZeroInit.no;
            }
            else if (!vd.type.isZeroInit(loc))
            {
                return ZeroInit.no;
            }
        }
        return ZeroInit.yes;
    }

    override final inout(StructDeclaration) isStructDeclaration() inout
    {
        return this;
    }

    override void accept(Visitor v)
    {
        v.visit(this);
    }

    final uint numArgTypes() const
    {
        return argTypes && argTypes.arguments ? cast(uint) argTypes.arguments.dim : 0;
    }

    final Type argType(uint index)
    {
        return index < numArgTypes() ? (*argTypes.arguments)[index].type : null;
    }

    final bool hasNonDisabledCtor()
    {
        static extern (C++) class HasNonDisabledCtorVisitor : Visitor
        {
            bool result;

            this() {}

            alias visit = Visitor.visit;

            override void visit(CtorDeclaration cd)
            {
                if (!(cd.storage_class & STC.disable))
                    result = true;
            }

            override void visit(TemplateDeclaration td)
            {
                result = true;
            }

            override void visit(OverloadSet os)
            {
                for (size_t i = 0; i < os.a.dim; i++)
                    os.a[i].accept(this);
            }
        }

        if (!ctor)
            return false;
        scope v = new HasNonDisabledCtorVisitor();
        ctor.accept(v);
        return v.result;
    }
}

/**********************************
 * Determine if exp is all binary zeros.
 * Params:
 *      exp = expression to check
 * Returns:
 *      true if it's all binary 0
 */
private bool _isZeroInit(Expression exp)
{
    switch (exp.op)
    {
        case TOK.int64:
            return exp.toInteger() == 0;

        case TOK.null_:
        case TOK.false_:
            return true;

        case TOK.structLiteral:
        {
            auto sle = cast(StructLiteralExp) exp;
            foreach (i; 0 .. sle.sd.fields.dim)
            {
                auto field = sle.sd.fields[i];
                if (field.type.size(field.loc))
                {
                    auto e = (*sle.elements)[i];
                    if (e ? !_isZeroInit(e)
                          : !field.type.isZeroInit(field.loc))
                        return false;
                }
            }
            return true;
        }

        case TOK.arrayLiteral:
        {
            auto ale = cast(ArrayLiteralExp)exp;

            const dim = ale.elements ? ale.elements.dim : 0;

            if (ale.type.toBasetype().ty == Tarray) // if initializing a dynamic array
                return dim == 0;

            foreach (i; 0 .. dim)
            {
                if (!_isZeroInit(ale[i]))
                    return false;
            }

            /* Note that true is returned for all T[0]
             */
            return true;
        }

        case TOK.string_:
        {
            StringExp se = cast(StringExp)exp;

            if (se.type.toBasetype().ty == Tarray) // if initializing a dynamic array
                return se.len == 0;

            foreach (i; 0 .. se.len)
            {
                if (se.getCodeUnit(i))
                    return false;
            }
            return true;
        }

        case TOK.vector:
        {
            auto ve = cast(VectorExp) exp;
            return _isZeroInit(ve.e1);
        }

        case TOK.float64:
        case TOK.complex80:
        {
            import dmd.root.ctfloat : CTFloat;
            return (exp.toReal()      is CTFloat.zero) &&
                   (exp.toImaginary() is CTFloat.zero);
        }

        default:
            return false;
    }
}

/***********************************************************
 * Unions are a variation on structs.
 */
extern (C++) final class UnionDeclaration : StructDeclaration
{
    extern (D) this(const ref Loc loc, Identifier id)
    {
        super(loc, id, false);
    }

    override Dsymbol syntaxCopy(Dsymbol s)
    {
        assert(!s);
        auto ud = new UnionDeclaration(loc, ident);
        return StructDeclaration.syntaxCopy(ud);
    }

    override const(char)* kind() const
    {
        return "union";
    }

    override inout(UnionDeclaration) isUnionDeclaration() inout
    {
        return this;
    }

    override void accept(Visitor v)
    {
        v.visit(this);
    }
}
