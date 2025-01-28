/**
 * Test the C++ compiler interface of the
 * $(LINK2 https://www.dlang.org, D programming language).
 *
 * Copyright:   Copyright (C) 2017-2023 by The D Language Foundation, All Rights Reserved
 * Authors:     Iain Buclaw
 * License:     $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/src/tests/cxxfrontend.c, _cxxfrontend.c)
 */

#include "root/array.h"
#include "root/bitarray.h"
#include "root/complex_t.h"
#include "root/ctfloat.h"
#include "root/dcompat.h"
#include "root/dsystem.h"
#include "root/filename.h"
#include "root/longdouble.h"
#include "root/optional.h"
#include "common/outbuffer.h"
#include "root/port.h"
#include "root/rmem.h"

#include "rootobject.h"
#include "aggregate.h"
#include "aliasthis.h"
#include "argtypes.h"
#include "arraytypes.h"
#include "ast_node.h"
#include "attrib.h"
#include "compiler.h"
#include "cond.h"
#include "ctfe.h"
#include "declaration.h"
#include "doc.h"
#include "dsymbol.h"
#include "enum.h"
#include "errors.h"
#include "expression.h"
#include "globals.h"
#include "hdrgen.h"
#include "identifier.h"
#include "id.h"
#include "import.h"
#include "init.h"
#include "json.h"
#include "mangle.h"
#include "module.h"
#include "mtype.h"
#include "nspace.h"
#include "objc.h"
#include "scope.h"
#include "statement.h"
#include "staticassert.h"
#include "target.h"
#include "template.h"
#include "tokens.h"
#include "typinf.h"
#include "version.h"
#include "visitor.h"

/**********************************/

extern "C" int rt_init();
extern "C" void gc_disable();

static void frontend_init()
{
    rt_init();
    gc_disable();

    global._init();
    global.compileEnv.vendor = "Front-End Tester";
    global.params.objname = NULL;

    target.os = Target::OS_linux;
    target.isX86_64 = true;
    target.cpu = CPU::native;
    target._init(global.params);

    Type::_init();
    Id::initialize();
    Module::_init();
    Expression::_init();
    Objc::_init();
    CTFloat::initialize();
}

/**********************************/

extern "C" int rt_term();
extern "C" void gc_enable();

static void frontend_term()
{
    gc_enable();
    rt_term();
}

/**********************************/

void test_tokens()
{
    // First valid TOK value
    assert((unsigned)TOK::leftParenthesis == 1);
    assert(strcmp(Token::toChars(TOK::leftParenthesis), "(") == 0);

    // Last valid TOK value
    assert((unsigned)TOK::attribute__ == (unsigned)TOK::MAX - 1);
    assert(strcmp(Token::toChars(TOK::attribute__), "__attribute__") == 0);
}

void test_compiler_globals()
{
    // only check constant prefix of version
    assert(strncmp(global.versionChars(), "v2.", 3) == 0);
    unsigned versionNumber = global.versionNumber();
    assert(versionNumber >= 2060 && versionNumber <= 3000);

    assert(strcmp(target.architectureName.ptr, "X86_64") == 0 ||
           strcmp(target.architectureName.ptr, "X86") == 0);
}

/**********************************/

class TestVisitor : public Visitor
{
  using Visitor::visit;

  public:
    bool expr;
    bool package;
    bool stmt;
    bool type;
    bool aggr;
    bool attrib;
    bool decl;
    bool typeinfo;
    bool idexpr;
    bool function;

    TestVisitor() : expr(false), package(false), stmt(false), type(false),
        aggr(false), attrib(false), decl(false), typeinfo(false), idexpr(false),
        function(false)
    {
    }

    void visit(Expression *) override
    {
        expr = true;
    }

    void visit(IdentifierExp *) override
    {
        idexpr = true;
    }

    void visit(Package *) override
    {
        package = true;
    }

    void visit(Statement *) override
    {
        stmt = true;
    }

    void visit(AttribDeclaration *) override
    {
        attrib = true;
    }

    void visit(Declaration *) override
    {
        decl = true;
    }

    void visit(AggregateDeclaration *) override
    {
        aggr = true;
    }

    void visit(TypeNext *) override
    {
        type = true;
    }

    void visit(TypeInfoDeclaration *) override
    {
        typeinfo = true;
    }

    void visit(FuncDeclaration *) override
    {
        function = true;
    }
};

void test_visitors()
{
    TestVisitor tv;
    Loc loc;
    Identifier *ident = Identifier::idPool("test");

    IntegerExp *ie = IntegerExp::create(loc, 42, Type::tint32);
    ie->accept(&tv);
    assert(tv.expr == true);

    IdentifierExp *id = IdentifierExp::create (loc, ident);
    id->accept(&tv);
    assert(tv.idexpr == true);

    Module *mod = Module::create("test", ident, 0, 0);
    assert(mod->isModule() == mod);
    mod->accept(&tv);
    assert(tv.package == true);

    ExpStatement *es = ExpStatement::create(loc, ie);
    assert(es->isExpStatement() == es);
    es->accept(&tv);
    assert(tv.stmt == true);

    TypePointer *tp = TypePointer::create(Type::tvoid);
    assert(dmd::hasPointers(tp) == true);
    tp->accept(&tv);
    assert(tv.type == true);

    LinkDeclaration *ld = LinkDeclaration::create(loc, LINK::d, NULL);
    assert(ld->isAttribDeclaration() == static_cast<AttribDeclaration *>(ld));
    assert(ld->linkage == LINK::d);
    ld->accept(&tv);
    assert(tv.attrib == true);

    ClassDeclaration *cd = ClassDeclaration::create(loc, Identifier::idPool("TypeInfo"), NULL, NULL, true);
    assert(cd->isClassDeclaration() == cd);
    assert(cd->vtblOffset() == 1);
    cd->accept(&tv);
    assert(tv.aggr == true);

    AliasDeclaration *ad = AliasDeclaration::create(loc, ident, tp);
    assert(ad->isAliasDeclaration() == ad);
    ad->storage_class = STCabstract;
    assert(ad->isAbstract() == true);
    ad->accept(&tv);
    assert(tv.decl == true);

    cd = ClassDeclaration::create(loc, Identifier::idPool("TypeInfo_Pointer"), NULL, NULL, true);
    TypeInfoPointerDeclaration *ti = TypeInfoPointerDeclaration::create(tp);
    assert(ti->isTypeInfoDeclaration() == ti);
    assert(ti->tinfo == tp);
    ti->accept(&tv);
    assert(tv.typeinfo == true);

    Parameters *args = new Parameters;
    TypeFunction *tf = TypeFunction::create(args, Type::tvoid, VARARGnone, LINK::c);
    FuncDeclaration *fd = FuncDeclaration::create(Loc (), Loc (), Identifier::idPool("test"),
                                                  STCextern, tf);
    assert(fd->isFuncDeclaration() == fd);
    assert(fd->type == tf);
    fd->accept(&tv);
    assert(tv.function == true);
}

/**********************************/

