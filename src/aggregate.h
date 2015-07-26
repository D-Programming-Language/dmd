
/* Compiler implementation of the D programming language
 * Copyright (c) 1999-2014 by Digital Mars
 * All Rights Reserved
 * written by Walter Bright
 * http://www.digitalmars.com
 * Distributed under the Boost Software License, Version 1.0.
 * http://www.boost.org/LICENSE_1_0.txt
 * https://github.com/D-Programming-Language/dmd/blob/master/src/aggregate.h
 */

#ifndef DMD_AGGREGATE_H
#define DMD_AGGREGATE_H

#ifdef __DMC__
#pragma once
#endif /* __DMC__ */

#include "root.h"

#include "dsymbol.h"
#include "declaration.h"
#include "objc.h"

class Identifier;
class Type;
class TypeFunction;
class Expression;
class FuncDeclaration;
class CtorDeclaration;
class DtorDeclaration;
class InvariantDeclaration;
class NewDeclaration;
class DeleteDeclaration;
class InterfaceDeclaration;
class TypeInfoClassDeclaration;
class VarDeclaration;

enum Sizeok
{
    SIZEOKnone,         // size of aggregate is not computed yet
    SIZEOKdone,         // size of aggregate is set correctly
    SIZEOKfwd,          // error in computing size of aggregate
};

enum Baseok
{
    BASEOKnone,         // base classes not computed yet
    BASEOKin,           // in process of resolving base classes
    BASEOKdone,         // all base classes are resolved
    BASEOKsemanticdone, // all base classes semantic done
};

enum StructPOD
{
    ISPODno,            // struct is not POD
    ISPODyes,           // struct is POD
    ISPODfwd,           // POD not yet computed
};

FuncDeclaration *hasIdentityOpAssign(AggregateDeclaration *ad, Scope *sc);
FuncDeclaration *buildOpAssign(StructDeclaration *sd, Scope *sc);
bool needOpEquals(StructDeclaration *sd);
FuncDeclaration *buildOpEquals(StructDeclaration *sd, Scope *sc);
FuncDeclaration *buildXopEquals(StructDeclaration *sd, Scope *sc);
FuncDeclaration *buildXopCmp(StructDeclaration *sd, Scope *sc);
FuncDeclaration *buildXtoHash(StructDeclaration *ad, Scope *sc);
FuncDeclaration *buildPostBlit(StructDeclaration *sd, Scope *sc);
FuncDeclaration *buildDtor(AggregateDeclaration *ad, Scope *sc);
FuncDeclaration *buildInv(AggregateDeclaration *ad, Scope *sc);

class AggregateDeclaration : public ScopeDsymbol
{
public:
    Type *type;
    StorageClass storage_class;
    Prot protection;
    unsigned structsize;        // size of struct
    unsigned alignsize;         // size of struct for alignment purposes
    VarDeclarations fields;     // VarDeclaration fields
    Sizeok sizeok;              // set when structsize contains valid data
    Dsymbol *deferred;          // any deferred semantic2() or semantic3() symbol
    bool isdeprecated;          // true if deprecated
    bool mutedeprecation;       // true while analysing RTInfo to avoid deprecation message

    Dsymbol *enclosing;         /* !=NULL if is nested
                                 * pointing to the dsymbol that directly enclosing it.
                                 * 1. The function that enclosing it (nested struct and class)
                                 * 2. The class that enclosing it (nested class only)
                                 * 3. If enclosing aggregate is template, its enclosing dsymbol.
                                 * See AggregateDeclaraton::makeNested for the details.
                                 */
    VarDeclaration *vthis;      // 'this' parameter if this aggregate is nested
    // Special member functions
    FuncDeclarations invs;              // Array of invariants
    FuncDeclaration *inv;               // invariant
    NewDeclaration *aggNew;             // allocator
    DeleteDeclaration *aggDelete;       // deallocator

    Dsymbol *ctor;                      // CtorDeclaration or TemplateDeclaration
    CtorDeclaration *defaultCtor;       // default constructor - should have no arguments, because
                                        // it would be stored in TypeInfo_Class.defaultConstructor
    Dsymbol *aliasthis;                 // forward unresolved lookups to aliasthis
    bool noDefaultCtor;         // no default construction

