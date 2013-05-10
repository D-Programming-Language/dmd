
// Compiler implementation of the D programming language
// Copyright (c) 1999-2011 by Digital Mars
// All Rights Reserved
// written by Walter Bright
// http://www.digitalmars.com
// License for redistribution is by either the Artistic License
// in artistic.txt, or the GNU General Public License in gnu.txt.
// See the included readme.txt for details.

#include <stdio.h>
#include <assert.h>

#include "root.h"
#include "aggregate.h"
#include "scope.h"
#include "mtype.h"
#include "declaration.h"
#include "module.h"
#include "id.h"
#include "expression.h"
#include "statement.h"
#include "init.h"
#include "template.h"


/*******************************************
 * Check given opAssign symbol is really identity opAssign or not.
 */

FuncDeclaration *AggregateDeclaration::hasIdentityOpAssign(Scope *sc)
{
    Dsymbol *assign = search_function(this, Id::assign);
    if (assign)
    {
        /* check identity opAssign exists
         */
        Expression *er = new NullExp(loc, type);        // dummy rvalue
        Expression *el = new IdentifierExp(loc, Id::p); // dummy lvalue
        el->type = type;
        Expressions ar;  ar.push(er);
        Expressions al;  al.push(el);
        FuncDeclaration *f = NULL;

        unsigned errors = global.startGagging();    // Do not report errors, even if the
        unsigned oldspec = global.speculativeGag;   // template opAssign fbody makes it.
        global.speculativeGag = global.gag;
        sc = sc->push();
        sc->speculative = true;

                 f = resolveFuncCall(loc, sc, assign, NULL, type, &ar, 1);
        if (!f)  f = resolveFuncCall(loc, sc, assign, NULL, type, &al, 1);

        sc = sc->pop();
        global.speculativeGag = oldspec;
        global.endGagging(errors);

        if (f)
        {
            int varargs;
            Parameters *fparams = f->getParameters(&varargs);
            if (fparams->dim >= 1)
            {
                Parameter *arg0 = Parameter::getNth(fparams, 0);
                if (arg0->type->toDsymbol(NULL) != this)
                    f = NULL;
            }
        }
        // BUGS: This detection mechanism cannot find some opAssign-s like follows:
        // struct S { void opAssign(ref immutable S) const; }
        return f;
    }
    return NULL;
}

/*******************************************
 * We need an opAssign for the struct if
 * it has a destructor or a postblit.
 * We need to generate one if a user-specified one does not exist.
 */

int StructDeclaration::needOpAssign()
{
#define X 0
    if (X) printf("StructDeclaration::needOpAssign() %s\n", toChars());

    if (hasIdentityAssign)
        goto Lneed;         // because has identity==elaborate opAssign

    if (dtor || postblit)
        goto Lneed;

    /* If any of the fields need an opAssign, then we
     * need it too.
     */
    for (size_t i = 0; i < fields.dim; i++)
    {
        Dsymbol *s = fields[i];
        VarDeclaration *v = s->isVarDeclaration();
        assert(v && v->isField());
        if (v->storage_class & STCref)
            continue;
        Type *tv = v->type->toBasetype();
        while (tv->ty == Tsarray)
        {   TypeSArray *ta = (TypeSArray *)tv;
            tv = tv->nextOf()->toBasetype();
        }
        if (tv->ty == Tstruct)
        {   TypeStruct *ts = (TypeStruct *)tv;
            StructDeclaration *sd = ts->sym;
            if (sd->needOpAssign())
                goto Lneed;
        }
    }
Ldontneed:
    if (X) printf("\tdontneed\n");
    return 0;

Lneed:
    if (X) printf("\tneed\n");
    return 1;
#undef X
}

/******************************************
 * Build opAssign for struct.
 *      ref S opAssign(S s) { ... }
 *
 * Note that s will be constructed onto the stack, probably copy-constructed.
 * Then, the body is:
 *      S tmp = this;   // bit copy
 *      this = s;       // bit copy
 *      tmp.dtor();
 * Instead of running the destructor on s, run it on tmp instead.
 */

