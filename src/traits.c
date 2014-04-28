
// Compiler implementation of the D programming language
// Copyright (c) 1999-2012 by Digital Mars
// All Rights Reserved
// written by Walter Bright
// http://www.digitalmars.com
// License for redistribution is by either the Artistic License
// in artistic.txt, or the GNU General Public License in gnu.txt.
// See the included readme.txt for details.

#include <stdio.h>
#include <stdlib.h>
#include <ctype.h>
#include <assert.h>
#include <math.h>

#include "rmem.h"
#include "aav.h"

//#include "port.h"
#include "mtype.h"
#include "init.h"
#include "expression.h"
#include "template.h"
#include "utf.h"
#include "enum.h"
#include "scope.h"
#include "statement.h"
#include "declaration.h"
#include "aggregate.h"
#include "import.h"
#include "id.h"
#include "dsymbol.h"
#include "module.h"
#include "attrib.h"
#include "hdrgen.h"
#include "parse.h"

#define LOGSEMANTIC     0


/************************************************
 * Delegate to be passed to overloadApply() that looks
 * for functions matching a trait.
 */

struct Ptrait
{
    Expression *e1;
    Expressions *exps;          // collected results
    Identifier *ident;          // which trait we're looking for
};

static int fptraits(void *param, Dsymbol *s)
{
    FuncDeclaration *f = s->isFuncDeclaration();
    if (!f)
        return 0;

    Ptrait *p = (Ptrait *)param;
    if (p->ident == Id::getVirtualFunctions && !f->isVirtual())
        return 0;

    if (p->ident == Id::getVirtualMethods && !f->isVirtualMethod())
        return 0;

    Expression *e;
    FuncAliasDeclaration* alias = new FuncAliasDeclaration(f, 0);
    alias->protection = f->protection;
    if (p->e1)
        e = new DotVarExp(Loc(), p->e1, alias);
    else
        e = new DsymbolExp(Loc(), alias);
    p->exps->push(e);
    return 0;
}

/**
 * Collects all unit test functions from the given array of symbols.
 *
 * This is a helper function used by the implementation of __traits(getUnitTests).
 *
 * Input:
 *      symbols             array of symbols to collect the functions from
 *      uniqueUnitTests     an associative array (should actually be a set) to
 *                          keep track of already collected functions. We're
 *                          using an AA here to avoid doing a linear search of unitTests
 *
 * Output:
 *      unitTests           array of DsymbolExp's of the collected unit test functions
 *      uniqueUnitTests     updated with symbols from unitTests[ ]
 */
static void collectUnitTests(Dsymbols *symbols, AA *uniqueUnitTests, Expressions *unitTests)
{
    if (!symbols)
        return;
    for (size_t i = 0; i < symbols->dim; i++)
    {
        Dsymbol *symbol = (*symbols)[i];
        UnitTestDeclaration *unitTest = symbol->isUnitTestDeclaration();
        if (unitTest)
        {
            if (!_aaGetRvalue(uniqueUnitTests, unitTest))
            {
                FuncAliasDeclaration* alias = new FuncAliasDeclaration(unitTest, 0);
                alias->protection = unitTest->protection;
                Expression* e = new DsymbolExp(Loc(), alias);
                unitTests->push(e);
                bool* value = (bool*) _aaGet(&uniqueUnitTests, unitTest);
                *value = true;
            }
        }
        else
        {
            AttribDeclaration *attrDecl = symbol->isAttribDeclaration();

            if (attrDecl)
            {
                Dsymbols *decl = attrDecl->include(NULL, NULL);
                collectUnitTests(decl, uniqueUnitTests, unitTests);
            }
        }
    }
}

/************************ TraitsExp ************************************/

bool isTypeArithmetic(Type *t)       { return t->isintegral() || t->isfloating(); }
bool isTypeFloating(Type *t)         { return t->isfloating(); }
bool isTypeIntegral(Type *t)         { return t->isintegral(); }
bool isTypeScalar(Type *t)           { return t->isscalar(); }
bool isTypeUnsigned(Type *t)         { return t->isunsigned(); }
bool isTypeAssociativeArray(Type *t) { return t->toBasetype()->ty == Taarray; }
bool isTypeStaticArray(Type *t)      { return t->toBasetype()->ty == Tsarray; }
bool isTypeAbstractClass(Type *t)    { return t->toBasetype()->ty == Tclass && ((TypeClass *)t->toBasetype())->sym->isAbstract(); }
bool isTypeFinalClass(Type *t)       { return t->toBasetype()->ty == Tclass && (((TypeClass *)t->toBasetype())->sym->storage_class & STCfinal) != 0; }