void test_semantic()
{
    /* Mini object.d source. Module::parse will add internal members also. */
    const char *buf =
        "module object;\n"
        "class Object { }\n"
        "class Throwable { }\n"
        "class Error : Throwable { this(immutable(char)[]); }";

    DArray<unsigned char> src = DArray<unsigned char>(strlen(buf), (unsigned char *)mem.xstrdup(buf));

    Module *m = Module::create("object.d", Identifier::idPool("object"), 0, 0);

    unsigned errors = global.startGagging();

    m->src = src;
    m->parse();
    m->importedFrom = m;
    dmd::importAll(m, NULL);
    dmd::dsymbolSemantic(m, NULL);
    dmd::semantic2(m, NULL);
    dmd::semantic3(m, NULL);

    Dsymbol *s = dmd::search(m, Loc(), Identifier::idPool("Error"));
    assert(s);
    AggregateDeclaration *ad = s->isAggregateDeclaration();
    assert(ad && ad->ctor && ad->sizeok == Sizeok::done);
    CtorDeclaration *ctor = ad->ctor->isCtorDeclaration();
    assert(ctor->isMember() && !ctor->isNested());
    assert(0 == strcmp(ctor->type->toChars(), "Error(string)"));

    ClassDeclaration *cd = ad->isClassDeclaration();
    assert(cd && cd->hasMonitor());

    assert(!global.endGagging(errors));
}

/**********************************/

void test_skip_importall()
{
    /* Similar to test_semantic(), but importAll step is skipped.  */
    const char *buf =
        "module rootobject;\n"
	"import object;\n"
        "class RootObject : Object { }";

    DArray<unsigned char> src = DArray<unsigned char>(strlen(buf), (unsigned char *)mem.xstrdup(buf));

    Module *m = Module::create("rootobject.d", Identifier::idPool("rootobject"), 0, 0);

    unsigned errors = global.startGagging();

    m->src = src;
    m->parse();
    m->importedFrom = m;
    dmd::dsymbolSemantic(m, NULL);
    dmd::semantic2(m, NULL);
    dmd::semantic3(m, NULL);

    assert(!global.endGagging(errors));
}

/**********************************/

void test_expression()
{
    Loc loc;
    IntegerExp *ie = IntegerExp::create(loc, 42, Type::tint32);
    Expression *e = dmd::ctfeInterpret(ie);

    assert(e);
    assert(e->isConst());

    Optional<bool> res = e->toBool();
    assert(res.get());
}

/**********************************/

void test_target()
{
    assert(target.isVectorOpSupported(Type::tint32, EXP::pow));
}

/**********************************/

void test_parameters()
{
    Parameters *args = new Parameters;
    args->push(Parameter::create(Loc(), STCundefined, Type::tint32, NULL, NULL, NULL));
    args->push(Parameter::create(Loc(), STCundefined, Type::tint64, NULL, NULL, NULL));

    TypeFunction *tf = TypeFunction::create(args, Type::tvoid, VARARGnone, LINK::c);

    assert(tf->parameterList.length() == 2);
    assert(tf->parameterList[0]->type == Type::tint32);
    assert(tf->parameterList[1]->type == Type::tint64);
    assert(!tf->isDstyleVariadic());
}

/**********************************/

void test_types()
{
    Parameters *args = new Parameters;
    StorageClass stc = STCnothrow|STCproperty|STCreturn|STCreturninferred|STCtrusted;
    TypeFunction *tfunction = TypeFunction::create(args, Type::tvoid, VARARGnone, LINK::d, stc);

    assert(tfunction->isNothrow());
    assert(!tfunction->isNogc());
    assert(tfunction->isProperty());
    assert(!tfunction->isRef());
    tfunction->isRef(true);
    assert(tfunction->isRef());
    assert(tfunction->isReturn());
    assert(!tfunction->isScopeQual());
    assert(tfunction->isReturnInferred());
    assert(!tfunction->isScopeInferred());
    assert(tfunction->linkage == LINK::d);
    assert(tfunction->trust == TRUST::trusted);
    assert(tfunction->purity == PURE::impure);
}

/**********************************/

void test_location()
{
    Loc loc1 = Loc("test.d", 24, 42);
    assert(loc1.equals(Loc("test.d", 24, 42)));
    assert(strcmp(loc1.toChars(true, MessageStyle::digitalmars), "test.d(24,42)") == 0);
    assert(strcmp(loc1.toChars(true, MessageStyle::gnu), "test.d:24:42") == 0);

    assert(strcmp(loc1.toChars(), "test.d(24)") == 0);
    Loc::set(true, MessageStyle::digitalmars);
    assert(strcmp(loc1.toChars(), "test.d(24,42)") == 0);
    Loc::set(false, MessageStyle::gnu);
    assert(strcmp(loc1.toChars(), "test.d:24") == 0);
}

/**********************************/

void test_array()
{
    Array<double> array;
    array.setDim(4);
    array.shift(10);
    array.push(20);
    array[2] = 15;
    assert(array[0] == 10);
    assert(array.find(10) == 0);
    assert(array.find(20) == 5);
    assert(!array.contains(99));
    array.remove(1);
    assert(array.length == 5);
    assert(array[1] == 15);
    assert(array.pop() == 20);
    assert(array.length == 4);
    array.insert(1, 30);
    assert(array[1] == 30);
    assert(array[2] == 15);

    Array<int> arrayA;
    array.setDim(0);
    int buf[3] = {10, 15, 20};
    arrayA.push(buf[0]);
    arrayA.push(buf[1]);
    arrayA.push(buf[2]);
    assert(memcmp(arrayA.tdata(), buf, sizeof(buf)) == 0);
    Array<int> *arrayPtr = arrayA.copy();
    assert(arrayPtr);
    assert(memcmp(arrayPtr->tdata(), arrayA.tdata(), arrayA.length * sizeof(int)) == 0);
    assert(arrayPtr->tdata() != arrayA.tdata());

    arrayPtr->setDim(0);
    int buf2[2] = {100, 200};
    arrayPtr->push(buf2[0]);
    arrayPtr->push(buf2[1]);

    arrayA.append(arrayPtr);
    assert(memcmp(arrayA.tdata() + 3, buf2, sizeof(buf2)) == 0);
    arrayA.insert(0, arrayPtr);
    assert(arrayA[0] == 100);
    assert(arrayA[1] == 200);
    assert(arrayA[2] == 10);
    assert(arrayA[3] == 15);
    assert(arrayA[4] == 20);
    assert(arrayA[5] == 100);
    assert(arrayA[6] == 200);

    arrayA.zero();
    for (size_t i = 0; i < arrayA.length; i++)
        assert(arrayA[i] == 0);

    Array<IntegerExp *> arrayInts;
    arrayInts.push(IntegerExp::create(Loc(), 10, Type::tint32));
    arrayInts.shift(IntegerExp::create(Loc(), 200, Type::tint32));
    arrayInts.push(IntegerExp::create(Loc(), 15, Type::tint32));
    arrayInts.shift(IntegerExp::create(Loc(), 100, Type::tint32));
    arrayInts.push(IntegerExp::create(Loc(), 20, Type::tint32));

    assert(strcmp(arrayInts.toChars(), "[100,200,10,15,20]") == 0);
}

