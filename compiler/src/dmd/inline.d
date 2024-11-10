/**
 * Performs inlining, which is an optimization pass enabled with the `-inline` flag.
 *
 * The AST is traversed, and every function call is considered for inlining using `inlinecost.d`.
 * The function call is then inlined if this cost is below a threshold.
 *
 * Copyright:   Copyright (C) 1999-2024 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 https://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:    $(LINK2 https://github.com/dlang/dmd/blob/master/src/dmd/inline.d, _inline.d)
 * Documentation:  https://dlang.org/phobos/dmd_inline.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/inline.d
 */

module dmd.inline;

import core.stdc.stdio;
import core.stdc.string;

import dmd.aggregate;
import dmd.arraytypes;
import dmd.astenums;
import dmd.attrib;
import dmd.declaration;
import dmd.dmodule;
import dmd.dscope;
import dmd.dstruct;
import dmd.dsymbol;
import dmd.dsymbolsem : include;
import dmd.dtemplate;
import dmd.expression;
import dmd.expressionsem : semanticTypeInfo;
import dmd.errors;
import dmd.func;
import dmd.funcsem;
import dmd.globals;
import dmd.hdrgen;
import dmd.id;
import dmd.identifier;
import dmd.init;
import dmd.initsem;
import dmd.location;
import dmd.mtype;
import dmd.opover;
import dmd.printast;
import dmd.statement;
import dmd.tokens;
import dmd.typesem : pointerTo, sarrayOf;
import dmd.visitor;
import dmd.visitor.postorder;
import dmd.inlinecost;

/***********************************************************
 * Scan function implementations in Module m looking for functions that can be inlined,
 * and inline them in situ.
 *
 * Params:
 *    m = module to scan
 */
public void inlineScanModule(Module m)
{
    if (m.semanticRun != PASS.semantic3done)
        return;
    m.semanticRun = PASS.inline;

    // Note that modules get their own scope, from scratch.
    // This is so regardless of where in the syntax a module
    // gets imported, it is unaffected by context.

    //printf("Module = %p\n", m.sc.scopesym);

    foreach (i; 0 .. m.members.length)
    {
        Dsymbol s = (*m.members)[i];
        //if (global.params.v.verbose)
        //    message("inline scan symbol %s", s.toChars());
        inlineScanDsymbol(s);
    }
    m.semanticRun = PASS.inlinedone;
}

private void inlineScanDsymbol(Dsymbol s)
{
    scope InlineScanVisitorDsymbol v = new InlineScanVisitorDsymbol();
    s.accept(v);
}

/***********************************************************
 * Perform the "inline copying" of a default argument for a function parameter.
 *
 * Todo:
 *  The hack for https://issues.dlang.org/show_bug.cgi?id=4820 case is still questionable.
 *  Perhaps would have to handle a delegate expression with 'null' context properly in front-end.
 */
public Expression inlineCopy(Expression e, Scope* sc)
{
    /* See https://issues.dlang.org/show_bug.cgi?id=2935
     * for explanation of why just a copy() is broken
     */
    //return e.copy();
    if (auto de = e.isDelegateExp())
    {
        if (de.func.isNested())
        {
            /* https://issues.dlang.org/show_bug.cgi?id=4820
             * Defer checking until later if we actually need the 'this' pointer
             */
            return de.copy();
        }
    }
    const cost = inlineCostExpression(e);
    if (cost >= COST_MAX)
    {
        error(e.loc, "cannot inline default argument `%s`", e.toChars());
        return ErrorExp.get();
    }
    scope ids = new InlineDoState(sc.parent, null);
    return doInlineAs!Expression(e, ids);
}






private:



enum LOG = false;
enum CANINLINE_LOG = false;
enum EXPANDINLINE_LOG = false;


/***********************************************************
 * Represent a context to inline statements and expressions.
 *
 * Todo:
 *  It would be better to make foundReturn an instance field of DoInlineAs visitor class,
 *  like as DoInlineAs!Result.result field, because it's one another result of inlining.
 *  The best would be to return a pair of result Expression and a bool value as foundReturn
 *  from doInlineAs function.
 */
private final class InlineDoState
{
    // inline context
    VarDeclaration vthis;
    Dsymbols from;      // old Dsymbols
    Dsymbols to;        // parallel array of new Dsymbols
    Dsymbol parent;     // new parent
    FuncDeclaration fd; // function being inlined (old parent)
    // inline result
    bool foundReturn;

    this(Dsymbol parent, FuncDeclaration fd) scope
    {
        this.parent = parent;
        this.fd = fd;
    }
}

/***********************************************************
 * Perform the inlining from (Statement or Expression) to (Statement or Expression).
 *
 * Inlining is done by:
 *  - Converting to an Expression
 *  - Copying the trees of the function to be inlined
 *  - Renaming the variables
 */