FuncDeclaration *StructDeclaration::buildOpAssign(Scope *sc)
{
    if (FuncDeclaration *f = hasIdentityOpAssign(sc))
    {
        hasIdentityAssign = 1;
        return f;
    }
    // Even if non-identity opAssign is defined, built-in identity opAssign
    // will be defined.

    if (!needOpAssign())
        return NULL;

    //printf("StructDeclaration::buildOpAssign() %s\n", toChars());

    Parameters *fparams = new Parameters;
    fparams->push(new Parameter(STCnodtor, type, Id::p, NULL));
    Type *ftype = new TypeFunction(fparams, handle, FALSE, LINKd);
    ((TypeFunction *)ftype)->isref = 1;

    FuncDeclaration *fop = new FuncDeclaration(loc, 0, Id::assign, STCundefined, ftype);

    Expression *e = NULL;
    if (dtor || postblit)
    {   /* Swap:
         *    tmp = *this; *this = s; tmp.dtor();
         */
        //printf("\tswap copy\n");
        Identifier *idtmp = Lexer::uniqueId("__tmp");
        VarDeclaration *tmp;
        AssignExp *ec = NULL;
        if (dtor)
        {
            tmp = new VarDeclaration(0, type, idtmp, new VoidInitializer(0));
            tmp->noscope = 1;
            tmp->storage_class |= STCctfe;
            e = new DeclarationExp(0, tmp);
            ec = new AssignExp(0,
                new VarExp(0, tmp),
                new ThisExp(0)
                );
            ec->op = TOKblit;
            e = Expression::combine(e, ec);
        }
        ec = new AssignExp(0,
                new ThisExp(0),
                new IdentifierExp(0, Id::p));
        ec->op = TOKblit;
        e = Expression::combine(e, ec);
        if (dtor)
        {
            /* Instead of running the destructor on s, run it
             * on tmp. This avoids needing to copy tmp back in to s.
             */
            Expression *ec2 = new DotVarExp(0, new VarExp(0, tmp), dtor, 0);
            ec2 = new CallExp(0, ec2);
            e = Expression::combine(e, ec2);
        }
    }
    else
    {   /* Do memberwise copy
         */
        //printf("\tmemberwise copy\n");
        for (size_t i = 0; i < fields.dim; i++)
        {
            Dsymbol *s = fields[i];
            VarDeclaration *v = s->isVarDeclaration();
            assert(v && v->isField());
            // this.v = s.v;
            AssignExp *ec = new AssignExp(0,
                new DotVarExp(0, new ThisExp(0), v, 0),
                new DotVarExp(0, new IdentifierExp(0, Id::p), v, 0));
            e = Expression::combine(e, ec);
        }
    }
    Statement *s1 = new ExpStatement(0, e);

    /* Add:
     *   return this;
     */
    e = new ThisExp(0);
    Statement *s2 = new ReturnStatement(0, e);

    fop->fbody = new CompoundStatement(0, s1, s2);

    Dsymbol *s = fop;
#if 1   // workaround until fixing issue 1528
    Dsymbol *assign = search_function(this, Id::assign);
    if (assign && assign->isTemplateDeclaration())
    {
        // Wrap a template around the function declaration
        TemplateParameters *tpl = new TemplateParameters();
        Dsymbols *decldefs = new Dsymbols();
        decldefs->push(s);
        TemplateDeclaration *tempdecl =
            new TemplateDeclaration(assign->loc, fop->ident, tpl, NULL, decldefs, 0);
        s = tempdecl;
    }
#endif
    members->push(s);
    s->addMember(sc, this, 1);
    this->hasIdentityAssign = 1;        // temporary mark identity assignable

    unsigned errors = global.startGagging();    // Do not report errors, even if the
    unsigned oldspec = global.speculativeGag;   // template opAssign fbody makes it.
    global.speculativeGag = global.gag;
    Scope *sc2 = sc->push();
    sc2->stc = 0;
    sc2->linkage = LINKd;
    sc2->speculative = true;

    s->semantic(sc2);
    s->semantic2(sc2);
    s->semantic3(sc2);

    sc2->pop();
    global.speculativeGag = oldspec;
    if (global.endGagging(errors))    // if errors happened
    {   // Disable generated opAssign, because some members forbid identity assignment.
        fop->storage_class |= STCdisable;
        fop->fbody = NULL;  // remove fbody which contains the error
    }

    //printf("-StructDeclaration::buildOpAssign() %s %s, errors = %d\n", toChars(), s->kind(), (fop->storage_class & STCdisable) != 0);

    return fop;
}