void test_outbuffer()
{
    OutBuffer buf;
    dmd::mangleToBuffer(Type::tint64, buf);
    assert(strcmp(buf.peekChars(), "l") == 0);
    buf.reset();

    buf.reserve(16);
    buf.writestring("hello");
    buf.writeByte('!');
    buf.write(&buf);
    buf.writenl();
    assert(buf.length() == 13);

    const char *data = buf.extractChars();
    assert(buf.length() == 0);
    assert(strcmp(data, "hello!hello!\n") == 0);
}

void test_cppmangle()
{
    // Based off runnable_cxx/cppa.d.
    const char *buf =
        "module cppa;\n"
        "extern (C++):\n"
        "class Base { void based() { } }\n"
        "interface Interface { int MethodCPP(); int MethodD(); }\n"
        "class Derived : Base, Interface { int MethodCPP(); int MethodD() { return 3; } }";

    DArray<unsigned char> src = DArray<unsigned char>(strlen(buf), (unsigned char *)mem.xstrdup(buf));

    Module *m = Module::create("cppa.d", Identifier::idPool("cppa"), 0, 0);

    unsigned errors = global.startGagging();
    FuncDeclaration *fd;
    const char *mangle;

    m->src = src;
    m->parse();
    m->importedFrom = m;
    dmd::importAll(m, NULL);
    dmd::dsymbolSemantic(m, NULL);
    dmd::semantic2(m, NULL);
    dmd::semantic3(m, NULL);

    Dsymbol *s = dmd::search(m, Loc(), Identifier::idPool("Derived"));
    assert(s);
    ClassDeclaration *cd = s->isClassDeclaration();
    assert(cd && cd->sizeok == Sizeok::done);
    assert(cd->members && cd->members->length == 2);
    assert(cd->vtblInterfaces && cd->vtblInterfaces->length == 1);
    BaseClass *b = (*cd->vtblInterfaces)[0];

    fd = (*cd->members)[0]->isFuncDeclaration();
    assert(fd);
    mangle = dmd::cppThunkMangleItanium(fd, b->offset);
    assert(strcmp(mangle, "_ZThn8_N7Derived9MethodCPPEv") == 0);

    fd = (*cd->members)[1]->isFuncDeclaration();
    assert(fd);
    mangle = dmd::cppThunkMangleItanium(fd, b->offset);
    assert(strcmp(mangle, "_ZThn8_N7Derived7MethodDEv") == 0);

    assert(!global.endGagging(errors));
}

void test_module()
{
    unsigned errors = global.startGagging();
    Module *mod = Module::load(Loc(), NULL, Identifier::idPool("doesnotexist.d"));
    assert(mod == NULL);
    assert(global.endGagging(errors));
}

void test_optional()
{
    Optional<bool> opt = Optional<bool>::create(true);
    assert(!opt.isEmpty());
    assert(opt.isPresent());
    assert(opt.get() == true);
    assert(opt.hasValue(true));
}

void test_filename()
{
    const char *fname = "/a/nice/long/path/to/somefile.d";

    const char *basename = FileName::name(fname);
    assert(strcmp(basename, "somefile.d") == 0);

    const char *name = FileName::removeExt(basename);
    assert(strcmp(name, "somefile") == 0);

    const char *jsonname = FileName::defaultExt(name, json_ext.ptr);
    assert(strcmp(jsonname, "somefile.json") == 0);

    FileName file = FileName::create("somefile.d");
    assert(FileName::equals(basename, file.toChars()));

    FileName::free(name);
    FileName::free(jsonname);
}

/**********************************/

class MiniGlueVisitor : public Visitor
{
    using Visitor::visit;
    FuncDeclaration *func;
public:
    MiniGlueVisitor(FuncDeclaration *func)
        : func(func)
    {
    }