private extern (C++) final class DoInlineAs(Result) : Visitor
if (is(Result == Statement) || is(Result == Expression))
{
    alias visit = Visitor.visit;
public:
    InlineDoState ids;
    Result result;

    enum asStatements = is(Result == Statement);

    extern (D) this(InlineDoState ids) scope
    {
        this.ids = ids;
    }

    // Statement -> (Statement | Expression)

    override void visit(Statement s)
    {
        printf("Statement.doInlineAs!%s()\n%s\n", Result.stringof.ptr, s.toChars());
        fflush(stdout);
        assert(0); // default is we can't inline it
    }

    override void visit(ExpStatement s)
    {
        static if (LOG)
        {
            if (s.exp)
                printf("ExpStatement.doInlineAs!%s() '%s'\n", Result.stringof.ptr, s.exp.toChars());
        }

        auto exp = doInlineAs!Expression(s.exp, ids);
        static if (asStatements)
            result = new ExpStatement(s.loc, exp);
        else
            result = exp;
    }

    override void visit(CompoundStatement s)
    {
        //printf("CompoundStatement.doInlineAs!%s() %d\n", Result.stringof.ptr, s.statements.length);
        static if (asStatements)
        {
            auto as = new Statements();
            as.reserve(s.statements.length);
        }

        foreach (i, sx; *s.statements)
        {
            if (!sx)
                continue;
            static if (asStatements)
            {
                as.push(doInlineAs!Statement(sx, ids));
            }
            else
            {
                /* Specifically allow:
                 *  if (condition)
                 *      return exp1;
                 *  return exp2;
                 */
                IfStatement ifs;
                Statement s3;
                if ((ifs = sx.isIfStatement()) !is null &&
                    ifs.ifbody &&
                    ifs.ifbody.endsWithReturnStatement() &&
                    !ifs.elsebody &&
                    i + 1 < s.statements.length &&
                    (s3 = (*s.statements)[i + 1]) !is null &&
                    s3.endsWithReturnStatement()
                   )
                {
                    /* Rewrite as ?:
                     */
                    auto econd = doInlineAs!Expression(ifs.condition, ids);
                    assert(econd);
                    auto e1 = doInlineAs!Expression(ifs.ifbody, ids);
                    assert(ids.foundReturn);
                    auto e2 = doInlineAs!Expression(s3, ids);
                    assert(e2);
                    Expression e = new CondExp(econd.loc, econd, e1, e2);
                    e.type = e1.type;
                    if (e.type.ty == Ttuple)
                    {
                        e1.type = Type.tvoid;
                        e2.type = Type.tvoid;
                        e.type = Type.tvoid;
                    }
                    result = Expression.combine(result, e);
                }
                else
                {
                    ids.foundReturn = false;
                    auto e = doInlineAs!Expression(sx, ids);
                    result = Expression.combine(result, e);
                }
            }

            if (ids.foundReturn)
                break;
        }

        static if (asStatements)
            result = new CompoundStatement(s.loc, as);
    }

    override void visit(UnrolledLoopStatement s)
    {
        //printf("UnrolledLoopStatement.doInlineAs!%s() %d\n", Result.stringof.ptr, s.statements.length);
        static if (asStatements)
        {
            auto as = new Statements();
            as.reserve(s.statements.length);
        }

        foreach (sx; *s.statements)
        {
            if (!sx)
                continue;
            auto r = doInlineAs!Result(sx, ids);
            static if (asStatements)
                as.push(r);
            else
                result = Expression.combine(result, r);

            if (ids.foundReturn)
                break;
        }

        static if (asStatements)
            result = new UnrolledLoopStatement(s.loc, as);
    }

    override void visit(ScopeStatement s)
    {
        //printf("ScopeStatement.doInlineAs!%s() %d\n", Result.stringof.ptr, s.statement.length);
        auto r = doInlineAs!Result(s.statement, ids);
        static if (asStatements)
            result = new ScopeStatement(s.loc, r, s.endloc);
        else
            result = r;
    }

    override void visit(IfStatement s)
    {
        assert(!s.param);
        auto econd = doInlineAs!Expression(s.condition, ids);
        assert(econd);

        auto ifbody = doInlineAs!Result(s.ifbody, ids);
        bool bodyReturn = ids.foundReturn;

        ids.foundReturn = false;
        auto elsebody = doInlineAs!Result(s.elsebody, ids);

        static if (asStatements)
        {
            result = new IfStatement(s.loc, s.param, econd, ifbody, elsebody, s.endloc);
        }
        else
        {
            alias e1 = ifbody;
            alias e2 = elsebody;
            if (e1 && e2)
            {
                result = new CondExp(econd.loc, econd, e1, e2);
                result.type = e1.type;
                if (result.type.ty == Ttuple)
                {
                    e1.type = Type.tvoid;
                    e2.type = Type.tvoid;
                    result.type = Type.tvoid;
                }
            }
            else if (e1)
            {
                result = new LogicalExp(econd.loc, EXP.andAnd, econd, e1);
                result.type = Type.tvoid;
            }
            else if (e2)
            {
                result = new LogicalExp(econd.loc, EXP.orOr, econd, e2);
                result.type = Type.tvoid;
            }
            else
            {
                result = econd;
            }
        }
        ids.foundReturn = ids.foundReturn && bodyReturn;
    }

    override void visit(ReturnStatement s)
    {
        //printf("ReturnStatement.doInlineAs!%s() '%s'\n", Result.stringof.ptr, s.exp ? s.exp.toChars() : "");
        ids.foundReturn = true;

        auto exp = doInlineAs!Expression(s.exp, ids);
        if (!exp) // https://issues.dlang.org/show_bug.cgi?id=14560
                  // 'return' must not leave in the expand result
            return;
        static if (asStatements)
        {
            /* Any return statement should be the last statement in the function being
             * inlined, otherwise things shouldn't have gotten this far. Since the
             * return value is being ignored (otherwise it wouldn't be inlined as a statement)
             * we only need to evaluate `exp` for side effects.
             * Already disallowed this if `exp` produces an object that needs destruction -
             * an enhancement would be to do the destruction here.
             */
            result = new ExpStatement(s.loc, exp);
        }
        else
            result = exp;
    }

    override void visit(ImportStatement s)
    {
        //printf("ImportStatement.doInlineAs!%s()\n", Result.stringof.ptr);
    }

    override void visit(ForStatement s)
    {
        //printf("ForStatement.doInlineAs!%s()\n", Result.stringof.ptr);
        static if (asStatements)
        {
            auto sinit = doInlineAs!Statement(s._init, ids);
            auto scond = doInlineAs!Expression(s.condition, ids);
            auto sincr = doInlineAs!Expression(s.increment, ids);
            auto sbody = doInlineAs!Statement(s._body, ids);
            result = new ForStatement(s.loc, sinit, scond, sincr, sbody, s.endloc);
        }
        else
            result = null;  // cannot be inlined as an Expression
    }

    override void visit(ThrowStatement s)
    {
        //printf("ThrowStatement.doInlineAs!%s() '%s'\n", Result.stringof.ptr, s.exp.toChars());
        static if (asStatements)
            result = new ThrowStatement(s.loc, doInlineAs!Expression(s.exp, ids));
        else
            result = null;  // cannot be inlined as an Expression
    }

    // Expression -> (Statement | Expression)

    static if (asStatements)
    {
        override void visit(Expression e)
        {
            result = new ExpStatement(e.loc, doInlineAs!Expression(e, ids));
        }
    }
    else
    {
        /******************************
         * Perform doInlineAs() on an array of Expressions.
         */
        Expressions* arrayExpressionDoInline(Expressions* a)
        {
            if (!a)
                return null;

            auto newa = new Expressions(a.length);

            foreach (i; 0 .. a.length)
            {
                (*newa)[i] = doInlineAs!Expression((*a)[i], ids);
            }
            return newa;
        }

        override void visit(Expression e)
        {
            //printf("Expression.doInlineAs!%s(%s): %s\n", Result.stringof.ptr, EXPtoString(e.op).ptr, e.toChars());
            result = e.copy();
        }

        override void visit(SymOffExp e)
        {
            //printf("SymOffExp.doInlineAs!%s(%s)\n", Result.stringof.ptr, e.toChars());
            foreach (i; 0 .. ids.from.length)
            {
                if (e.var != ids.from[i])
                    continue;
                auto se = e.copy().isSymOffExp();
                se.var = ids.to[i].isDeclaration();
                result = se;
                return;
            }
            result = e;
        }

        override void visit(VarExp e)
        {
            //printf("VarExp.doInlineAs!%s(%s)\n", Result.stringof.ptr, e.toChars());
            foreach (i; 0 .. ids.from.length)
            {
                if (e.var != ids.from[i])
                    continue;
                auto ve = e.copy().isVarExp();
                ve.var = ids.to[i].isDeclaration();
                result = ve;
                return;
            }
            if (ids.fd && e.var == ids.fd.vthis)
            {
                result = new VarExp(e.loc, ids.vthis);
                if (ids.fd.hasDualContext())
                    result = new AddrExp(e.loc, result);
                result.type = e.type;
                return;
            }

            /* Inlining context pointer access for nested referenced variables.
             * For example:
             *      auto fun() {
             *        int i = 40;
             *        auto foo() {
             *          int g = 2;
             *          struct Result {
             *            auto bar() { return i + g; }
             *          }
             *          return Result();
             *        }
             *        return foo();
             *      }
             *      auto t = fun();
             * 'i' and 'g' are nested referenced variables in Result.bar(), so:
             *      auto x = t.bar();
             * should be inlined to:
             *      auto x = *(t.vthis.vthis + i.voffset) + *(t.vthis + g.voffset)
             */
            auto v = e.var.isVarDeclaration();
            if (v && v.nestedrefs.length && ids.vthis)
            {
                Dsymbol s = ids.fd;
                auto fdv = v.toParent().isFuncDeclaration();
                assert(fdv);
                result = new VarExp(e.loc, ids.vthis);
                result.type = ids.vthis.type;
                if (ids.fd.hasDualContext())
                {
                    // &__this
                    result = new AddrExp(e.loc, result);
                    result.type = ids.vthis.type.pointerTo();
                }
                while (s != fdv)
                {
                    auto f = s.isFuncDeclaration();
                    AggregateDeclaration ad;
                    if (f && f.hasDualContext())
                    {
                        if (f.hasNestedFrameRefs())
                        {
                            result = new DotVarExp(e.loc, result, f.vthis);
                            result.type = f.vthis.type;
                        }
                        // (*__this)[i]
                        uint i = f.followInstantiationContext(fdv);
                        if (i == 1 && f == ids.fd)
                        {
                            auto ve = e.copy().isVarExp();
                            ve.originalScope = ids.fd;
                            result = ve;
                            return;
                        }
                        result = new PtrExp(e.loc, result);
                        result.type = Type.tvoidptr.sarrayOf(2);
                        auto ie = new IndexExp(e.loc, result, new IntegerExp(i));
                        ie.indexIsInBounds = true; // no runtime bounds checking
                        result = ie;
                        result.type = Type.tvoidptr;
                        s = f.toParentP(fdv);
                        ad = s.isAggregateDeclaration();
                        if (ad)
                            goto Lad;
                        continue;
                    }
                    else if ((ad = s.isThis()) !is null)
                    {
                Lad:
                        while (ad)
                        {
                            assert(ad.vthis);
                            bool i = ad.followInstantiationContext(fdv);
                            auto vthis = i ? ad.vthis2 : ad.vthis;
                            result = new DotVarExp(e.loc, result, vthis);
                            result.type = vthis.type;
                            s = ad.toParentP(fdv);
                            ad = s.isAggregateDeclaration();
                        }
                    }
                    else if (f && f.isNested())
                    {
                        assert(f.vthis);
                        if (f.hasNestedFrameRefs())
                        {
                            result = new DotVarExp(e.loc, result, f.vthis);
                            result.type = f.vthis.type;
                        }
                        s = f.toParent2();
                    }
                    else
                        assert(0);
                    assert(s);
                }
                result = new DotVarExp(e.loc, result, v);
                result.type = v.type;
                //printf("\t==> result = %s, type = %s\n", result.toChars(), result.type.toChars());
                return;
            }
            else if (v && v.nestedrefs.length)
            {
                auto ve = e.copy().isVarExp();
                ve.originalScope = ids.fd;
                result = ve;
                return;
            }

            result = e;
        }

        override void visit(ThisExp e)
        {
            //if (!ids.vthis)
            //    e.error("no `this` when inlining `%s`", ids.parent.toChars());
            if (!ids.vthis)
            {
                result = e;
                return;
            }
            result = new VarExp(e.loc, ids.vthis);
            if (ids.fd.hasDualContext())
            {
                // __this[0]
                result.type = ids.vthis.type;
                auto ie = new IndexExp(e.loc, result, IntegerExp.literal!0);
                ie.indexIsInBounds = true; // no runtime bounds checking
                result = ie;
                if (e.type.ty == Tstruct)
                {
                    result.type = e.type.pointerTo();
                    result = new PtrExp(e.loc, result);
                }
            }
            result.type = e.type;
        }

        override void visit(SuperExp e)
        {
            assert(ids.vthis);
            result = new VarExp(e.loc, ids.vthis);
            if (ids.fd.hasDualContext())
            {
                // __this[0]
                result.type = ids.vthis.type;
                auto ie = new IndexExp(e.loc, result, IntegerExp.literal!0);
                ie.indexIsInBounds = true; // no runtime bounds checking
                result = ie;
            }
            result.type = e.type;
        }

        override void visit(DeclarationExp e)
        {
            //printf("DeclarationExp.doInlineAs!%s(%s)\n", Result.stringof.ptr, e.toChars());
            if (auto vd = e.declaration.isVarDeclaration())
            {
                version (none)
                {
                    // Need to figure this out before inlining can work for tuples
                    if (auto tup = vd.toAlias().isTupleDeclaration())
                    {
                        tup.foreachVar((s) { s; });
                        result = st.objects.length;
                        return;
                    }
                }
                if (vd.isStatic())
                    return;

                if (ids.fd && vd == ids.fd.nrvo_var)
                {
                    foreach (i; 0 .. ids.from.length)
                    {
                        if (vd != ids.from[i])
                            continue;
                        if (vd._init && !vd._init.isVoidInitializer())
                        {
                            result = vd._init.initializerToExpression();
                            assert(result);
                            result = doInlineAs!Expression(result, ids);
                        }
                        else
                            result = IntegerExp.literal!0;
                        return;
                    }
                }

                auto vto = new VarDeclaration(vd.loc, vd.type, vd.ident, vd._init);
                memcpy(cast(void*)vto, cast(void*)vd, __traits(classInstanceSize, VarDeclaration));
                vto.parent = ids.parent;
                vto.csym = null;

                ids.from.push(vd);
                ids.to.push(vto);

                if (vd._init)
                {
                    if (vd._init.isVoidInitializer())
                    {
                        vto._init = new VoidInitializer(vd._init.loc);
                    }
                    else
                    {
                        auto ei = vd._init.initializerToExpression();
                        assert(ei);
                        vto._init = new ExpInitializer(ei.loc, doInlineAs!Expression(ei, ids));
                    }
                }
                if (vd.edtor)
                {
                    vto.edtor = doInlineAs!Expression(vd.edtor, ids);
                }
                auto de = e.copy().isDeclarationExp();
                de.declaration = vto;
                result = de;
                return;
            }

            // Prevent the copy of the aggregates allowed in inlineable funcs
            if (isInlinableNestedAggregate(e))
                return;

            /* This needs work, like DeclarationExp.toElem(), if we are
             * to handle TemplateMixin's. For now, we just don't inline them.
             */
            visit(cast(Expression)e);
        }

        override void visit(TypeidExp e)
        {
            //printf("TypeidExp.doInlineAs!%s(): %s\n", Result.stringof.ptr, e.toChars());
            auto te = e.copy().isTypeidExp();
            if (auto ex = isExpression(te.obj))
            {
                te.obj = doInlineAs!Expression(ex, ids);
            }
            else
                assert(isType(te.obj));
            result = te;
        }

        override void visit(NewExp e)
        {
            //printf("NewExp.doInlineAs!%s(): %s\n", Result.stringof.ptr, e.toChars());
            auto ne = e.copy().isNewExp();
            auto lowering = ne.lowering;
            if (lowering)
                if (auto ce = lowering.isCallExp())
                    if (ce.f.ident == Id._d_newarrayT || ce.f.ident == Id._d_newarraymTX)
                    {
                        ne.lowering = doInlineAs!Expression(lowering, ids);
                        goto LhasLowering;
                    }

            ne.placement = doInlineAs!Expression(e.placement, ids);
            ne.thisexp = doInlineAs!Expression(e.thisexp, ids);
            ne.argprefix = doInlineAs!Expression(e.argprefix, ids);
            ne.arguments = arrayExpressionDoInline(e.arguments);

        LhasLowering:
            result = ne;

            semanticTypeInfo(null, e.type);
        }

        override void visit(UnaExp e)
        {
            auto ue = cast(UnaExp)e.copy();
            ue.e1 = doInlineAs!Expression(e.e1, ids);
            result = ue;
        }

        override void visit(AssertExp e)
        {
            auto ae = e.copy().isAssertExp();
            ae.e1 = doInlineAs!Expression(e.e1, ids);
            ae.msg = doInlineAs!Expression(e.msg, ids);
            result = ae;
        }

        override void visit(CatExp e)
        {
            auto ce = e.copy().isCatExp();

            if (auto lowering = ce.lowering)
                ce.lowering = doInlineAs!Expression(lowering, ids);
            else
            {
                ce.e1 = doInlineAs!Expression(e.e1, ids);
                ce.e2 = doInlineAs!Expression(e.e2, ids);
            }

            result = ce;
        }

        override void visit(CatAssignExp e)
        {
            auto cae = cast(CatAssignExp) e.copy();

            if (auto lowering = cae.lowering)
                cae.lowering = doInlineAs!Expression(cae.lowering, ids);
            else
            {
                cae.e1 = doInlineAs!Expression(e.e1, ids);
                cae.e2 = doInlineAs!Expression(e.e2, ids);
            }

            result = cae;
        }

        override void visit(BinExp e)
        {
            auto be = cast(BinExp)e.copy();
            be.e1 = doInlineAs!Expression(e.e1, ids);
            be.e2 = doInlineAs!Expression(e.e2, ids);
            result = be;
        }

        override void visit(CallExp e)
        {
            auto ce = e.copy().isCallExp();
            ce.e1 = doInlineAs!Expression(e.e1, ids);
            ce.arguments = arrayExpressionDoInline(e.arguments);
            result = ce;
        }

        override void visit(AssignExp e)
        {
            visit(cast(BinExp)e);
        }

        override void visit(LoweredAssignExp e)
        {
            result = doInlineAs!Expression(e.lowering, ids);
        }

        override void visit(EqualExp e)
        {
            visit(cast(BinExp)e);

            Type t1 = e.e1.type.toBasetype();
            if (t1.ty == Tarray || t1.ty == Tsarray)
            {
                Type t = t1.nextOf().toBasetype();
                while (t.toBasetype().nextOf())
                    t = t.nextOf().toBasetype();
                if (t.ty == Tstruct)
                    semanticTypeInfo(null, t);
            }
            else if (t1.ty == Taarray)
            {
                semanticTypeInfo(null, t1);
            }
        }

        override void visit(IndexExp e)
        {
            auto are = e.copy().isIndexExp();
            are.e1 = doInlineAs!Expression(e.e1, ids);
            if (e.lengthVar)
            {
                //printf("lengthVar\n");
                auto vd = e.lengthVar;
                auto vto = new VarDeclaration(vd.loc, vd.type, vd.ident, vd._init);
                memcpy(cast(void*)vto, cast(void*)vd, __traits(classInstanceSize, VarDeclaration));
                vto.parent = ids.parent;
                vto.csym = null;

                ids.from.push(vd);
                ids.to.push(vto);

                if (vd._init && !vd._init.isVoidInitializer())
                {
                    auto ie = vd._init.isExpInitializer();
                    assert(ie);
                    vto._init = new ExpInitializer(ie.loc, doInlineAs!Expression(ie.exp, ids));
                }
                are.lengthVar = vto;
            }
            are.e2 = doInlineAs!Expression(e.e2, ids);
            result = are;
        }

        override void visit(SliceExp e)
        {
            auto are = e.copy().isSliceExp();
            are.e1 = doInlineAs!Expression(e.e1, ids);
            if (e.lengthVar)
            {
                //printf("lengthVar\n");
                auto vd = e.lengthVar;
                auto vto = new VarDeclaration(vd.loc, vd.type, vd.ident, vd._init);
                memcpy(cast(void*)vto, cast(void*)vd, __traits(classInstanceSize, VarDeclaration));
                vto.parent = ids.parent;
                vto.csym = null;

                ids.from.push(vd);
                ids.to.push(vto);

                if (vd._init && !vd._init.isVoidInitializer())
                {
                    auto ie = vd._init.isExpInitializer();
                    assert(ie);
                    vto._init = new ExpInitializer(ie.loc, doInlineAs!Expression(ie.exp, ids));
                }

                are.lengthVar = vto;
            }
            are.lwr = doInlineAs!Expression(e.lwr, ids);
            are.upr = doInlineAs!Expression(e.upr, ids);
            result = are;
        }

        override void visit(TupleExp e)
        {
            auto ce = e.copy().isTupleExp();
            ce.e0 = doInlineAs!Expression(e.e0, ids);
            ce.exps = arrayExpressionDoInline(e.exps);
            result = ce;
        }

        override void visit(ArrayLiteralExp e)
        {
            auto ce = e.copy().isArrayLiteralExp();
            ce.basis = doInlineAs!Expression(e.basis, ids);
            ce.elements = arrayExpressionDoInline(e.elements);
            result = ce;

            semanticTypeInfo(null, e.type);
        }

        override void visit(AssocArrayLiteralExp e)
        {
            auto ce = e.copy().isAssocArrayLiteralExp();
            ce.keys = arrayExpressionDoInline(e.keys);
            ce.values = arrayExpressionDoInline(e.values);
            result = ce;

            semanticTypeInfo(null, e.type);
        }

        override void visit(StructLiteralExp e)
        {
            if (e.inlinecopy)
            {
                result = e.inlinecopy;
                return;
            }
            auto ce = e.copy().isStructLiteralExp();
            e.inlinecopy = ce;
            ce.elements = arrayExpressionDoInline(e.elements);
            e.inlinecopy = null;
            result = ce;
        }

        override void visit(ArrayExp e)
        {
            assert(0); // this should have been lowered to something else
        }

        override void visit(CondExp e)
        {
            auto ce = e.copy().isCondExp();
            ce.econd = doInlineAs!Expression(e.econd, ids);
            ce.e1 = doInlineAs!Expression(e.e1, ids);
            ce.e2 = doInlineAs!Expression(e.e2, ids);
            result = ce;
        }
    }
}