/*******************************************
 * We need an opEquals for the struct if
 * any fields has an opEquals.
 * Generate one if a user-specified one does not exist.
 */

int StructDeclaration::needOpEquals()
{
#define X 0
    if (X) printf("StructDeclaration::needOpEquals() %s\n", toChars());

    if (hasIdentityEquals)
        goto Lneed;

    if (isUnionDeclaration())
        goto Ldontneed;

    /* If any of the fields has an opEquals, then we
     * need it too.
     */
    for (size_t i = 0; i < fields.dim; i++)
    {
        Dsymbol *s = fields[i];
        VarDeclaration *v = s->isVarDeclaration();
        assert(v && v->isField());
        if (v->storage_class & STCref)
            continue;
        Type *tv = v->type->toBasetype();
        if (tv->isfloating())
            goto Lneed;
        if (tv->ty == Tarray)
            goto Lneed;
        if (tv->ty == Taarray)
            goto Lneed;
        if (tv->ty == Tclass)
            goto Lneed;
        while (tv->ty == Tsarray)
        {   TypeSArray *ta = (TypeSArray *)tv;
            tv = tv->nextOf()->toBasetype();
        }
        if (tv->ty == Tstruct)
        {   TypeStruct *ts = (TypeStruct *)tv;
            StructDeclaration *sd = ts->sym;
            if (sd->needOpEquals())
                goto Lneed;
        }
    }
Ldontneed:
    if (X) printf("\tdontneed\n");
    return 0;

Lneed:
    if (X) printf("\tneed\n");
    return 1;
#undef X
}

FuncDeclaration *AggregateDeclaration::hasIdentityOpEquals(Scope *sc)
{
    Dsymbol *eq = search_function(this, Id::eq);
    if (eq)
    {
        /* check identity opEquals exists
         */
        for (size_t i = 0; ; i++)
        {
            Type *tthis;
            if (i == 0) tthis = type;
            if (i == 1) tthis = type->constOf();
            if (i == 2) tthis = type->invariantOf();
            if (i == 3) tthis = type->sharedOf();
            if (i == 4) tthis = type->sharedConstOf();
            if (i == 5) break;
            Expression *er = new NullExp(loc, tthis);       // dummy rvalue
            Expression *el = new IdentifierExp(loc, Id::p); // dummy lvalue
            el->type = tthis;
            Expressions ar;  ar.push(er);
            Expressions al;  al.push(el);
            FuncDeclaration *f = NULL;

            unsigned errors = global.startGagging();    // Do not report errors, even if the
            unsigned oldspec = global.speculativeGag;   // template opAssign fbody makes it.
            global.speculativeGag = global.gag;
            sc = sc->push();
            sc->speculative = true;

                     f = resolveFuncCall(loc, sc, eq, NULL, tthis, &ar, 1);
            if (!f)  f = resolveFuncCall(loc, sc, eq, NULL, tthis, &al, 1);

            sc = sc->pop();
            global.speculativeGag = oldspec;
            global.endGagging(errors);

            if (f)
                return f;
        }
    }
    return NULL;
}

/******************************************
 * Build __xopEquals for TypeInfo_Struct
 *      bool __xopEquals(in ref S p, in ref S q) { ... }
 */