    void visit(Type *) override { assert(0); }
    void visit(TypeError *t) override { (void)t->ctype; }
    void visit(TypeNull *t) override { (void)t->ctype; }
    void visit(TypeNoreturn *t) override { (void)t->ctype; }
    void visit(TypeBasic *t) override
    {
        switch (t->ty)
        {
        case TY::Tvoid:
        case TY::Tbool:
        case TY::Tint8:
        case TY::Tuns8:
        case TY::Tint16:
        case TY::Tuns16:
        case TY::Tint32:
        case TY::Tuns32:
        case TY::Tint64:
        case TY::Tuns64:
        case TY::Tint128:
        case TY::Tuns128:
        case TY::Tfloat32:
        case TY::Tfloat64:
        case TY::Tfloat80:
        case TY::Timaginary32:
        case TY::Timaginary64:
        case TY::Timaginary80:
        case TY::Tcomplex32:
        case TY::Tcomplex64:
        case TY::Tcomplex80:
        case TY::Tchar:
        case TY::Twchar:
        case TY::Tdchar:
            (void)t->ctype; break;
        default:
            assert(0);
        }
        (void)t->toChars();
    }
    void visit(TypePointer *t) override
    {
        t->next->accept(this);
        (void)t->ctype;
    }
    void visit(TypeDArray *t) override
    {
        t->next->accept(this);
        Type::tsize_t->accept(this);
        (void)t->ctype;
        (void)t->toChars();
    }
    void visit(TypeSArray *t) override
    {
        if (t->dim->isConst() && t->dim->type->isIntegral())
        {
            (void)t->dim->toUInteger();
            t->next->accept(this);
            (void)t->ctype;
        }
        else
            assert(0);
    }
    void visit(TypeVector *t) override
    {
        (void)t->basetype->isTypeSArray()->dim->toUInteger();
        t->elementType()->accept(this);
        if (t->ty == TY::Tvoid)
            Type::tuns8->accept(this);
        (void)t->ctype;
        (void)t->toChars();
    }
    void visit(TypeAArray *t) override
    {
        (void)t->ctype;
        (void)t->toChars();
    }
    void visit(TypeFunction *t) override
    {
        if (t->isDstyleVariadic())
            Type::typeinfotypelist->type->accept(this);
        for (size_t i = 0; i < t->parameterList.length(); i++)
        {
            Parameter *arg = t->parameterList[i];
            (void)arg->storageClass;
            arg->type->accept(this);
        }
        if (t->parameterList.varargs != VARARGvariadic)
            Type::tvoid->accept(this);
        if (t->next != NULL)
        {
            t->next->accept(this);
            (void)t->isRef();
        }
        (void)t->ctype;
        switch (t->linkage)
        {
        case LINK::windows:
        case LINK::c:
        case LINK::cpp:
        case LINK::d:
        case LINK::objc:
            break;
        default:
            assert(0);
        }
    }
    void visit(TypeDelegate *t) override
    {
        t->next->accept(this);
        Type::tvoidptr->accept(this);
        (void)t->ctype;
        (void)t->toChars();
    }
    void visitUserAttributes(Dsymbol *sym)
    {
        if (!sym->userAttribDecl())
            return;
        Expressions *attrs = dmd::getAttributes(sym->userAttribDecl());
        if (attrs)
        {
            dmd::expandTuples(attrs);
            for (size_t i = 0; i < attrs->length; i++)
            {
                Expression *attr = (*attrs)[i];
                Dsymbol *sym = dmd::toDsymbol(attr->type, 0);
                if (!sym)
                {
                    if (TemplateExp *te = attr->isTemplateExp())
                    {
                        if (!te->td || !te->td->onemember)
                            continue;
                        sym = te->td->onemember;
                    }
                    else
                        continue;
                }
                sym->getModule()->accept(this);
                if (attr->op == EXP::call)
                    attr = dmd::ctfeInterpret(attr);
                if (attr->op != EXP::structLiteral)
                    continue;
            }
        }
    }
    void visit(TypeEnum *t) override
    {
        if (t->sym->memtype)
            t->sym->memtype->accept(this);
        if (t->sym->isSpecial())
        {
            (void)t->toChars();
            (void)t->ctype;
            t->sym->accept(this);
        }
        else if (t->sym->ident == NULL)
        {
            (void)t->ctype;
        }
        else
        {
            (void)t->ctype;
            dmd::size(t, t->sym->loc);
            if (t->sym->members)
            {
                for (size_t i = 0; i < t->sym->members->length; i++)
                {
                    EnumMember *member = (*t->sym->members)[i]->isEnumMember();
                    if (member == NULL)
                        continue;
                    (void)member->ident->toChars();
                    (void)member->value()->toInteger();
                }
            }
        }
        visitUserAttributes(t->sym);
    }
    void visit(TypeStruct *t) override
    {
        t->sym->accept(this);
        (void)t->sym->isUnionDeclaration();
        (void)t->ctype;
        if (t->sym->members)
        {
            (void)t->sym->structsize;
            (void)t->sym->alignment.isDefault();
            (void)t->sym->alignsize;
            (void)t->sym->alignment.get();
            (void)t->sym->isPOD();
            for (size_t i = 0; i < t->sym->members->length; i++)
            {
                Dsymbol *sym = (*t->sym->members)[i];
                if (VarDeclaration *var = sym->isVarDeclaration())
                {
                    (void)var->csym;
                    (void)var->aliasTuple;
                    (void)var->isField();
                    (void)var->ident->toChars();
                    continue;
                }
                if (AnonDeclaration *ad = sym->isAnonDeclaration())
                {
                    (void)ad->isunion;
                    (void)ad->loc;
                    (void)ad->decl;
                    (void)ad->anonoffset;
                    (void)ad->anonstructsize;
                    (void)ad->anonalignsize;
                    continue;
                }
                if (AttribDeclaration *attrib = sym->isAttribDeclaration())
                {
                    dmd::include(attrib, NULL);
                    continue;
                }
                if (sym->isTemplateMixin() || sym->isNspace())
                {
                    if (ScopeDsymbol *scopesym = sym->isScopeDsymbol())
                    {
                        (void)scopesym->members;
                        continue;
                    }
                }
            }
        }
        visitUserAttributes(t->sym);
    }
    void visit(TypeClass *t) override
    {
        t->sym->accept(this);
        (void)t->ctype;
        if (ClassDeclaration *cd = t->sym->isClassDeclaration())
        {
            (void)cd->baseClass;
            cd->type->accept(this);
            if (InterfaceDeclaration *id = cd->isInterfaceDeclaration())
                (void)id->vtblInterfaces->length;
            (void)cd->hasMonitor();
            if (cd->vtblInterfaces)
            {
                for (size_t i = 0; i < cd->vtblInterfaces->length; i++)
                {
                    BaseClass *bc = (*cd->vtblInterfaces)[i];
                    (void)bc->offset;
                }
            }
        }
        if (t->sym->members)
        {
            (void)t->sym->structsize;
            (void)t->sym->alignsize;
            for (size_t i = 0; i < t->sym->members->length; i++)
            {
                Dsymbol *sym = (*t->sym->members)[i];
                if (VarDeclaration *var = sym->isVarDeclaration())
                {
                    (void)var->csym;
                    (void)var->aliasTuple;
                    (void)var->isField();
                    (void)var->ident->toChars();
                    continue;
                }
                if (AnonDeclaration *ad = sym->isAnonDeclaration())
                {
                    (void)ad->isunion;
                    (void)ad->loc;
                    (void)ad->decl;
                    (void)ad->anonoffset;
                    (void)ad->anonstructsize;
                    (void)ad->anonalignsize;
                    continue;
                }
                if (AttribDeclaration *attrib = sym->isAttribDeclaration())
                {
                    dmd::include(attrib, NULL);
                    continue;
                }
                if (sym->isTemplateMixin() || sym->isNspace())
                {
                    if (ScopeDsymbol *scopesym = sym->isScopeDsymbol())
                    {
                        (void)scopesym->members;
                        continue;
                    }
                }
            }
        }
        (void)t->sym->storage_class;
        t->sym->type->accept(this);
        for (size_t i = 0; i < t->sym->vtbl.length; i++)
            t->sym->vtbl[i]->isFuncDeclaration()->accept(this);
        for (size_t i = 0; i < t->sym->baseclasses->length; i++)
        {
            BaseClass *bc = (*t->sym->baseclasses)[i];
            bc->sym->accept(this);
        }
        visitUserAttributes(t->sym);
    }
    void visit(Statement *) override { assert(0); }
    void visit(ScopeGuardStatement *) override { }
    void visit(IfStatement *s) override
    {
        s->condition->accept(this);
        s->condition->type->accept(this);
        if (s->ifbody)
            s->ifbody->accept(this);
        if (s->elsebody)
            s->elsebody->accept(this);
    }
    void visit(PragmaStatement *) override { }
    void visit(WhileStatement *) override { assert(0); }
    void visit(DoStatement *s) override
    {
        s->getRelatedLabeled()->accept(this);
        if (s->_body)
            s->_body->accept(this);
        s->condition->accept(this);
        s->condition->type->accept(this);
    }
    void visit(ForStatement *s) override
    {
        s->getRelatedLabeled()->accept(this);
        if (s->_init)
            s->_init->accept(this);
        if (s->condition)
        {
            s->condition->accept(this);
            s->condition->type->accept(this);
        }
        if (s->_body)
            s->_body->accept(this);
        if (s->increment)
            s->increment->accept(this);
    }
    void visit(ForeachStatement *) override { assert(0); }
    void visit(ForeachRangeStatement *) override { assert(0); }
    void visit(BreakStatement *s) override
    {
        if (s->ident)
        {
            LabelDsymbol *sym = func->searchLabel(s->ident, s->loc);
            LabelStatement *label = sym->statement;
            label->statement->getRelatedLabeled()->accept(this);
        }
    }
    void visit(ContinueStatement *s) override
    {
        if (s->ident)
        {
            LabelDsymbol *sym = func->searchLabel(s->ident, s->loc);
            LabelStatement *label = sym->statement;
            label->statement->accept(this);
        }
    }
    void visit(GotoStatement *s) override
    {
        assert(s->label->statement != NULL);
        assert(s->tf == s->label->statement->tf);
        (void)s->label->ident;
    }
    void visit(LabelStatement *s) override
    {
        LabelDsymbol *sym;
        if (func->returnLabel && func->returnLabel->ident == s->ident)
            sym = func->returnLabel;
        else
            sym = func->searchLabel(s->ident, s->loc);
        sym->statement->accept(this);
        if (sym == func->returnLabel && func->fensure() != NULL)
            func->fensure()->accept(this);
        else if (s->statement)
            s->statement->accept(this);
    }
    void visit(SwitchStatement *s) override
    {
        s->getRelatedLabeled()->accept(this);
        s->condition->accept(this);
        Type *condtype = s->condition->type->toBasetype();
        if (!condtype->isScalar())
            assert(0);
        if (s->cases)
        {
            for (size_t i = 0; i < s->cases->length; i++)
            {
                CaseStatement *cs = (*s->cases)[i];
                if (s->hasVars)
                    cs->exp->accept(this);
            }
            s->sdefault->accept(this);
        }
        if (s->_body)
            s->_body->accept(this);
    }
    void visit(CaseStatement *s) override
    {
        s->getRelatedLabeled()->accept(this);
        if (s->exp->type->isScalar())
            s->exp->accept(this);
        else
            (void)s->index;
        if (s->statement)
            s->statement->accept(this);
    }
    void visit(DefaultStatement *s) override
    {
        s->getRelatedLabeled()->accept(this);
        if (s->statement)
            s->statement->accept(this);
    }
    void visit(GotoDefaultStatement *s) override
    {
        s->sw->sdefault->accept(this);
    }
    void visit(GotoCaseStatement *s) override
    {
        s->cs->accept(this);
    }
    void visit(SwitchErrorStatement *s) override
    {
        s->exp->accept(this);
    }
    void visit(ReturnStatement *s) override
    {
        if (s->exp == NULL || s->exp->type->toBasetype()->ty == TY::Tvoid)
            return;
        TypeFunction *tf = func->type->toTypeFunction();
        Type *type = func->tintro != NULL ? func->tintro->nextOf() : tf->nextOf();
        if ((func->isMain() || func->isCMain()) && type->toBasetype()->ty == TY::Tvoid)
            type = Type::tint32;
        if (func->shidden)
        {
            func->accept(this);
            if (func->isNRVO() && func->nrvo_var)
                return;
            StructLiteralExp *sle = NULL;
            if (DotVarExp *dve = (s->exp->isCallExp()
                                  ? s->exp->isCallExp()->e1->isDotVarExp() : NULL))
            {
                if (dve->var->isCtorDeclaration())
                {
                    if (CommaExp *ce = dve->e1->isCommaExp())
                    {
                        DeclarationExp *de = ce->e1->isDeclarationExp();
                        VarExp *ve = ce->e2->isVarExp();
                        if (de && ve && ve->var == de->declaration &&
                            ve->var->storage_class & STCtemp)
                        {
                            ve->var->accept(this);
                        }
                    }
                    else
                        sle = dve->e1->isStructLiteralExp();
                }
            }
            else
                sle = s->exp->isStructLiteralExp();
            if (sle != NULL)
            {
                type->baseElemOf()->isTypeStruct()->sym->accept(this);
                sle->sym = func->shidden;
            }
            s->exp->accept(this);
        }
        else if (tf->next->ty == TY::Tnoreturn)
            s->exp->accept(this);
        else
            s->exp->accept(this);
    }
    void visit(ExpStatement *s) override
    {
        if (s->exp)
            s->exp->accept(this);
    }
    void visit(CompoundStatement *s) override
    {
        if (s->statements == NULL)
            return;
        for (size_t i = 0; i < s->statements->length; i++)
        {
            Statement *statement = (*s->statements)[i];
            if (statement)
                statement->accept(this);
        }
    }
    void visit(UnrolledLoopStatement *s) override
    {
        if (s->statements == NULL)
            return;
        s->getRelatedLabeled()->accept(this);
        for (size_t i = 0; i < s->statements->length; i++)
        {
            Statement *statement = (*s->statements)[i];
            if (statement != NULL)
                statement->accept(this);
        }
    }
    void visit(ScopeStatement *s) override
    {
        if (s->statement == NULL)
            return;
        s->statement->accept(this);
    }
    void visit(WithStatement *s) override
    {
        if (s->wthis)
        {
            s->wthis->accept(this);
            s->wthis->_init->isExpInitializer()->exp->accept(this);
        }
        if (s->_body)
            s->_body->accept(this);
    }
    void visit(ThrowStatement *s) override
    {
        s->exp->type->toBasetype()->isClassHandle()->accept(this);
        s->exp->accept(this);
    }
    void visit(TryCatchStatement *s) override
    {
        if (s->_body)
            s->_body->accept(this);
        if (s->catches)
        {
            for (size_t i = 0; i < s->catches->length; i++)
            {
                Catch *vcatch = (*s->catches)[i];
                vcatch->type->accept(this);
                vcatch->type->isClassHandle()->accept(this);
                if (vcatch->var)
                    vcatch->var->accept(this);
                if (vcatch->handler)
                    vcatch->handler->accept(this);
            }
        }
    }
    void visit(TryFinallyStatement *s) override
    {
        if (s->_body)
            s->_body->accept(this);
        if (s->finalbody)
            s->finalbody->accept(this);
    }
    void visit(SynchronizedStatement *) override
    {
        assert(0);
    }
    void visit(AsmStatement *) override
    {
        assert(0);
    }
    void visit(GccAsmStatement *s) override
    {
        s->insn->accept(this);
        if (s->args)
        {
            for (size_t i = 0; i < s->args->length; i++)
            {
                (void)(*s->names)[i]->toChars();
                (*s->constraints)[i]->toStringExp()->accept(this);
                (*s->args)[i]->accept(this);
                (void)s->outputargs;
            }
        }
        if (s->clobbers)
        {
            for (size_t i = 0; i < s->clobbers->length; i++)
                (*s->clobbers)[i]->toStringExp()->accept(this);
        }
        if (s->labels)
        {
            for (size_t i = 0; i < s->labels->length; i++)
            {
                (void)(*s->labels)[i]->toChars();
                GotoStatement *gs = (*s->gotos)[i];
                gs->label->statement->accept(this);
                (void)gs->label->ident;
            }
        }
    }
    void visit(ImportStatement *s) override
    {
        if (s->imports == NULL)
            return;
        for (size_t i = 0; i < s->imports->length; i++)
        {
            Dsymbol *dsym = (*s->imports)[i];
            if (dsym != NULL)
                dsym->accept(this);
        }
    }
    void visit(Dsymbol *) override { assert(0); }
    void visit(Module *d) override
    {
        if (d->semanticRun >= PASS::obj)
            return;
        if (d->members)
        {
            for (size_t i = 0; i < d->members->length; i++)
            {
                Dsymbol *s = (*d->members)[i];
                s->accept(this);
            }
            ClassDeclarations aclasses;
            dmd::getLocalClasses(d, aclasses);
            for (size_t i = 0; i < d->aimports.length; i++)
            {
                Module *mi = d->aimports[i];
                if (mi->needmoduleinfo)
                    mi->accept(this);
            }
            (void)dmd::findGetMembers(d);
            (void)d->sctor;
            (void)d->sdtor;
            (void)d->ssharedctor;
            (void)d->sshareddtor;
            (void)d->sictor;
            (void)d->stest;
            (void)d->needmoduleinfo;
        }
        d->semanticRun = PASS::obj;
    }
    void visit(Import *d) override
    {
        if (d->semanticRun >= PASS::obj)
            return;
        if (d->isstatic)
            return;
        if (d->ident == NULL)
        {
            for (size_t i = 0; i < d->names.length; i++)
            {
                d->aliasdecls[i]->accept(this);
                (void)d->aliases[i]->toChars();
            }
        }
        else
            d->mod->accept(this);
        d->semanticRun = PASS::obj;
    }
    void visit(TupleDeclaration *d) override
    {
        for (size_t i = 0; i < d->objects->length; i++)
        {
            RootObject *o = (*d->objects)[i];
            if (o->dyncast() == DYNCAST_EXPRESSION)
            {
                VarExp *ve = ((Expression *) o)->isVarExp();
                if (ve)
                    ve->var->accept(this);
            }
        }
    }
    void visit(AttribDeclaration *d) override
    {
        Dsymbols *ds = dmd::include(d, NULL);

        if (!ds)
            return;
        for (size_t i = 0; i < ds->length; i++)
            (*ds)[i]->accept(this);
    }
    void visit(PragmaDeclaration *d) override
    {
        visit((AttribDeclaration *)d);
    }
    void visit(ConditionalDeclaration *d) override
    {
        (void)d->condition->isVersionCondition();
        visit((AttribDeclaration *)d);
    }
    void visit(Nspace *d) override
    {
        if (dmd::isError(d) || !d->members)
            return;
        for (size_t i = 0; i < d->members->length; i++)
            (*d->members)[i]->accept(this);
    }
    void visit(TemplateDeclaration *d) override
    {
        if (!func || !func->isAuto())
            return;
        Type *tb = func->type->nextOf()->baseElemOf();
        while (tb->ty == TY::Tarray || tb->ty == TY::Tpointer)
            tb = tb->nextOf()->baseElemOf();
        TemplateInstance *ti = NULL;
        if (tb->ty == TY::Tstruct)
            ti = tb->isTypeStruct()->sym->isInstantiated();
        else if (tb->ty == TY::Tclass)
            ti = tb->isTypeClass()->sym->isInstantiated();
        if (ti && ti->tempdecl == d)
            ti->accept(this);
    }
    void visit(TemplateInstance *d) override
    {
        if (dmd::isError(d) || !d->members)
            return;
        if (!d->needsCodegen())
            return;
        for (size_t i = 0; i < d->members->length; i++)
            (*d->members)[i]->accept(this);
    }
    void visit(TemplateMixin *d) override
    {
        if (dmd::isError(d) || !d->members)
            return;
        for (size_t i = 0; i < d->members->length; i++)
            (*d->members)[i]->accept(this);
    }
    void visit(StructDeclaration *d) override
    {
        if (d->semanticRun >= PASS::obj)
            return;
        if (d->type->ty == TY::Terror)
            return;
        d->type->accept(this);
        if (d->isAnonymous() || !d->members)
            return;
        (void)d->sinit;
        StructLiteralExp *sle = StructLiteralExp::create(d->loc, d, NULL);
        if (!dmd::fill(d, d->loc, *sle->elements, true))
            assert(0);
        sle->type = d->type;
        sle->accept(this);
        for (size_t i = 0; i < d->members->length; i++)
            (*d->members)[i]->accept(this);
        if (d->xeq && d->xeq != d->xerreq)
            d->xeq->accept(this);
        if (d->xcmp && d->xcmp != d->xerrcmp)
            d->xcmp->accept(this);
        if (d->xhash)
            d->xhash->accept(this);
        d->semanticRun = PASS::obj;
    }
    void visit(ClassDeclaration *d) override
    {
        if (d->semanticRun >= PASS::obj)
            return;
        if (d->type->ty == TY::Terror)
            return;
        if (!d->members)
            return;
        for (size_t i = 0; i < d->members->length; i++)
            (*d->members)[i]->accept(this);
        for (size_t i = d->vtblOffset(); i < d->vtbl.length; i++)
        {
            FuncDeclaration *fd = d->vtbl[i]->isFuncDeclaration();
            if (!fd || (!fd->fbody && d->isAbstract()))
                continue;
            if (!dmd::functionSemantic(fd))
                return;
            if (!d->isFuncHidden(fd) || fd->isFuture())
                continue;
            for (size_t j = 1; j < d->vtbl.length; j++)
            {
                if (j == i)
                    continue;
                FuncDeclaration *fd2 = d->vtbl[j]->isFuncDeclaration();
                if (!fd2->ident->equals(fd->ident))
                    continue;
                if (fd2->isFuture())
                    continue;
                if (dmd::leastAsSpecialized(fd, fd2, NULL) != MATCH::nomatch ||
                    dmd::leastAsSpecialized(fd2, fd, NULL) != MATCH::nomatch)
                {
                    return;
                }
            }
        }
        (void)d->csym;
        (void)d->vtblSymbol()->csym;
        (void)d->sinit;
        NewExp *ne = NewExp::create(d->loc, NULL, NULL, d->type, NULL);
        ne->type = d->type;
        Expression *e = dmd::ctfeInterpret(ne);
        assert(e->op == EXP::classReference);
        ClassReferenceExp *exp = e->isClassReferenceExp();
        ClassDeclaration *cd = exp->originalClass();
        exp->value->stype->accept(this);
        cd->accept(this);
        for (ClassDeclaration *bcd = cd; bcd != NULL; bcd = bcd->baseClass)
        {
            for (size_t i = 0; i < bcd->vtblInterfaces->length; i++)
            {
                BaseClass *bc = (*bcd->vtblInterfaces)[i];
                for (ClassDeclaration *cd2 = cd; 1; cd2 = cd2->baseClass)
                {
                    assert(cd2 != NULL);
                    for (size_t i = 0; i < cd2->vtblInterfaces->length; i++)
                    {
                        BaseClass *b = (*cd2->vtblInterfaces)[i];
                        if (b == bc)
                            break;
                        (void)b->sym->vtbl.length;
                    }
                    for (ClassDeclaration *cd3 = cd2->baseClass; cd3; cd3 = cd3->baseClass)
                    {
                        for (size_t k = 0; k < cd3->vtblInterfaces->length; k++)
                        {
                            BaseClass *bs = (*cd3->vtblInterfaces)[k];
                            if (bs->fillVtbl(cd2, NULL, 0))
                            {
                                if (bc == bs)
                                    break;
                                (void)bs->sym->vtbl.length;
                            }
                        }
                    }
                }
                (void)bc->offset;
            }
            for (size_t i = 0; i < bcd->fields.length; i++)
            {
                VarDeclaration *vfield = bcd->fields[i];
                size_t index = exp->findFieldIndexByName(vfield);
                Expression *value = (*exp->value->elements)[index];
                if (!value)
                    continue;
                vfield->accept(this);
                value->accept(this);
            }
        }
        for (size_t i = d->vtblOffset(); i < d->vtbl.length; i++)
        {
            FuncDeclaration *fd = d->vtbl[i]->isFuncDeclaration();
            if (fd && (fd->fbody || !d->isAbstract()))
                visitDeclaration(fd);
        }
        d->type->accept(this);
        d->semanticRun = PASS::obj;
    }
    void visit(InterfaceDeclaration *d) override
    {
        if (d->semanticRun >= PASS::obj)
            return;
        if (d->type->ty == TY::Terror)
            return;
        if (!d->members)
            return;
        for (size_t i = 0; i < d->members->length; i++)
            (*d->members)[i]->accept(this);
        (void)d->csym;
        d->type->accept(this);
        d->semanticRun = PASS::obj;
    }
    void visit(EnumDeclaration *d) override
    {
        if (d->semanticRun >= PASS::obj)
            return;
        if (d->errors || d->type->ty == TY::Terror)
            return;
        if (d->isAnonymous())
            return;
        TypeEnum *tc = d->type->isTypeEnum();
        if (tc->sym->members && !dmd::isZeroInit(d->type))
        {
            (void)d->sinit;
            tc->sym->defaultval->accept(this);
        }
        d->type->accept(this);
        d->semanticRun = PASS::obj;
    }
    void visitDeclaration(Declaration *decl)
    {
        if (decl->csym)
            return;
        if (SymbolDeclaration *sd = decl->isSymbolDeclaration())
        {
            sd->dsym->accept(this);
            return;
        }
        if (TypeInfoDeclaration *tinfo = decl->isTypeInfoDeclaration())
        {
            tinfo->accept(this);
            return;
        }
        if (FuncAliasDeclaration *fad = decl->isFuncAliasDeclaration())
            return visitDeclaration(fad->funcalias);
        if (decl->isField())
        {
            decl->toParent()->isAggregateDeclaration()->type->accept(this);
            return;
        }
        if (FuncDeclaration *fd = decl->isFuncDeclaration())
        {
            if (!dmd::functionSemantic(fd))
                return;
            if (fd->needThis() && !fd->isMember2())
                return;
            (void)decl->ident->toChars();
            fd->type->accept(this);
            (void)fd->fbody;
            (void)fd->hasDualContext();
            AggregateDeclaration *ad = fd->isMember2();
            (void)fd->isNested();
            fd->isThis()->accept(this);
            ad->handleType()->accept(this);
            (void)fd->isVirtual();
            (void)fd->vtblIndex;
            if (fd->inlining == PINLINE::always || fd->inlining == PINLINE::never)
                (void)fd->inlining;
            if (fd->isCrtCtor() || fd->isCrtDtor())
                (void)fd->flags;
            (void)fd->isNaked();
            (void)fd->isGenerated();
            (void)fd->ident;
            (void)fd->storage_class;
            (void)fd->type->nextOf()->isTypeNoreturn();
        }
        else
        {
            VarDeclaration *vd = decl->isVarDeclaration();
            (void)vd->isParameter();
            (void)vd->canTakeAddressOf();
            vd->type->accept(this);
            (void)vd->alignment.isDefault();
            (void)vd->alignment.get();
            (void)vd->storage_class;
            if (vd->storage_class & STCmanifest)
            {
                if (vd->_init && !vd->_init->isVoidInitializer())
                {
                    Expression *ie = dmd::initializerToExpression(vd->_init);
                    ie->accept(this);
                }
            }
        }
        if (decl->isCodeseg() || decl->isDataseg())
        {
            if (decl->mangleOverride.length)
                (void)decl->mangleOverride.ptr;
            (void)decl->isInstantiated();
            (void)decl->toPrettyChars(true);
        }
        if ((decl->storage_class & STCtemp) ||
            (decl->storage_class & STCvolatile) ||
            (decl->storage_class & STCdeprecated))
        {
            (void)decl->storage_class;
        }
        if (decl->visibility.kind == Visibility::private_ ||
            decl->visibility.kind == Visibility::protected_)
        {
            (void)decl->visibility.kind;
        }
        (void)decl->isImportedSymbol();
        (void)decl->isExport();
        if (decl->isThreadlocal())
            (void)decl->csym;
        visitUserAttributes(decl);
    }
    void visit(VarDeclaration *d) override
    {
        if (d->semanticRun >= PASS::obj)
            return;
        if (d->type->ty == TY::Terror)
            return;
        if (d->type->isTypeNoreturn())
        {
            if (!d->isDataseg() && !d->isMember() &&
                d->_init && !d->_init->isVoidInitializer())
            {
                Expression *e = d->type->defaultInitLiteral(d->loc);
                e->accept(this);
            }
            return;
        }
        if (d->aliasTuple)
        {
            d->toAlias()->accept(this);
            return;
        }
        if (!d->canTakeAddressOf())
        {
            if (!d->type->isScalar())
                visitDeclaration(d);
        }
        else if (d->isDataseg() && !(d->storage_class & STCextern))
        {
            visitDeclaration(d);
            dmd::size(d->type, d->loc);
            if (d->_init)
            {
                if (!d->_init->isVoidInitializer())
                {
                    Expression *e = dmd::initializerToExpression(d->_init, d->type);
                    e->accept(this);
                }
            }
            else
            {
                Expression *e = d->type->defaultInitLiteral(d->loc);
                e->accept(this);
            }
        }
        else if (!d->isDataseg() && !d->isMember())
        {
            visitDeclaration(d);
            if (d->_init && !d->_init->isVoidInitializer())
            {
                ExpInitializer *vinit = d->_init->isExpInitializer();
                dmd::initializerToExpression(vinit)->accept(this);
                if (d->needsScopeDtor())
                    d->edtor->accept(this);
            }
        }
        d->type->accept(this);
        d->semanticRun = PASS::obj;
    }
    void visit(TypeInfoDeclaration *d) override
    {
        if (d->semanticRun >= PASS::obj)
            return;
        visitDeclaration(d);
        d->semanticRun = PASS::obj;
    }
    void visit(FuncDeclaration *d) override
    {
        if (d->semanticRun >= PASS::obj)
            return;
        if (d->isUnitTestDeclaration())
            return;
        if (TypeFunction *tf = d->type->isTypeFunction())
        {
            if (tf->next == NULL || tf->next->ty == TY::Terror)
                return;
        }
        if (d->hasSemantic3Errors())
            return;
        if (d->isNested())
        {
            FuncDeclaration *fdp = d;
            while (fdp && fdp->isNested())
            {
                fdp = fdp->toParent2()->isFuncDeclaration();
                if (fdp == NULL)
                    break;
                if (fdp->hasSemantic3Errors())
                    return;
            }
        }
        if (d->semanticRun < PASS::semantic3)
        {
            dmd::functionSemantic3(d);
            Module::runDeferredSemantic3();
        }
        if (global.errors)
            return;
        visitDeclaration(d);
        if (!d->fbody)
            return;
        assert(d->semanticRun == PASS::semantic3done);
        d->semanticRun = PASS::obj;
        if (d->vthis)
            visitDeclaration(d->vthis);
        if (d->v_arguments)
            visitDeclaration(d->v_arguments);
        for (size_t i = 0; i < (d->parameters ? d->parameters->length : 0); i++)
        {
            VarDeclaration *param = (*d->parameters)[i];
            visitDeclaration(param);
            if (param->type->ty == TY::Tnoreturn)
                break;
        }
        if (AggregateDeclaration *ad = d->isThis())
        {
            while (ad->isNested())
            {
                Dsymbol *pd = ad->toParent2();
                visitDeclaration(ad->vthis);
                ad = pd->isAggregateDeclaration();
                if (ad == NULL)
                    break;
            }
        }
        for (size_t i = 0; i < d->closureVars.length; i++)
        {
            VarDeclaration *v = d->closureVars[i];
            if (!v->isParameter())
                continue;
            visitDeclaration(v);
        }
        if (d->vresult)
            visitDeclaration(d->vresult);
        if (d->isNRVO() && d->nrvo_var)
            visitDeclaration(d->nrvo_var);
        d->fbody->accept(this);
        if (d->v_argptr)
            visitDeclaration(d->v_argptr);
    }
};