/// ditto
private Result doInlineAs(Result)(Statement s, InlineDoState ids)
{
    if (!s)
        return null;

    scope DoInlineAs!Result v = new DoInlineAs!Result(ids);
    s.accept(v);
    return v.result;
}

/// ditto
private Result doInlineAs(Result)(Expression e, InlineDoState ids)
{
    if (!e)
        return null;

    scope DoInlineAs!Result v = new DoInlineAs!Result(ids);
    e.accept(v);
    return v.result;
}

/***********************************************************
 * Walk the trees, looking for functions to inline.
 * Inline any that can be.
 */
private extern (C++) final class InlineScanVisitor : Visitor
{
    alias visit = Visitor.visit;
public:
    FuncDeclaration parent;     // function being scanned
    // As the visit method cannot return a value, these variables
    // are used to pass the result from 'visit' back to 'inlineScan'
    Statement sresult;
    Expression eresult;
    bool again;

    extern (D) this() scope @safe
    {
    }

    override void visit(Statement s)
    {
    }

    override void visit(ExpStatement s)
    {
        static if (LOG)
        {
            printf("ExpStatement.inlineScan(%s)\n", toChars(s));
        }
        if (!s.exp)
            return;

        Statement inlineScanExpAsStatement(ref Expression exp)
        {
            /* If there's a EXP.call at the top, then it may fail to inline
             * as an Expression. Try to inline as a Statement instead.
             */
            if (auto ce = exp.isCallExp())
            {
                visitCallExp(ce, null, true);
                if (eresult)
                    exp = eresult;
                auto s = sresult;
                sresult = null;
                eresult = null;
                return s;
            }

            /* If there's a CondExp or CommaExp at the top, then its
             * sub-expressions may be inlined as statements.
             */
            if (auto e = exp.isCondExp())
            {
                inlineScan(e.econd);
                auto s1 = inlineScanExpAsStatement(e.e1);
                auto s2 = inlineScanExpAsStatement(e.e2);
                if (!s1 && !s2)
                    return null;
                auto ifbody   = !s1 ? new ExpStatement(e.e1.loc, e.e1) : s1;
                auto elsebody = !s2 ? new ExpStatement(e.e2.loc, e.e2) : s2;
                return new IfStatement(exp.loc, null, e.econd, ifbody, elsebody, exp.loc);
            }
            if (auto e = exp.isCommaExp())
            {
                /* If expression declares temporaries which have to be destructed
                 * at the end of the scope then it is better handled as an expression.
                 */
                if (expNeedsDtor(e.e1))
                {
                    inlineScan(exp);
                    return null;
                }

                auto s1 = inlineScanExpAsStatement(e.e1);
                auto s2 = inlineScanExpAsStatement(e.e2);
                if (!s1 && !s2)
                    return null;
                auto a = new Statements();
                a.push(!s1 ? new ExpStatement(e.e1.loc, e.e1) : s1);
                a.push(!s2 ? new ExpStatement(e.e2.loc, e.e2) : s2);
                return new CompoundStatement(exp.loc, a);
            }

            // inline as an expression
            inlineScan(exp);
            return null;
        }

        sresult = inlineScanExpAsStatement(s.exp);
    }

    override void visit(CompoundStatement s)
    {
        foreach (i; 0 .. s.statements.length)
        {
            inlineScan((*s.statements)[i]);
        }
    }

    override void visit(UnrolledLoopStatement s)
    {
        foreach (i; 0 .. s.statements.length)
        {
            inlineScan((*s.statements)[i]);
        }
    }

    override void visit(ScopeStatement s)
    {
        inlineScan(s.statement);
    }

    override void visit(WhileStatement s)
    {
        inlineScan(s.condition);
        inlineScan(s._body);
    }

    override void visit(DoStatement s)
    {
        inlineScan(s._body);
        inlineScan(s.condition);
    }

    override void visit(ForStatement s)
    {
        inlineScan(s._init);
        inlineScan(s.condition);
        inlineScan(s.increment);
        inlineScan(s._body);
    }

    override void visit(ForeachStatement s)
    {
        inlineScan(s.aggr);
        inlineScan(s._body);
    }

    override void visit(ForeachRangeStatement s)
    {
        inlineScan(s.lwr);
        inlineScan(s.upr);
        inlineScan(s._body);
    }

    override void visit(IfStatement s)
    {
        inlineScan(s.condition);
        inlineScan(s.ifbody);
        inlineScan(s.elsebody);
    }

    override void visit(SwitchStatement s)
    {
        //printf("SwitchStatement.inlineScan()\n");
        inlineScan(s.condition);
        inlineScan(s._body);
        Statement sdefault = s.sdefault;
        inlineScan(sdefault);
        s.sdefault = cast(DefaultStatement)sdefault;
        if (s.cases)
        {
            foreach (i; 0 .. s.cases.length)
            {
                Statement scase = (*s.cases)[i];
                inlineScan(scase);
                (*s.cases)[i] = cast(CaseStatement)scase;
            }
        }
    }

    override void visit(CaseStatement s)
    {
        //printf("CaseStatement.inlineScan()\n");
        inlineScan(s.exp);
        inlineScan(s.statement);
    }

    override void visit(DefaultStatement s)
    {
        inlineScan(s.statement);
    }

    override void visit(ReturnStatement s)
    {
        //printf("ReturnStatement.inlineScan()\n");
        inlineScan(s.exp);
    }

    override void visit(SynchronizedStatement s)
    {
        inlineScan(s.exp);
        inlineScan(s._body);
    }

    override void visit(WithStatement s)
    {
        inlineScan(s.exp);
        inlineScan(s._body);
    }

    override void visit(TryCatchStatement s)
    {
        inlineScan(s._body);
        if (s.catches)
        {
            foreach (c; *s.catches)
            {
                inlineScan(c.handler);
            }
        }
    }

    override void visit(TryFinallyStatement s)
    {
        inlineScan(s._body);
        inlineScan(s.finalbody);
    }

    override void visit(ThrowStatement s)
    {
        inlineScan(s.exp);
    }

    override void visit(LabelStatement s)
    {
        inlineScan(s.statement);
    }

    /********************************
     * Scan Statement s for inlining opportunities,
     * and if found replace s with an inlined one.
     * Params:
     *  s = Statement to be scanned and updated
     */
    void inlineScan(ref Statement s)
    {
        if (!s)
            return;
        assert(sresult is null);
        s.accept(this);
        if (sresult)
        {
            s = sresult;
            sresult = null;
        }
    }

    /* -------------------------- */
    void arrayInlineScan(Expressions* arguments)
    {
        if (arguments)
        {
            foreach (i; 0 .. arguments.length)
            {
                inlineScan((*arguments)[i]);
            }
        }
    }

    override void visit(Expression e)
    {
    }

    void scanVar(Dsymbol s)
    {
        //printf("scanVar(%s %s)\n", s.kind(), s.toPrettyChars());
        if (VarDeclaration vd = s.isVarDeclaration())
        {
            if (TupleDeclaration td = vd.toAlias().isTupleDeclaration())
            {
                td.foreachVar((s)
                {
                    scanVar(s); // TODO
                });
            }
            else if (vd._init)
            {
                if (ExpInitializer ie = vd._init.isExpInitializer())
                {
                    inlineScan(ie.exp);
                }
            }
        }
        else
        {
            inlineScanDsymbol(s);
        }
    }

    override void visit(DeclarationExp e)
    {
        //printf("DeclarationExp.inlineScan() %s\n", e.toChars());
        scanVar(e.declaration);
    }

    override void visit(UnaExp e)
    {
        inlineScan(e.e1);
    }

    override void visit(AssertExp e)
    {
        inlineScan(e.e1);
        inlineScan(e.msg);
    }

    override void visit(CatExp e)
    {
        if (auto lowering = e.lowering)
        {
            inlineScan(lowering);
            return;
        }

        inlineScan(e.e1);
        inlineScan(e.e2);
    }

    override void visit(CatAssignExp e)
    {
        if (auto lowering = e.lowering)
            inlineScan(lowering);
        else
            visit(cast(BinExp) e);
    }

    override void visit(BinExp e)
    {
        inlineScan(e.e1);
        inlineScan(e.e2);
    }

    override void visit(AssignExp e)
    {
        // Look for NRVO, as inlining NRVO function returns require special handling
        if (e.op == EXP.construct && e.e2.op == EXP.call)
        {
            auto ce = e.e2.isCallExp();
            if (ce.f && ce.f.isNRVO() && ce.f.nrvo_var) // NRVO
            {
                if (auto ve = e.e1.isVarExp())
                {
                    /* Inlining:
                     *   S s = foo();   // initializing by rvalue
                     *   S s = S(1);    // constructor call
                     */
                    Declaration d = ve.var;
                    if (d.storage_class & (STC.out_ | STC.ref_)) // refinit
                        goto L1;
                }
                else
                {
                    /* Inlining:
                     *   this.field = foo();   // inside constructor
                     */
                    inlineScan(e.e1);
                }

                visitCallExp(ce, e.e1, false);
                if (eresult)
                {
                    //printf("call with nrvo: %s ==> %s\n", e.toChars(), eresult.toChars());
                    return;
                }
            }
        }
    L1:
        visit(cast(BinExp)e);
    }

    override void visit(LoweredAssignExp e)
    {
        inlineScan(e.lowering);
    }

    override void visit(CallExp e)
    {
        //printf("CallExp.inlineScan() %s\n", e.toChars());
        visitCallExp(e, null, false);
    }

    /**************************************
     * Check function call to see if can be inlined,
     * and then inline it if it can.
     * Params:
     *  e = the function call
     *  eret = if !null, then this is the lvalue of the nrvo function result
     *  asStatements = if inline as statements rather than as an Expression
     * Returns:
     *  this.eresult if asStatements == false
     *  this.sresult if asStatements == true
     */
    void visitCallExp(CallExp e, Expression eret, bool asStatements)
    {
        inlineScan(e.e1);
        arrayInlineScan(e.arguments);

        //printf("visitCallExp() %s\n", e.toChars());
        FuncDeclaration fd;

        void inlineFd()
        {
            if (!fd || fd == parent)
                return;

            /* If the arguments generate temporaries that need destruction, the destruction
             * must be done after the function body is executed.
             * The easiest way to accomplish that is to do the inlining as an Expression.
             * https://issues.dlang.org/show_bug.cgi?id=16652
             */
            bool asStates = asStatements;
            if (asStates)
            {
                if (fd.inlineStatusExp == ILS.yes)
                    asStates = false;           // inline as expressions
                                                // so no need to recompute argumentsNeedDtors()
                else if (argumentsNeedDtors(e.arguments))
                    asStates = false;
            }

            if (canInline(fd, false, false, asStates))
            {
                expandInline(e.loc, fd, parent, eret, null, e.arguments, asStates, e.vthis2, eresult, sresult, again);
                if (asStatements && eresult)
                {
                    sresult = new ExpStatement(eresult.loc, eresult);
                    eresult = null;
                }
            }
        }

        /* Pattern match various ASTs looking for indirect function calls, delegate calls,
         * function literal calls, delegate literal calls, and dot member calls.
         * If so, and that is only assigned its _init.
         * If so, do 'copy propagation' of the _init value and try to inline it.
         */
        if (auto ve = e.e1.isVarExp())
        {
            fd = ve.var.isFuncDeclaration();
            if (fd)
                // delegate call
                inlineFd();
            else
            {
                // delegate literal call
                auto v = ve.var.isVarDeclaration();
                if (v && v._init && v.type.ty == Tdelegate && onlyOneAssign(v, parent))
                {
                    //printf("init: %s\n", v._init.toChars());
                    auto ei = v._init.isExpInitializer();
                    if (ei && ei.exp.op == EXP.blit)
                    {
                        Expression e2 = (cast(AssignExp)ei.exp).e2;
                        if (auto fe = e2.isFuncExp())
                        {
                            auto fld = fe.fd;
                            assert(fld.tok == TOK.delegate_);
                            fd = fld;
                            inlineFd();
                        }
                        else if (auto de = e2.isDelegateExp())
                        {
                            if (auto ve2 = de.e1.isVarExp())
                            {
                                fd = ve2.var.isFuncDeclaration();
                                inlineFd();
                            }
                        }
                    }
                }
            }
        }
        else if (auto dve = e.e1.isDotVarExp())
        {
            fd = dve.var.isFuncDeclaration();
            if (fd && fd != parent && canInline(fd, true, false, asStatements))
            {
                if (dve.e1.op == EXP.call && dve.e1.type.toBasetype().ty == Tstruct)
                {
                    /* To create ethis, we'll need to take the address
                     * of dve.e1, but this won't work if dve.e1 is
                     * a function call.
                     */
                }
                else
                {
                    expandInline(e.loc, fd, parent, eret, dve.e1, e.arguments, asStatements, e.vthis2, eresult, sresult, again);
                }
            }
        }
        else if (e.e1.op == EXP.star &&
                 (cast(PtrExp)e.e1).e1.op == EXP.variable)
        {
            auto ve = e.e1.isPtrExp().e1.isVarExp();
            VarDeclaration v = ve.var.isVarDeclaration();
            if (v && v._init && onlyOneAssign(v, parent))
            {
                //printf("init: %s\n", v._init.toChars());
                auto ei = v._init.isExpInitializer();
                if (ei && ei.exp.op == EXP.blit)
                {
                    Expression e2 = (cast(AssignExp)ei.exp).e2;
                    // function pointer call
                    if (auto se = e2.isSymOffExp())
                    {
                        fd = se.var.isFuncDeclaration();
                        inlineFd();
                    }
                    // function literal call
                    else if (auto fe = e2.isFuncExp())
                    {
                        auto fld = fe.fd;
                        assert(fld.tok == TOK.function_);
                        fd = fld;
                        inlineFd();
                    }
                }
            }
        }
        else if (auto fe = e.e1.isFuncExp())
        {
            if (fe.fd)
            {
                fd = fe.fd;
                inlineFd();
            }
            else
                return;
        }
        else
        {
            return;
        }

        if (global.params.v.verbose && (eresult || sresult))
            message("inlined   %s =>\n          %s", fd.toPrettyChars(), parent.toPrettyChars());

        if (eresult && e.type.ty != Tvoid)
        {
            Expression ex = eresult;
            while (ex.op == EXP.comma)
            {
                ex.type = e.type;
                ex = ex.isCommaExp().e2;
            }
            ex.type = e.type;
        }
    }

    override void visit(SliceExp e)
    {
        inlineScan(e.e1);
        inlineScan(e.lwr);
        inlineScan(e.upr);
    }

    override void visit(TupleExp e)
    {
        //printf("TupleExp.inlineScan()\n");
        inlineScan(e.e0);
        arrayInlineScan(e.exps);
    }

    override void visit(ArrayLiteralExp e)
    {
        //printf("ArrayLiteralExp.inlineScan()\n");
        inlineScan(e.basis);
        arrayInlineScan(e.elements);
    }

    override void visit(AssocArrayLiteralExp e)
    {
        //printf("AssocArrayLiteralExp.inlineScan()\n");
        arrayInlineScan(e.keys);
        arrayInlineScan(e.values);
    }

    override void visit(StructLiteralExp e)
    {
        //printf("StructLiteralExp.inlineScan()\n");
        if (e.stageflags & StructLiteralExp.StageFlags.inlineScan)
            return;
        const old = e.stageflags;
        e.stageflags |= StructLiteralExp.StageFlags.inlineScan;
        arrayInlineScan(e.elements);
        e.stageflags = old;
    }

    override void visit(ArrayExp e)
    {
        //printf("ArrayExp.inlineScan()\n");
        inlineScan(e.e1);
        arrayInlineScan(e.arguments);
    }

    override void visit(CondExp e)
    {
        inlineScan(e.econd);
        inlineScan(e.e1);
        inlineScan(e.e2);
    }

    /********************************
     * Scan Expression e for inlining opportunities,
     * and if found replace e with an inlined one.
     * Params:
     *  e = Expression to be scanned and updated
     */
    void inlineScan(ref Expression e)
    {
        if (!e)
            return;
        assert(eresult is null);
        e.accept(this);
        if (eresult)
        {
            e = eresult;
            eresult = null;
        }
    }
}

