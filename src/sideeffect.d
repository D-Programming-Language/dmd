// Compiler implementation of the D programming language
// Copyright (c) 1999-2016 by Digital Mars
// All Rights Reserved
// written by Walter Bright
// http://www.digitalmars.com
// Distributed under the Boost Software License, Version 1.0.
// http://www.boost.org/LICENSE_1_0.txt

module ddmd.sideeffect;

import ddmd.apply;
import ddmd.arraytypes;
import ddmd.declaration;
import ddmd.dscope;
import ddmd.expression;
import ddmd.func;
import ddmd.globals;
import ddmd.identifier;
import ddmd.init;
import ddmd.mtype;
import ddmd.tokens;
import ddmd.visitor;

/**************************************************
 * Front-end expression rewriting should create temporary variables for
 * non trivial sub-expressions in order to:
 *  1. save evaluation order
 *  2. prevent sharing of sub-expression in AST
 */
extern (C++) bool isTrivialExp(Expression e)
{
    extern (C++) final class IsTrivialExp : StoppableVisitor
    {
        alias visit = super.visit;
    public:
        extern (D) this()
        {
        }

        override void visit(Expression e)
        {
            /* Bugzilla 11201: CallExp is always non trivial expression,
             * especially for inlining.
             */
            if (e.op == TOKcall)
            {
                stop = true;
                return;
            }
            // stop walking if we determine this expression has side effects
            stop = lambdaHasSideEffect(e);
        }
    }

    scope IsTrivialExp v = new IsTrivialExp();
    return walkPostorder(e, v) == false;
}

/********************************************
 * Determine if Expression has any side effects.
 */
extern (C++) bool hasSideEffect(Expression e)
{
    extern (C++) final class LambdaHasSideEffect : StoppableVisitor
    {
        alias visit = super.visit;
    public:
        extern (D) this()
        {
        }

        override void visit(Expression e)
        {
            // stop walking if we determine this expression has side effects
            stop = lambdaHasSideEffect(e);
        }
    }

    scope LambdaHasSideEffect v = new LambdaHasSideEffect();
    return walkPostorder(e, v);
}

/********************************************
 * Determine if the call of f, or function type or delegate type t1, has any side effects.
 * Returns:
 *      0   has any side effects
 *      1   nothrow + constant purity
 *      2   nothrow + strong purity
 */
extern (C++) int callSideEffectLevel(FuncDeclaration f)
{
    /* Bugzilla 12760: ctor call always has side effects.
     */
    if (f.isCtorDeclaration())
        return 0;
    assert(f.type.ty == Tfunction);
    TypeFunction tf = cast(TypeFunction)f.type;
    if (tf.isnothrow)
    {
        PURE purity = f.isPure();
        if (purity == PUREstrong)
            return 2;
        if (purity == PUREconst)
            return 1;
    }
    return 0;
}

extern (C++) int callSideEffectLevel(Type t)
{
    t = t.toBasetype();
    TypeFunction tf;
    if (t.ty == Tdelegate)
        tf = cast(TypeFunction)(cast(TypeDelegate)t).next;
    else
    {
        assert(t.ty == Tfunction);
        tf = cast(TypeFunction)t;
    }
    tf.purityLevel();
    PURE purity = tf.purity;
    if (t.ty == Tdelegate && purity > PUREweak)
    {
        if (tf.isMutable())
            purity = PUREweak;
        else if (!tf.isImmutable())
            purity = PUREconst;
    }
    if (tf.isnothrow)
    {
        if (purity == PUREstrong)
            return 2;
        if (purity == PUREconst)
            return 1;
    }
    return 0;
}