void test_backend(FuncDeclaration *f, Type *t)
{
    MiniGlueVisitor v(f);
    if (t->isNaked())
        t->accept(&v);
    else
    {
        Type *tb = dmd::castMod(t, 0);
        tb->accept(&v);
        (void)t->mod;
    }
    f->fbody->accept(&v);
}

void test_import_paths(const char *path, const char *imppath)
{
  global.path.push(path);
  global.params.imppath.shift(imppath);
}

/**********************************/

int main(int argc, char **argv)
{
    frontend_init();

    test_tokens();
    test_compiler_globals();
    test_visitors();
    test_semantic();
    test_skip_importall();
    test_expression();
    test_target();
    test_parameters();
    test_types();
    test_location();
    test_array();
    test_outbuffer();
    test_cppmangle();
    test_module();
    test_optional();
    test_filename();

    frontend_term();

    return 0;
}

/**********************************/
// Link Tests

void aggregate_h(StructDeclaration *sd)
{
    dmd::search_toString(sd);
    dmd::semanticTypeInfoMembers(sd);
}

void argtypes_h(Type *t)
{
    // LLVM-only
    //dmd::toArgTypes_x86(t);
    //dmd::toArgTypes_sysv_x64(t);
    //dmd::toArgTypes_aarch64(t);
    //dmd::isHFVA(t);
}