Expression *isTypeX(TraitsExp *e, bool (*fp)(Type *t))
{
    int result = 0;
    if (!e->args || !e->args->dim)
        goto Lfalse;
    for (size_t i = 0; i < e->args->dim; i++)
    {
        Type *t = getType((*e->args)[i]);
        if (!t || !fp(t))
            goto Lfalse;
    }
    result = 1;
Lfalse:
    return new IntegerExp(e->loc, result, Type::tbool);
}

bool isFuncAbstractFunction(FuncDeclaration *f) { return f->isAbstract(); }
bool isFuncVirtualFunction(FuncDeclaration *f) { return f->isVirtual(); }
bool isFuncVirtualMethod(FuncDeclaration *f) { return f->isVirtualMethod(); }
bool isFuncFinalFunction(FuncDeclaration *f) { return f->isFinalFunc(); }
bool isFuncStaticFunction(FuncDeclaration *f) { return !f->needThis() && !f->isNested(); }
bool isFuncOverrideFunction(FuncDeclaration *f) { return f->isOverride(); }

Expression *isFuncX(TraitsExp *e, bool (*fp)(FuncDeclaration *f))
{
    int result = 0;
    if (!e->args || !e->args->dim)
        goto Lfalse;
    for (size_t i = 0; i < e->args->dim; i++)
    {
        Dsymbol *s = getDsymbol((*e->args)[i]);
        if (!s)
            goto Lfalse;
        FuncDeclaration *f = s->isFuncDeclaration();
        if (!f || !fp(f))
            goto Lfalse;
    }
    result = 1;
Lfalse:
    return new IntegerExp(e->loc, result, Type::tbool);
}

bool isDeclRef(Declaration *d) { return d->isRef(); }
bool isDeclOut(Declaration *d) { return d->isOut(); }
bool isDeclLazy(Declaration *d) { return (d->storage_class & STClazy) != 0; }

Expression *isDeclX(TraitsExp *e, bool (*fp)(Declaration *d))
{
    int result = 0;
    if (!e->args || !e->args->dim)
        goto Lfalse;
    for (size_t i = 0; i < e->args->dim; i++)
    {
        Dsymbol *s = getDsymbol((*e->args)[i]);
        if (!s)
            goto Lfalse;
        Declaration *d = s->isDeclaration();
        if (!d || !fp(d))
            goto Lfalse;
    }
    result = 1;
Lfalse:
    return new IntegerExp(e->loc, result, Type::tbool);
}

// callback for TypeFunction::attributesApply
struct PushAttributes
{
    Expressions *mods;

    static int fp(void *param, const char *str)
    {
        PushAttributes *p = (PushAttributes *)param;
        p->mods->push(new StringExp(Loc(), (char *)str));
        return 0;
    }
};