extern (C++) bool lambdaHasSideEffect(Expression e)
{
    switch (e.op)
    {
    // Sort the cases by most frequently used first
    case TOKassign:
    case TOKplusplus:
    case TOKminusminus:
    case TOKdeclaration:
    case TOKconstruct:
    case TOKblit:
    case TOKaddass:
    case TOKminass:
    case TOKcatass:
    case TOKmulass:
    case TOKdivass:
    case TOKmodass:
    case TOKshlass:
    case TOKshrass:
    case TOKushrass:
    case TOKandass:
    case TOKorass:
    case TOKxorass:
    case TOKpowass:
    case TOKin:
    case TOKremove:
    case TOKassert:
    case TOKhalt:
    case TOKdelete:
    case TOKnew:
    case TOKnewanonclass:
        return true;
    case TOKcall:
        {
            CallExp ce = cast(CallExp)e;
            /* Calling a function or delegate that is pure nothrow
             * has no side effects.
             */
            if (ce.e1.type)
            {
                Type t = ce.e1.type.toBasetype();
                if (t.ty == Tdelegate)
                    t = (cast(TypeDelegate)t).next;
                if (t.ty == Tfunction && (ce.f ? callSideEffectLevel(ce.f) : callSideEffectLevel(ce.e1.type)) > 0)
                {
                }
                else
                    return true;
            }
            break;
        }
    case TOKcast:
        {
            CastExp ce = cast(CastExp)e;
            /* if:
             *  cast(classtype)func()  // because it may throw
             */
            if (ce.to.ty == Tclass && ce.e1.op == TOKcall && ce.e1.type.ty == Tclass)
                return true;
            break;
        }
    default:
        break;
    }
    return false;
}

/***********************************
 * The result of this expression will be discarded.
 * Complain if the operation has no side effects (and hence is meaningless).
 */
extern (C++) void discardValue(Expression e)
{
    if (lambdaHasSideEffect(e)) // check side-effect shallowly
        return;
    switch (e.op)
    {
    case TOKcast:
        {
            CastExp ce = cast(CastExp)e;
            if (ce.to.equals(Type.tvoid))
            {
                /*
                 * Don't complain about an expression with no effect if it was cast to void
                 */
                return;
            }
            break; // complain
        }
    case TOKerror:
        return;
    case TOKvar:
        {
            VarDeclaration v = (cast(VarExp)e).var.isVarDeclaration();
            if (v && (v.storage_class & STCtemp))
            {
                // Bugzilla 5810: Don't complain about an internal generated variable.
                return;
            }
            break;
        }
    case TOKcall:
        /* Issue 3882: */
        if (global.params.warnings && !global.gag)
        {
            CallExp ce = cast(CallExp)e;
            if (e.type.ty == Tvoid)
            {
                /* Don't complain about calling void-returning functions with no side-effect,
                 * because purity and nothrow are inferred, and because some of the
                 * runtime library depends on it. Needs more investigation.
                 *
                 * One possible solution is to restrict this message to only be called in hierarchies that
                 * never call assert (and or not called from inside unittest blocks)
                 */
            }
            else if (ce.e1.type)
            {
                Type t = ce.e1.type.toBasetype();
                if (t.ty == Tdelegate)
                    t = (cast(TypeDelegate)t).next;
                if (t.ty == Tfunction && (ce.f ? callSideEffectLevel(ce.f) : callSideEffectLevel(ce.e1.type)) > 0)
                {
                    const(char)* s;
                    if (ce.f)
                        s = ce.f.toPrettyChars();
                    else if (ce.e1.op == TOKstar)
                    {
                        // print 'fp' if ce->e1 is (*fp)
                        s = (cast(PtrExp)ce.e1).e1.toChars();
                    }
                    else
                        s = ce.e1.toChars();
                    e.warning("calling %s without side effects discards return value of type %s, prepend a cast(void) if intentional", s, e.type.toChars());
                }
            }
        }
        return;
    case TOKscope:
        e.error("%s has no effect", e.toChars());
        return;
    case TOKandand:
        {
            AndAndExp aae = cast(AndAndExp)e;
            discardValue(aae.e2);
            return;
        }
    case TOKoror:
        {
            OrOrExp ooe = cast(OrOrExp)e;
            discardValue(ooe.e2);
            return;
        }
    case TOKquestion:
        {
            CondExp ce = cast(CondExp)e;
            /* Bugzilla 6178 & 14089: Either CondExp::e1 or e2 may have
             * redundant expression to make those types common. For example:
             *
             *  struct S { this(int n); int v; alias v this; }
             *  S[int] aa;
             *  aa[1] = 0;
             *
             * The last assignment statement will be rewitten to:
             *
             *  1 in aa ? aa[1].value = 0 : (aa[1] = 0, aa[1].this(0)).value;
             *
             * The last DotVarExp is necessary to take assigned value.
             *
             *  int value = (aa[1] = 0);    // value = aa[1].value
             *
             * To avoid false error, discardValue() should be called only when
             * the both tops of e1 and e2 have actually no side effects.
             */
            if (!lambdaHasSideEffect(ce.e1) && !lambdaHasSideEffect(ce.e2))
            {
                discardValue(ce.e1);
                discardValue(ce.e2);
            }
            return;
        }
    case TOKcomma:
        {
            CommaExp ce = cast(CommaExp)e;
            /* Check for compiler-generated code of the form  auto __tmp, e, __tmp;
             * In such cases, only check e for side effect (it's OK for __tmp to have
             * no side effect).
             * See Bugzilla 4231 for discussion
             */
            CommaExp firstComma = ce;
            while (firstComma.e1.op == TOKcomma)
                firstComma = cast(CommaExp)firstComma.e1;
            if (firstComma.e1.op == TOKdeclaration && ce.e2.op == TOKvar && (cast(DeclarationExp)firstComma.e1).declaration == (cast(VarExp)ce.e2).var)
            {
                return;
            }
            // Don't check e1 until we cast(void) the a,b code generation
            //discardValue(ce->e1);
            discardValue(ce.e2);
            return;
        }
    case TOKtuple:
        /* Pass without complaint if any of the tuple elements have side effects.
         * Ideally any tuple elements with no side effects should raise an error,
         * this needs more investigation as to what is the right thing to do.
         */
        if (!hasSideEffect(e))
            break;
        return;
    default:
        break;
    }
    e.error("%s has no effect in expression (%s)", Token.toChars(e.op), e.toChars());
}