void declaration_h(FuncDeclaration *fd, const Loc &loc, Expressions* args)
{
    dmd::functionSemantic(fd);
    dmd::functionSemantic3(fd);
    ::eval_builtin(loc, fd, args);
    ::isBuiltin(fd);
}

void doc_h(Module *m, const char *ptr, d_size_t length, const char *date,
           ErrorSink *sink, OutBuffer &buf)
{
    dmd::gendocfile(m, ptr, length, date, sink, buf);
}

void dsymbol_h(Dsymbol *d, Scope *sc, ScopeDsymbol *sds, const Loc &loc, Identifier *ident)
{
    dmd::dsymbolSemantic(d, sc);
    dmd::semantic2(d, sc);
    dmd::semantic3(d, sc);
    dmd::addMember(d, sc, sds);
    dmd::search(d, loc, ident);
    dmd::setScope(d, sc);
    dmd::importAll(d, sc);
}

void expression_h(Expression *e, Scope *sc, Type *t, const Loc &loc, Expressions *es)
{
    dmd::expressionSemantic(e, sc);
    dmd::defaultInit(t, loc);
    dmd::ctfeInterpret(e);
    dmd::expandTuples(es);
    dmd::optimize(e, 0);
}

void hdrgen_h(Module *m, OutBuffer &buf, Modules &ms, ParameterList pl,
              Expression *e, Initializer *i, Statement *s, Type *t)
{
    dmd::genhdrfile(m, true, buf);
    dmd::genCppHdrFiles(ms);
    dmd::moduleToBuffer(buf, true, m);
    dmd::parametersTypeToChars(pl);
    dmd::toChars(e);
    dmd::toChars(i);
    dmd::toChars(s);
    dmd::toChars(t);
}

