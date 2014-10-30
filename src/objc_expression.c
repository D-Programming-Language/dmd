
/* Compiler implementation of the D programming language
 * Copyright (c) 2014 by Digital Mars
 * All Rights Reserved
 * written by Michel Fortin
 * http://www.digitalmars.com
 * Distributed under the Boost Software License, Version 1.0.
 * http://www.boost.org/LICENSE_1_0.txt
 * https://github.com/D-Programming-Language/dmd/blob/master/src/objc_expression.c
 */

#include "aggregate.h"
#include "declaration.h"
#include "expression.h"
#include "id.h"
#include "objc.h"
#include "utf.h"

// MARK: ObjcSelectorExp

ObjcSelectorExp::ObjcSelectorExp(Loc loc, FuncDeclaration *f, int hasOverloads)
: Expression(loc, TOKobjcselector, sizeof(ObjcSelectorExp))
{
    this->func = f;
    this->selname = NULL;
    this->hasOverloads = hasOverloads;
}

ObjcSelectorExp::ObjcSelectorExp(Loc loc, char *selname, int hasOverloads)
: Expression(loc, TOKobjcselector, sizeof(ObjcSelectorExp))
{
    this->func = NULL;
    this->selname = selname;
    this->hasOverloads = hasOverloads;
}

Expression *ObjcSelectorExp::semantic(Scope *sc)
{
#if LOGSEMANTIC
    printf("ObjcSelectorExp::semantic('%s')\n", toChars());
#endif
    if (!type)
    {
        type = new TypeObjcSelector(func->type);
        type = type->semantic(loc, sc);
        if (!func->needThis())
        {   error("%s isn't a member function, has no selector", func->toChars());
            return new ErrorExp();
        }
        ClassDeclaration *cd = func->toParent()->isClassDeclaration();
        if (!cd->objc.objc)
        {   error("%s isn't an Objective-C class, function has no selector", cd->toChars());
            return new ErrorExp();
        }
    }
    return this;
}

// MARK: .interface Expression

ClassDeclaration *ObjcProtocolOfExp::protocolClassDecl = NULL;

ObjcProtocolOfExp::ObjcProtocolOfExp(Loc loc, Expression *e)
: UnaExp(loc, TOKobjc_dotprotocolof, sizeof(ObjcProtocolOfExp), e)
{
    idecl = NULL;
}

Expression *ObjcProtocolOfExp::semantic(Scope *sc)
{
    if (Expression *ex = unaSemantic(sc))
        return ex;

    if (e1->type && e1->type->ty == Tclass)
    {
        ClassDeclaration *cd = ((TypeClass *)e1->type)->sym;
        if (cd->objc.objc)
        {
            if (e1->op == TOKtype)
            {
                if (cd->isInterfaceDeclaration())
                {
                    if (protocolClassDecl)
                    {
                        idecl = (InterfaceDeclaration *)cd;
                        type = protocolClassDecl->type;
                        return this;
                    }
                    else
                    {
                        error("'protocolof' property not available because its the 'Protocol' Objective-C class is not defined (did you forget to import objc.types?)");
                        return new ErrorExp();
                    }
                }
            }
        }
    }

    error("%s of type %s has no 'protocolof' property", e1->toChars(), e1->type->toChars());
    return new ErrorExp();
}

// MARK: semantic

ControlFlow objc_StringExp_semantic(StringExp *self, Expression *&error)
{
    // determine if this string is pure ascii
    int ascii = 1;
    for (size_t i = 0; i < self->len; ++i)
    {
        if (((unsigned char *)self->string)[i] & 0x80)
        {
            ascii = 0;
            break;
        }
    }

    if (!ascii)
    {   // use UTF-16 for non-ASCII strings
        OutBuffer buffer;
        size_t newlen = 0;
        const char *p;
        size_t u;
        unsigned c;

        for (u = 0; u < self->len;)
        {
            p = utf_decodeChar((unsigned char *)self->string, self->len, &u, &c);
            if (p)
            {
                self->error("%s", p);
                error = new ErrorExp();
                return CFreturn;
            }
            else
            {
                buffer.writeUTF16(c);
                newlen++;
                if (c >= 0x10000)
                    newlen++;
            }
        }
        buffer.writeUTF16(0);
        self->string = buffer.extractData();
        self->len = newlen;
        self->sz = 2;
    }
    self->committed = 1;
    return CFnone;
}