    FuncDeclarations dtors;     // Array of destructors
    FuncDeclaration *dtor;      // aggregate destructor

    Expression *getRTInfo;      // pointer to GC info generated by object.RTInfo(this)

    AggregateDeclaration(Loc loc, Identifier *id);
    void setScope(Scope *sc);
    void semantic2(Scope *sc);
    void semantic3(Scope *sc);
    unsigned size(Loc loc);
    virtual void finalizeSize(Scope *sc) = 0;
    static void alignmember(structalign_t salign, unsigned size, unsigned *poffset);
    static unsigned placeField(unsigned *nextoffset,
        unsigned memsize, unsigned memalignsize, structalign_t memalign,
        unsigned *paggsize, unsigned *paggalignsize, bool isunion);
    Type *getType();
    int firstFieldInUnion(int indx); // first field in union that includes indx
    int numFieldsInUnion(int firstIndex); // #fields in union starting at index
    bool isDeprecated();         // is aggregate deprecated?
    bool muteDeprecationMessage(); // disable deprecation message on Dsymbol?
    bool isNested();
    void makeNested();
    bool isExport();
    Dsymbol *searchCtor();

    Prot prot();

    Type *handleType() { return type; } // 'this' type

    // Back end
    Symbol *stag;               // tag symbol for debug data
    Symbol *sinit;

    AggregateDeclaration *isAggregateDeclaration() { return this; }
    void accept(Visitor *v) { v->visit(this); }
};

struct StructFlags
{
    typedef unsigned Type;
    enum Enum
    {
        hasPointers = 0x1, // NB: should use noPointers as in ClassFlags
    };
};

class StructDeclaration : public AggregateDeclaration
{
public:
    int zeroInit;               // !=0 if initialize with 0 fill
    bool hasIdentityAssign;     // true if has identity opAssign
    bool hasIdentityEquals;     // true if has identity opEquals
    FuncDeclarations postblits; // Array of postblit functions
    FuncDeclaration *postblit;  // aggregate postblit

    FuncDeclaration *xeq;       // TypeInfo_Struct.xopEquals
    FuncDeclaration *xcmp;      // TypeInfo_Struct.xopCmp
    FuncDeclaration *xhash;     // TypeInfo_Struct.xtoHash
    static FuncDeclaration *xerreq;      // object.xopEquals
    static FuncDeclaration *xerrcmp;     // object.xopCmp

    structalign_t alignment;    // alignment applied outside of the struct
    StructPOD ispod;            // if struct is POD

    // For 64 bit Efl function call/return ABI
    Type *arg1type;
    Type *arg2type;

    StructDeclaration(Loc loc, Identifier *id);
    Dsymbol *syntaxCopy(Dsymbol *s);
    void semantic(Scope *sc);
    void semanticTypeInfoMembers();
    Dsymbol *search(Loc, Identifier *ident, int flags = IgnoreNone);
    const char *kind();
    void finalizeSize(Scope *sc);
    bool fit(Loc loc, Scope *sc, Expressions *elements, Type *stype);
    bool fill(Loc loc, Expressions *elements, bool ctorinit);
    bool isPOD();

    StructDeclaration *isStructDeclaration() { return this; }
    void accept(Visitor *v) { v->visit(this); }
};

class UnionDeclaration : public StructDeclaration
{
public:
    UnionDeclaration(Loc loc, Identifier *id);
    Dsymbol *syntaxCopy(Dsymbol *s);
    const char *kind();

    UnionDeclaration *isUnionDeclaration() { return this; }
    void accept(Visitor *v) { v->visit(this); }
};

struct BaseClass
{
    Type *type;                         // (before semantic processing)
    Prot protection;                    // protection for the base interface

    ClassDeclaration *sym;
    unsigned offset;                    // 'this' pointer offset
    FuncDeclarations vtbl;              // for interfaces: Array of FuncDeclaration's
                                        // making up the vtbl[]

    size_t baseInterfaces_dim;
    // if BaseClass is an interface, these
    // are a copy of the InterfaceDeclaration::interfaces
    BaseClass *baseInterfaces;