/**************************************************
 * Build a temporary variable to copy the value of e into.
 * Params:
 *  stc = storage classes will be added to the made temporary variable
 *  name = name for temporary variable
 *  e = original expression
 * Returns:
 *  Newly created temporary variable.
 */
VarDeclaration copyToTemp(StorageClass stc, const char* name, Expression e)
{
    assert(name && name[0] == '_' && name[1] == '_');
    auto id = Identifier.generateId(name);
    auto ez = new ExpInitializer(e.loc, e);
    auto vd = new VarDeclaration(e.loc, e.type, id, ez);
    vd.storage_class = stc;
    vd.storage_class |= STCtemp;
    vd.storage_class |= STCctfe; // temporary is always CTFEable
    return vd;
}

/**************************************************
 * Build a temporary variable to extract e's evaluation, if e is not trivial.
 * Params:
 *  sc = scope
 *  name = name for temporary variable
 *  e0 = a new side effect part will be appended to it.
 *  e = original expression
 *  alwaysCopy = if true, build new temporary variable even if e is trivial.
 * Returns:
 *  When e is trivial and alwaysCopy == false, e itself is returned.
 *  Otherwise, a new VarExp is returned.
 * Note:
 *  e's lvalue-ness will be handled well by STCref or STCrvalue.
 */