void init_h(Initializer *i, Type *t, Scope *sc, NeedInterpret ni)
{
    dmd::initializerToExpression(i, t, true);
    dmd::initializerSemantic(i, sc, t, ni);
}

void json_h(Modules &ms, OutBuffer &buf, const char *name)
{
    dmd::json_generate(ms, buf);
    dmd::tryParseJsonField(name);
}

void mangle_h(Dsymbol *s, FuncDeclaration *fd, Type *t, OutBuffer &buf,
              Expression *e, TemplateInstance *ti)
{
    dmd::toCppMangleItanium(s);
    dmd::cppTypeInfoMangleItanium(s);
    dmd::cppThunkMangleItanium(fd, 42);
    dmd::mangleExact(fd);
    dmd::mangleToBuffer(t, buf);
    dmd::mangleToBuffer(e, buf);
    dmd::mangleToBuffer(s, buf);
    dmd::mangleToBuffer(ti, buf);
}

void module_h(Module *m, Array<ClassDeclaration* >& acs, ScopeDsymbol *sds)
{
    dmd::getLocalClasses(m, acs);
    dmd::findGetMembers(sds);
}

void mtype_h(Type *t1, Type *t2, const Loc &loc, Scope *sc, int *p)
{
    dmd::typeSemantic(t1, loc, sc);
    dmd::merge(t1);
    dmd::isAggregate(t1);
    dmd::hasPointers(t1);
    dmd::toDsymbol(t1, sc);
    dmd::equivalent(t1, t2);
    dmd::covariant(t1, t2);
    dmd::isBaseOf(t1, t2, p);
    dmd::trySemantic(t1, loc, sc);
    dmd::merge2(t1);
    dmd::sarrayOf(t1, 0);
    dmd::arrayOf(t1);
    dmd::constOf(t1);
    dmd::immutableOf(t1);
    dmd::mutableOf(t1);
    dmd::sharedOf(t1);
    dmd::sharedConstOf(t1);
    dmd::unSharedOf(t1);
    dmd::wildOf(t1);
    dmd::wildConstOf(t1);
    dmd::sharedWildOf(t1);
    dmd::sharedWildConstOf(t1);
    dmd::castMod(t1, 0);
    dmd::addMod(t1, 0);
    dmd::pointerTo(t1);
    dmd::referenceTo(t1);
}

void statement_h(Statement *s, AsmStatement *as, GccAsmStatement *gas,
                 CAsmDeclaration *ad, Scope *sc)
{
    dmd::statementSemantic(s, sc);
    dmd::asmSemantic(as, sc);
    dmd::asmSemantic(ad, sc);
    dmd::gccAsmSemantic(gas, sc);
    dmd::gccAsmSemantic(ad, sc);
}

void template_h(TemplateParameter *tp, Scope *sc, TemplateParameters *tps,
                RootObject *o, ErrorSink *sink)
{
    dmd::tpsemantic(tp, sc, tps);
    dmd::isExpression(o);
    dmd::isDsymbol(o);
    dmd::isType(o);
    dmd::isTuple(o);
    dmd::isParameter(o);
    dmd::isTemplateParameter(o);
    dmd::isError(o);
    dmd::printTemplateStats(true, sink);
}

void typinf_h(Expression *e, const Loc &loc, Type *t, Scope *sc)
{
    dmd::genTypeInfo(e, loc, t, sc);
    ::getTypeInfoType(loc, t, sc);
    dmd::isSpeculativeType(t);
    dmd::builtinTypeInfo(t);
}