/***********************************************************
 * Walk the trees, looking for functions to inline.
 * Inline any that can be.
 */
private extern (C++) final class InlineScanVisitorDsymbol : Visitor
{
    alias visit = Visitor.visit;
public:

    extern (D) this() scope @safe
    {
    }

    /*************************************
     * Look for function inlining possibilities.
     */
    override void visit(Dsymbol d)
    {
        // Most Dsymbols aren't functions
    }

    override void visit(FuncDeclaration fd)
    {
        static if (LOG)
        {
            printf("FuncDeclaration.inlineScan('%s')\n", fd.toPrettyChars());
        }
        if (!(global.params.useInline || fd.hasAlwaysInlines))
            return;
        if (fd.isUnitTestDeclaration() && !global.params.useUnitTests || fd.inlineScanned)
            return;
        if (fd.fbody && !fd.isNaked())
        {
            while (1)
            {
                fd.inlineNest++;
                fd.inlineScanned = true;

                scope InlineScanVisitor v = new InlineScanVisitor();
                v.parent = fd;
                v.inlineScan(fd.fbody);
                bool again = v.again;

                fd.inlineNest--;
                if (!again)
                    break;
            }
        }
    }

    override void visit(AttribDeclaration d)
    {
        Dsymbols* decls = d.include(null);
        if (decls)
        {
            foreach (i; 0 .. decls.length)
            {
                Dsymbol s = (*decls)[i];
                //printf("AttribDeclaration.inlineScan %s\n", s.toChars());
                s.accept(this);
            }
        }
    }

    override void visit(AggregateDeclaration ad)
    {
        //printf("AggregateDeclaration.inlineScan(%s)\n", toChars());
        if (ad.members)
        {
            foreach (i; 0 .. ad.members.length)
            {
                Dsymbol s = (*ad.members)[i];
                //printf("inline scan aggregate symbol '%s'\n", s.toChars());
                s.accept(this);
            }
        }
    }

    override void visit(TemplateInstance ti)
    {
        static if (LOG)
        {
            printf("TemplateInstance.inlineScan('%s')\n", ti.toChars());
        }
        if (!ti.errors && ti.members)
        {
            foreach (i; 0 .. ti.members.length)
            {
                Dsymbol s = (*ti.members)[i];
                s.accept(this);
            }
        }
    }
}