Expression extractSideEffect(Scope* sc, const char* name,
    ref Expression e0, Expression e, bool alwaysCopy = false)
{
    if (!alwaysCopy && isTrivialExp(e))
        return e;

    auto vd = copyToTemp(0, name, e);
    if (e.isLvalue())
        vd.storage_class |= STCref;
    else
        vd.storage_class |= STCrvalue;

    Expression de = new DeclarationExp(vd.loc, vd);
    Expression ve = new VarExp(vd.loc, vd);
    de = de.semantic(sc);
    ve = ve.semantic(sc);

    e0 = Expression.combine(e0, de);
    return ve;
}

/**************************************************
 * This is similar to Expression.extractLast, but does more drastic rewriting.
 * It's not good to use this in front-end, because some specific AST forms
 * within CommaExp are assumed.
 */
extern (C++) void extractLast2(Expressions* exps, Expression* pe0)
{
    if (!exps)
        return;
    for (size_t i = 0; i < exps.dim; i++)
    {
        (*exps)[i] = extractLast2((*exps)[i], pe0);
    }
}

/// ditto
extern (C++) Expression extractLast2(Expression e, Expression* pe0)
{
    extern (C++) final class CommaVisitor : Visitor
    {
        alias visit = super.visit;
    public:
        Expression e0;
        Expression result;      // the result that comma part are stripped

        this(Expression e0)
        {
            this.e0 = e0;
            result = null;
        }

        override void visit(Expression e)
        {
            result = e;
        }

        override void visit(NewExp e)
        {
            e.thisexp = extractLast2(e.thisexp, &e0);
            extractLast2(e.newargs, &e0);
            extractLast2(e.arguments, &e0);
            result = e;
        }

        override void visit(NewAnonClassExp e)
        {
            assert(0);
        }

        override void visit(UnaExp e)
        {
            e.e1 = extractLast2(e.e1, &e0);
            result = e;
        }

        override void visit(BinExp e)
        {
            e.e1 = extractLast2(e.e1, &e0);
            e.e2 = extractLast2(e.e2, &e0);
            result = e;
        }

        override void visit(AssertExp e)
        {
            e.e1 = extractLast2(e.e1, &e0);
            e.msg = extractLast2(e.msg, &e0);
            result = e;
        }

        override void visit(CallExp e)
        {
            e.e1 = extractLast2(e.e1, &e0);
            extractLast2(e.arguments, &e0);
            result = e;
        }

        override void visit(ArrayExp e)
        {
            e.e1 = extractLast2(e.e1, &e0);
            extractLast2(e.arguments, &e0);
            result = e;
        }

        override void visit(SliceExp e)
        {
            e.e1 = extractLast2(e.e1, &e0);
            e.lwr = extractLast2(e.lwr, &e0);
            e.upr = extractLast2(e.upr, &e0);
            result = e;
        }

        override void visit(ArrayLiteralExp e)
        {
            extractLast2(e.elements, &e0);
            result = e;
        }

        override void visit(AssocArrayLiteralExp e)
        {
            extractLast2(e.keys, &e0);
            extractLast2(e.values, &e0);
            result = e;
        }

        override void visit(StructLiteralExp e)
        {
            if (!(e.stageflags & stageApply))
            {
                int old = e.stageflags;
                e.stageflags |= stageApply;
                extractLast2(e.elements, &e0);
                e.stageflags = old;
            }
            result = e;
        }

        override void visit(TupleExp e)
        {
            e0 = Expression.combine(e0, e.e0);
            e.e0 = null;
            extractLast2(e.exps, &e0);
            result = e;
        }

        override void visit(CondExp e)
        {
            e.econd = extractLast2(e.econd, &e0);
            // Either e.e1 or e.e2 is conditionally evaluated,
            // so don't extract comma lefts from them.
            result = e;
        }

        override void visit(CommaExp e)
        {
            e0 = Expression.combine(e0, e.e1);
            result = extractLast2(e.e2, &e0);
        }
    }

    assert(pe0);

    if (!e)
        return e;

    scope v = new CommaVisitor(*pe0);
    e.accept(v);
    *pe0 = v.e0;
    assert(v.result);
    return v.result;
}
