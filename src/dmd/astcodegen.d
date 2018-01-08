module dmd.astcodegen;

/**
 * Documentation:  https://dlang.org/phobos/dmd_astcodegen.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/astcodegen.d
 */

struct ASTCodegen
{
    import dmd.aggregate;
    import dmd.aliasthis;
    import dmd.arraytypes;
    import dmd.attrib;
    import dmd.cond;
    import dmd.dclass;
    import dmd.declaration;
    import dmd.denum;
    import dmd.dimport;
    import dmd.dmodule;
    import dmd.dstruct;
    import dmd.dsymbol;
    import dmd.dtemplate;
    import dmd.dversion;
    import dmd.expression;
    import dmd.func;
    import dmd.hdrgen;
    import dmd.init;
    import dmd.initsem;
    import dmd.mtype;
    import dmd.nspace;
    import dmd.statement;
    import dmd.staticassert;
    import dmd.typesem;
    import dmd.ctfeexpr;

//    alias initializerToExpression   = dmd.initsem.initializerToExpression;
    static initializerToExpression(Initializer i, Type t = null)
    { return dmd.initsem.initializerToExpression(i, t); }
    alias typeToExpression          = dmd.typesem.typeToExpression;
    alias UserAttributeDeclaration  = dmd.attrib.UserAttributeDeclaration;

    alias MODconst                  = dmd.mtype.MODconst;
    alias MODimmutable              = dmd.mtype.MODimmutable;
    alias MODshared                 = dmd.mtype.MODshared;
    alias MODwild                   = dmd.mtype.MODwild;
    alias Type                      = dmd.mtype.Type;
    alias Tident                    = dmd.mtype.Tident;
    alias Tfunction                 = dmd.mtype.Tfunction;
    alias Parameter                 = dmd.mtype.Parameter;
    alias Taarray                   = dmd.mtype.Taarray;
    alias Tsarray                   = dmd.mtype.Tsarray;
    alias Terror                    = dmd.mtype.Terror;

    alias STC                       = dmd.declaration.STC;
    alias PROTprivate               = dmd.dsymbol.PROTprivate;
    alias PROTpackage               = dmd.dsymbol.PROTpackage;
    alias PROTprotected             = dmd.dsymbol.PROTprotected;
    alias PROTpublic                = dmd.dsymbol.PROTpublic;
    alias PROTexport                = dmd.dsymbol.PROTexport;
    alias PROTundefined             = dmd.dsymbol.PROTundefined;
    alias Prot                      = dmd.dsymbol.Prot;

    alias stcToBuffer               = dmd.hdrgen.stcToBuffer;
    alias linkageToChars            = dmd.hdrgen.linkageToChars;
    alias protectionToChars         = dmd.hdrgen.protectionToChars;

    alias isType                    = dmd.dtemplate.isType;
    alias isExpression              = dmd.dtemplate.isExpression;
    alias isTuple                   = dmd.dtemplate.isTuple;
}

struct ASTClassCount
{
    import dmd.aggregate;
    import dmd.aliasthis;
    import dmd.arraytypes;
    import dmd.attrib;
    import dmd.cond;
    import dmd.dclass;
    import dmd.declaration;
    import dmd.denum;
    import dmd.dimport;
    import dmd.dmodule;
    import dmd.dstruct;
    import dmd.dsymbol;
    import dmd.dtemplate;
    import dmd.dversion;
    import dmd.expression;
    import dmd.func;
    import dmd.hdrgen;
    import dmd.init;
    import dmd.initsem;
    import dmd.mtype;
    import dmd.nspace;
    import dmd.statement;
    import dmd.staticassert;
    import dmd.typesem;
    import dmd.ctfeexpr;

    alias initializerToExpression   = dmd.initsem.initializerToExpression;
    alias typeToExpression          = dmd.typesem.typeToExpression;
    alias UserAttributeDeclaration  = dmd.attrib.UserAttributeDeclaration;

    alias MODconst                  = dmd.mtype.MODconst;
    alias MODimmutable              = dmd.mtype.MODimmutable;
    alias MODshared                 = dmd.mtype.MODshared;
    alias MODwild                   = dmd.mtype.MODwild;
    alias Type                      = dmd.mtype.Type;
    alias Tident                    = dmd.mtype.Tident;
    alias Tfunction                 = dmd.mtype.Tfunction;
    alias Parameter                 = dmd.mtype.Parameter;
    alias Taarray                   = dmd.mtype.Taarray;
    alias Tsarray                   = dmd.mtype.Tsarray;
    alias Terror                    = dmd.mtype.Terror;

    alias STC                       = dmd.declaration.STC;
    alias Dsymbol                   = dmd.dsymbol.Dsymbol;
    alias Dsymbols                  = dmd.dsymbol.Dsymbols;
    alias PROTprivate               = dmd.dsymbol.PROTprivate;
    alias PROTpackage               = dmd.dsymbol.PROTpackage;
    alias PROTprotected             = dmd.dsymbol.PROTprotected;
    alias PROTpublic                = dmd.dsymbol.PROTpublic;
    alias PROTexport                = dmd.dsymbol.PROTexport;
    alias PROTundefined             = dmd.dsymbol.PROTundefined;
    alias Prot                      = dmd.dsymbol.Prot;

    alias stcToBuffer               = dmd.hdrgen.stcToBuffer;
    alias linkageToChars            = dmd.hdrgen.linkageToChars;
    alias protectionToChars         = dmd.hdrgen.protectionToChars;

    alias isType                    = dmd.dtemplate.isType;
    alias isExpression              = dmd.dtemplate.isExpression;
    alias isTuple                   = dmd.dtemplate.isTuple;


    import dmd.globals;
    import dmd.identifier;

    static int classCount;
    extern (C++) class ClassDeclaration : dmd.dclass.ClassDeclaration
    {
        final extern (D) this(Loc loc, Identifier id, BaseClasses* baseclasses, Dsymbols* members, bool inObject)
        {
            ++classCount;
            super(loc, id, baseclasses, members, inObject);
        }
    }
}