/***********************************************************
 * Test that `fd` can be inlined.
 *
 * Params:
 *  hasthis = `true` if the function call has explicit 'this' expression.
 *  hdrscan = `true` if the inline scan is for 'D header' content.
 *  statementsToo = `true` if the function call is placed on ExpStatement.
 *      It means more code-block dependent statements in fd body - ForStatement,
 *      ThrowStatement, etc. can be inlined.
 *
 * Returns:
 *  true if the function body can be expanded.
 *
 * Todo:
 *  - Would be able to eliminate `hasthis` parameter, because semantic analysis
 *    no longer accepts calls of contextful function without valid 'this'.
 *  - Would be able to eliminate `hdrscan` parameter, because it's always false.
 */
private bool canInline(FuncDeclaration fd, bool hasthis, bool hdrscan, bool statementsToo)
{
    int cost;

    static if (CANINLINE_LOG)
    {
        printf("FuncDeclaration.canInline(hasthis = %d, statementsToo = %d, '%s')\n",
            hasthis, statementsToo, fd.toPrettyChars());
    }

    if (fd.needThis() && !hasthis)
        return false;

    if (fd.inlineNest)
    {
        static if (CANINLINE_LOG)
        {
            printf("\t1: no, inlineNest = %d, semanticRun = %d\n", fd.inlineNest, fd.semanticRun);
        }
        return false;
    }

    if (fd.semanticRun < PASS.semantic3 && !hdrscan)
    {
        if (!fd.fbody)
            return false;
        if (!functionSemantic3(fd))
            return false;
        Module.runDeferredSemantic3();
        if (global.errors)
            return false;
        assert(fd.semanticRun >= PASS.semantic3done);
    }

    if (fd.skipCodegen)
        return false;

    final switch (statementsToo ? fd.inlineStatusStmt : fd.inlineStatusExp)
    {
    case ILS.yes:
        static if (CANINLINE_LOG)
        {
            printf("\t1: yes %s\n", fd.toChars());
        }
        return true;
    case ILS.no:
        static if (CANINLINE_LOG)
        {
            printf("\t1: no %s\n", fd.toChars());
        }
        return false;
    case ILS.uninitialized:
        break;
    }

    final switch (fd.inlining)
    {
    case PINLINE.default_:
        if (!global.params.useInline)
            return false;
        break;
    case PINLINE.always:
        break;
    case PINLINE.never:
        return false;
    }

    if (fd.type)
    {
        TypeFunction tf = fd.type.isTypeFunction();

        // no variadic parameter lists
        if (tf.parameterList.varargs == VarArg.variadic ||
            tf.parameterList.varargs == VarArg.KRvariadic)
            goto Lno;

        /* No lazy parameters when inlining by statement, as the inliner tries to
         * operate on the created delegate itself rather than the return value.
         * Discussion: https://github.com/dlang/dmd/pull/6815
         */
        if (statementsToo && fd.parameters)
        {
            foreach (param; *fd.parameters)
            {
                if (param.storage_class & STC.lazy_)
                    goto Lno;
            }
        }

        static bool hasDtor(Type t)
        {
            auto tv = t.baseElemOf();
            return tv.ty == Tstruct || tv.ty == Tclass; // for now assume these might have a destructor
        }

        /* Don't inline a function that returns non-void, but has
         * no or multiple return expression.
         * When inlining as a statement:
         * 1. don't inline array operations, because the order the arguments
         *    get evaluated gets reversed. This is the same issue that e2ir.callfunc()
         *    has with them
         * 2. don't inline when the return value has a destructor, as it doesn't
         *    get handled properly
         */
        if (auto tfnext = tf.next)
        {
            /* for the isTypeSArray() case see https://github.com/dlang/dmd/pull/16145#issuecomment-1932776873
             */
            if (tfnext.ty != Tvoid &&
                (!fd.hasReturnExp ||
                 hasDtor(tfnext) && (statementsToo || tfnext.isTypeSArray())) &&
                !hdrscan)
            {
                static if (CANINLINE_LOG)
                {
                    printf("\t3: no %s\n", fd.toChars());
                }
                goto Lno;
            }
        }

        /* https://issues.dlang.org/show_bug.cgi?id=14560
         * If fd returns void, all explicit `return;`s
         * must not appear in the expanded result.
         * See also ReturnStatement.doInlineAs!Statement().
         */
    }

    // cannot inline constructor calls because we need to convert:
    //      return;
    // to:
    //      return this;
    // ensure() has magic properties the inliner loses
    // require() has magic properties too
    // see bug 7699
    // no nested references to this frame
    if (!fd.fbody ||
        fd.ident == Id.ensure ||
        (fd.ident == Id.require &&
         fd.toParent().isFuncDeclaration() &&
         fd.toParent().isFuncDeclaration().needThis()) ||
        !hdrscan && (fd.isSynchronized() ||
                     fd.isImportedSymbol() ||
                     fd.hasNestedFrameRefs() ||
                     (fd.isVirtual() && !fd.isFinalFunc())))
    {
        static if (CANINLINE_LOG)
        {
            printf("\t4: no %s\n", fd.toChars());
        }
        goto Lno;
    }

    // cannot inline functions as statement if they have multiple
    //  return statements
    if (fd.hasMultipleReturnExp && statementsToo)
    {
        static if (CANINLINE_LOG)
        {
            printf("\t5: no %s\n", fd.toChars());
        }
        goto Lno;
    }

    {
        cost = inlineCostFunction(fd, hasthis, hdrscan);
    }
    static if (CANINLINE_LOG)
    {
        printf("\tcost = %d for %s\n", cost, fd.toChars());
    }

    if (tooCostly(cost))
        goto Lno;
    if (!statementsToo && cost > COST_MAX)
        goto Lno;

    if (!hdrscan)
    {
        // Don't modify inlineStatus for header content scan
        if (statementsToo)
            fd.inlineStatusStmt = ILS.yes;
        else
            fd.inlineStatusExp = ILS.yes;

        inlineScanDsymbol(fd); // Don't scan recursively for header content scan

        if (fd.inlineStatusExp == ILS.uninitialized)
        {
            // Need to redo cost computation, as some statements or expressions have been inlined
            cost = inlineCostFunction(fd, hasthis, hdrscan);
            static if (CANINLINE_LOG)
            {
                printf("recomputed cost = %d for %s\n", cost, fd.toChars());
            }

            if (tooCostly(cost))
                goto Lno;
            if (!statementsToo && cost > COST_MAX)
                goto Lno;

            if (statementsToo)
                fd.inlineStatusStmt = ILS.yes;
            else
                fd.inlineStatusExp = ILS.yes;
        }
    }
    static if (CANINLINE_LOG)
    {
        printf("\t2: yes %s\n", fd.toChars());
    }
    return true;

Lno:
    if (fd.inlining == PINLINE.always && global.params.useWarnings == DiagnosticReporting.inform)
        warning(fd.loc, "cannot inline function `%s`", fd.toPrettyChars());

    if (!hdrscan) // Don't modify inlineStatus for header content scan
    {
        if (statementsToo)
            fd.inlineStatusStmt = ILS.no;
        else
            fd.inlineStatusExp = ILS.no;
    }
    static if (CANINLINE_LOG)
    {
        printf("\t2: no %s\n", fd.toChars());
    }
    return false;
}