    BaseClass();
    BaseClass(Type *type, Prot protection);

    bool fillVtbl(ClassDeclaration *cd, FuncDeclarations *vtbl, int newinstance);
    void copyBaseInterfaces(BaseClasses *);
};

struct ClassFlags
{
    typedef unsigned Type;
    enum Enum
    {
        isCOMclass = 0x1,
        noPointers = 0x2,
        hasOffTi = 0x4,
        hasCtor = 0x8,
        hasGetMembers = 0x10,
        hasTypeInfo = 0x20,
        isAbstract = 0x40,
        isCPPclass = 0x80,
        hasDtor = 0x100,
    };
};

class ClassDeclaration : public AggregateDeclaration
{
public:
    static ClassDeclaration *object;
    static ClassDeclaration *throwable;
    static ClassDeclaration *exception;
    static ClassDeclaration *errorException;

    ClassDeclaration *baseClass;        // NULL only if this is Object
    FuncDeclaration *staticCtor;
    FuncDeclaration *staticDtor;
    Dsymbols vtbl;                      // Array of FuncDeclaration's making up the vtbl[]
    Dsymbols vtblFinal;                 // More FuncDeclaration's that aren't in vtbl[]

    BaseClasses *baseclasses;           // Array of BaseClass's; first is super,
                                        // rest are Interface's

    size_t interfaces_dim;
    BaseClass **interfaces;             // interfaces[interfaces_dim] for this class
                                        // (does not include baseClass)

    BaseClasses *vtblInterfaces;        // array of base interfaces that have
                                        // their own vtbl[]

    TypeInfoClassDeclaration *vclassinfo;       // the ClassInfo object for this ClassDeclaration
    bool com;                           // true if this is a COM class (meaning it derives from IUnknown)
    bool cpp;                           // true if this is a C++ interface
    bool isscope;                       // true if this is a scope class
    bool isabstract;                    // true if abstract class
    int inuse;                          // to prevent recursive attempts
    Baseok baseok;                      // set the progress of base classes resolving
    Objc_ClassDeclaration objc;

    ClassDeclaration(Loc loc, Identifier *id, BaseClasses *baseclasses, bool inObject = false);
    Dsymbol *syntaxCopy(Dsymbol *s);
    void semantic(Scope *sc);
    bool isBaseOf2(ClassDeclaration *cd);

    #define OFFSET_RUNTIME 0x76543210
    virtual bool isBaseOf(ClassDeclaration *cd, int *poffset);

    bool isBaseInfoComplete();
    Dsymbol *search(Loc, Identifier *ident, int flags = IgnoreNone);
    ClassDeclaration *searchBase(Loc, Identifier *ident);
    void finalizeSize(Scope *sc);
    bool isFuncHidden(FuncDeclaration *fd);
    FuncDeclaration *findFunc(Identifier *ident, TypeFunction *tf);
    void interfaceSemantic(Scope *sc);
    unsigned setBaseInterfaceOffsets(unsigned baseOffset);
    bool isCOMclass();
    virtual bool isCOMinterface();
    bool isCPPclass();
    virtual bool isCPPinterface();
    bool isAbstract();
    virtual int vtblOffset();
    const char *kind();

    void addLocalClass(ClassDeclarations *);

    // Back end
    Symbol *vtblsym;

    ClassDeclaration *isClassDeclaration() { return (ClassDeclaration *)this; }
    void accept(Visitor *v) { v->visit(this); }
};

class InterfaceDeclaration : public ClassDeclaration
{
public:
    InterfaceDeclaration(Loc loc, Identifier *id, BaseClasses *baseclasses);
    Dsymbol *syntaxCopy(Dsymbol *s);
    void semantic(Scope *sc);
    void finalizeSize(Scope *sc);
    bool isBaseOf(ClassDeclaration *cd, int *poffset);
    bool isBaseOf(BaseClass *bc, int *poffset);
    const char *kind();
    int vtblOffset();
    bool isCPPinterface();
    bool isCOMinterface();

    InterfaceDeclaration *isInterfaceDeclaration() { return this; }
    void accept(Visitor *v) { v->visit(this); }
};

#endif /* DMD_AGGREGATE_H */