ControlFlow objc_NewExp_semantic_alloc(NewExp *self, Scope *sc, ClassDeclaration *cd)
{
    if (cd->objc.meta)
    {
        self->error("cannot instanciate meta class '%s'", cd->toChars());
        return CFgoto;
    }

    // use Objective-C 'alloc' function
    Dsymbol *s = cd->search(self->loc, Id::alloc, 0);
    if (s)
    {
        FuncDeclaration *allocf = s->isFuncDeclaration();
        if (allocf)
        {
            allocf = resolveFuncCall(self->loc, sc, allocf, NULL, NULL, self->newargs);
            if (!allocf->isStatic())
            {
                self->error("function %s must be static to qualify as an allocator for Objective-C class %s", allocf->toChars(), cd->toChars());
                return CFgoto;
            }
            else if (((TypeFunction *)allocf->type)->next != allocf->parent->isClassDeclaration()->type)
            {
                self->error("function %s should return %s instead of %s to qualify as an allocator for Objective-C class %s",
                            allocf->toChars(), allocf->parent->isClassDeclaration()->type->toChars(),
                            ((TypeFunction *)allocf->type)->next->toChars(), cd->toChars());
                return CFgoto;
            }

            self->objcalloc = allocf;
        }
    }
    if (self->objcalloc == NULL)
    {
        self->error("no matching 'alloc' function in Objective-C class %s", cd->toChars());
        return CFgoto;
    }

    return CFnone;
}

ControlFlow objc_IsExp_semantic_TOKobjcselector(IsExp *self, Type *&tded)
{
    if (self->targ->ty != Tobjcselector)
        return CFgoto;
    tded = ((TypeObjcSelector *)self->targ)->next; // the underlying function type
    return CFbreak;
}

void objc_IsExp_semantic_TOKreturn_selector(IsExp *self, Type *&tded)
{
    tded = ((TypeDelegate *)self->targ)->next;
    tded = ((TypeFunction *)tded)->next;
}

void objc_CallExp_semantic_opOverload_selector(CallExp *self, Scope *sc, Type *t1)
{
    assert(self->argument0 == NULL);
    TypeObjcSelector *sel = (TypeObjcSelector *)t1;

    // harvest first argument and check if valid target for a selector
    int validtarget = 0;
    if (self->arguments->dim >= 1)
    {
        self->argument0 = ((Expression *)self->arguments->data[0])->semantic(sc);
        if (self->argument0 && self->argument0->type->ty == Tclass)
        {
            TypeClass *tc = (TypeClass *)self->argument0->type;
            if (tc && tc->sym && tc->sym->objc.objc)
                validtarget = 1; // Objective-C object
        }
        else if (self->argument0 && self->argument0->type->ty == Tpointer)
        {
            TypePointer *tp = (TypePointer *)self->argument0->type;
            if (tp->next->ty == Tstruct)
            {
                TypeStruct *ts = (TypeStruct *)tp->next;
                if (ts && ts->sym && ts->sym->objc.selectorTarget)
                    validtarget = 1; // struct with objc_selectortarget pragma applied
            }
        }
    }
    if (validtarget)
    {   // take first argument and use it as 'this'
        // create new array of expressions omiting first argument
        Expressions *newargs = new Expressions();
        for (int i = 1; i < self->arguments->dim; ++i)
            newargs->push(self->arguments->tdata()[i]);
        assert(newargs->dim == self->arguments->dim - 1);
        self->arguments = newargs;
    }
    else
        self->error("calling a selector needs an Objective-C object as the first argument");
}

void objc_CallExp_semantic_noFunction_selector(Type *t1, TypeFunction *&tf, const char *&p)
{
    TypeObjcSelector *td = (TypeObjcSelector *)t1;
    assert(td->next->ty == Tfunction);
    tf = (TypeFunction *)(td->next);
    p = "Objective-C selector";
}

ObjcSelectorExp * objc_AddrExp_semantic_TOKdotvar_selector(AddrExp *self, DotVarExp *dve, FuncDeclaration *f)
{
    return new ObjcSelectorExp(self->loc, f, dve->hasOverloads);
}

Expression * objc_AddrExp_semantic_TOKvar_selector(AddrExp *self, Scope *sc, VarExp *ve, FuncDeclaration *f)
{
    Expression *e = new ObjcSelectorExp(self->loc, f, ve->hasOverloads);
    e = e->semantic(sc);
    return e;
}

// MARK: getRightThis

ControlFlow objc_getRightThis(AggregateDeclaration *ad, Expression *&e1, Declaration *var)
{
    ControlFlow controlFlow = CFnone;

    if (e1->op == TOKobjcclsref)
    {
        // We already have an Objective-C class reference, just use that as 'this'.
        controlFlow = CFgoto;
    }
    else if (ad &&
             ad->isClassDeclaration() && ((ClassDeclaration *)ad)->objc.objc &&
             var->isFuncDeclaration() && ((FuncDeclaration *)var)->isStatic() &&
             ((FuncDeclaration *)var)->objc.selector)
    {
        // Create class reference from the class declaration
        e1 = new ObjcClassRefExp(e1->loc, (ClassDeclaration *)ad);
        controlFlow = CFgoto;
    }

    return controlFlow;
}