/***********************************************************
 * Expand a function call inline,
 *      ethis.fd(arguments)
 *
 * Params:
 *      callLoc = location of CallExp
 *      fd = function to expand
 *      parent = function that the call to fd is being expanded into
 *      eret = if !null then the lvalue of where the nrvo return value goes
 *      ethis = 'this' reference
 *      arguments = arguments passed to fd
 *      asStatements = expand to Statements rather than Expressions
 *      eresult = if expanding to an expression, this is where the expression is written to
 *      sresult = if expanding to a statement, this is where the statement is written to
 *      again = if true, then fd can be inline scanned again because there may be
 *           more opportunities for inlining
 */
private void expandInline(Loc callLoc, FuncDeclaration fd, FuncDeclaration parent, Expression eret,
        Expression ethis, Expressions* arguments, bool asStatements, VarDeclaration vthis2,
        out Expression eresult, out Statement sresult, out bool again)
{
    auto tf = fd.type.isTypeFunction();
    static if (LOG || CANINLINE_LOG || EXPANDINLINE_LOG)
        printf("FuncDeclaration.expandInline('%s', %d)\n", fd.toChars(), asStatements);
    static if (EXPANDINLINE_LOG)
    {
        if (eret) printf("\teret = %s\n", eret.toChars());
        if (ethis) printf("\tethis = %s\n", ethis.toChars());
    }
    scope ids = new InlineDoState(parent, fd);

    if (fd.isNested())
    {
        if (!parent.inlinedNestedCallees)
            parent.inlinedNestedCallees = new FuncDeclarations();
        parent.inlinedNestedCallees.push(fd);
    }

    VarDeclaration vret;    // will be set the function call result
    if (eret)
    {
        if (auto ve = eret.isVarExp())
        {
            vret = ve.var.isVarDeclaration();
            assert(!(vret.storage_class & (STC.out_ | STC.ref_)));
            eret = null;
        }
        else
        {
            /* Inlining:
             *   this.field = foo();   // inside constructor
             */
            auto ei = new ExpInitializer(callLoc, null);
            auto tmp = Identifier.generateId("__retvar");
            vret = new VarDeclaration(fd.loc, eret.type, tmp, ei);
            vret.storage_class |= STC.temp | STC.ref_;
            vret._linkage = LINK.d;
            vret.parent = parent;

            ei.exp = new ConstructExp(fd.loc, vret, eret);
            ei.exp.type = vret.type;

            auto de = new DeclarationExp(fd.loc, vret);
            de.type = Type.tvoid;
            eret = de;
        }

        if (!asStatements && fd.nrvo_var)
        {
            ids.from.push(fd.nrvo_var);
            ids.to.push(vret);
        }
    }
    else
    {
        if (!asStatements && fd.nrvo_var)
        {
            auto tmp = Identifier.generateId("__retvar");
            vret = new VarDeclaration(fd.loc, fd.nrvo_var.type, tmp, new VoidInitializer(fd.loc));
            assert(!tf.isRef);
            vret.storage_class = STC.temp | STC.rvalue;
            vret._linkage = tf.linkage;
            vret.parent = parent;

            auto de = new DeclarationExp(fd.loc, vret);
            de.type = Type.tvoid;
            eret = de;

            ids.from.push(fd.nrvo_var);
            ids.to.push(vret);
        }
    }

    // Set up vthis
    VarDeclaration vthis;
    if (ethis)
    {
        Expression e0;
        ethis = Expression.extractLast(ethis, e0);
        assert(vthis2 || !fd.hasDualContext());
        if (vthis2)
        {
            // void*[2] __this = [ethis, this]
            if (ethis.type.ty == Tstruct)
            {
                // &ethis
                Type t = ethis.type.pointerTo();
                ethis = new AddrExp(ethis.loc, ethis);
                ethis.type = t;
            }
            auto elements = new Expressions(2);
            (*elements)[0] = ethis;
            (*elements)[1] = new NullExp(Loc.initial, Type.tvoidptr);
            Expression ae = new ArrayLiteralExp(vthis2.loc, vthis2.type, elements);
            Expression ce = new ConstructExp(vthis2.loc, vthis2, ae);
            ce.type = vthis2.type;
            vthis2._init = new ExpInitializer(vthis2.loc, ce);
            vthis = vthis2;
        }
        else if (auto ve = ethis.isVarExp())
        {
            vthis = ve.var.isVarDeclaration();
        }
        else
        {
            //assert(ethis.type.ty != Tpointer);
            if (ethis.type.ty == Tpointer)
            {
                Type t = ethis.type.nextOf();
                ethis = new PtrExp(ethis.loc, ethis);
                ethis.type = t;
            }

            auto ei = new ExpInitializer(fd.loc, ethis);
            vthis = new VarDeclaration(fd.loc, ethis.type, Id.This, ei);
            if (ethis.type.ty != Tclass)
                vthis.storage_class = STC.ref_;
            else
                vthis.storage_class = STC.in_;
            vthis._linkage = LINK.d;
            vthis.parent = parent;

            ei.exp = new ConstructExp(fd.loc, vthis, ethis);
            ei.exp.type = vthis.type;

            auto de = new DeclarationExp(fd.loc, vthis);
            de.type = Type.tvoid;
            e0 = Expression.combine(e0, de);
        }
        ethis = e0;

        ids.vthis = vthis;
    }

    // Set up parameters
    Expression eparams;
    if (arguments && arguments.length)
    {
        assert(fd.parameters.length == arguments.length);
        foreach (i; 0 .. arguments.length)
        {
            auto vfrom = (*fd.parameters)[i];
            auto arg = (*arguments)[i];

            auto ei = new ExpInitializer(vfrom.loc, arg);
            auto vto = new VarDeclaration(vfrom.loc, vfrom.type, vfrom.ident, ei);
            vto.storage_class |= vfrom.storage_class & (STC.temp | STC.IOR | STC.lazy_ | STC.nodtor);
            vto._linkage = vfrom._linkage;
            vto.parent = parent;
            //printf("vto = '%s', vto.storage_class = x%x\n", vto.toChars(), vto.storage_class);
            //printf("vto.parent = '%s'\n", parent.toChars());

            if (VarExp ve = arg.isVarExp())
            {
                VarDeclaration va = ve.var.isVarDeclaration();
                if (va && va.isArgDtorVar)
                {
                    assert(vto.storage_class & STC.nodtor);
                    // The destructor is called on va so take it by ref
                    vto.storage_class |= STC.ref_;
                }
            }

            // Even if vto is STC.lazy_, `vto = arg` is handled correctly in glue layer.
            ei.exp = new BlitExp(vto.loc, vto, arg);
            ei.exp.type = vto.type;

            ids.from.push(vfrom);
            ids.to.push(vto);

            auto de = new DeclarationExp(vto.loc, vto);
            de.type = Type.tvoid;
            eparams = Expression.combine(eparams, de);

            /* If function pointer or delegate parameters are present,
             * inline scan again because if they are initialized to a symbol,
             * any calls to the fp or dg can be inlined.
             */
            if (vfrom.type.ty == Tdelegate ||
                vfrom.type.isPtrToFunction())
            {
                if (auto ve = arg.isVarExp())
                {
                    if (ve.var.isFuncDeclaration())
                        again = true;
                }
                else if (auto se = arg.isSymOffExp())
                {
                    if (se.var.isFuncDeclaration())
                        again = true;
                }
                else if (arg.op == EXP.function_ || arg.op == EXP.delegate_)
                    again = true;
            }
        }
    }

    if (asStatements)
    {
        /* Construct:
         *  { eret; ethis; eparams; fd.fbody; }
         * or:
         *  { eret; ethis; try { eparams; fd.fbody; } finally { vthis.edtor; } }
         */

        auto as = new Statements();
        if (eret)
            as.push(new ExpStatement(callLoc, eret));
        if (ethis)
            as.push(new ExpStatement(callLoc, ethis));

        auto as2 = as;
        if (vthis && !vthis.isDataseg())
        {
            if (vthis.needsScopeDtor())
            {
                // same with ExpStatement.scopeCode()
                as2 = new Statements();
                vthis.storage_class |= STC.nodtor;
            }
        }

        if (eparams)
            as2.push(new ExpStatement(callLoc, eparams));

        fd.inlineNest++;
        Statement s = doInlineAs!Statement(fd.fbody, ids);
        fd.inlineNest--;
        as2.push(s);

        if (as2 != as)
        {
            as.push(new TryFinallyStatement(callLoc,
                        new CompoundStatement(callLoc, as2),
                        new DtorExpStatement(callLoc, vthis.edtor, vthis)));
        }

        sresult = new ScopeStatement(callLoc, new CompoundStatement(callLoc, as), callLoc);

        static if (EXPANDINLINE_LOG)
            printf("\n[%s] %s expandInline sresult =\n%s\n",
                callLoc.toChars(), fd.toPrettyChars(), toChars(sresult));
    }
    else
    {
        /* Construct:
         *  (eret, ethis, eparams, fd.fbody)
         */

        fd.inlineNest++;
        auto e = doInlineAs!Expression(fd.fbody, ids);
        fd.inlineNest--;

        import dmd.expressionsem : toLvalue;
        // https://issues.dlang.org/show_bug.cgi?id=11322
        if (tf.isRef)
            e = e.toLvalue(null, "`ref` return");

        /* If the inlined function returns a copy of a struct,
         * and then the return value is used subsequently as an
         * lvalue, as in a struct return that is then used as a 'this'.
         * Taking the address of the return value will be taking the address
         * of the original, not the copy. Fix this by assigning the return value to
         * a temporary, then returning the temporary. If the temporary is used as an
         * lvalue, it will work.
         * This only happens with struct returns.
         * See https://issues.dlang.org/show_bug.cgi?id=2127 for an example.
         *
         * On constructor call making __inlineretval is merely redundant, because
         * the returned reference is exactly same as vthis, and the 'this' variable
         * already exists at the caller side.
         */
        if (tf.next.ty == Tstruct && !fd.nrvo_var && !fd.isCtorDeclaration() &&
            !isConstruction(e))
        {
            /* Generate a new variable to hold the result and initialize it with the
             * inlined body of the function:
             *   tret __inlineretval = e;
             */
            auto ei = new ExpInitializer(callLoc, e);
            auto tmp = Identifier.generateId("__inlineretval");
            auto vd = new VarDeclaration(callLoc, tf.next, tmp, ei);
            vd.storage_class = STC.temp | (tf.isRef ? STC.ref_ : STC.rvalue);
            vd._linkage = tf.linkage;
            vd.parent = parent;

            ei.exp = new ConstructExp(callLoc, vd, e);
            ei.exp.type = vd.type;

            auto de = new DeclarationExp(callLoc, vd);
            de.type = Type.tvoid;

            // Chain the two together:
            //   ( typeof(return) __inlineretval = ( inlined body )) , __inlineretval
            e = Expression.combine(de, new VarExp(callLoc, vd));
        }

        // https://issues.dlang.org/show_bug.cgi?id=15210
        if (tf.next.ty == Tvoid && e && e.type.ty != Tvoid)
        {
            e = new CastExp(callLoc, e, Type.tvoid);
            e.type = Type.tvoid;
        }

        eresult = Expression.combine(eresult, eret, ethis, eparams);
        eresult = Expression.combine(eresult, e);

        static if (EXPANDINLINE_LOG)
            printf("\n[%s] %s expandInline eresult = %s\n",
                callLoc.toChars(), fd.toPrettyChars(), eresult.toChars());
    }

    // Need to reevaluate whether parent can now be inlined
    // in expressions, as we might have inlined statements
    parent.inlineStatusExp = ILS.uninitialized;
}