FuncDeclaration *StructDeclaration::buildXopEquals(Scope *sc)
{
    if (FuncDeclaration *f = hasIdentityOpEquals(sc))
    {
        hasIdentityEquals = 1;
    }

    if (!needOpEquals())
        return NULL;

    /* static bool__xopEquals(ref const S p, ref const S q) {
     *     return p == q;
     * }
     */
    Parameters *parameters = new Parameters;
    parameters->push(new Parameter(STCref | STCconst, type, Id::p, NULL));
    parameters->push(new Parameter(STCref | STCconst, type, Id::q, NULL));
    TypeFunction *tf = new TypeFunction(parameters, Type::tbool, 0, LINKd);
    tf = (TypeFunction *)tf->semantic(0, sc);

    Identifier *id = Lexer::idPool("__xopEquals");
    FuncDeclaration *fop = new FuncDeclaration(0, 0, id, STCstatic, tf);

    Expression *e1 = new IdentifierExp(0, Id::p);
    Expression *e2 = new IdentifierExp(0, Id::q);
    Expression *e = new EqualExp(TOKequal, 0, e1, e2);

    fop->fbody = new ReturnStatement(0, e);

    size_t index = members->dim;
    members->push(fop);

    unsigned errors = global.startGagging();    // Do not report errors, even if the
    unsigned oldspec = global.speculativeGag;   // template opAssign fbody makes it.
    global.speculativeGag = global.gag;
    Scope *sc2 = sc->push();
    sc2->stc = 0;
    sc2->linkage = LINKd;
    sc2->speculative = true;

    fop->semantic(sc2);
    fop->semantic2(sc2);
    fop->semantic3(sc2);

    sc2->pop();
    global.speculativeGag = oldspec;
    if (global.endGagging(errors))    // if errors happened
    {
        members->remove(index);

        if (!xerreq)
        {
            Expression *e = new IdentifierExp(0, Id::empty);
            e = new DotIdExp(0, e, Id::object);
            e = new DotIdExp(0, e, Lexer::idPool("_xopEquals"));
            e = e->semantic(sc);
            Dsymbol *s = getDsymbol(e);
            FuncDeclaration *fd = s->isFuncDeclaration();

            xerreq = fd;
        }
        fop = xerreq;
    }
    else
        fop->addMember(sc, this, 1);

    return fop;
}


/*******************************************
 * Build copy constructor for struct.
 * Copy constructors are compiler generated only, and are only
 * callable from the compiler. They are not user accessible.
 * A copy constructor is:
 *    void cpctpr(ref const S s) const
 *    {
 *      (*cast(S*)&this) = *cast(S*)s;
 *      (*cast(S*)&this).postBlit();
 *    }
 * This is done so:
 *      - postBlit() never sees uninitialized data
 *      - memcpy can be much more efficient than memberwise copy
 *      - no fields are overlooked
 */

FuncDeclaration *StructDeclaration::buildCpCtor(Scope *sc)
{
    //printf("StructDeclaration::buildCpCtor() %s\n", toChars());
    FuncDeclaration *fcp = NULL;

    /* Copy constructor is only necessary if there is a postblit function,
     * otherwise the code generator will just do a bit copy.
     */
    if (postblit)
    {
        //printf("generating cpctor\n");

        StorageClass stc = postblit->storage_class &
                            (STCdisable | STCsafe | STCtrusted | STCsystem | STCpure | STCnothrow);
        if (stc & (STCsafe | STCtrusted))
            stc = stc & ~STCsafe | STCtrusted;

        Parameters *fparams = new Parameters;
        fparams->push(new Parameter(STCref, type->constOf(), Id::p, NULL));
        Type *ftype = new TypeFunction(fparams, Type::tvoid, FALSE, LINKd, stc);
        ftype->mod = MODconst;

        fcp = new FuncDeclaration(loc, 0, Id::cpctor, stc, ftype);

        if (!(fcp->storage_class & STCdisable))
        {
            // Build *this = p;
            Expression *e = new ThisExp(0);
            AssignExp *ea = new AssignExp(0,
                new PtrExp(0, new CastExp(0, new AddrExp(0, e), type->mutableOf()->pointerTo())),
                new PtrExp(0, new CastExp(0, new AddrExp(0, new IdentifierExp(0, Id::p)), type->mutableOf()->pointerTo()))
            );
            ea->op = TOKblit;
            Statement *s = new ExpStatement(0, ea);

            // Build postBlit();
            e = new ThisExp(0);
            e = new PtrExp(0, new CastExp(0, new AddrExp(0, e), type->mutableOf()->pointerTo()));
            e = new DotVarExp(0, e, postblit, 0);
            e = new CallExp(0, e);

            s = new CompoundStatement(0, s, new ExpStatement(0, e));
            fcp->fbody = s;
        }
        else
            fcp->fbody = new ExpStatement(0, (Expression *)NULL);

        members->push(fcp);

        sc = sc->push();
        sc->stc = 0;
        sc->linkage = LINKd;

        fcp->semantic(sc);

        sc->pop();
    }

    return fcp;
}