Expression *semanticTraits(TraitsExp *e, Scope *sc)
{
#if LOGSEMANTIC
    printf("TraitsExp::semantic() %s\n", e->toChars());
#endif
    if (e->ident != Id::compiles && e->ident != Id::isSame &&
        e->ident != Id::identifier && e->ident != Id::getProtection)
    {
        if (!TemplateInstance::semanticTiargs(e->loc, sc, e->args, 1))
            return new ErrorExp();
    }
    size_t dim = e->args ? e->args->dim : 0;
    Declaration *d;

    if (e->ident == Id::isArithmetic)
    {
        return isTypeX(e, &isTypeArithmetic);
    }
    else if (e->ident == Id::isFloating)
    {
        return isTypeX(e, &isTypeFloating);
    }
    else if (e->ident == Id::isIntegral)
    {
        return isTypeX(e, &isTypeIntegral);
    }
    else if (e->ident == Id::isScalar)
    {
        return isTypeX(e, &isTypeScalar);
    }
    else if (e->ident == Id::isUnsigned)
    {
        return isTypeX(e, &isTypeUnsigned);
    }
    else if (e->ident == Id::isAssociativeArray)
    {
        return isTypeX(e, &isTypeAssociativeArray);
    }
    else if (e->ident == Id::isStaticArray)
    {
        return isTypeX(e, &isTypeStaticArray);
    }
    else if (e->ident == Id::isAbstractClass)
    {
        return isTypeX(e, &isTypeAbstractClass);
    }
    else if (e->ident == Id::isFinalClass)
    {
        return isTypeX(e, &isTypeFinalClass);
    }
    else if (e->ident == Id::isPOD)
    {
        if (dim != 1)
            goto Ldimerror;
        RootObject *o = (*e->args)[0];
        Type *t = isType(o);
        StructDeclaration *sd;
        if (!t)
        {
            e->error("type expected as second argument of __traits %s instead of %s", e->ident->toChars(), o->toChars());
            goto Lfalse;
        }
        Type *tb = t->baseElemOf();
        if (tb->ty == Tstruct
            && ((sd = (StructDeclaration *)(((TypeStruct *)tb)->sym)) != NULL))
        {
            if (sd->isPOD())
                goto Ltrue;
            else
                goto Lfalse;
        }
        goto Ltrue;
    }
    else if (e->ident == Id::isNested)
    {
        if (dim != 1)
            goto Ldimerror;
        RootObject *o = (*e->args)[0];
        Dsymbol *s = getDsymbol(o);
        AggregateDeclaration *a;
        FuncDeclaration *f;

        if (!s) { }
        else if ((a = s->isAggregateDeclaration()) != NULL)
        {
            if (a->isNested())
                goto Ltrue;
            else
                goto Lfalse;
        }
        else if ((f = s->isFuncDeclaration()) != NULL)
        {
            if (f->isNested())
                goto Ltrue;
            else
                goto Lfalse;
        }

        e->error("aggregate or function expected instead of '%s'", o->toChars());
        goto Lfalse;
    }
    else if (e->ident == Id::isAbstractFunction)
    {
        return isFuncX(e, &isFuncAbstractFunction);
    }
    else if (e->ident == Id::isVirtualFunction)
    {
        return isFuncX(e, &isFuncVirtualFunction);
    }
    else if (e->ident == Id::isVirtualMethod)
    {
        return isFuncX(e, &isFuncVirtualMethod);
    }
    else if (e->ident == Id::isFinalFunction)
    {
        return isFuncX(e, &isFuncFinalFunction);
    }
    else if (e->ident == Id::isOverrideFunction)
    {
        return isFuncX(e, &isFuncOverrideFunction);
    }
    else if (e->ident == Id::isStaticFunction)
    {
        return isFuncX(e, &isFuncStaticFunction);
    }
    else if (e->ident == Id::isRef)
    {
        return isDeclX(e, &isDeclRef);
    }
    else if (e->ident == Id::isOut)
    {
        return isDeclX(e, &isDeclOut);
    }
    else if (e->ident == Id::isLazy)
    {
        return isDeclX(e, &isDeclLazy);
    }
    else if (e->ident == Id::identifier)
    {
        // Get identifier for symbol as a string literal
        /* Specify 0 for bit 0 of the flags argument to semanticTiargs() so that
         * a symbol should not be folded to a constant.
         * Bit 1 means don't convert Parameter to Type if Parameter has an identifier
         */
        if (!TemplateInstance::semanticTiargs(e->loc, sc, e->args, 2))
            return new ErrorExp();

        if (dim != 1)
            goto Ldimerror;
        RootObject *o = (*e->args)[0];
        Parameter *po = isParameter(o);
        Identifier *id;
        if (po)
        {
            id = po->ident;
            assert(id);
        }
        else
        {
            Dsymbol *s = getDsymbol(o);
            if (!s || !s->ident)
            {
                e->error("argument %s has no identifier", o->toChars());
                goto Lfalse;
            }
            id = s->ident;
        }
        StringExp *se = new StringExp(e->loc, id->toChars());
        return se->semantic(sc);
    }
    else if (e->ident == Id::getProtection)
    {
        if (dim != 1)
            goto Ldimerror;

        Scope *sc2 = sc->push();
        sc2->flags = sc->flags | SCOPEnoaccesscheck;
        bool ok = TemplateInstance::semanticTiargs(e->loc, sc2, e->args, 1);
        sc2->pop();

        if (!ok)
            return new ErrorExp();

        RootObject *o = (*e->args)[0];
        Dsymbol *s = getDsymbol(o);
        if (!s)
        {
            if (!isError(o))
                e->error("argument %s has no protection", o->toChars());
            goto Lfalse;
        }
        if (s->scope)
            s->semantic(s->scope);
        PROT protection = s->prot();

        const char *protName = Pprotectionnames[protection];

        assert(protName);
        StringExp *se = new StringExp(e->loc, (char *) protName);
        return se->semantic(sc);
    }
    else if (e->ident == Id::parent)
    {
        if (dim != 1)
            goto Ldimerror;
        RootObject *o = (*e->args)[0];
        Dsymbol *s = getDsymbol(o);
        if (s)
        {
            if (FuncDeclaration *fd = s->isFuncDeclaration())   // Bugzilla 8943
                s = fd->toAliasFunc();
            if (!s->isImport())  // Bugzilla 8922
                s = s->toParent();
        }
        if (!s || s->isImport())
        {
            e->error("argument %s has no parent", o->toChars());
            goto Lfalse;
        }
        return (new DsymbolExp(e->loc, s))->semantic(sc);
    }
    else if (e->ident == Id::hasMember ||
             e->ident == Id::getMember ||
             e->ident == Id::getOverloads ||
             e->ident == Id::getVirtualMethods ||
             e->ident == Id::getVirtualFunctions)
    {
        if (dim != 2)
            goto Ldimerror;
        RootObject *o = (*e->args)[0];
        Expression *ex = isExpression((*e->args)[1]);
        if (!ex)
        {
            e->error("expression expected as second argument of __traits %s", e->ident->toChars());
            goto Lfalse;
        }
        ex = ex->ctfeInterpret();
        StringExp *se = ex->toStringExp();
        if (!se || se->length() == 0)
        {
            e->error("string expected as second argument of __traits %s instead of %s", e->ident->toChars(), ex->toChars());
            goto Lfalse;
        }
        se = se->toUTF8(sc);
        if (se->sz != 1)
        {
            e->error("string must be chars");
            goto Lfalse;
        }
        Identifier *id = Lexer::idPool((char *)se->string);

        /* Prefer dsymbol, because it might need some runtime contexts.
         */
        Dsymbol *sym = getDsymbol(o);
        if (sym)
        {
            ex = new DsymbolExp(e->loc, sym);
            ex = new DotIdExp(e->loc, ex, id);
        }
        else if (Type *t = isType(o))
            ex = typeDotIdExp(e->loc, t, id);
        else if (Expression *ex2 = isExpression(o))
            ex = new DotIdExp(e->loc, ex2, id);
        else
        {
            e->error("invalid first argument");
            goto Lfalse;
        }

        if (e->ident == Id::hasMember)
        {
            if (sym)
            {
                Dsymbol *sm = sym->search(e->loc, id);
                if (sm)
                    goto Ltrue;
            }

            /* Take any errors as meaning it wasn't found
             */
            Scope *sc2 = sc->push();
            ex = ex->trySemantic(sc2);
            sc2->pop();
            if (!ex)
                goto Lfalse;
            else
                goto Ltrue;
        }
        else if (e->ident == Id::getMember)
        {
            ex = ex->semantic(sc);
            return ex;
        }
        else if (e->ident == Id::getVirtualFunctions ||
                 e->ident == Id::getVirtualMethods ||
                 e->ident == Id::getOverloads)
        {
            unsigned errors = global.errors;
            Expression *eorig = ex;
            ex = ex->semantic(sc);
            if (errors < global.errors)
                e->error("%s cannot be resolved", eorig->toChars());

            /* Create tuple of functions of ex
             */
            //ex->print();
            Expressions *exps = new Expressions();
            FuncDeclaration *f;
            if (ex->op == TOKvar)
            {
                VarExp *ve = (VarExp *)ex;
                f = ve->var->isFuncDeclaration();
                ex = NULL;
            }
            else if (ex->op == TOKdotvar)
            {
                DotVarExp *dve = (DotVarExp *)ex;
                f = dve->var->isFuncDeclaration();
                if (dve->e1->op == TOKdottype || dve->e1->op == TOKthis)
                    ex = NULL;
                else
                    ex = dve->e1;
            }
            else
                f = NULL;
            Ptrait p;
            p.exps = exps;
            p.e1 = ex;
            p.ident = e->ident;
            overloadApply(f, &p, &fptraits);

            TupleExp *tup = new TupleExp(e->loc, exps);
            return tup->semantic(sc);
        }
        else
            assert(0);
    }
    else if (e->ident == Id::classInstanceSize)
    {
        if (dim != 1)
            goto Ldimerror;
        RootObject *o = (*e->args)[0];
        Dsymbol *s = getDsymbol(o);
        ClassDeclaration *cd;
        if (!s || (cd = s->isClassDeclaration()) == NULL)
        {
            e->error("first argument is not a class");
            goto Lfalse;
        }
        if (cd->sizeok == SIZEOKnone)
        {
            if (cd->scope)
                cd->semantic(cd->scope);
        }
        if (cd->sizeok != SIZEOKdone)
        {
            e->error("%s %s is forward referenced", cd->kind(), cd->toChars());
            goto Lfalse;
        }
        return new IntegerExp(e->loc, cd->structsize, Type::tsize_t);
    }
    else if (e->ident == Id::getAliasThis)
    {
        if (dim != 1)
            goto Ldimerror;
        RootObject *o = (*e->args)[0];
        Dsymbol *s = getDsymbol(o);
        AggregateDeclaration *ad;
        if (!s || (ad = s->isAggregateDeclaration()) == NULL)
        {
            e->error("argument is not an aggregate type");
            goto Lfalse;
        }

        Expressions *exps = new Expressions();
        if (ad->aliasthis)
            exps->push(new StringExp(e->loc, ad->aliasthis->ident->toChars()));

        Expression *ex = new TupleExp(e->loc, exps);
        ex = ex->semantic(sc);
        return ex;
    }
    else if (e->ident == Id::getAttributes)
    {
        if (dim != 1)
            goto Ldimerror;
        RootObject *o = (*e->args)[0];
        Dsymbol *s = getDsymbol(o);
        if (!s)
        {
        #if 0
            Expression *x = isExpression(o);
            Type *t = isType(o);
            if (x) printf("e = %s %s\n", Token::toChars(x->op), x->toChars());
            if (t) printf("t = %d %s\n", t->ty, t->toChars());
        #endif
            e->error("first argument is not a symbol");
            goto Lfalse;
        }
        //printf("getAttributes %s, attrs = %p, scope = %p\n", s->toChars(), s->userAttributes, s->userAttributesScope);
        UserAttributeDeclaration *udad = s->userAttribDecl;
        TupleExp *tup = new TupleExp(e->loc, udad ? udad->getAttributes() : new Expressions());
        return tup->semantic(sc);
    }
    else if (e->ident == Id::getFunctionAttributes)
    {
        /// extract all function attributes as a tuple (const/shared/inout/pure/nothrow/etc) except UDAs.

        if (dim != 1)
            goto Ldimerror;
        RootObject *o = (*e->args)[0];
        Dsymbol *s = getDsymbol(o);
        TypeFunction *tf = NULL;
        FuncDeclaration *fd = NULL;

        if (!s) { }
        else if (FuncDeclaration *sfd = s->isFuncDeclaration())
        {
            fd = sfd;
            tf = (TypeFunction *)fd->type;
        }
        else if (VarDeclaration *vd = s->isVarDeclaration())
        {
            if (vd->type->ty == Tfunction)
                tf = (TypeFunction *)vd->type;
            else if (vd->type->ty == Tdelegate)
                tf = (TypeFunction *)vd->type->nextOf();
            else if (vd->type->ty == Tpointer && vd->type->nextOf()->ty == Tfunction)
                tf = (TypeFunction *)vd->type->nextOf();
        }

        if (!tf)
        {
            e->error("first argument is not a function");
            goto Lfalse;
        }

        Expressions *mods = new Expressions();

        PushAttributes pa;
        pa.mods = mods;

        // const/immutable/inout/shared is only valid for member functions
        if (fd)
            fd->type->modifiersApply(&pa, &PushAttributes::fp);

        tf->attributesApply(&pa, &PushAttributes::fp);

        TupleExp *tup = new TupleExp(e->loc, mods);
        return tup->semantic(sc);
    }
    else if (e->ident == Id::allMembers || e->ident == Id::derivedMembers)
    {
        if (dim != 1)
            goto Ldimerror;
        RootObject *o = (*e->args)[0];
        Dsymbol *s = getDsymbol(o);
        ScopeDsymbol *sd;
        if (!s)
        {
            e->error("argument has no members");
            goto Lfalse;
        }
        Import *import;
        if ((import = s->isImport()) != NULL)
        {
            // Bugzilla 9692
            sd = import->mod;
        }
        else if ((sd = s->isScopeDsymbol()) == NULL)
        {
            e->error("%s %s has no members", s->kind(), s->toChars());
            goto Lfalse;
        }

        // use a struct as local function
        struct PushIdentsDg
        {
            static int dg(void *ctx, size_t n, Dsymbol *sm)
            {
                if (!sm)
                    return 1;
                //printf("\t[%i] %s %s\n", i, sm->kind(), sm->toChars());
                if (sm->ident)
                {
                    if (sm->ident != Id::ctor &&
                        sm->ident != Id::dtor &&
                        sm->ident != Id::_postblit &&
                        memcmp(sm->ident->string, "__", 2) == 0)
                    {
                        return 0;
                    }

                    //printf("\t%s\n", sm->ident->toChars());
                    Identifiers *idents = (Identifiers *)ctx;

                    /* Skip if already present in idents[]
                     */
                    for (size_t j = 0; j < idents->dim; j++)
                    {   Identifier *id = (*idents)[j];
                        if (id == sm->ident)
                            return 0;
#ifdef DEBUG
                        // Avoid using strcmp in the first place due to the performance impact in an O(N^2) loop.
                        assert(strcmp(id->toChars(), sm->ident->toChars()) != 0);
#endif
                    }

                    idents->push(sm->ident);
                }
                else
                {
                    EnumDeclaration *ed = sm->isEnumDeclaration();
                    if (ed)
                    {
                        ScopeDsymbol::foreach(NULL, ed->members, &PushIdentsDg::dg, (Identifiers *)ctx);
                    }
                }
                return 0;
            }
        };

        Identifiers *idents = new Identifiers;

        ScopeDsymbol::foreach(sc, sd->members, &PushIdentsDg::dg, idents);

        ClassDeclaration *cd = sd->isClassDeclaration();
        if (cd && e->ident == Id::allMembers)
        {
            struct PushBaseMembers
            {
                static void dg(ClassDeclaration *cd, Identifiers *idents)
                {
                    for (size_t i = 0; i < cd->baseclasses->dim; i++)
                    {
                        ClassDeclaration *cb = (*cd->baseclasses)[i]->base;
                        ScopeDsymbol::foreach(NULL, cb->members, &PushIdentsDg::dg, idents);
                        if (cb->baseclasses->dim)
                            dg(cb, idents);
                    }
                }
            };
            PushBaseMembers::dg(cd, idents);
        }

        // Turn Identifiers into StringExps reusing the allocated array
        assert(sizeof(Expressions) == sizeof(Identifiers));
        Expressions *exps = (Expressions *)idents;
        for (size_t i = 0; i < idents->dim; i++)
        {
            Identifier *id = (*idents)[i];
            StringExp *se = new StringExp(e->loc, id->toChars());
            (*exps)[i] = se;
        }

        /* Making this a tuple is more flexible, as it can be statically unrolled.
         * To make an array literal, enclose __traits in [ ]:
         *   [ __traits(allMembers, ...) ]
         */
        Expression *ex = new TupleExp(e->loc, exps);
        ex = ex->semantic(sc);
        return ex;
    }
    else if (e->ident == Id::compiles)
    {
        /* Determine if all the objects - types, expressions, or symbols -
         * compile without error
         */
        if (!dim)
            goto Lfalse;

        for (size_t i = 0; i < dim; i++)
        {
            unsigned errors = global.startGagging();
            unsigned oldspec = global.speculativeGag;
            global.speculativeGag = global.gag;
            Scope *sc2 = sc->push();
            sc2->speculative = true;
            sc2->flags = sc->flags & ~SCOPEctfe | SCOPEcompile;
            bool err = false;

            RootObject *o = (*e->args)[i];
            Type *t = isType(o);
            Expression *ex = t ? t->toExpression() : isExpression(o);
            if (!ex && t)
            {
                Dsymbol *s;
                t->resolve(e->loc, sc2, &ex, &t, &s);
                if (t)
                {
                    t->semantic(e->loc, sc2);
                    if (t->ty == Terror)
                        err = true;
                }
                else if (s && s->errors)
                    err = true;
            }
            if (ex)
            {
                ex = ex->semantic(sc2);
                ex = resolvePropertiesOnly(sc2, ex);
                ex = ex->optimize(WANTvalue);
                if (ex->op == TOKerror)
                    err = true;
            }

            sc2->pop();
            global.speculativeGag = oldspec;
            if (global.endGagging(errors) || err)
            {
                goto Lfalse;
            }
        }
        goto Ltrue;
    }
    else if (e->ident == Id::isSame)
    {
        /* Determine if two symbols are the same
         */
        if (dim != 2)
            goto Ldimerror;
        if (!TemplateInstance::semanticTiargs(e->loc, sc, e->args, 0))
            return new ErrorExp();
        RootObject *o1 = (*e->args)[0];
        RootObject *o2 = (*e->args)[1];
        Dsymbol *s1 = getDsymbol(o1);
        Dsymbol *s2 = getDsymbol(o2);

        //printf("isSame: %s, %s\n", o1->toChars(), o2->toChars());
#if 0
        printf("o1: %p\n", o1);
        printf("o2: %p\n", o2);
        if (!s1)
        {
            Expression *ea = isExpression(o1);
            if (ea)
                printf("%s\n", ea->toChars());
            Type *ta = isType(o1);
            if (ta)
                printf("%s\n", ta->toChars());
            goto Lfalse;
        }
        else
            printf("%s %s\n", s1->kind(), s1->toChars());
#endif
        if (!s1 && !s2)
        {
            Expression *ea1 = isExpression(o1);
            Expression *ea2 = isExpression(o2);
            if (ea1 && ea2)
            {
                if (ea1->equals(ea2))
                    goto Ltrue;
            }
        }

        if (!s1 || !s2)
            goto Lfalse;

        s1 = s1->toAlias();
        s2 = s2->toAlias();

        if (s1->isFuncAliasDeclaration())
            s1 = ((FuncAliasDeclaration *)s1)->toAliasFunc();
        if (s2->isFuncAliasDeclaration())
            s2 = ((FuncAliasDeclaration *)s2)->toAliasFunc();

        if (s1 == s2)
            goto Ltrue;
        else
            goto Lfalse;
    }
    else if (e->ident == Id::getUnitTests)
    {
        if (dim != 1)
            goto Ldimerror;
        RootObject *o = (*e->args)[0];
        Dsymbol *s = getDsymbol(o);
        if (!s)
        {
            e->error("argument %s to __traits(getUnitTests) must be a module or aggregate", o->toChars());
            goto Lfalse;
        }

        Import *imp = s->isImport();
        if (imp)  // Bugzilla 10990
            s = imp->mod;

        ScopeDsymbol* scope = s->isScopeDsymbol();

        if (!scope)
        {
            e->error("argument %s to __traits(getUnitTests) must be a module or aggregate, not a %s", s->toChars(), s->kind());
            goto Lfalse;
        }

        Expressions* unitTests = new Expressions();
        Dsymbols* symbols = scope->members;

        if (global.params.useUnitTests && symbols)
        {
            // Should actually be a set
            AA* uniqueUnitTests = NULL;
            collectUnitTests(symbols, uniqueUnitTests, unitTests);
        }

        TupleExp *tup = new TupleExp(e->loc, unitTests);
        return tup->semantic(sc);
    }
    else if(e->ident == Id::getVirtualIndex)
    {
        if (dim != 1)
            goto Ldimerror;
        RootObject *o = (*e->args)[0];
        Dsymbol *s = getDsymbol(o);
        FuncDeclaration *fd;
        if (!s || (fd = s->isFuncDeclaration()) == NULL)
        {
            e->error("first argument to __traits(getVirtualIndex) must be a function");
            goto Lfalse;
        }
        fd = fd->toAliasFunc(); // Neccessary to support multiple overloads.
        ptrdiff_t result = fd->isVirtual() ? fd->vtblIndex : -1;
        return new IntegerExp(e->loc, fd->vtblIndex, Type::tptrdiff_t);
    }
    else if (e->ident == Id::getTemplateParamCount)
    {
        if (dim != 1)
            goto Ldimerror;
        RootObject *o = (*e->args)[0];
        Dsymbol *s = getDsymbol(o);
        TemplateDeclaration *td;
        if (!s || (td = s->isTemplateDeclaration()) == NULL)
        {
            e->error("first argument must be a template");
            goto Lfalse;
        }

        size_t paramCount = td->parameters ? td->parameters->dim : 0;
        return new IntegerExp(e->loc, paramCount, Type::tsize_t);
    }
    else if (e->ident == Id::isTemplateTypeParam
             || e->ident == Id::isTemplateValueParam
             || e->ident == Id::isTemplateAliasParam
             || e->ident == Id::isTemplateThisParam
             || e->ident == Id::isTemplateVariadicParam
             || e->ident == Id::getTemplateParamIdent
             || e->ident == Id::getTemplateParamType
             || e->ident == Id::getTemplateParamSpec
             || e->ident == Id::getTemplateParamDefault)
    {
        if (dim != 2)
            goto Ldimerror;
        RootObject *o = (*e->args)[0];
        Dsymbol *s = getDsymbol(o);
        TemplateDeclaration *td;
        if (!s || (td = s->isTemplateDeclaration()) == NULL)
        {
            e->error("first argument must be a template");
            goto Lfalse;
        }

        Expression *ex = isExpression((*e->args)[1]);
        if (!ex)
        {
            e->error("parameter index expected as second argument");
            goto Lfalse;
        }
        ex = ex->ctfeInterpret();

        uinteger_t paramIdx = ex->toInteger();
        size_t paramCount = td->parameters ? td->parameters->dim : 0;
        if (paramIdx >= paramCount)
        {
            e->error("parameter index '%u' exceeds length '%u'", paramCount, paramIdx);
            goto Lfalse;
        }

        TemplateParameter *tp = (*td->parameters)[paramIdx];

        if (e->ident == Id::isTemplateTypeParam)
        {
            // note: TemplateThisParameter inherits TemplateTypeParameter
            if (!tp->isTemplateThisParameter() && tp->isTemplateTypeParameter())
                goto Ltrue;
            else
                goto Lfalse;
        }
        else if (e->ident == Id::isTemplateValueParam)
        {
            if (tp->isTemplateValueParameter())
                goto Ltrue;
            else
                goto Lfalse;
        }
        else if (e->ident == Id::isTemplateAliasParam)
        {
            if (tp->isTemplateAliasParameter())
                goto Ltrue;
            else
                goto Lfalse;
        }
        else if (e->ident == Id::isTemplateThisParam)
        {
            if (tp->isTemplateThisParameter())
                goto Ltrue;
            else
                goto Lfalse;
        }
        else if (e->ident == Id::isTemplateVariadicParam)
        {
            if (tp->isTemplateTupleParameter())
                goto Ltrue;
            else
                goto Lfalse;
        }
        else if (e->ident == Id::getTemplateParamIdent)
        {
            StringExp *se = new StringExp(e->loc, tp->ident->toChars());
            return se->semantic(sc);
        }
        else if (e->ident == Id::getTemplateParamType)
        {
            if (TemplateValueParameter *tvp = tp->isTemplateValueParameter())
            {
                return (new TypeExp(e->loc, tvp->valType))->semantic(sc);
            }
            else if (TemplateAliasParameter *tap = tp->isTemplateAliasParameter())
            {
                if (tap->specType)
                    return (new TypeExp(e->loc, tap->specType))->semantic(sc);
            }
            else if (TemplateThisParameter *ttp = tp->isTemplateThisParameter())
            {
                if (ttp->specType)
                    return (new TypeExp(e->loc, ttp->specType))->semantic(sc);
            }

            e->error("Template parameter '%s' at index '%u' does not have a type.", tp->toChars(), paramIdx);
            goto Lfalse;
        }
        else if (e->ident == Id::getTemplateParamSpec)
        {
            if (TemplateValueParameter *tvp = tp->isTemplateValueParameter())
            {
                if (tvp->specValue)
                    return tvp->specValue->semantic(sc);
            }
            else if (TemplateAliasParameter *tap = tp->isTemplateAliasParameter())
            {
                if (tap->specAlias)
                {
                    if (Type *t = isType(tap->specAlias))
                        return (new TypeExp(e->loc, t))->semantic(sc);
                    else if (Dsymbol *sym = getDsymbol(tap->specAlias))
                        return (new DsymbolExp(e->loc, sym))->semantic(sc);
                    else if (Expression *ex = isExpression(tap->specAlias))
                        return ex->semantic(sc);
                    else
                        assert(0);  // unhandled case
                }
            }
            else if (TemplateThisParameter *ttp = tp->isTemplateThisParameter())
            {
                if (ttp->specType)
                    return (new TypeExp(e->loc, ttp->specType))->semantic(sc);
            }
            else if (TemplateTypeParameter *ttp = tp->isTemplateTypeParameter())
            {
                // note: TemplateThisParameter inherits TemplateTypeParameter
                assert(!tp->isTemplateThisParameter());

                if (ttp->specType)
                    return (new TypeExp(e->loc, ttp->specType))->semantic(sc);
            }

            e->error("Template parameter '%s' at index '%u' does not have a specialization.", tp->toChars(), paramIdx);
            goto Lfalse;
        }
        else if (e->ident == Id::getTemplateParamDefault)
        {
            if (TemplateValueParameter *tvp = tp->isTemplateValueParameter())
            {
                if (tvp->defaultValue)
                    return tvp->defaultValue->semantic(sc);
            }
            else if (TemplateAliasParameter *tap = tp->isTemplateAliasParameter())
            {
                if (tap->defaultAlias)
                {
                    if (Type *t = isType(tap->defaultAlias))
                        return (new TypeExp(e->loc, t))->semantic(sc);
                    else if (Dsymbol *sym = getDsymbol(tap->defaultAlias))
                        return (new DsymbolExp(e->loc, sym))->semantic(sc);
                    else if (Expression *ex = isExpression(tap->defaultAlias))
                        return ex->semantic(sc);
                    else
                        assert(0);  // unhandled case
                }
            }
            else if (TemplateThisParameter *ttp = tp->isTemplateThisParameter())
            {
                if (ttp->defaultType)
                    return new TypeExp(e->loc, ttp->defaultType);
            }
            else if (TemplateTypeParameter *ttp = tp->isTemplateTypeParameter())
            {
                // note: TemplateThisParameter inherits TemplateTypeParameter
                assert(!tp->isTemplateThisParameter());

                if (ttp->defaultType)
                    return (new TypeExp(e->loc, ttp->defaultType))->semantic(sc);
            }

            e->error("Template parameter '%s' at index '%u' does not have a default.", tp->toChars(), paramIdx);
            goto Lfalse;
        }
        else
        {
            assert(0);  // unhandled case
        }

        goto Lfalse;
    }
    else
    {
        e->error("unrecognized trait %s", e->ident->toChars());
        goto Lfalse;
    }

    return NULL;

Ldimerror:
    e->error("wrong number of arguments %d", (int)dim);
    goto Lfalse;


Lfalse:
    return new IntegerExp(e->loc, 0, Type::tbool);

Ltrue:
    return new IntegerExp(e->loc, 1, Type::tbool);
}