/****************************************************
 * Determine if the value of `e` is the result of construction.
 *
 * Params:
 *      e = expression to check
 * Returns:
 *      true for value generated by a constructor or struct literal
 */
private bool isConstruction(Expression e)
{
    e = lastComma(e);

    if (e.op == EXP.structLiteral)
    {
        return true;
    }
    /* Detect:
     *    structliteral.ctor(args)
     */
    else if (e.op == EXP.call)
    {
        auto ce = cast(CallExp)e;
        if (ce.e1.op == EXP.dotVariable)
        {
            auto dve = cast(DotVarExp)ce.e1;
            auto fd = dve.var.isFuncDeclaration();
            if (fd && fd.isCtorDeclaration())
            {
                if (dve.e1.op == EXP.structLiteral)
                {
                    return true;
                }
            }
        }
    }
    return false;
}


/***********************************************************
 * Determine if v is 'head const', meaning
 * that once it is initialized it is not changed
 * again.
 *
 * This is done using a primitive flow analysis.
 *
 * v is head const if v is const or immutable.
 * Otherwise, v is assumed to be head const unless one of the
 * following is true:
 *      1. v is a `ref` or `out` variable
 *      2. v is a parameter and fd is a variadic function
 *      3. v is assigned to again
 *      4. the address of v is taken
 *      5. v is referred to by a function nested within fd
 *      6. v is ever assigned to a `ref` or `out` variable
 *      7. v is ever passed to another function as `ref` or `out`
 *
 * Params:
 *      v       variable to check
 *      fd      function that v is local to
 * Returns:
 *      true if v's initializer is the only value assigned to v
 */