/*****************************************
 * Create inclusive postblit for struct by aggregating
 * all the postblits in postblits[] with the postblits for
 * all the members.
 * Note the close similarity with AggregateDeclaration::buildDtor(),
 * and the ordering changes (runs forward instead of backwards).
 */

#if DMDV2
FuncDeclaration *StructDeclaration::buildPostBlit(Scope *sc)
{
    //printf("StructDeclaration::buildPostBlit() %s\n", toChars());
    Expression *e = NULL;
    StorageClass stc = 0;

    for (size_t i = 0; i < fields.dim; i++)
    {
        Dsymbol *s = fields[i];
        VarDeclaration *v = s->isVarDeclaration();
        assert(v && v->isField());
        if (v->storage_class & STCref)
            continue;
        Type *tv = v->type->toBasetype();
        dinteger_t dim = 1;
        while (tv->ty == Tsarray)
        {   TypeSArray *ta = (TypeSArray *)tv;
            dim *= ((TypeSArray *)tv)->dim->toInteger();
            tv = tv->nextOf()->toBasetype();
        }
        if (tv->ty == Tstruct)
        {   TypeStruct *ts = (TypeStruct *)tv;
            StructDeclaration *sd = ts->sym;
            if (sd->postblit && dim)
            {
                stc |= sd->postblit->storage_class & STCdisable;

                if (stc & STCdisable)
                {
                    e = NULL;
                    break;
                }

                // this.v
                Expression *ex = new ThisExp(0);
                ex = new DotVarExp(0, ex, v, 0);

                if (v->type->toBasetype()->ty == Tstruct)
                {   // this.v.postblit()
                    ex = new DotVarExp(0, ex, sd->postblit, 0);
                    ex = new CallExp(0, ex);
                }
                else
                {
                    // Typeinfo.postblit(cast(void*)&this.v);
                    Expression *ea = new AddrExp(0, ex);
                    ea = new CastExp(0, ea, Type::tvoid->pointerTo());

                    Expression *et = v->type->getTypeInfo(sc);
                    et = new DotIdExp(0, et, Id::postblit);

                    ex = new CallExp(0, et, ea);
                }
                e = Expression::combine(e, ex); // combine in forward order
            }
        }
    }

    /* Build our own "postblit" which executes e
     */
    if (e || (stc & STCdisable))
    {   //printf("Building __fieldPostBlit()\n");
        PostBlitDeclaration *dd = new PostBlitDeclaration(loc, 0, stc, Lexer::idPool("__fieldPostBlit"));
        dd->fbody = new ExpStatement(0, e);
        postblits.shift(dd);
        members->push(dd);
        dd->semantic(sc);
    }

    switch (postblits.dim)
    {
        case 0:
            return NULL;

        case 1:
            return postblits[0];

        default:
            e = NULL;
            for (size_t i = 0; i < postblits.dim; i++)
            {   FuncDeclaration *fd = postblits[i];
                stc |= fd->storage_class & STCdisable;
                if (stc & STCdisable)
                {
                    e = NULL;
                    break;
                }
                Expression *ex = new ThisExp(0);
                ex = new DotVarExp(0, ex, fd, 0);
                ex = new CallExp(0, ex);
                e = Expression::combine(e, ex);
            }
            PostBlitDeclaration *dd = new PostBlitDeclaration(loc, 0, stc, Lexer::idPool("__aggrPostBlit"));
            dd->fbody = new ExpStatement(0, e);
            members->push(dd);
            dd->semantic(sc);
            return dd;
    }
}

#endif

/*****************************************
 * Create inclusive destructor for struct/class by aggregating
 * all the destructors in dtors[] with the destructors for
 * all the members.
 * Note the close similarity with StructDeclaration::buildPostBlit(),
 * and the ordering changes (runs backward instead of forwards).
 */

FuncDeclaration *AggregateDeclaration::buildDtor(Scope *sc)
{
    //printf("AggregateDeclaration::buildDtor() %s\n", toChars());
    Expression *e = NULL;
    StorageClass stc = 0;
    DtorDeclaration* decldtor = NULL;

    for (size_t i = 0; i < dtors.dim; i++)
    {
        if (dtors[i]->ident == Id::dtor)
        {
            decldtor = (DtorDeclaration*)dtors[i];
            break;
        }
    }

    Loc declLoc = decldtor ? decldtor->loc : loc;

#if DMDV2
    for (size_t i = 0; i < fields.dim; i++)
    {
        Dsymbol *s = fields[i];
        VarDeclaration *v = s->isVarDeclaration();
        assert(v && v->isField());
        if (v->storage_class & STCref)
            continue;
        Type *tv = v->type->toBasetype();
        dinteger_t dim = 1;
        while (tv->ty == Tsarray)
        {   TypeSArray *ta = (TypeSArray *)tv;
            dim *= ((TypeSArray *)tv)->dim->toInteger();
            tv = tv->nextOf()->toBasetype();
        }
        if (tv->ty == Tstruct)
        {   TypeStruct *ts = (TypeStruct *)tv;
            StructDeclaration *sd = ts->sym;
            if (sd->dtor && dim)
            {
                stc |= sd->dtor->storage_class & (STCdisable | STC_FUNCATTR);

                if (stc & STCdisable)
                {
                    e = NULL;
                    break;
                }

                // this.v
                Expression *ex = new ThisExp(declLoc);
                ex = new DotVarExp(declLoc, ex, v, 0);

                if (v->type->toBasetype()->ty == Tstruct)
                {   // this.v.dtor()
                    ex = new DotVarExp(declLoc, ex, sd->dtor, 0);
                    ex = new CallExp(declLoc, ex);
                }
                else
                {
                    // Typeinfo.destroy(cast(void*)&this.v);
                    Expression *ea = new AddrExp(0, ex);
                    ea = new CastExp(declLoc, ea, Type::tvoid->pointerTo());

                    Expression *et = v->type->getTypeInfo(sc);
                    et = new DotIdExp(declLoc, et, Id::destroy);

                    ex = new CallExp(declLoc, et, ea);
                }
                e = Expression::combine(ex, e); // combine in reverse order
            }
        }
    }

    /* Build our own "destructor" which executes e
     */
    if (e || (stc & STCdisable))
    {   //printf("Building __fieldDtor()\n");
        DtorDeclaration *dd = new DtorDeclaration(declLoc, 0, decldtor ? decldtor->storage_class : stc, Lexer::idPool("__fieldDtor"));
        dd->fbody = new ExpStatement(declLoc, e);
        dtors.shift(dd);
        members->push(dd);
        dd->semantic(sc);
    }
#endif

    switch (dtors.dim)
    {
        case 0:
            return NULL;

        case 1:
            return dtors[0];

        default:
            e = NULL;
            for (size_t i = 0; i < dtors.dim; i++)
            {   FuncDeclaration *fd = dtors[i];
                stc |= fd->storage_class & STCdisable;
                if (stc & STCdisable)
                {
                    e = NULL;
                    break;
                }
                Expression *ex = new ThisExp(declLoc);
                ex = new DotVarExp(declLoc, ex, fd, 0);
                ex = new CallExp(declLoc, ex);
                e = Expression::combine(ex, e);
            }
            DtorDeclaration *dd = new DtorDeclaration(declLoc, 0, decldtor ? decldtor->storage_class : stc, Lexer::idPool("__aggrDtor"));
            dd->fbody = new ExpStatement(declLoc, e);
            members->push(dd);
            dd->semantic(sc);
            return dd;
    }
}