private bool onlyOneAssign(VarDeclaration v, FuncDeclaration fd) @safe
{
    if (!v.type.isMutable())
        return true;            // currently the only case handled atm
    return false;
}

/************************************************************
 * See if arguments to a function are creating temporaries that
 * will need destruction after the function is executed.
 * Params:
 *      arguments = arguments to function
 * Returns:
 *      true if temporaries need destruction
 */

private bool argumentsNeedDtors(Expressions* arguments)
{
    if (arguments)
    {
        foreach (arg; *arguments)
        {
            if (expNeedsDtor(arg))
                return true;
        }
    }
    return false;
}

/************************************************************
 * See if expression is creating temporaries that
 * will need destruction at the end of the scope.
 * Params:
 *      exp = expression
 * Returns:
 *      true if temporaries need destruction
 */

private bool expNeedsDtor(Expression exp)
{
    extern (C++) final class NeedsDtor : StoppableVisitor
    {
        alias visit = typeof(super).visit;
        Expression exp;

    public:
        extern (D) this(Expression exp) scope @safe
        {
            this.exp = exp;
        }

        override void visit(Expression)
        {
        }

        override void visit(DeclarationExp de)
        {
            Dsymbol_needsDtor(de.declaration);
        }

        void Dsymbol_needsDtor(Dsymbol s)
        {
            /* This mirrors logic of Dsymbol_toElem() in e2ir.d
             * perhaps they can be combined.
             */

            void symbolDg(Dsymbol s)
            {
                Dsymbol_needsDtor(s);
            }

            if (auto vd = s.isVarDeclaration())
            {
                s = s.toAlias();
                if (s != vd)
                    return Dsymbol_needsDtor(s);
                if (vd.isStatic() || vd.storage_class & (STC.extern_ | STC.gshared | STC.manifest))
                    return;
                if (vd.needsScopeDtor())
                {
                    stop = true;
                }
            }
            else if (auto tm = s.isTemplateMixin())
            {
                tm.members.foreachDsymbol(&symbolDg);
            }
            else if (auto ad = s.isAttribDeclaration())
            {
                ad.include(null).foreachDsymbol(&symbolDg);
            }
            else if (auto td = s.isTupleDeclaration())
            {
                td.foreachVar(&symbolDg);
            }


        }
    }

    scope NeedsDtor ct = new NeedsDtor(exp);
    return walkPostorder(exp, ct);
}
