/**
 * Defines AST nodes for the parsing stage.
 *
 * Copyright:   Copyright (C) 1999-2020 by The D Language Foundation, All Rights Reserved
 * License:     $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/src/dmd/astbase.d, _astbase.d)
 * Documentation:  https://dlang.org/phobos/dmd_astbase.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/astbase.d
 */

module dmd.astbase;

import dmd.parsetimevisitor;

/** The ASTBase  family defines a family of AST nodes appropriate for parsing with
  * no semantic information. It defines all the AST nodes that the parser needs
  * and also all the conveniance methods and variables. The resulting AST can be
  * visited with the strict, permissive and transitive visitors.
  * The ASTBase family is used to instantiate the parser in the parser library.
  */
struct ASTBase
{
    import dmd.root.file;
    import dmd.root.filename;
    import dmd.root.array;
    import dmd.root.rootobject;
    import dmd.root.outbuffer;
    import dmd.root.ctfloat;
    import dmd.root.rmem;
    import dmd.root.string : toDString;
    import dmd.root.stringtable;

    import dmd.tokens;
    import dmd.identifier;
    import dmd.globals;
    import dmd.id;
    import dmd.errors;
    import dmd.lexer;

    import core.stdc.string;
    import core.stdc.stdarg;

    alias Dsymbols              = Array!(Dsymbol);
    alias Objects               = Array!(RootObject);
    alias Expressions           = Array!(Expression);
    alias TemplateParameters    = Array!(TemplateParameter);
    alias BaseClasses           = Array!(BaseClass*);
    alias Parameters            = Array!(Parameter);
    alias Statements            = Array!(Statement);
    alias Catches               = Array!(Catch);
    alias Identifiers           = Array!(Identifier);
    alias Initializers          = Array!(Initializer);
    alias Ensures               = Array!(Ensure);

    enum Sizeok : ubyte
    {
        none,               // size of aggregate is not yet able to compute
        fwd,                // size of aggregate is ready to compute
        done,               // size of aggregate is set correctly
    }

    enum Baseok : ubyte
    {
        none,               // base classes not computed yet
        start,              // in process of resolving base classes
        done,               // all base classes are resolved
        semanticdone,       // all base classes semantic done
    }

    enum MODFlags : int
    {
        const_       = 1,    // type is const
        immutable_   = 4,    // type is immutable
        shared_      = 2,    // type is shared
        wild         = 8,    // type is wild
        wildconst    = (MODFlags.wild | MODFlags.const_), // type is wild const
        mutable      = 0x10, // type is mutable (only used in wildcard matching)
    }

    alias MOD = ubyte;

    enum STC : ulong
    {
        undefined_          = 0L,
        static_             = (1L << 0),
        extern_             = (1L << 1),
        const_              = (1L << 2),
        final_              = (1L << 3),
        abstract_           = (1L << 4),
        parameter           = (1L << 5),
        field               = (1L << 6),
        override_           = (1L << 7),
        auto_               = (1L << 8),
        synchronized_       = (1L << 9),
        deprecated_         = (1L << 10),
        in_                 = (1L << 11),   // in parameter
        out_                = (1L << 12),   // out parameter
        lazy_               = (1L << 13),   // lazy parameter
        foreach_            = (1L << 14),   // variable for foreach loop
                              //(1L << 15)
        variadic            = (1L << 16),   // the 'variadic' parameter in: T foo(T a, U b, V variadic...)
        ctorinit            = (1L << 17),   // can only be set inside constructor
        templateparameter   = (1L << 18),   // template parameter
        scope_              = (1L << 19),
        immutable_          = (1L << 20),
        ref_                = (1L << 21),
        init                = (1L << 22),   // has explicit initializer
        manifest            = (1L << 23),   // manifest constant
        nodtor              = (1L << 24),   // don't run destructor
        nothrow_            = (1L << 25),   // never throws exceptions
        pure_               = (1L << 26),   // pure function
        tls                 = (1L << 27),   // thread local
        alias_              = (1L << 28),   // alias parameter
        shared_             = (1L << 29),   // accessible from multiple threads
        gshared             = (1L << 30),   // accessible from multiple threads, but not typed as "shared"
        wild                = (1L << 31),   // for "wild" type constructor
        property            = (1L << 32),
        safe                = (1L << 33),
        trusted             = (1L << 34),
        system              = (1L << 35),
        ctfe                = (1L << 36),   // can be used in CTFE, even if it is static
        disable             = (1L << 37),   // for functions that are not callable
        result              = (1L << 38),   // for result variables passed to out contracts
        nodefaultctor       = (1L << 39),   // must be set inside constructor
        temp                = (1L << 40),   // temporary variable
        rvalue              = (1L << 41),   // force rvalue for variables
        nogc                = (1L << 42),   // @nogc
        volatile_           = (1L << 43),   // destined for volatile in the back end
        return_             = (1L << 44),   // 'return ref' or 'return scope' for function parameters
        autoref             = (1L << 45),   // Mark for the already deduced 'auto ref' parameter
        inference           = (1L << 46),   // do attribute inference
        exptemp             = (1L << 47),   // temporary variable that has lifetime restricted to an expression
        maybescope          = (1L << 48),   // parameter might be 'scope'
        scopeinferred       = (1L << 49),   // 'scope' has been inferred and should not be part of mangling
        future              = (1L << 50),   // introducing new base class function
        local               = (1L << 51),   // do not forward (see dmd.dsymbol.ForwardingScopeDsymbol).
        returninferred      = (1L << 52),   // 'return' has been inferred and should not be part of mangling
        live                = (1L << 53),   // function @live attribute

        safeGroup = STC.safe | STC.trusted | STC.system,
        IOR  = STC.in_ | STC.ref_ | STC.out_,
        TYPECTOR = (STC.const_ | STC.immutable_ | STC.shared_ | STC.wild),
        FUNCATTR = (STC.ref_ | STC.nothrow_ | STC.nogc | STC.pure_ | STC.property | STC.live |
                    safeGroup),
    }

    extern (C++) __gshared const(StorageClass) STCStorageClass =
        (STC.auto_ | STC.scope_ | STC.static_ | STC.extern_ | STC.const_ | STC.final_ |
         STC.abstract_ | STC.synchronized_ | STC.deprecated_ | STC.override_ | STC.lazy_ |
         STC.alias_ | STC.out_ | STC.in_ | STC.manifest | STC.immutable_ | STC.shared_ |
         STC.wild | STC.nothrow_ | STC.nogc | STC.pure_ | STC.ref_ | STC.return_ | STC.tls |
         STC.gshared | STC.property | STC.live |
         STC.safeGroup | STC.disable);

    enum ENUMTY : int
    {
        Tarray,     // slice array, aka T[]
        Tsarray,    // static array, aka T[dimension]
        Taarray,    // associative array, aka T[type]
        Tpointer,
        Treference,
        Tfunction,
        Tident,
        Tclass,
        Tstruct,
        Tenum,

        Tdelegate,
        Tnone,
        Tvoid,
        Tint8,
        Tuns8,
        Tint16,
        Tuns16,
        Tint32,
        Tuns32,
        Tint64,

        Tuns64,
        Tfloat32,
        Tfloat64,
        Tfloat80,
        Timaginary32,
        Timaginary64,
        Timaginary80,
        Tcomplex32,
        Tcomplex64,
        Tcomplex80,

        Tbool,
        Tchar,
        Twchar,
        Tdchar,
        Terror,
        Tinstance,
        Ttypeof,
        Ttuple,
        Tslice,
        Treturn,

        Tnull,
        Tvector,
        Tint128,
        Tuns128,
        Ttraits,
        Tmixin,
        TMAX
    }

    alias Tarray = ENUMTY.Tarray;
    alias Tsarray = ENUMTY.Tsarray;
    alias Taarray = ENUMTY.Taarray;
    alias Tpointer = ENUMTY.Tpointer;
    alias Treference = ENUMTY.Treference;
    alias Tfunction = ENUMTY.Tfunction;
    alias Tident = ENUMTY.Tident;
    alias Tclass = ENUMTY.Tclass;
    alias Tstruct = ENUMTY.Tstruct;
    alias Tenum = ENUMTY.Tenum;
    alias Tdelegate = ENUMTY.Tdelegate;
    alias Tnone = ENUMTY.Tnone;
    alias Tvoid = ENUMTY.Tvoid;
    alias Tint8 = ENUMTY.Tint8;
    alias Tuns8 = ENUMTY.Tuns8;
    alias Tint16 = ENUMTY.Tint16;
    alias Tuns16 = ENUMTY.Tuns16;
    alias Tint32 = ENUMTY.Tint32;
    alias Tuns32 = ENUMTY.Tuns32;
    alias Tint64 = ENUMTY.Tint64;
    alias Tuns64 = ENUMTY.Tuns64;
    alias Tfloat32 = ENUMTY.Tfloat32;
    alias Tfloat64 = ENUMTY.Tfloat64;
    alias Tfloat80 = ENUMTY.Tfloat80;
    alias Timaginary32 = ENUMTY.Timaginary32;
    alias Timaginary64 = ENUMTY.Timaginary64;
    alias Timaginary80 = ENUMTY.Timaginary80;
    alias Tcomplex32 = ENUMTY.Tcomplex32;
    alias Tcomplex64 = ENUMTY.Tcomplex64;
    alias Tcomplex80 = ENUMTY.Tcomplex80;
    alias Tbool = ENUMTY.Tbool;
    alias Tchar = ENUMTY.Tchar;
    alias Twchar = ENUMTY.Twchar;
    alias Tdchar = ENUMTY.Tdchar;
    alias Terror = ENUMTY.Terror;
    alias Tinstance = ENUMTY.Tinstance;
    alias Ttypeof = ENUMTY.Ttypeof;
    alias Ttuple = ENUMTY.Ttuple;
    alias Tslice = ENUMTY.Tslice;
    alias Treturn = ENUMTY.Treturn;
    alias Tnull = ENUMTY.Tnull;
    alias Tvector = ENUMTY.Tvector;
    alias Tint128 = ENUMTY.Tint128;
    alias Tuns128 = ENUMTY.Tuns128;
    alias Ttraits = ENUMTY.Ttraits;
    alias Tmixin = ENUMTY.Tmixin;
    alias TMAX = ENUMTY.TMAX;

    alias TY = ubyte;

    enum TFlags
    {
        integral     = 1,
        floating     = 2,
        unsigned     = 4,
        real_        = 8,
        imaginary    = 0x10,
        complex      = 0x20,
    }

    enum PKG : int
    {
        unknown,     // not yet determined whether it's a package.d or not
        module_,      // already determined that's an actual package.d
        package_,     // already determined that's an actual package
    }

    enum StructPOD : int
    {
        no,    // struct is not POD
        yes,   // struct is POD
        fwd,   // POD not yet computed
    }

    enum ZeroInit : byte
    {
        unknown = -1,  // not computed yet
        no = 0,        // struct is not all zeroes
        yes = 1,       // struct is all zeroes
    };

    enum TRUST : ubyte
    {
        default_   = 0,
        system     = 1,    // @system (same as TRUST.default)
        trusted    = 2,    // @trusted
        safe       = 3,    // @safe
        live       = 4,    // @live
    }

    enum PURE : ubyte
    {
        impure      = 0,    // not pure at all
        fwdref      = 1,    // it's pure, but not known which level yet
        weak        = 2,    // no mutable globals are read or written
        const_      = 3,    // parameters are values or const
        strong      = 4,    // parameters are values or immutable
    }

    enum AliasThisRec : int
    {
        no           = 0,    // no alias this recursion
        yes          = 1,    // alias this has recursive dependency
        fwdref       = 2,    // not yet known
        typeMask     = 3,    // mask to read no/yes/fwdref
        tracing      = 0x4,  // mark in progress of implicitConvTo/deduceWild
        tracingDT    = 0x8,  // mark in progress of deduceType
    }

    enum VarArg : ubyte
    {
        none     = 0,  /// fixed number of arguments
        variadic = 1,  /// T t, ...)  can be C-style (core.stdc.stdarg) or D-style (core.vararg)
        typesafe = 2,  /// T t ...) typesafe https://dlang.org/spec/function.html#typesafe_variadic_functions
                       ///   or https://dlang.org/spec/function.html#typesafe_variadic_functions
    }

    alias Visitor = ParseTimeVisitor!ASTBase;

    extern (C++) abstract class ASTNode : RootObject
    {
        abstract void accept(Visitor v);
    }

    extern (C++) class Dsymbol : ASTNode
    {
        Loc loc;
        Identifier ident;
        UnitTestDeclaration ddocUnittest;
        UserAttributeDeclaration userAttribDecl;
        Dsymbol parent;

        const(char)* comment;

        final extern (D) this() {}
        final extern (D) this(Identifier ident)
        {
            this.ident = ident;
        }

        final extern (D) this(const ref Loc loc, Identifier ident)
        {
            this.loc = loc;
            this.ident = ident;
        }

        void addComment(const(char)* comment)
        {
            if (!this.comment)
                this.comment = comment;
            else if (comment && strcmp(cast(char*)comment, cast(char*)this.comment) != 0)
                this.comment = Lexer.combineComments(this.comment.toDString(), comment.toDString(), true);
        }

        override const(char)* toChars() const
        {
            return ident ? ident.toChars() : "__anonymous";
        }

        bool oneMember(Dsymbol *ps, Identifier ident)
        {
            *ps = this;
            return true;
        }

        extern (D) static bool oneMembers(ref Dsymbols members, Dsymbol* ps, Identifier ident)
        {
            Dsymbol s = null;
            for (size_t i = 0; i < members.dim; i++)
            {
                Dsymbol sx = members[i];
                bool x = sx.oneMember(ps, ident);
                if (!x)
                {
                    assert(*ps is null);
                    return false;
                }
                if (*ps)
                {
                    assert(ident);
                    if (!(*ps).ident || !(*ps).ident.equals(ident))
                        continue;
                    if (!s)
                        s = *ps;
                    else if (s.isOverloadable() && (*ps).isOverloadable())
                    {
                        // keep head of overload set
                        FuncDeclaration f1 = s.isFuncDeclaration();
                        FuncDeclaration f2 = (*ps).isFuncDeclaration();
                        if (f1 && f2)
                        {
                            for (; f1 != f2; f1 = f1.overnext0)
                            {
                                if (f1.overnext0 is null)
                                {
                                    f1.overnext0 = f2;
                                    break;
                                }
                            }
                        }
                    }
                    else // more than one symbol
                    {
                        *ps = null;
                        //printf("\tfalse 2\n");
                        return false;
                    }
                }
            }
            *ps = s;
            return true;
        }

        bool isOverloadable() const
        {
            return false;
        }

        const(char)* kind() const
        {
            return "symbol";
        }

        static if (__VERSION__ < 2092)
            final void error(const(char)* format, ...)
            {
                va_list ap;
                va_start(ap, format);
                // last parameter : toPrettyChars
                verror(loc, format, ap, kind(), "");
                va_end(ap);
            }
        else
            pragma(printf) final void error(const(char)* format, ...)
            {
                va_list ap;
                va_start(ap, format);
                // last parameter : toPrettyChars
                verror(loc, format, ap, kind(), "");
                va_end(ap);
            }

        inout(AttribDeclaration) isAttribDeclaration() inout
        {
            return null;
        }

        inout(TemplateDeclaration) isTemplateDeclaration() inout
        {
            return null;
        }

        inout(FuncLiteralDeclaration) isFuncLiteralDeclaration() inout
        {
            return null;
        }

        inout(FuncDeclaration) isFuncDeclaration() inout
        {
            return null;
        }

        inout(VarDeclaration) isVarDeclaration() inout
        {
            return null;
        }

        inout(TemplateInstance) isTemplateInstance() inout
        {
            return null;
        }

        inout(Declaration) isDeclaration() inout
        {
            return null;
        }

        inout(ClassDeclaration) isClassDeclaration() inout
        {
            return null;
        }

        inout(AggregateDeclaration) isAggregateDeclaration() inout
        {
            return null;
        }

        Dsymbol syntaxCopy(Dsymbol s)
        {
            return null;
        }

        override final DYNCAST dyncast() const
        {
            return DYNCAST.dsymbol;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) class AliasThis : Dsymbol
    {
        Identifier ident;

        extern (D) this(const ref Loc loc, Identifier ident)
        {
            super(null);
            this.loc = loc;
            this.ident = ident;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) abstract class Declaration : Dsymbol
    {
        StorageClass storage_class;
        Prot protection;
        LINK linkage;
        Type type;

        final extern (D) this(Identifier id)
        {
            super(id);
            storage_class = STC.undefined_;
            protection = Prot(Prot.Kind.undefined);
            linkage = LINK.default_;
        }

        override final inout(Declaration) isDeclaration() inout
        {
            return this;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) class ScopeDsymbol : Dsymbol
    {
        Dsymbols* members;
        final extern (D) this() {}
        final extern (D) this(Identifier id)
        {
            super(id);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) class Import : Dsymbol
    {
        Identifiers* packages;
        Identifier id;
        Identifier aliasId;
        int isstatic;
        Prot protection;

        Identifiers names;
        Identifiers aliases;

        extern (D) this(const ref Loc loc, Identifiers* packages, Identifier id, Identifier aliasId, int isstatic)
        {
            super(null);
            this.loc = loc;
            this.packages = packages;
            this.id = id;
            this.aliasId = aliasId;
            this.isstatic = isstatic;
            this.protection = Prot(Prot.Kind.private_);

            if (aliasId)
            {
                // import [cstdio] = std.stdio;
                this.ident = aliasId;
            }
            else if (packages && packages.dim)
            {
                // import [std].stdio;
                this.ident = (*packages)[0];
            }
            else
            {
                // import [foo];
                this.ident = id;
            }
        }
        void addAlias(Identifier name, Identifier _alias)
        {
            if (isstatic)
                error("cannot have an import bind list");
            if (!aliasId)
                this.ident = null;

            names.push(name);
            aliases.push(_alias);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) abstract class AttribDeclaration : Dsymbol
    {
        Dsymbols* decl;

        final extern (D) this(Dsymbols *decl)
        {
            this.decl = decl;
        }

        final extern (D) this(const ref Loc loc, Identifier ident, Dsymbols* decl)
        {
            super(loc, ident);
            this.decl = decl;
        }

        override final inout(AttribDeclaration) isAttribDeclaration() inout
        {
            return this;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class StaticAssert : Dsymbol
    {
        Expression exp;
        Expression msg;

        extern (D) this(const ref Loc loc, Expression exp, Expression msg)
        {
            super(Id.empty);
            this.loc = loc;
            this.exp = exp;
            this.msg = msg;
        }
    }

    extern (C++) final class DebugSymbol : Dsymbol
    {
        uint level;

        extern (D) this(const ref Loc loc, Identifier ident)
        {
            super(ident);
            this.loc = loc;
        }
        extern (D) this(const ref Loc loc, uint level)
        {
            this.level = level;
            this.loc = loc;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class VersionSymbol : Dsymbol
    {
        uint level;

        extern (D) this(const ref Loc loc, Identifier ident)
        {
            super(ident);
            this.loc = loc;
        }
        extern (D) this(const ref Loc loc, uint level)
        {
            this.level = level;
            this.loc = loc;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) class VarDeclaration : Declaration
    {
        Type type;
        Initializer _init;
        enum AdrOnStackNone = ~0u;
        uint ctfeAdrOnStack;
        uint sequenceNumber;
        __gshared uint nextSequenceNumber;

        final extern (D) this(const ref Loc loc, Type type, Identifier id, Initializer _init, StorageClass st = STC.undefined_)
        {
            super(id);
            this.type = type;
            this._init = _init;
            this.loc = loc;
            this.storage_class = st;
            sequenceNumber = ++nextSequenceNumber;
            ctfeAdrOnStack = AdrOnStackNone;
        }

        override final inout(VarDeclaration) isVarDeclaration() inout
        {
            return this;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) struct Ensure
    {
        Identifier id;
        Statement ensure;
    }

    extern (C++) class FuncDeclaration : Declaration
    {
        Statement fbody;
        Statements* frequires;
        Ensures* fensures;
        Loc endloc;
        StorageClass storage_class;
        Type type;
        bool inferRetType;
        ForeachStatement fes;
        FuncDeclaration overnext0;

        final extern (D) this(const ref Loc loc, Loc endloc, Identifier id, StorageClass storage_class, Type type)
        {
            super(id);
            this.storage_class = storage_class;
            this.type = type;
            if (type)
            {
                // Normalize storage_class, because function-type related attributes
                // are already set in the 'type' in parsing phase.
                this.storage_class &= ~(STC.TYPECTOR | STC.FUNCATTR);
            }
            this.loc = loc;
            this.endloc = endloc;
            inferRetType = (type && type.nextOf() is null);
        }

        FuncLiteralDeclaration isFuncLiteralDeclaration()
        {
            return null;
        }

        override bool isOverloadable() const
        {
            return true;
        }

        override final inout(FuncDeclaration) isFuncDeclaration() inout
        {
            return this;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class AliasDeclaration : Declaration
    {
        Dsymbol aliassym;

        extern (D) this(const ref Loc loc, Identifier id, Dsymbol s)
        {
            super(id);
            this.loc = loc;
            this.aliassym = s;
        }

        extern (D) this(const ref Loc loc, Identifier id, Type type)
        {
            super(id);
            this.loc = loc;
            this.type = type;
        }

        override bool isOverloadable() const
        {
            //assume overloadable until alias is resolved;
            // should be modified when semantic analysis is added
            return true;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class TupleDeclaration : Declaration
    {
        Objects* objects;

        extern (D) this(const ref Loc loc, Identifier id, Objects* objects)
        {
            super(id);
            this.loc = loc;
            this.objects = objects;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class FuncLiteralDeclaration : FuncDeclaration
    {
        TOK tok;

        extern (D) this(const ref Loc loc, Loc endloc, Type type, TOK tok, ForeachStatement fes, Identifier id = null)
        {
            super(loc, endloc, null, STC.undefined_, type);
            this.ident = id ? id : Id.empty;
            this.tok = tok;
            this.fes = fes;
        }

        override inout(FuncLiteralDeclaration) isFuncLiteralDeclaration() inout
        {
            return this;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class PostBlitDeclaration : FuncDeclaration
    {
        extern (D) this(const ref Loc loc, Loc endloc, StorageClass stc, Identifier id)
        {
            super(loc, endloc, id, stc, null);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class CtorDeclaration : FuncDeclaration
    {
        extern (D) this(const ref Loc loc, Loc endloc, StorageClass stc, Type type, bool isCopyCtor = false)
        {
            super(loc, endloc, Id.ctor, stc, type);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class DtorDeclaration : FuncDeclaration
    {
        extern (D) this(const ref Loc loc, Loc endloc)
        {
            super(loc, endloc, Id.dtor, STC.undefined_, null);
        }
        extern (D) this(const ref Loc loc, Loc endloc, StorageClass stc, Identifier id)
        {
            super(loc, endloc, id, stc, null);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class InvariantDeclaration : FuncDeclaration
    {
        extern (D) this(const ref Loc loc, Loc endloc, StorageClass stc, Identifier id, Statement fbody)
        {
            super(loc, endloc, id ? id : Identifier.generateId("__invariant"), stc, null);
            this.fbody = fbody;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class UnitTestDeclaration : FuncDeclaration
    {
        char* codedoc;

        extern (D) this(const ref Loc loc, Loc endloc, StorageClass stc, char* codedoc)
        {
            super(loc, endloc, Identifier.generateIdWithLoc("__unittest", loc), stc, null);
            this.codedoc = codedoc;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class NewDeclaration : FuncDeclaration
    {
        ParameterList parameterList;

        extern (D) this(const ref Loc loc, Loc endloc, StorageClass stc, ref ParameterList parameterList)
        {
            super(loc, endloc, Id.classNew, STC.static_ | stc, null);
            this.parameterList = parameterList;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) class StaticCtorDeclaration : FuncDeclaration
    {
        final extern (D) this(const ref Loc loc, Loc endloc, StorageClass stc)
        {
            super(loc, endloc, Identifier.generateIdWithLoc("_staticCtor", loc), STC.static_ | stc, null);
        }
        final extern (D) this(const ref Loc loc, Loc endloc, string name, StorageClass stc)
        {
            super(loc, endloc, Identifier.generateIdWithLoc(name, loc), STC.static_ | stc, null);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) class StaticDtorDeclaration : FuncDeclaration
    {
        final extern (D) this()(Loc loc, Loc endloc, StorageClass stc)
        {
            super(loc, endloc, Identifier.generateIdWithLoc("__staticDtor", loc), STC.static_ | stc, null);
        }
        final extern (D) this(const ref Loc loc, Loc endloc, string name, StorageClass stc)
        {
            super(loc, endloc, Identifier.generateIdWithLoc(name, loc), STC.static_ | stc, null);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class SharedStaticCtorDeclaration : StaticCtorDeclaration
    {
        extern (D) this(const ref Loc loc, Loc endloc, StorageClass stc)
        {
            super(loc, endloc, "_sharedStaticCtor", stc);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class SharedStaticDtorDeclaration : StaticDtorDeclaration
    {
        extern (D) this(const ref Loc loc, Loc endloc, StorageClass stc)
        {
            super(loc, endloc, "_sharedStaticDtor", stc);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) class Package : ScopeDsymbol
    {
        PKG isPkgMod;
        uint tag;

        final extern (D) this(Identifier ident)
        {
            super(ident);
            this.isPkgMod = PKG.unknown;
            __gshared uint packageTag;
            this.tag = packageTag++;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class EnumDeclaration : ScopeDsymbol
    {
        Type type;
        Type memtype;
        Prot protection;

        extern (D) this(const ref Loc loc, Identifier id, Type memtype)
        {
            super(id);
            this.loc = loc;
            type = new TypeEnum(this);
            this.memtype = memtype;
            protection = Prot(Prot.Kind.undefined);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) abstract class AggregateDeclaration : ScopeDsymbol
    {
        Prot protection;
        Sizeok sizeok;
        Type type;

        final extern (D) this(const ref Loc loc, Identifier id)
        {
            super(id);
            this.loc = loc;
            protection = Prot(Prot.Kind.public_);
            sizeok = Sizeok.none;
        }

        override final inout(AggregateDeclaration) isAggregateDeclaration() inout
        {
            return this;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class TemplateDeclaration : ScopeDsymbol
    {
        TemplateParameters* parameters;
        TemplateParameters* origParameters;
        Expression constraint;
        bool literal;
        bool ismixin;
        bool isstatic;
        Prot protection;
        Dsymbol onemember;

        extern (D) this(const ref Loc loc, Identifier id, TemplateParameters* parameters, Expression constraint, Dsymbols* decldefs, bool ismixin = false, bool literal = false)
        {
            super(id);
            this.loc = loc;
            this.parameters = parameters;
            this.origParameters = parameters;
            this.members = decldefs;
            this.literal = literal;
            this.ismixin = ismixin;
            this.isstatic = true;
            this.protection = Prot(Prot.Kind.undefined);

            if (members && ident)
            {
                Dsymbol s;
                if (Dsymbol.oneMembers(*members, &s, ident) && s)
                {
                    onemember = s;
                    s.parent = this;
                }
            }
        }

        override bool isOverloadable() const
        {
            return true;
        }

        override inout(TemplateDeclaration) isTemplateDeclaration () inout
        {
            return this;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) class TemplateInstance : ScopeDsymbol
    {
        Identifier name;
        Objects* tiargs;
        Dsymbol tempdecl;
        bool semantictiargsdone;
        bool havetempdecl;
        TemplateInstance inst;

        final extern (D) this(const ref Loc loc, Identifier ident, Objects* tiargs)
        {
            super(null);
            this.loc = loc;
            this.name = ident;
            this.tiargs = tiargs;
        }

        final extern (D) this(const ref Loc loc, TemplateDeclaration td, Objects* tiargs)
        {
            super(null);
            this.loc = loc;
            this.name = td.ident;
            this.tempdecl = td;
            this.semantictiargsdone = true;
            this.havetempdecl = true;
        }

        override final inout(TemplateInstance) isTemplateInstance() inout
        {
            return this;
        }

        Objects* arraySyntaxCopy(Objects* objs)
        {
            Objects* a = null;
            if (objs)
            {
                a = new Objects();
                a.setDim(objs.dim);
                for (size_t i = 0; i < objs.dim; i++)
                    (*a)[i] = objectSyntaxCopy((*objs)[i]);
            }
            return a;
        }

        RootObject objectSyntaxCopy(RootObject o)
        {
            if (!o)
                return null;
            if (Type t = isType(o))
                return t.syntaxCopy();
            if (Expression e = isExpression(o))
                return e.syntaxCopy();
            return o;
        }

        override Dsymbol syntaxCopy(Dsymbol s)
        {
            TemplateInstance ti = s ? cast(TemplateInstance)s : new TemplateInstance(loc, name, null);
            ti.tiargs = arraySyntaxCopy(tiargs);
            TemplateDeclaration td;
            if (inst && tempdecl && (td = tempdecl.isTemplateDeclaration()) !is null)
                td.ScopeDsymbol.syntaxCopy(ti);
            else
                ScopeDsymbol.syntaxCopy(ti);
            return ti;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class Nspace : ScopeDsymbol
    {
        /**
         * Namespace identifier resolved during semantic.
         */
        Expression identExp;

        extern (D) this(const ref Loc loc, Identifier ident, Expression identExp, Dsymbols* members)
        {
            super(ident);
            this.loc = loc;
            this.members = members;
            this.identExp = identExp;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class CompileDeclaration : AttribDeclaration
    {
        Expressions* exps;

        extern (D) this(const ref Loc loc, Expressions* exps)
        {
            super(null);
            this.loc = loc;
            this.exps = exps;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class UserAttributeDeclaration : AttribDeclaration
    {
        Expressions* atts;

        extern (D) this(Expressions* atts, Dsymbols* decl)
        {
            super(decl);
            this.atts = atts;
        }

        extern (D) static Expressions* concat(Expressions* udas1, Expressions* udas2)
        {
            Expressions* udas;
            if (!udas1 || udas1.dim == 0)
                udas = udas2;
            else if (!udas2 || udas2.dim == 0)
                udas = udas1;
            else
            {
                udas = new Expressions(2);
                (*udas)[0] = new TupleExp(Loc.initial, udas1);
                (*udas)[1] = new TupleExp(Loc.initial, udas2);
            }
            return udas;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class LinkDeclaration : AttribDeclaration
    {
        LINK linkage;

        extern (D) this(LINK p, Dsymbols* decl)
        {
            super(decl);
            linkage = p;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class AnonDeclaration : AttribDeclaration
    {
        bool isunion;

        extern (D) this(const ref Loc loc, bool isunion, Dsymbols* decl)
        {
            super(decl);
            this.loc = loc;
            this.isunion = isunion;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class AlignDeclaration : AttribDeclaration
    {
        Expression ealign;

        extern (D) this(const ref Loc loc, Expression ealign, Dsymbols* decl)
        {
            super(decl);
            this.loc = loc;
            this.ealign = ealign;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class CPPMangleDeclaration : AttribDeclaration
    {
        CPPMANGLE cppmangle;

        extern (D) this(CPPMANGLE p, Dsymbols* decl)
        {
            super(decl);
            cppmangle = p;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class CPPNamespaceDeclaration : AttribDeclaration
    {
        Expression exp;

        extern (D) this(Identifier ident, Dsymbols* decl)
        {
            super(decl);
            this.ident = ident;
        }

        extern (D) this(Expression exp, Dsymbols* decl)
        {
            super(decl);
            this.exp = exp;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class ProtDeclaration : AttribDeclaration
    {
        Prot protection;
        Identifiers* pkg_identifiers;

        extern (D) this(const ref Loc loc, Prot p, Dsymbols* decl)
        {
            super(decl);
            this.loc = loc;
            this.protection = p;
        }
        extern (D) this(const ref Loc loc, Identifiers* pkg_identifiers, Dsymbols* decl)
        {
            super(decl);
            this.loc = loc;
            this.protection.kind = Prot.Kind.package_;
            this.protection.pkg = null;
            this.pkg_identifiers = pkg_identifiers;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class PragmaDeclaration : AttribDeclaration
    {
        Expressions* args;

        extern (D) this(const ref Loc loc, Identifier ident, Expressions* args, Dsymbols* decl)
        {
            super(decl);
            this.loc = loc;
            this.ident = ident;
            this.args = args;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) class StorageClassDeclaration : AttribDeclaration
    {
        StorageClass stc;

        final extern (D) this(StorageClass stc, Dsymbols* decl)
        {
            super(decl);
            this.stc = stc;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) class ConditionalDeclaration : AttribDeclaration
    {
        Condition condition;
        Dsymbols* elsedecl;

        final extern (D) this(const ref Loc loc, Condition condition, Dsymbols* decl, Dsymbols* elsedecl)
        {
            super(loc, null, decl);
            this.condition = condition;
            this.elsedecl = elsedecl;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class DeprecatedDeclaration : StorageClassDeclaration
    {
        Expression msg;

        extern (D) this(Expression msg, Dsymbols* decl)
        {
            super(STC.deprecated_, decl);
            this.msg = msg;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class StaticIfDeclaration : ConditionalDeclaration
    {
        extern (D) this(const ref Loc loc, Condition condition, Dsymbols* decl, Dsymbols* elsedecl)
        {
            super(loc, condition, decl, elsedecl);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class StaticForeachDeclaration : AttribDeclaration
    {
        StaticForeach sfe;

        extern (D) this(StaticForeach sfe, Dsymbols* decl)
        {
            super(decl);
            this.sfe = sfe;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class EnumMember : VarDeclaration
    {
        Expression origValue;
        Type origType;

        @property ref value() { return (cast(ExpInitializer)_init).exp; }

        extern (D) this(const ref Loc loc, Identifier id, Expression value, Type origType)
        {
            super(loc, null, id ? id : Id.empty, new ExpInitializer(loc, value));
            this.origValue = value;
            this.origType = origType;
        }

        extern(D) this(const ref Loc loc, Identifier id, Expression value, Type memtype,
            StorageClass stc, UserAttributeDeclaration uad, DeprecatedDeclaration dd)
        {
            this(loc, id, value, memtype);
            storage_class = stc;
            userAttribDecl = uad;
            // just ignore `dd`
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class Module : Package
    {
        extern (C++) __gshared AggregateDeclaration moduleinfo;

        const FileName srcfile;
        const(char)* arg;

        extern (D) this(const(char)* filename, Identifier ident, int doDocComment, int doHdrGen)
        {
            super(ident);
            this.arg = filename;
            srcfile = FileName(FileName.defaultExt(filename.toDString, global.mars_ext));
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) class StructDeclaration : AggregateDeclaration
    {
        ZeroInit zeroInit;
        StructPOD ispod;

        final extern (D) this(const ref Loc loc, Identifier id, bool inObject)
        {
            super(loc, id);
            zeroInit = ZeroInit.unknown;
            ispod = StructPOD.fwd;
            type = new TypeStruct(this);
            if (inObject)
            {
                if (id == Id.ModuleInfo && !Module.moduleinfo)
                    Module.moduleinfo = this;
            }
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class UnionDeclaration : StructDeclaration
    {
        extern (D) this(const ref Loc loc, Identifier id)
        {
            super(loc, id, false);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) class ClassDeclaration : AggregateDeclaration
    {
        extern (C++) __gshared
        {
            // Names found by reading object.d in druntime
            ClassDeclaration object;
            ClassDeclaration throwable;
            ClassDeclaration exception;
            ClassDeclaration errorException;
            ClassDeclaration cpp_type_info_ptr;   // Object.__cpp_type_info_ptr
        }

        BaseClasses* baseclasses;
        Baseok baseok;

        final extern (D) this(const ref Loc loc, Identifier id, BaseClasses* baseclasses, Dsymbols* members, bool inObject)
        {
            if(!id)
                id = Identifier.generateId("__anonclass");
            assert(id);

            super(loc, id);

            __gshared const(char)* msg = "only object.d can define this reserved class name";

            if (baseclasses)
            {
                // Actually, this is a transfer
                this.baseclasses = baseclasses;
            }
            else
                this.baseclasses = new BaseClasses();

            this.members = members;

            //printf("ClassDeclaration(%s), dim = %d\n", id.toChars(), this.baseclasses.dim);

            // For forward references
            type = new TypeClass(this);

            if (id)
            {
                // Look for special class names
                if (id == Id.__sizeof || id == Id.__xalignof || id == Id._mangleof)
                    error("illegal class name");

                // BUG: What if this is the wrong TypeInfo, i.e. it is nested?
                if (id.toChars()[0] == 'T')
                {
                    if (id == Id.TypeInfo)
                    {
                        if (!inObject)
                            error("%s", msg);
                        Type.dtypeinfo = this;
                    }
                    if (id == Id.TypeInfo_Class)
                    {
                        if (!inObject)
                            error("%s", msg);
                        Type.typeinfoclass = this;
                    }
                    if (id == Id.TypeInfo_Interface)
                    {
                        if (!inObject)
                            error("%s", msg);
                        Type.typeinfointerface = this;
                    }
                    if (id == Id.TypeInfo_Struct)
                    {
                        if (!inObject)
                            error("%s", msg);
                        Type.typeinfostruct = this;
                    }
                    if (id == Id.TypeInfo_Pointer)
                    {
                        if (!inObject)
                            error("%s", msg);
                        Type.typeinfopointer = this;
                    }
                    if (id == Id.TypeInfo_Array)
                    {
                        if (!inObject)
                            error("%s", msg);
                        Type.typeinfoarray = this;
                    }
                    if (id == Id.TypeInfo_StaticArray)
                    {
                        //if (!inObject)
                        //    Type.typeinfostaticarray.error("%s", msg);
                        Type.typeinfostaticarray = this;
                    }
                    if (id == Id.TypeInfo_AssociativeArray)
                    {
                        if (!inObject)
                            error("%s", msg);
                        Type.typeinfoassociativearray = this;
                    }
                    if (id == Id.TypeInfo_Enum)
                    {
                        if (!inObject)
                            error("%s", msg);
                        Type.typeinfoenum = this;
                    }
                    if (id == Id.TypeInfo_Function)
                    {
                        if (!inObject)
                            error("%s", msg);
                        Type.typeinfofunction = this;
                    }
                    if (id == Id.TypeInfo_Delegate)
                    {
                        if (!inObject)
                            error("%s", msg);
                        Type.typeinfodelegate = this;
                    }
                    if (id == Id.TypeInfo_Tuple)
                    {
                        if (!inObject)
                            error("%s", msg);
                        Type.typeinfotypelist = this;
                    }
                    if (id == Id.TypeInfo_Const)
                    {
                        if (!inObject)
                            error("%s", msg);
                        Type.typeinfoconst = this;
                    }
                    if (id == Id.TypeInfo_Invariant)
                    {
                        if (!inObject)
                            error("%s", msg);
                        Type.typeinfoinvariant = this;
                    }
                    if (id == Id.TypeInfo_Shared)
                    {
                        if (!inObject)
                            error("%s", msg);
                        Type.typeinfoshared = this;
                    }
                    if (id == Id.TypeInfo_Wild)
                    {
                        if (!inObject)
                            error("%s", msg);
                        Type.typeinfowild = this;
                    }
                    if (id == Id.TypeInfo_Vector)
                    {
                        if (!inObject)
                            error("%s", msg);
                        Type.typeinfovector = this;
                    }
                }

                if (id == Id.Object)
                {
                    if (!inObject)
                        error("%s", msg);
                    object = this;
                }

                if (id == Id.Throwable)
                {
                    if (!inObject)
                        error("%s", msg);
                    throwable = this;
                }
                if (id == Id.Exception)
                {
                    if (!inObject)
                        error("%s", msg);
                    exception = this;
                }
                if (id == Id.Error)
                {
                    if (!inObject)
                        error("%s", msg);
                    errorException = this;
                }
                if (id == Id.cpp_type_info_ptr)
                {
                    if (!inObject)
                        error("%s", msg);
                    cpp_type_info_ptr = this;
                }
            }
            baseok = Baseok.none;
        }

        override final inout(ClassDeclaration) isClassDeclaration() inout
        {
            return this;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) class InterfaceDeclaration : ClassDeclaration
    {
        final extern (D) this(const ref Loc loc, Identifier id, BaseClasses* baseclasses)
        {
            super(loc, id, baseclasses, null, false);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) class TemplateMixin : TemplateInstance
    {
        TypeQualified tqual;

        extern (D) this(const ref Loc loc, Identifier ident, TypeQualified tqual, Objects *tiargs)
        {
            super(loc,
                  tqual.idents.dim ? cast(Identifier)tqual.idents[tqual.idents.dim - 1] : (cast(TypeIdentifier)tqual).ident,
                  tiargs ? tiargs : new Objects());
            this.ident = ident;
            this.tqual = tqual;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) struct ParameterList
    {
        Parameters* parameters;
        StorageClass stc;                   // storage class of ...
        VarArg varargs = VarArg.none;

        this(Parameters* parameters, VarArg varargs = VarArg.none, StorageClass stc = 0)
        {
            this.parameters = parameters;
            this.varargs = varargs;
            this.stc = stc;
        }
    }

    extern (C++) final class Parameter : ASTNode
    {
        StorageClass storageClass;
        Type type;
        Identifier ident;
        Expression defaultArg;
        UserAttributeDeclaration userAttribDecl; // user defined attributes

        extern (D) alias ForeachDg = int delegate(size_t idx, Parameter param);

        final extern (D) this(StorageClass storageClass, Type type, Identifier ident, Expression defaultArg, UserAttributeDeclaration userAttribDecl)
        {
            this.storageClass = storageClass;
            this.type = type;
            this.ident = ident;
            this.defaultArg = defaultArg;
            this.userAttribDecl = userAttribDecl;
        }

        static size_t dim(Parameters* parameters)
        {
           size_t nargs = 0;

            int dimDg(size_t n, Parameter p)
            {
                ++nargs;
                return 0;
            }

            _foreach(parameters, &dimDg);
            return nargs;
        }

        static Parameter getNth(Parameters* parameters, size_t nth, size_t* pn = null)
        {
            Parameter param;

            int getNthParamDg(size_t n, Parameter p)
            {
                if (n == nth)
                {
                    param = p;
                    return 1;
                }
                return 0;
            }

            int res = _foreach(parameters, &getNthParamDg);
            return res ? param : null;
        }

        extern (D) static int _foreach(Parameters* parameters, scope ForeachDg dg, size_t* pn = null)
        {
            assert(dg);
            if (!parameters)
                return 0;

            size_t n = pn ? *pn : 0; // take over index
            int result = 0;
            foreach (i; 0 .. parameters.dim)
            {
                Parameter p = (*parameters)[i];
                Type t = p.type.toBasetype();

                if (t.ty == Ttuple)
                {
                    TypeTuple tu = cast(TypeTuple)t;
                    result = _foreach(tu.arguments, dg, &n);
                }
                else
                    result = dg(n++, p);

                if (result)
                    break;
            }

            if (pn)
                *pn = n; // update index
            return result;
        }

        Parameter syntaxCopy()
        {
            return new Parameter(storageClass, type ? type.syntaxCopy() : null, ident, defaultArg ? defaultArg.syntaxCopy() : null, userAttribDecl ? cast(UserAttributeDeclaration) userAttribDecl.syntaxCopy(null) : null);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }

        static Parameters* arraySyntaxCopy(Parameters* parameters)
        {
            Parameters* params = null;
            if (parameters)
            {
                params = new Parameters();
                params.setDim(parameters.dim);
                for (size_t i = 0; i < params.dim; i++)
                    (*params)[i] = (*parameters)[i].syntaxCopy();
            }
            return params;
        }

    }

    enum STMT : ubyte
    {
        Error,
        Peel,
        Exp, DtorExp,
        Compile,
        Compound, CompoundDeclaration, CompoundAsm,
        UnrolledLoop,
        Scope,
        Forwarding,
        While,
        Do,
        For,
        Foreach,
        ForeachRange,
        If,
        Conditional,
        StaticForeach,
        Pragma,
        StaticAssert,
        Switch,
        Case,
        CaseRange,
        Default,
        GotoDefault,
        GotoCase,
        SwitchError,
        Return,
        Break,
        Continue,
        Synchronized,
        With,
        TryCatch,
        TryFinally,
        ScopeGuard,
        Throw,
        Debug,
        Goto,
        Label,
        Asm, InlineAsm, GccAsm,
        Import,
    }

    extern (C++) abstract class Statement : ASTNode
    {
        Loc loc;
        STMT stmt;

        final extern (D) this(const ref Loc loc, STMT stmt)
        {
            this.loc = loc;
            this.stmt = stmt;
        }

        nothrow pure @nogc
        inout(ExpStatement) isExpStatement() inout { return stmt == STMT.Exp ? cast(typeof(return))this : null; }

        nothrow pure @nogc
        inout(CompoundStatement) isCompoundStatement() inout { return stmt == STMT.Compound ? cast(typeof(return))this : null; }

        nothrow pure @nogc
        inout(ReturnStatement) isReturnStatement() inout { return stmt == STMT.Return ? cast(typeof(return))this : null; }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class ImportStatement : Statement
    {
        Dsymbols* imports;

        extern (D) this(const ref Loc loc, Dsymbols* imports)
        {
            super(loc, STMT.Import);
            this.imports = imports;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class ScopeStatement : Statement
    {
        Statement statement;
        Loc endloc;

        extern (D) this(const ref Loc loc, Statement s, Loc endloc)
        {
            super(loc, STMT.Scope);
            this.statement = s;
            this.endloc = endloc;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class ReturnStatement : Statement
    {
        Expression exp;

        extern (D) this(const ref Loc loc, Expression exp)
        {
            super(loc, STMT.Return);
            this.exp = exp;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class LabelStatement : Statement
    {
        Identifier ident;
        Statement statement;

        final extern (D) this(const ref Loc loc, Identifier ident, Statement statement)
        {
            super(loc, STMT.Label);
            this.ident = ident;
            this.statement = statement;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class StaticAssertStatement : Statement
    {
        StaticAssert sa;

        final extern (D) this(StaticAssert sa)
        {
            super(sa.loc, STMT.StaticAssert);
            this.sa = sa;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class CompileStatement : Statement
    {
        Expressions* exps;

        final extern (D) this(const ref Loc loc, Expressions* exps)
        {
            super(loc, STMT.Compile);
            this.exps = exps;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class WhileStatement : Statement
    {
        Expression condition;
        Statement _body;
        Loc endloc;

        extern (D) this(const ref Loc loc, Expression c, Statement b, Loc endloc)
        {
            super(loc, STMT.While);
            condition = c;
            _body = b;
            this.endloc = endloc;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class ForStatement : Statement
    {
        Statement _init;
        Expression condition;
        Expression increment;
        Statement _body;
        Loc endloc;

        extern (D) this(const ref Loc loc, Statement _init, Expression condition, Expression increment, Statement _body, Loc endloc)
        {
            super(loc, STMT.For);
            this._init = _init;
            this.condition = condition;
            this.increment = increment;
            this._body = _body;
            this.endloc = endloc;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class DoStatement : Statement
    {
        Statement _body;
        Expression condition;
        Loc endloc;

        extern (D) this(const ref Loc loc, Statement b, Expression c, Loc endloc)
        {
            super(loc, STMT.Do);
            _body = b;
            condition = c;
            this.endloc = endloc;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class ForeachRangeStatement : Statement
    {
        TOK op;                 // TOK.foreach_ or TOK.foreach_reverse_
        Parameter prm;          // loop index variable
        Expression lwr;
        Expression upr;
        Statement _body;
        Loc endloc;             // location of closing curly bracket


        extern (D) this(const ref Loc loc, TOK op, Parameter prm, Expression lwr, Expression upr, Statement _body, Loc endloc)
        {
            super(loc, STMT.ForeachRange);
            this.op = op;
            this.prm = prm;
            this.lwr = lwr;
            this.upr = upr;
            this._body = _body;
            this.endloc = endloc;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class ForeachStatement : Statement
    {
        TOK op;                     // TOK.foreach_ or TOK.foreach_reverse_
        Parameters* parameters;     // array of Parameter*'s
        Expression aggr;
        Statement _body;
        Loc endloc;                 // location of closing curly bracket

        extern (D) this(const ref Loc loc, TOK op, Parameters* parameters, Expression aggr, Statement _body, Loc endloc)
        {
            super(loc, STMT.Foreach);
            this.op = op;
            this.parameters = parameters;
            this.aggr = aggr;
            this._body = _body;
            this.endloc = endloc;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class IfStatement : Statement
    {
        Parameter prm;
        Expression condition;
        Statement ifbody;
        Statement elsebody;
        VarDeclaration match;   // for MatchExpression results
        Loc endloc;                 // location of closing curly bracket

        extern (D) this(const ref Loc loc, Parameter prm, Expression condition, Statement ifbody, Statement elsebody, Loc endloc)
        {
            super(loc, STMT.If);
            this.prm = prm;
            this.condition = condition;
            this.ifbody = ifbody;
            this.elsebody = elsebody;
            this.endloc = endloc;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class ScopeGuardStatement : Statement
    {
        TOK tok;
        Statement statement;

        extern (D) this(const ref Loc loc, TOK tok, Statement statement)
        {
            super(loc, STMT.ScopeGuard);
            this.tok = tok;
            this.statement = statement;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class ConditionalStatement : Statement
    {
        Condition condition;
        Statement ifbody;
        Statement elsebody;

        extern (D) this(const ref Loc loc, Condition condition, Statement ifbody, Statement elsebody)
        {
            super(loc, STMT.Conditional);
            this.condition = condition;
            this.ifbody = ifbody;
            this.elsebody = elsebody;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class StaticForeachStatement : Statement
    {
        StaticForeach sfe;

        extern (D) this(const ref Loc loc, StaticForeach sfe)
        {
            super(loc, STMT.StaticForeach);
            this.sfe = sfe;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class PragmaStatement : Statement
    {
        Identifier ident;
        Expressions* args;      // array of Expression's
        Statement _body;

        extern (D) this(const ref Loc loc, Identifier ident, Expressions* args, Statement _body)
        {
            super(loc, STMT.Pragma);
            this.ident = ident;
            this.args = args;
            this._body = _body;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class SwitchStatement : Statement
    {
        Expression condition;
        Statement _body;
        bool isFinal;

        extern (D) this(const ref Loc loc, Expression c, Statement b, bool isFinal)
        {
            super(loc, STMT.Switch);
            this.condition = c;
            this._body = b;
            this.isFinal = isFinal;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class CaseRangeStatement : Statement
    {
        Expression first;
        Expression last;
        Statement statement;

        extern (D) this(const ref Loc loc, Expression first, Expression last, Statement s)
        {
            super(loc, STMT.CaseRange);
            this.first = first;
            this.last = last;
            this.statement = s;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class CaseStatement : Statement
    {
        Expression exp;
        Statement statement;

        extern (D) this(const ref Loc loc, Expression exp, Statement s)
        {
            super(loc, STMT.Case);
            this.exp = exp;
            this.statement = s;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class DefaultStatement : Statement
    {
        Statement statement;

        extern (D) this(const ref Loc loc, Statement s)
        {
            super(loc, STMT.Default);
            this.statement = s;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class BreakStatement : Statement
    {
        Identifier ident;

        extern (D) this(const ref Loc loc, Identifier ident)
        {
            super(loc, STMT.Break);
            this.ident = ident;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class ContinueStatement : Statement
    {
        Identifier ident;

        extern (D) this(const ref Loc loc, Identifier ident)
        {
            super(loc, STMT.Continue);
            this.ident = ident;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class GotoDefaultStatement : Statement
    {
        extern (D) this(const ref Loc loc)
        {
            super(loc, STMT.GotoDefault);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class GotoCaseStatement : Statement
    {
        Expression exp;

        extern (D) this(const ref Loc loc, Expression exp)
        {
            super(loc, STMT.GotoCase);
            this.exp = exp;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class GotoStatement : Statement
    {
        Identifier ident;

        extern (D) this(const ref Loc loc, Identifier ident)
        {
            super(loc, STMT.Goto);
            this.ident = ident;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class SynchronizedStatement : Statement
    {
        Expression exp;
        Statement _body;

        extern (D) this(const ref Loc loc, Expression exp, Statement _body)
        {
            super(loc, STMT.Synchronized);
            this.exp = exp;
            this._body = _body;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class WithStatement : Statement
    {
        Expression exp;
        Statement _body;
        Loc endloc;

        extern (D) this(const ref Loc loc, Expression exp, Statement _body, Loc endloc)
        {
            super(loc, STMT.With);
            this.exp = exp;
            this._body = _body;
            this.endloc = endloc;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class TryCatchStatement : Statement
    {
        Statement _body;
        Catches* catches;

        extern (D) this(const ref Loc loc, Statement _body, Catches* catches)
        {
            super(loc, STMT.TryCatch);
            this._body = _body;
            this.catches = catches;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class TryFinallyStatement : Statement
    {
        Statement _body;
        Statement finalbody;

        extern (D) this(const ref Loc loc, Statement _body, Statement finalbody)
        {
            super(loc, STMT.TryFinally);
            this._body = _body;
            this.finalbody = finalbody;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class ThrowStatement : Statement
    {
        Expression exp;

        extern (D) this(const ref Loc loc, Expression exp)
        {
            super(loc, STMT.Throw);
            this.exp = exp;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) class AsmStatement : Statement
    {
        Token* tokens;

        extern (D) this(const ref Loc loc, Token* tokens)
        {
            super(loc, STMT.Asm);
            this.tokens = tokens;
        }

        extern (D) this(const ref Loc loc, Token* tokens, STMT stmt)
        {
            super(loc, stmt);
            this.tokens = tokens;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class InlineAsmStatement : AsmStatement
    {
        extern (D) this(const ref Loc loc, Token* tokens)
        {
            super(loc, tokens, STMT.InlineAsm);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class GccAsmStatement : AsmStatement
    {
        extern (D) this(const ref Loc loc, Token* tokens)
        {
            super(loc, tokens, STMT.GccAsm);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) class ExpStatement : Statement
    {
        Expression exp;

        final extern (D) this(const ref Loc loc, Expression exp)
        {
            super(loc, STMT.Exp);
            this.exp = exp;
        }
        final extern (D) this(const ref Loc loc, Dsymbol declaration)
        {
            super(loc, STMT.Exp);
            this.exp = new DeclarationExp(loc, declaration);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) class CompoundStatement : Statement
    {
        Statements* statements;

        final extern (D) this(const ref Loc loc, Statements* statements)
        {
            super(loc, STMT.Compound);
            this.statements = statements;
        }

        final extern (D) this(const ref Loc loc, Statements* statements, STMT stmt)
        {
            super(loc, stmt);
            this.statements = statements;
        }

        final extern (D) this(const ref Loc loc, Statement[] sts...)
        {
            super(loc, STMT.Compound);
            statements = new Statements();
            statements.reserve(sts.length);
            foreach (s; sts)
                statements.push(s);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class CompoundDeclarationStatement : CompoundStatement
    {
        final extern (D) this(const ref Loc loc, Statements* statements)
        {
            super(loc, statements, STMT.CompoundDeclaration);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class CompoundAsmStatement : CompoundStatement
    {
        StorageClass stc;

        final extern (D) this(const ref Loc loc, Statements* s, StorageClass stc)
        {
            super(loc, s, STMT.CompoundAsm);
            this.stc = stc;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class Catch : RootObject
    {
        Loc loc;
        Type type;
        Identifier ident;
        Statement handler;

        extern (D) this(const ref Loc loc, Type t, Identifier id, Statement handler)
        {
            this.loc = loc;
            this.type = t;
            this.ident = id;
            this.handler = handler;
        }
    }

    extern (C++) abstract class Type : ASTNode
    {
        TY ty;
        MOD mod;
        char* deco;

        extern (C++) __gshared Type tvoid;
        extern (C++) __gshared Type tint8;
        extern (C++) __gshared Type tuns8;
        extern (C++) __gshared Type tint16;
        extern (C++) __gshared Type tuns16;
        extern (C++) __gshared Type tint32;
        extern (C++) __gshared Type tuns32;
        extern (C++) __gshared Type tint64;
        extern (C++) __gshared Type tuns64;
        extern (C++) __gshared Type tint128;
        extern (C++) __gshared Type tuns128;
        extern (C++) __gshared Type tfloat32;
        extern (C++) __gshared Type tfloat64;
        extern (C++) __gshared Type tfloat80;
        extern (C++) __gshared Type timaginary32;
        extern (C++) __gshared Type timaginary64;
        extern (C++) __gshared Type timaginary80;
        extern (C++) __gshared Type tcomplex32;
        extern (C++) __gshared Type tcomplex64;
        extern (C++) __gshared Type tcomplex80;
        extern (C++) __gshared Type tbool;
        extern (C++) __gshared Type tchar;
        extern (C++) __gshared Type twchar;
        extern (C++) __gshared Type tdchar;

        extern (C++) __gshared Type[TMAX] basic;

        extern (C++) __gshared Type tshiftcnt;
        extern (C++) __gshared Type tvoidptr;    // void*
        extern (C++) __gshared Type tstring;     // immutable(char)[]
        extern (C++) __gshared Type twstring;    // immutable(wchar)[]
        extern (C++) __gshared Type tdstring;    // immutable(dchar)[]
        extern (C++) __gshared Type terror;      // for error recovery
        extern (C++) __gshared Type tnull;       // for null type

        extern (C++) __gshared Type tsize_t;     // matches size_t alias
        extern (C++) __gshared Type tptrdiff_t;  // matches ptrdiff_t alias
        extern (C++) __gshared Type thash_t;     // matches hash_t alias



        extern (C++) __gshared ClassDeclaration dtypeinfo;
        extern (C++) __gshared ClassDeclaration typeinfoclass;
        extern (C++) __gshared ClassDeclaration typeinfointerface;
        extern (C++) __gshared ClassDeclaration typeinfostruct;
        extern (C++) __gshared ClassDeclaration typeinfopointer;
        extern (C++) __gshared ClassDeclaration typeinfoarray;
        extern (C++) __gshared ClassDeclaration typeinfostaticarray;
        extern (C++) __gshared ClassDeclaration typeinfoassociativearray;
        extern (C++) __gshared ClassDeclaration typeinfovector;
        extern (C++) __gshared ClassDeclaration typeinfoenum;
        extern (C++) __gshared ClassDeclaration typeinfofunction;
        extern (C++) __gshared ClassDeclaration typeinfodelegate;
        extern (C++) __gshared ClassDeclaration typeinfotypelist;
        extern (C++) __gshared ClassDeclaration typeinfoconst;
        extern (C++) __gshared ClassDeclaration typeinfoinvariant;
        extern (C++) __gshared ClassDeclaration typeinfoshared;
        extern (C++) __gshared ClassDeclaration typeinfowild;
        extern (C++) __gshared StringTable!Type stringtable;
        extern (C++) __gshared ubyte[TMAX] sizeTy = ()
            {
                ubyte[TMAX] sizeTy = __traits(classInstanceSize, TypeBasic);
                sizeTy[Tsarray] = __traits(classInstanceSize, TypeSArray);
                sizeTy[Tarray] = __traits(classInstanceSize, TypeDArray);
                sizeTy[Taarray] = __traits(classInstanceSize, TypeAArray);
                sizeTy[Tpointer] = __traits(classInstanceSize, TypePointer);
                sizeTy[Treference] = __traits(classInstanceSize, TypeReference);
                sizeTy[Tfunction] = __traits(classInstanceSize, TypeFunction);
                sizeTy[Tdelegate] = __traits(classInstanceSize, TypeDelegate);
                sizeTy[Tident] = __traits(classInstanceSize, TypeIdentifier);
                sizeTy[Tinstance] = __traits(classInstanceSize, TypeInstance);
                sizeTy[Ttypeof] = __traits(classInstanceSize, TypeTypeof);
                sizeTy[Tenum] = __traits(classInstanceSize, TypeEnum);
                sizeTy[Tstruct] = __traits(classInstanceSize, TypeStruct);
                sizeTy[Tclass] = __traits(classInstanceSize, TypeClass);
                sizeTy[Ttuple] = __traits(classInstanceSize, TypeTuple);
                sizeTy[Tslice] = __traits(classInstanceSize, TypeSlice);
                sizeTy[Treturn] = __traits(classInstanceSize, TypeReturn);
                sizeTy[Terror] = __traits(classInstanceSize, TypeError);
                sizeTy[Tnull] = __traits(classInstanceSize, TypeNull);
                sizeTy[Tvector] = __traits(classInstanceSize, TypeVector);
                sizeTy[Tmixin] = __traits(classInstanceSize, TypeMixin);
                return sizeTy;
            }();

        static struct Mcache
        {
            Type cto;       // MODFlags.const_
            Type ito;       // MODFlags.immutable_
            Type sto;       // MODFlags.shared_
            Type scto;      // MODFlags.shared_ | MODFlags.const_
            Type wto;       // MODFlags.wild
            Type wcto;      // MODFlags.wildconst
            Type swto;      // MODFlags.shared_ | MODFlags.wild
            Type swcto;     // MODFlags.shared_ | MODFlags.wildconst
        }
        private Mcache* mcache;

        Type pto;
        Type rto;
        Type arrayof;

        // These members are probably used in semnatic analysis
        //TypeInfoDeclaration vtinfo;
        //type* ctype;

        final extern (D) this(TY ty)
        {
            this.ty = ty;
        }

        override const(char)* toChars() const
        {
            return "type";
        }

        static void _init()
        {
            stringtable._init(14_000);

            // Set basic types
            __gshared TY* basetab =
            [
                Tvoid,
                Tint8,
                Tuns8,
                Tint16,
                Tuns16,
                Tint32,
                Tuns32,
                Tint64,
                Tuns64,
                Tint128,
                Tuns128,
                Tfloat32,
                Tfloat64,
                Tfloat80,
                Timaginary32,
                Timaginary64,
                Timaginary80,
                Tcomplex32,
                Tcomplex64,
                Tcomplex80,
                Tbool,
                Tchar,
                Twchar,
                Tdchar,
                Terror
            ];

            for (size_t i = 0; basetab[i] != Terror; i++)
            {
                Type t = new TypeBasic(basetab[i]);
                t = t.merge();
                basic[basetab[i]] = t;
            }
            basic[Terror] = new TypeError();

            tvoid = basic[Tvoid];
            tint8 = basic[Tint8];
            tuns8 = basic[Tuns8];
            tint16 = basic[Tint16];
            tuns16 = basic[Tuns16];
            tint32 = basic[Tint32];
            tuns32 = basic[Tuns32];
            tint64 = basic[Tint64];
            tuns64 = basic[Tuns64];
            tint128 = basic[Tint128];
            tuns128 = basic[Tuns128];
            tfloat32 = basic[Tfloat32];
            tfloat64 = basic[Tfloat64];
            tfloat80 = basic[Tfloat80];

            timaginary32 = basic[Timaginary32];
            timaginary64 = basic[Timaginary64];
            timaginary80 = basic[Timaginary80];

            tcomplex32 = basic[Tcomplex32];
            tcomplex64 = basic[Tcomplex64];
            tcomplex80 = basic[Tcomplex80];

            tbool = basic[Tbool];
            tchar = basic[Tchar];
            twchar = basic[Twchar];
            tdchar = basic[Tdchar];

            tshiftcnt = tint32;
            terror = basic[Terror];
            tnull = new TypeNull();
            tnull.deco = tnull.merge().deco;

            tvoidptr = tvoid.pointerTo();
            tstring = tchar.immutableOf().arrayOf();
            twstring = twchar.immutableOf().arrayOf();
            tdstring = tdchar.immutableOf().arrayOf();

            const isLP64 = global.params.isLP64;

            tsize_t    = basic[isLP64 ? Tuns64 : Tuns32];
            tptrdiff_t = basic[isLP64 ? Tint64 : Tint32];
            thash_t = tsize_t;
        }

        extern (D)
        final Mcache* getMcache()
        {
            if (!mcache)
                mcache = cast(Mcache*) mem.xcalloc(Mcache.sizeof, 1);
            return mcache;
        }

        final Type pointerTo()
        {
            if (ty == Terror)
                return this;
            if (!pto)
            {
                Type t = new TypePointer(this);
                if (ty == Tfunction)
                {
                    t.deco = t.merge().deco;
                    pto = t;
                }
                else
                    pto = t.merge();
            }
            return pto;
        }

        final Type arrayOf()
        {
            if (ty == Terror)
                return this;
            if (!arrayof)
            {
                Type t = new TypeDArray(this);
                arrayof = t.merge();
            }
            return arrayof;
        }

        final bool isImmutable() const
        {
            return (mod & MODFlags.immutable_) != 0;
        }

        final Type nullAttributes()
        {
            uint sz = sizeTy[ty];
            Type t = cast(Type)mem.xmalloc(sz);
            memcpy(cast(void*)t, cast(void*)this, sz);
            // t.mod = NULL;  // leave mod unchanged
            t.deco = null;
            t.arrayof = null;
            t.pto = null;
            t.rto = null;
            t.mcache = null;
            //t.vtinfo = null; these aren't used in parsing
            //t.ctype = null;
            if (t.ty == Tstruct)
                (cast(TypeStruct)t).att = AliasThisRec.fwdref;
            if (t.ty == Tclass)
                (cast(TypeClass)t).att = AliasThisRec.fwdref;
            return t;
        }

        Type makeConst()
        {
            if (mcache && mcache.cto)
                return mcache.cto;
            Type t = this.nullAttributes();
            t.mod = MODFlags.const_;
            return t;
        }

        Type makeWildConst()
        {
            if (mcache && mcache.wcto)
                return mcache.wcto;
            Type t = this.nullAttributes();
            t.mod = MODFlags.wildconst;
            return t;
        }

        Type makeShared()
        {
            if (mcache && mcache.sto)
                return mcache.sto;
            Type t = this.nullAttributes();
            t.mod = MODFlags.shared_;
            return t;
        }

        Type makeSharedConst()
        {
            if (mcache && mcache.scto)
                return mcache.scto;
            Type t = this.nullAttributes();
            t.mod = MODFlags.shared_ | MODFlags.const_;
            return t;
        }

        Type makeImmutable()
        {
            if (mcache && mcache.ito)
                return mcache.ito;
            Type t = this.nullAttributes();
            t.mod = MODFlags.immutable_;
            return t;
        }

        Type makeWild()
        {
            if (mcache && mcache.wto)
                return mcache.wto;
            Type t = this.nullAttributes();
            t.mod = MODFlags.wild;
            return t;
        }

        Type makeSharedWildConst()
        {
            if (mcache && mcache.swcto)
                return mcache.swcto;
            Type t = this.nullAttributes();
            t.mod = MODFlags.shared_ | MODFlags.wildconst;
            return t;
        }

        Type makeSharedWild()
        {
            if (mcache && mcache.swto)
                return mcache.swto;
            Type t = this.nullAttributes();
            t.mod = MODFlags.shared_ | MODFlags.wild;
            return t;
        }

        // Truncated
        final Type merge()
        {
            if (ty == Terror)
                return this;
            if (ty == Ttypeof)
                return this;
            if (ty == Tident)
                return this;
            if (ty == Tinstance)
                return this;
            if (ty == Taarray && !(cast(TypeAArray)this).index.merge().deco)
                return this;
            if (ty != Tenum && nextOf() && !nextOf().deco)
                return this;

            // if (!deco) - code missing

            Type t = this;
            assert(t);
            return t;
        }

        final Type addSTC(StorageClass stc)
        {
            Type t = this;
            if (t.isImmutable())
            {
            }
            else if (stc & STC.immutable_)
            {
                t = t.makeImmutable();
            }
            else
            {
                if ((stc & STC.shared_) && !t.isShared())
                {
                    if (t.isWild())
                    {
                        if (t.isConst())
                            t = t.makeSharedWildConst();
                        else
                            t = t.makeSharedWild();
                    }
                    else
                    {
                        if (t.isConst())
                            t = t.makeSharedConst();
                        else
                            t = t.makeShared();
                    }
                }
                if ((stc & STC.const_) && !t.isConst())
                {
                    if (t.isShared())
                    {
                        if (t.isWild())
                            t = t.makeSharedWildConst();
                        else
                            t = t.makeSharedConst();
                    }
                    else
                    {
                        if (t.isWild())
                            t = t.makeWildConst();
                        else
                            t = t.makeConst();
                    }
                }
                if ((stc & STC.wild) && !t.isWild())
                {
                    if (t.isShared())
                    {
                        if (t.isConst())
                            t = t.makeSharedWildConst();
                        else
                            t = t.makeSharedWild();
                    }
                    else
                    {
                        if (t.isConst())
                            t = t.makeWildConst();
                        else
                            t = t.makeWild();
                    }
                }
            }
            return t;
        }

        Expression toExpression()
        {
            return null;
        }

        Type syntaxCopy()
        {
            return null;
        }

        final Type sharedWildConstOf()
        {
            if (mod == (MODFlags.shared_ | MODFlags.wildconst))
                return this;
            if (mcache.swcto)
            {
                assert(mcache.swcto.mod == (MODFlags.shared_ | MODFlags.wildconst));
                return mcache.swcto;
            }
            Type t = makeSharedWildConst();
            t = t.merge();
            t.fixTo(this);
            return t;
        }

        final Type sharedConstOf()
        {
            if (mod == (MODFlags.shared_ | MODFlags.const_))
                return this;
            if (mcache.scto)
            {
                assert(mcache.scto.mod == (MODFlags.shared_ | MODFlags.const_));
                return mcache.scto;
            }
            Type t = makeSharedConst();
            t = t.merge();
            t.fixTo(this);
            return t;
        }

        final Type wildConstOf()
        {
            if (mod == MODFlags.wildconst)
                return this;
            if (mcache && mcache.wcto)
            {
                assert(mcache.wcto.mod == MODFlags.wildconst);
                return mcache.wcto;
            }
            Type t = makeWildConst();
            t = t.merge();
            t.fixTo(this);
            return t;
        }

        final Type constOf()
        {
            if (mod == MODFlags.const_)
                return this;
            if (mcache && mcache.cto)
            {
                assert(mcache.cto.mod == MODFlags.const_);
                return mcache.cto;
            }
            Type t = makeConst();
            t = t.merge();
            t.fixTo(this);
            return t;
        }

        final Type sharedWildOf()
        {
            if (mod == (MODFlags.shared_ | MODFlags.wild))
                return this;
            if (mcache && mcache.swto)
            {
                assert(mcache.swto.mod == (MODFlags.shared_ | MODFlags.wild));
                return mcache.swto;
            }
            Type t = makeSharedWild();
            t = t.merge();
            t.fixTo(this);
            return t;
        }

        final Type wildOf()
        {
            if (mod == MODFlags.wild)
                return this;
            if (mcache && mcache.wto)
            {
                assert(mcache.wto.mod == MODFlags.wild);
                return mcache.wto;
            }
            Type t = makeWild();
            t = t.merge();
            t.fixTo(this);
            return t;
        }

        final Type sharedOf()
        {
            if (mod == MODFlags.shared_)
                return this;
            if (mcache && mcache.sto)
            {
                assert(mcache.sto.mod == MODFlags.shared_);
                return mcache.sto;
            }
            Type t = makeShared();
            t = t.merge();
            t.fixTo(this);
            return t;
        }

        final Type immutableOf()
        {
            if (isImmutable())
                return this;
            if (mcache && mcache.ito)
            {
                assert(mcache.ito.isImmutable());
                return mcache.ito;
            }
            Type t = makeImmutable();
            t = t.merge();
            t.fixTo(this);
            return t;
        }

        final void fixTo(Type t)
        {
            Type mto = null;
            Type tn = nextOf();
            if (!tn || ty != Tsarray && tn.mod == t.nextOf().mod)
            {
                switch (t.mod)
                {
                case 0:
                    mto = t;
                    break;

                case MODFlags.const_:
                    getMcache();
                    mcache.cto = t;
                    break;

                case MODFlags.wild:
                    getMcache();
                    mcache.wto = t;
                    break;

                case MODFlags.wildconst:
                    getMcache();
                    mcache.wcto = t;
                    break;

                case MODFlags.shared_:
                    getMcache();
                    mcache.sto = t;
                    break;

                case MODFlags.shared_ | MODFlags.const_:
                    getMcache();
                    mcache.scto = t;
                    break;

                case MODFlags.shared_ | MODFlags.wild:
                    getMcache();
                    mcache.swto = t;
                    break;

                case MODFlags.shared_ | MODFlags.wildconst:
                    getMcache();
                    mcache.swcto = t;
                    break;

                case MODFlags.immutable_:
                    getMcache();
                    mcache.ito = t;
                    break;

                default:
                    break;
                }
            }
            assert(mod != t.mod);

            if (mod)
            {
                getMcache();
                t.getMcache();
            }
            switch (mod)
            {
            case 0:
                break;

            case MODFlags.const_:
                mcache.cto = mto;
                t.mcache.cto = this;
                break;

            case MODFlags.wild:
                mcache.wto = mto;
                t.mcache.wto = this;
                break;

            case MODFlags.wildconst:
                mcache.wcto = mto;
                t.mcache.wcto = this;
                break;

            case MODFlags.shared_:
                mcache.sto = mto;
                t.mcache.sto = this;
                break;

            case MODFlags.shared_ | MODFlags.const_:
                mcache.scto = mto;
                t.mcache.scto = this;
                break;

            case MODFlags.shared_ | MODFlags.wild:
                mcache.swto = mto;
                t.mcache.swto = this;
                break;

            case MODFlags.shared_ | MODFlags.wildconst:
                mcache.swcto = mto;
                t.mcache.swcto = this;
                break;

            case MODFlags.immutable_:
                t.mcache.ito = this;
                if (t.mcache.cto)
                    t.mcache.cto.getMcache().ito = this;
                if (t.mcache.sto)
                    t.mcache.sto.getMcache().ito = this;
                if (t.mcache.scto)
                    t.mcache.scto.getMcache().ito = this;
                if (t.mcache.wto)
                    t.mcache.wto.getMcache().ito = this;
                if (t.mcache.wcto)
                    t.mcache.wcto.getMcache().ito = this;
                if (t.mcache.swto)
                    t.mcache.swto.getMcache().ito = this;
                if (t.mcache.swcto)
                    t.mcache.swcto.getMcache().ito = this;
                break;

            default:
                assert(0);
            }
        }

        final Type addMod(MOD mod)
        {
            Type t = this;
            if (!t.isImmutable())
            {
                switch (mod)
                {
                case 0:
                    break;

                case MODFlags.const_:
                    if (isShared())
                    {
                        if (isWild())
                            t = sharedWildConstOf();
                        else
                            t = sharedConstOf();
                    }
                    else
                    {
                        if (isWild())
                            t = wildConstOf();
                        else
                            t = constOf();
                    }
                    break;

                case MODFlags.wild:
                    if (isShared())
                    {
                        if (isConst())
                            t = sharedWildConstOf();
                        else
                            t = sharedWildOf();
                    }
                    else
                    {
                        if (isConst())
                            t = wildConstOf();
                        else
                            t = wildOf();
                    }
                    break;

                case MODFlags.wildconst:
                    if (isShared())
                        t = sharedWildConstOf();
                    else
                        t = wildConstOf();
                    break;

                case MODFlags.shared_:
                    if (isWild())
                    {
                        if (isConst())
                            t = sharedWildConstOf();
                        else
                            t = sharedWildOf();
                    }
                    else
                    {
                        if (isConst())
                            t = sharedConstOf();
                        else
                            t = sharedOf();
                    }
                    break;

                case MODFlags.shared_ | MODFlags.const_:
                    if (isWild())
                        t = sharedWildConstOf();
                    else
                        t = sharedConstOf();
                    break;

                case MODFlags.shared_ | MODFlags.wild:
                    if (isConst())
                        t = sharedWildConstOf();
                    else
                        t = sharedWildOf();
                    break;

                case MODFlags.shared_ | MODFlags.wildconst:
                    t = sharedWildConstOf();
                    break;

                case MODFlags.immutable_:
                    t = immutableOf();
                    break;

                default:
                    assert(0);
                }
            }
            return t;
        }

        // TypeEnum overrides this method
        Type nextOf()
        {
            return null;
        }

        // TypeBasic, TypeVector, TypePointer, TypeEnum override this method
        bool isscalar()
        {
            return false;
        }

        final bool isConst() const
        {
            return (mod & MODFlags.const_) != 0;
        }

        final bool isWild() const
        {
            return (mod & MODFlags.wild) != 0;
        }

        final bool isShared() const
        {
            return (mod & MODFlags.shared_) != 0;
        }

        Type toBasetype()
        {
            return this;
        }

        // TypeIdentifier, TypeInstance, TypeTypeOf, TypeReturn, TypeStruct, TypeEnum, TypeClass override this method
        Dsymbol toDsymbol(Scope* sc)
        {
            return null;
        }

        final pure inout nothrow @nogc
        {
            inout(TypeError)      isTypeError()      { return ty == Terror     ? cast(typeof(return))this : null; }
            inout(TypeVector)     isTypeVector()     { return ty == Tvector    ? cast(typeof(return))this : null; }
            inout(TypeSArray)     isTypeSArray()     { return ty == Tsarray    ? cast(typeof(return))this : null; }
            inout(TypeDArray)     isTypeDArray()     { return ty == Tarray     ? cast(typeof(return))this : null; }
            inout(TypeAArray)     isTypeAArray()     { return ty == Taarray    ? cast(typeof(return))this : null; }
            inout(TypePointer)    isTypePointer()    { return ty == Tpointer   ? cast(typeof(return))this : null; }
            inout(TypeReference)  isTypeReference()  { return ty == Treference ? cast(typeof(return))this : null; }
            inout(TypeFunction)   isTypeFunction()   { return ty == Tfunction  ? cast(typeof(return))this : null; }
            inout(TypeDelegate)   isTypeDelegate()   { return ty == Tdelegate  ? cast(typeof(return))this : null; }
            inout(TypeIdentifier) isTypeIdentifier() { return ty == Tident     ? cast(typeof(return))this : null; }
            inout(TypeInstance)   isTypeInstance()   { return ty == Tinstance  ? cast(typeof(return))this : null; }
            inout(TypeTypeof)     isTypeTypeof()     { return ty == Ttypeof    ? cast(typeof(return))this : null; }
            inout(TypeReturn)     isTypeReturn()     { return ty == Treturn    ? cast(typeof(return))this : null; }
            inout(TypeStruct)     isTypeStruct()     { return ty == Tstruct    ? cast(typeof(return))this : null; }
            inout(TypeEnum)       isTypeEnum()       { return ty == Tenum      ? cast(typeof(return))this : null; }
            inout(TypeClass)      isTypeClass()      { return ty == Tclass     ? cast(typeof(return))this : null; }
            inout(TypeTuple)      isTypeTuple()      { return ty == Ttuple     ? cast(typeof(return))this : null; }
            inout(TypeSlice)      isTypeSlice()      { return ty == Tslice     ? cast(typeof(return))this : null; }
            inout(TypeNull)       isTypeNull()       { return ty == Tnull      ? cast(typeof(return))this : null; }
            inout(TypeMixin)      isTypeMixin()      { return ty == Tmixin     ? cast(typeof(return))this : null; }
            inout(TypeTraits)     isTypeTraits()     { return ty == Ttraits    ? cast(typeof(return))this : null; }
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    // missing functionality in constructor, but that's ok
    // since the class is needed only for its size; need to add all method definitions
    extern (C++) final class TypeBasic : Type
    {
        const(char)* dstring;
        uint flags;

        extern (D) this(TY ty)
        {
            super(ty);
            const(char)* d;
            uint flags = 0;
            switch (ty)
            {
            case Tvoid:
                d = Token.toChars(TOK.void_);
                break;

            case Tint8:
                d = Token.toChars(TOK.int8);
                flags |= TFlags.integral;
                break;

            case Tuns8:
                d = Token.toChars(TOK.uns8);
                flags |= TFlags.integral | TFlags.unsigned;
                break;

            case Tint16:
                d = Token.toChars(TOK.int16);
                flags |= TFlags.integral;
                break;

            case Tuns16:
                d = Token.toChars(TOK.uns16);
                flags |= TFlags.integral | TFlags.unsigned;
                break;

            case Tint32:
                d = Token.toChars(TOK.int32);
                flags |= TFlags.integral;
                break;

            case Tuns32:
                d = Token.toChars(TOK.uns32);
                flags |= TFlags.integral | TFlags.unsigned;
                break;

            case Tfloat32:
                d = Token.toChars(TOK.float32);
                flags |= TFlags.floating | TFlags.real_;
                break;

            case Tint64:
                d = Token.toChars(TOK.int64);
                flags |= TFlags.integral;
                break;

            case Tuns64:
                d = Token.toChars(TOK.uns64);
                flags |= TFlags.integral | TFlags.unsigned;
                break;

            case Tint128:
                d = Token.toChars(TOK.int128);
                flags |= TFlags.integral;
                break;

            case Tuns128:
                d = Token.toChars(TOK.uns128);
                flags |= TFlags.integral | TFlags.unsigned;
                break;

            case Tfloat64:
                d = Token.toChars(TOK.float64);
                flags |= TFlags.floating | TFlags.real_;
                break;

            case Tfloat80:
                d = Token.toChars(TOK.float80);
                flags |= TFlags.floating | TFlags.real_;
                break;

            case Timaginary32:
                d = Token.toChars(TOK.imaginary32);
                flags |= TFlags.floating | TFlags.imaginary;
                break;

            case Timaginary64:
                d = Token.toChars(TOK.imaginary64);
                flags |= TFlags.floating | TFlags.imaginary;
                break;

            case Timaginary80:
                d = Token.toChars(TOK.imaginary80);
                flags |= TFlags.floating | TFlags.imaginary;
                break;

            case Tcomplex32:
                d = Token.toChars(TOK.complex32);
                flags |= TFlags.floating | TFlags.complex;
                break;

            case Tcomplex64:
                d = Token.toChars(TOK.complex64);
                flags |= TFlags.floating | TFlags.complex;
                break;

            case Tcomplex80:
                d = Token.toChars(TOK.complex80);
                flags |= TFlags.floating | TFlags.complex;
                break;

            case Tbool:
                d = "bool";
                flags |= TFlags.integral | TFlags.unsigned;
                break;

            case Tchar:
                d = Token.toChars(TOK.char_);
                flags |= TFlags.integral | TFlags.unsigned;
                break;

            case Twchar:
                d = Token.toChars(TOK.wchar_);
                flags |= TFlags.integral | TFlags.unsigned;
                break;

            case Tdchar:
                d = Token.toChars(TOK.dchar_);
                flags |= TFlags.integral | TFlags.unsigned;
                break;

            default:
                assert(0);
            }
            this.dstring = d;
            this.flags = flags;
            merge();
        }

        override bool isscalar() const
        {
            return (flags & (TFlags.integral | TFlags.floating)) != 0;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class TypeError : Type
    {
        extern (D) this()
        {
            super(Terror);
        }

        override Type syntaxCopy()
        {
            return this;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class TypeNull : Type
    {
        extern (D) this()
        {
            super(Tnull);
        }

        override Type syntaxCopy()
        {
            // No semantic analysis done, no need to copy
            return this;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) class TypeVector : Type
    {
        Type basetype;

        extern (D) this(Type basetype)
        {
            super(Tvector);
            this.basetype = basetype;
        }

        override Type syntaxCopy()
        {
            return new TypeVector(basetype.syntaxCopy());
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class TypeEnum : Type
    {
        EnumDeclaration sym;

        extern (D) this(EnumDeclaration sym)
        {
            super(Tenum);
            this.sym = sym;
        }

        override Type syntaxCopy()
        {
            return this;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class TypeTuple : Type
    {
        Parameters* arguments;

        extern (D) this(Parameters* arguments)
        {
            super(Ttuple);
            this.arguments = arguments;
        }

        extern (D) this(Expressions* exps)
        {
            super(Ttuple);
            auto arguments = new Parameters();
            if (exps)
            {
                arguments.setDim(exps.dim);
                for (size_t i = 0; i < exps.dim; i++)
                {
                    Expression e = (*exps)[i];
                    if (e.type.ty == Ttuple)
                        e.error("cannot form tuple of tuples");
                    auto arg = new Parameter(STC.undefined_, e.type, null, null, null);
                    (*arguments)[i] = arg;
                }
            }
            this.arguments = arguments;
        }

        override Type syntaxCopy()
        {
            Parameters* args = Parameter.arraySyntaxCopy(arguments);
            Type t = new TypeTuple(args);
            t.mod = mod;
            return t;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class TypeClass : Type
    {
        ClassDeclaration sym;
        AliasThisRec att = AliasThisRec.fwdref;

        extern (D) this (ClassDeclaration sym)
        {
            super(Tclass);
            this.sym = sym;
        }

        override Type syntaxCopy()
        {
            return this;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class TypeStruct : Type
    {
        StructDeclaration sym;
        AliasThisRec att = AliasThisRec.fwdref;
        bool inuse = false;

        extern (D) this(StructDeclaration sym)
        {
            super(Tstruct);
            this.sym = sym;
        }

        override Type syntaxCopy()
        {
            return this;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class TypeReference : TypeNext
    {
        extern (D) this(Type t)
        {
            super(Treference, t);
            // BUG: what about references to static arrays?
        }

        override Type syntaxCopy()
        {
            Type t = next.syntaxCopy();
            if (t == next)
                t = this;
            else
            {
                t = new TypeReference(t);
                t.mod = mod;
            }
            return t;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) abstract class TypeNext : Type
    {
        Type next;

        final extern (D) this(TY ty, Type next)
        {
            super(ty);
            this.next = next;
        }

        override final Type nextOf()
        {
            return next;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class TypeSlice : TypeNext
    {
        Expression lwr;
        Expression upr;

        extern (D) this(Type next, Expression lwr, Expression upr)
        {
            super(Tslice, next);
            this.lwr = lwr;
            this.upr = upr;
        }

        override Type syntaxCopy()
        {
            Type t = new TypeSlice(next.syntaxCopy(), lwr.syntaxCopy(), upr.syntaxCopy());
            t.mod = mod;
            return t;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) class TypeDelegate : TypeNext
    {
        extern (D) this(Type t)
        {
            super(Tfunction, t);
            ty = Tdelegate;
        }

        override Type syntaxCopy()
        {
            Type t = next.syntaxCopy();
            if (t == next)
                t = this;
            else
            {
                t = new TypeDelegate(t);
                t.mod = mod;
            }
            return t;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class TypePointer : TypeNext
    {
        extern (D) this(Type t)
        {
            super(Tpointer, t);
        }

        override Type syntaxCopy()
        {
            Type t = next.syntaxCopy();
            if (t == next)
                t = this;
            else
            {
                t = new TypePointer(t);
                t.mod = mod;
            }
            return t;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) class TypeFunction : TypeNext
    {
        // .next is the return type

        ParameterList parameterList;   // function parameters

        private enum FunctionFlag : uint
        {
            none            = 0,
            isnothrow       = 0x0001, // nothrow
            isnogc          = 0x0002, // is @nogc
            isproperty      = 0x0004, // can be called without parentheses
            isref           = 0x0008, // returns a reference
            isreturn        = 0x0010, // 'this' is returned by ref
            isscope         = 0x0020, // 'this' is scope
            isreturninferred= 0x0040, // 'this' is return from inference
            isscopeinferred = 0x0080, // 'this' is scope from inference
            islive          = 0x0100, // is @live
            incomplete      = 0x0200, // return type or default arguments removed
            inoutParam      = 0x0400, // inout on the parameters
            inoutQual       = 0x0800, // inout on the qualifier
        }

        LINK linkage;               // calling convention
        FunctionFlag funcFlags;
        TRUST trust;                // level of trust
        PURE purity = PURE.impure;
        byte inuse;
        Expressions* fargs;         // function arguments

        extern (D) this(ParameterList pl, Type treturn, LINK linkage, StorageClass stc = 0)
        {
            super(Tfunction, treturn);
            assert(VarArg.none <= pl.varargs && pl.varargs <= VarArg.typesafe);
            this.parameterList = pl;
            this.linkage = linkage;

            if (stc & STC.pure_)
                this.purity = PURE.fwdref;
            if (stc & STC.nothrow_)
                this.isnothrow = true;
            if (stc & STC.nogc)
                this.isnogc = true;
            if (stc & STC.property)
                this.isproperty = true;
            if (stc & STC.live)
                this.islive = true;

            if (stc & STC.ref_)
                this.isref = true;
            if (stc & STC.return_)
                this.isreturn = true;
            if (stc & STC.scope_)
                this.isScopeQual = true;

            this.trust = TRUST.default_;
            if (stc & STC.safe)
                this.trust = TRUST.safe;
            if (stc & STC.system)
                this.trust = TRUST.system;
            if (stc & STC.trusted)
                this.trust = TRUST.trusted;
        }

        override Type syntaxCopy()
        {
            Type treturn = next ? next.syntaxCopy() : null;
            Parameters* params = Parameter.arraySyntaxCopy(parameterList.parameters);
            auto t = new TypeFunction(ParameterList(params, parameterList.varargs), treturn, linkage);
            t.mod = mod;
            t.isnothrow = isnothrow;
            t.isnogc = isnogc;
            t.purity = purity;
            t.isproperty = isproperty;
            t.isref = isref;
            t.isreturn = isreturn;
            t.isScopeQual = isScopeQual;
            t.isreturninferred = isreturninferred;
            t.isscopeinferred = isscopeinferred;
            t.isInOutParam = isInOutParam;
            t.isInOutQual = isInOutQual;
            t.trust = trust;
            t.fargs = fargs;
            return t;
        }

        /// set or get if the function has the `nothrow` attribute
        bool isnothrow() const pure nothrow @safe @nogc
        {
            return (funcFlags & FunctionFlag.isnothrow) != 0;
        }
        /// ditto
        void isnothrow(bool v) pure nothrow @safe @nogc
        {
            if (v) funcFlags |= FunctionFlag.isnothrow;
            else funcFlags &= ~FunctionFlag.isnothrow;
        }

        /// set or get if the function has the `@nogc` attribute
        bool isnogc() const pure nothrow @safe @nogc
        {
            return (funcFlags & FunctionFlag.isnogc) != 0;
        }
        /// ditto
        void isnogc(bool v) pure nothrow @safe @nogc
        {
            if (v) funcFlags |= FunctionFlag.isnogc;
            else funcFlags &= ~FunctionFlag.isnogc;
        }

        /// set or get if the function has the `@property` attribute
        bool isproperty() const pure nothrow @safe @nogc
        {
            return (funcFlags & FunctionFlag.isproperty) != 0;
        }
        /// ditto
        void isproperty(bool v) pure nothrow @safe @nogc
        {
            if (v) funcFlags |= FunctionFlag.isproperty;
            else funcFlags &= ~FunctionFlag.isproperty;
        }

        /// set or get if the function has the `ref` attribute
        bool isref() const pure nothrow @safe @nogc
        {
            return (funcFlags & FunctionFlag.isref) != 0;
        }
        /// ditto
        void isref(bool v) pure nothrow @safe @nogc
        {
            if (v) funcFlags |= FunctionFlag.isref;
            else funcFlags &= ~FunctionFlag.isref;
        }

        /// set or get if the function has the `return` attribute
        bool isreturn() const pure nothrow @safe @nogc
        {
            return (funcFlags & FunctionFlag.isreturn) != 0;
        }
        /// ditto
        void isreturn(bool v) pure nothrow @safe @nogc
        {
            if (v) funcFlags |= FunctionFlag.isreturn;
            else funcFlags &= ~FunctionFlag.isreturn;
        }

        /// set or get if the function has the `scope` attribute
        bool isScopeQual() const pure nothrow @safe @nogc
        {
            return (funcFlags & FunctionFlag.isscope) != 0;
        }
        /// ditto
        void isScopeQual(bool v) pure nothrow @safe @nogc
        {
            if (v) funcFlags |= FunctionFlag.isscope;
            else funcFlags &= ~FunctionFlag.isscope;
        }

        /// set or get if the function has the `return` attribute inferred
        bool isreturninferred() const pure nothrow @safe @nogc
        {
            return (funcFlags & FunctionFlag.isreturninferred) != 0;
        }
        /// ditto
        void isreturninferred(bool v) pure nothrow @safe @nogc
        {
            if (v) funcFlags |= FunctionFlag.isreturninferred;
            else funcFlags &= ~FunctionFlag.isreturninferred;
        }

        /// set or get if the function has the `scope` attribute inferred
        bool isscopeinferred() const pure nothrow @safe @nogc
        {
            return (funcFlags & FunctionFlag.isscopeinferred) != 0;
        }
        /// ditoo
        void isscopeinferred(bool v) pure nothrow @safe @nogc
        {
            if (v) funcFlags |= FunctionFlag.isscopeinferred;
            else funcFlags &= ~FunctionFlag.isscopeinferred;
        }

        /// set or get if the function has the `@live` attribute
        bool islive() const pure nothrow @safe @nogc
        {
            return (funcFlags & FunctionFlag.islive) != 0;
        }
        /// ditto
        void islive(bool v) pure nothrow @safe @nogc
        {
            if (v) funcFlags |= FunctionFlag.islive;
            else funcFlags &= ~FunctionFlag.islive;
        }

        /// set or get if the return type or the default arguments are removed
        bool incomplete() const pure nothrow @safe @nogc
        {
            return (funcFlags & FunctionFlag.incomplete) != 0;
        }
        /// ditto
        void incomplete(bool v) pure nothrow @safe @nogc
        {
            if (v) funcFlags |= FunctionFlag.incomplete;
            else funcFlags &= ~FunctionFlag.incomplete;
        }

        /// set or get if the function has the `inout` on the parameters
        bool isInOutParam() const pure nothrow @safe @nogc
        {
            return (funcFlags & FunctionFlag.inoutParam) != 0;
        }
        /// ditto
        void isInOutParam(bool v) pure nothrow @safe @nogc
        {
            if (v) funcFlags |= FunctionFlag.inoutParam;
            else funcFlags &= ~FunctionFlag.inoutParam;
        }

        /// set or get if the function has the `inout` on the parameters
        bool isInOutQual() const pure nothrow @safe @nogc
        {
            return (funcFlags & FunctionFlag.inoutQual) != 0;
        }
        /// ditto
        void isInOutQual(bool v) pure nothrow @safe @nogc
        {
            if (v) funcFlags |= FunctionFlag.inoutQual;
            else funcFlags &= ~FunctionFlag.inoutQual;
        }
        /// Returns: `true` the function is `isInOutQual` or `isInOutParam` ,`false` otherwise.
        bool iswild() const pure nothrow @safe @nogc
        {
            return (funcFlags & (FunctionFlag.inoutParam | FunctionFlag.inoutQual)) != 0;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) class TypeArray : TypeNext
    {
        final extern (D) this(TY ty, Type next)
        {
            super(ty, next);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class TypeDArray : TypeArray
    {
        extern (D) this(Type t)
        {
            super(Tarray, t);
        }

        override Type syntaxCopy()
        {
            Type t = next.syntaxCopy();
            if (t == next)
                t = this;
            else
            {
                t = new TypeDArray(t);
                t.mod = mod;
            }
            return t;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class TypeAArray : TypeArray
    {
        Type index;
        Loc loc;

        extern (D) this(Type t, Type index)
        {
            super(Taarray, t);
            this.index = index;
        }

        override Type syntaxCopy()
        {
            Type t = next.syntaxCopy();
            Type ti = index.syntaxCopy();
            if (t == next && ti == index)
                t = this;
            else
            {
                t = new TypeAArray(t, ti);
                t.mod = mod;
            }
            return t;
        }

        override Expression toExpression()
        {
            Expression e = next.toExpression();
            if (e)
            {
                Expression ei = index.toExpression();
                if (ei)
                    return new ArrayExp(loc, e, ei);
            }
            return null;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class TypeSArray : TypeArray
    {
        Expression dim;

        final extern (D) this(Type t, Expression dim)
        {
            super(Tsarray, t);
            this.dim = dim;
        }

        override Type syntaxCopy()
        {
            Type t = next.syntaxCopy();
            Expression e = dim.syntaxCopy();
            t = new TypeSArray(t, e);
            t.mod = mod;
            return t;
        }

        override Expression toExpression()
        {
            Expression e = next.toExpression();
            if (e)
                e = new ArrayExp(dim.loc, e, dim);
            return e;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) abstract class TypeQualified : Type
    {
        Objects idents;
        Loc loc;

        final extern (D) this(TY ty, Loc loc)
        {
            super(ty);
            this.loc = loc;
        }

        final void addIdent(Identifier id)
        {
            idents.push(id);
        }

        final void addInst(TemplateInstance ti)
        {
            idents.push(ti);
        }

        final void addIndex(RootObject e)
        {
            idents.push(e);
        }

        final void syntaxCopyHelper(TypeQualified t)
        {
            idents.setDim(t.idents.dim);
            for (size_t i = 0; i < idents.dim; i++)
            {
                RootObject id = t.idents[i];
                if (id.dyncast() == DYNCAST.dsymbol)
                {
                    TemplateInstance ti = cast(TemplateInstance)id;
                    ti = cast(TemplateInstance)ti.syntaxCopy(null);
                    id = ti;
                }
                else if (id.dyncast() == DYNCAST.expression)
                {
                    Expression e = cast(Expression)id;
                    e = e.syntaxCopy();
                    id = e;
                }
                else if (id.dyncast() == DYNCAST.type)
                {
                    Type tx = cast(Type)id;
                    tx = tx.syntaxCopy();
                    id = tx;
                }
                idents[i] = id;
            }
        }

        final Expression toExpressionHelper(Expression e, size_t i = 0)
        {
            for (; i < idents.dim; i++)
            {
                RootObject id = idents[i];

                switch (id.dyncast())
                {
                    case DYNCAST.identifier:
                        e = new DotIdExp(e.loc, e, cast(Identifier)id);
                        break;

                    case DYNCAST.dsymbol:
                        auto ti = (cast(Dsymbol)id).isTemplateInstance();
                        assert(ti);
                        e = new DotTemplateInstanceExp(e.loc, e, ti.name, ti.tiargs);
                        break;

                    case DYNCAST.type:          // Bugzilla 1215
                        e = new ArrayExp(loc, e, new TypeExp(loc, cast(Type)id));
                        break;

                    case DYNCAST.expression:    // Bugzilla 1215
                        e = new ArrayExp(loc, e, cast(Expression)id);
                        break;

                    default:
                        assert(0);
                }
            }
            return e;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) class TypeTraits : Type
    {
        TraitsExp exp;
        Loc loc;

        extern (D) this(const ref Loc loc, TraitsExp exp)
        {
            super(Tident);
            this.loc = loc;
            this.exp = exp;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }

        override Type syntaxCopy()
        {
            TraitsExp te = cast(TraitsExp) exp.syntaxCopy();
            TypeTraits tt = new TypeTraits(loc, te);
            tt.mod = mod;
            return tt;
        }
    }

    extern (C++) final class TypeMixin : Type
    {
        Loc loc;
        Expressions* exps;

        extern (D) this(const ref Loc loc, Expressions* exps)
        {
            super(Tmixin);
            this.loc = loc;
            this.exps = exps;
        }

        override Type syntaxCopy()
        {
            static Expressions* arraySyntaxCopy(Expressions* exps)
            {
                Expressions* a = null;
                if (exps)
                {
                    a = new Expressions(exps.dim);
                    foreach (i, e; *exps)
                    {
                        (*a)[i] = e ? e.syntaxCopy() : null;
                    }
                }
                return a;
            }

            return new TypeMixin(loc, arraySyntaxCopy(exps));
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class TypeIdentifier : TypeQualified
    {
        Identifier ident;

        extern (D) this(const ref Loc loc, Identifier ident)
        {
            super(Tident, loc);
            this.ident = ident;
        }

        override Type syntaxCopy()
        {
            auto t = new TypeIdentifier(loc, ident);
            t.syntaxCopyHelper(this);
            t.mod = mod;
            return t;
        }

        override Expression toExpression()
        {
            return toExpressionHelper(new IdentifierExp(loc, ident));
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class TypeReturn : TypeQualified
    {
        extern (D) this(const ref Loc loc)
        {
            super(Treturn, loc);
        }

        override Type syntaxCopy()
        {
            auto t = new TypeReturn(loc);
            t.syntaxCopyHelper(this);
            t.mod = mod;
            return t;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class TypeTypeof : TypeQualified
    {
        Expression exp;

        extern (D) this(const ref Loc loc, Expression exp)
        {
            super(Ttypeof, loc);
            this.exp = exp;
        }

        override Type syntaxCopy()
        {
            auto t = new TypeTypeof(loc, exp.syntaxCopy());
            t.syntaxCopyHelper(this);
            t.mod = mod;
            return t;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class TypeInstance : TypeQualified
    {
        TemplateInstance tempinst;

        final extern (D) this(const ref Loc loc, TemplateInstance tempinst)
        {
            super(Tinstance, loc);
            this.tempinst = tempinst;
        }

        override Type syntaxCopy()
        {
            auto t = new TypeInstance(loc, cast(TemplateInstance)tempinst.syntaxCopy(null));
            t.syntaxCopyHelper(this);
            t.mod = mod;
            return t;
        }

        override Expression toExpression()
        {
            return toExpressionHelper(new ScopeExp(loc, tempinst));
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) abstract class Expression : ASTNode
    {
        TOK op;
        ubyte size;
        ubyte parens;
        Type type;
        Loc loc;

        final extern (D) this(const ref Loc loc, TOK op, int size)
        {
            this.loc = loc;
            this.op = op;
            this.size = cast(ubyte)size;
        }

        Expression syntaxCopy()
        {
            return copy();
        }

        final void error(const(char)* format, ...) const
        {
            if (type != Type.terror)
            {
                va_list ap;
                va_start(ap, format);
                verror(loc, format, ap);
                va_end(ap);
            }
        }

        final Expression copy()
        {
            Expression e;
            if (!size)
            {
                assert(0);
            }
            e = cast(Expression)mem.xmalloc(size);
            return cast(Expression)memcpy(cast(void*)e, cast(void*)this, size);
        }

        override final DYNCAST dyncast() const
        {
            return DYNCAST.expression;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class DeclarationExp : Expression
    {
        Dsymbol declaration;

        extern (D) this(const ref Loc loc, Dsymbol declaration)
        {
            super(loc, TOK.declaration, __traits(classInstanceSize, DeclarationExp));
            this.declaration = declaration;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class IntegerExp : Expression
    {
        dinteger_t value;

        extern (D) this(const ref Loc loc, dinteger_t value, Type type)
        {
            super(loc, TOK.int64, __traits(classInstanceSize, IntegerExp));
            assert(type);
            if (!type.isscalar())
            {
                if (type.ty != Terror)
                    error("integral constant must be scalar type, not %s", type.toChars());
                type = Type.terror;
            }
            this.type = type;
            setInteger(value);
        }

        void setInteger(dinteger_t value)
        {
            this.value = value;
            normalize();
        }

        void normalize()
        {
            /* 'Normalize' the value of the integer to be in range of the type
             */
            switch (type.toBasetype().ty)
            {
            case Tbool:
                value = (value != 0);
                break;

            case Tint8:
                value = cast(d_int8)value;
                break;

            case Tchar:
            case Tuns8:
                value = cast(d_uns8)value;
                break;

            case Tint16:
                value = cast(d_int16)value;
                break;

            case Twchar:
            case Tuns16:
                value = cast(d_uns16)value;
                break;

            case Tint32:
                value = cast(d_int32)value;
                break;

            case Tdchar:
            case Tuns32:
                value = cast(d_uns32)value;
                break;

            case Tint64:
                value = cast(d_int64)value;
                break;

            case Tuns64:
                value = cast(d_uns64)value;
                break;

            case Tpointer:
                if (Target.ptrsize == 8)
                    goto case Tuns64;
                if (Target.ptrsize == 4)
                    goto case Tuns32;
                if (Target.ptrsize == 2)
                    goto case Tuns16;
                assert(0);

            default:
                break;
            }
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class NewAnonClassExp : Expression
    {
        Expression thisexp;     // if !=null, 'this' for class being allocated
        Expressions* newargs;   // Array of Expression's to call new operator
        ClassDeclaration cd;    // class being instantiated
        Expressions* arguments; // Array of Expression's to call class constructor

        extern (D) this(const ref Loc loc, Expression thisexp, Expressions* newargs, ClassDeclaration cd, Expressions* arguments)
        {
            super(loc, TOK.newAnonymousClass, __traits(classInstanceSize, NewAnonClassExp));
            this.thisexp = thisexp;
            this.newargs = newargs;
            this.cd = cd;
            this.arguments = arguments;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class IsExp : Expression
    {
        Type targ;
        Identifier id;      // can be null
        Type tspec;         // can be null
        TemplateParameters* parameters;
        TOK tok;            // ':' or '=='
        TOK tok2;           // 'struct', 'union', etc.

        extern (D) this(const ref Loc loc, Type targ, Identifier id, TOK tok, Type tspec, TOK tok2, TemplateParameters* parameters)
        {
            super(loc, TOK.is_, __traits(classInstanceSize, IsExp));
            this.targ = targ;
            this.id = id;
            this.tok = tok;
            this.tspec = tspec;
            this.tok2 = tok2;
            this.parameters = parameters;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class RealExp : Expression
    {
        real_t value;

        extern (D) this(const ref Loc loc, real_t value, Type type)
        {
            super(loc, TOK.float64, __traits(classInstanceSize, RealExp));
            this.value = value;
            this.type = type;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class NullExp : Expression
    {
        extern (D) this(const ref Loc loc, Type type = null)
        {
            super(loc, TOK.null_, __traits(classInstanceSize, NullExp));
            this.type = type;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class TypeidExp : Expression
    {
        RootObject obj;

        extern (D) this(const ref Loc loc, RootObject o)
        {
            super(loc, TOK.typeid_, __traits(classInstanceSize, TypeidExp));
            this.obj = o;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class TraitsExp : Expression
    {
        Identifier ident;
        Objects* args;

        extern (D) this(const ref Loc loc, Identifier ident, Objects* args)
        {
            super(loc, TOK.traits, __traits(classInstanceSize, TraitsExp));
            this.ident = ident;
            this.args = args;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class StringExp : Expression
    {
        union
        {
            char* string;   // if sz == 1
            wchar* wstring; // if sz == 2
            dchar* dstring; // if sz == 4
        }                   // (const if ownedByCtfe == OwnedBy.code)
        size_t len;         // number of code units
        ubyte sz = 1;       // 1: char, 2: wchar, 4: dchar
        char postfix = 0;   // 'c', 'w', 'd'

        extern (D) this(const ref Loc loc, const(void)[] string)
        {
            super(loc, TOK.string_, __traits(classInstanceSize, StringExp));
            this.string = cast(char*)string.ptr;
            this.len = string.length;
            this.sz = 1;                    // work around LDC bug #1286
        }

        extern (D) this(const ref Loc loc, const(void)[] string, size_t len, ubyte sz, char postfix = 0)
        {
            super(loc, TOK.string_, __traits(classInstanceSize, StringExp));
            this.string = cast(char*)string;
            this.len = len;
            this.postfix = postfix;
            this.sz = 1;                    // work around LDC bug #1286
        }

        /**********************************************
        * Write the contents of the string to dest.
        * Use numberOfCodeUnits() to determine size of result.
        * Params:
        *  dest = destination
        *  tyto = encoding type of the result
        *  zero = add terminating 0
        */
        void writeTo(void* dest, bool zero, int tyto = 0) const
        {
            int encSize;
            switch (tyto)
            {
                case 0:      encSize = sz; break;
                case Tchar:  encSize = 1; break;
                case Twchar: encSize = 2; break;
                case Tdchar: encSize = 4; break;
                default:
                    assert(0);
            }
            if (sz == encSize)
            {
                memcpy(dest, string, len * sz);
                if (zero)
                    memset(dest + len * sz, 0, sz);
            }
            else
                assert(0);
        }

        extern (D) const(char)[] toStringz() const
        {
            auto nbytes = len * sz;
            char* s = cast(char*)mem.xmalloc_noscan(nbytes + sz);
            writeTo(s, true);
            return s[0 .. nbytes];
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) class NewExp : Expression
    {
        Expression thisexp;         // if !=null, 'this' for class being allocated
        Expressions* newargs;       // Array of Expression's to call new operator
        Type newtype;
        Expressions* arguments;     // Array of Expression's

        extern (D) this(const ref Loc loc, Expression thisexp, Expressions* newargs, Type newtype, Expressions* arguments)
        {
            super(loc, TOK.new_, __traits(classInstanceSize, NewExp));
            this.thisexp = thisexp;
            this.newargs = newargs;
            this.newtype = newtype;
            this.arguments = arguments;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class AssocArrayLiteralExp : Expression
    {
        Expressions* keys;
        Expressions* values;

        extern (D) this(const ref Loc loc, Expressions* keys, Expressions* values)
        {
            super(loc, TOK.assocArrayLiteral, __traits(classInstanceSize, AssocArrayLiteralExp));
            assert(keys.dim == values.dim);
            this.keys = keys;
            this.values = values;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class ArrayLiteralExp : Expression
    {
        Expression basis;
        Expressions* elements;

        extern (D) this(const ref Loc loc, Expressions* elements)
        {
            super(loc, TOK.arrayLiteral, __traits(classInstanceSize, ArrayLiteralExp));
            this.elements = elements;
        }

        extern (D) this(const ref Loc loc, Expression e)
        {
            super(loc, TOK.arrayLiteral, __traits(classInstanceSize, ArrayLiteralExp));
            elements = new Expressions();
            elements.push(e);
        }

        extern (D) this(const ref Loc loc, Expression basis, Expressions* elements)
        {
            super(loc, TOK.arrayLiteral, __traits(classInstanceSize, ArrayLiteralExp));
            this.basis = basis;
            this.elements = elements;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class FuncExp : Expression
    {
        FuncLiteralDeclaration fd;
        TemplateDeclaration td;
        TOK tok;

        extern (D) this(const ref Loc loc, Dsymbol s)
        {
            super(loc, TOK.function_, __traits(classInstanceSize, FuncExp));
            this.td = s.isTemplateDeclaration();
            this.fd = s.isFuncLiteralDeclaration();
            if (td)
            {
                assert(td.literal);
                assert(td.members && td.members.dim == 1);
                fd = (*td.members)[0].isFuncLiteralDeclaration();
            }
            tok = fd.tok; // save original kind of function/delegate/(infer)
            assert(fd.fbody);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class IntervalExp : Expression
    {
        Expression lwr;
        Expression upr;

        extern (D) this(const ref Loc loc, Expression lwr, Expression upr)
        {
            super(loc, TOK.interval, __traits(classInstanceSize, IntervalExp));
            this.lwr = lwr;
            this.upr = upr;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class TypeExp : Expression
    {
        extern (D) this(const ref Loc loc, Type type)
        {
            super(loc, TOK.type, __traits(classInstanceSize, TypeExp));
            this.type = type;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class ScopeExp : Expression
    {
        ScopeDsymbol sds;

        extern (D) this(const ref Loc loc, ScopeDsymbol sds)
        {
            super(loc, TOK.scope_, __traits(classInstanceSize, ScopeExp));
            this.sds = sds;
            assert(!sds.isTemplateDeclaration());
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) class IdentifierExp : Expression
    {
        Identifier ident;

        final extern (D) this(const ref Loc loc, Identifier ident)
        {
            super(loc, TOK.identifier, __traits(classInstanceSize, IdentifierExp));
            this.ident = ident;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) class UnaExp : Expression
    {
        Expression e1;

        final extern (D) this(const ref Loc loc, TOK op, int size, Expression e1)
        {
            super(loc, op, size);
            this.e1 = e1;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) class DefaultInitExp : Expression
    {
        final extern (D) this(const ref Loc loc, TOK op, int size)
        {
            super(loc, op, size);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) abstract class BinExp : Expression
    {
        Expression e1;
        Expression e2;

        final extern (D) this(const ref Loc loc, TOK op, int size, Expression e1, Expression e2)
        {
            super(loc, op, size);
            this.e1 = e1;
            this.e2 = e2;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class DsymbolExp : Expression
    {
        Dsymbol s;
        bool hasOverloads;

        extern (D) this(const ref Loc loc, Dsymbol s, bool hasOverloads = true)
        {
            super(loc, TOK.dSymbol, __traits(classInstanceSize, DsymbolExp));
            this.s = s;
            this.hasOverloads = hasOverloads;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class TemplateExp : Expression
    {
        TemplateDeclaration td;
        FuncDeclaration fd;

        extern (D) this(const ref Loc loc, TemplateDeclaration td, FuncDeclaration fd = null)
        {
            super(loc, TOK.template_, __traits(classInstanceSize, TemplateExp));
            //printf("TemplateExp(): %s\n", td.toChars());
            this.td = td;
            this.fd = fd;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) class SymbolExp : Expression
    {
        Declaration var;
        bool hasOverloads;

        final extern (D) this(const ref Loc loc, TOK op, int size, Declaration var, bool hasOverloads)
        {
            super(loc, op, size);
            assert(var);
            this.var = var;
            this.hasOverloads = hasOverloads;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class VarExp : SymbolExp
    {
        extern (D) this(const ref Loc loc, Declaration var, bool hasOverloads = true)
        {
            if (var.isVarDeclaration())
                hasOverloads = false;

            super(loc, TOK.variable, __traits(classInstanceSize, VarExp), var, hasOverloads);
            this.type = var.type;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class TupleExp : Expression
    {
        Expression e0;
        Expressions* exps;

        extern (D) this(const ref Loc loc, Expression e0, Expressions* exps)
        {
            super(loc, TOK.tuple, __traits(classInstanceSize, TupleExp));
            //printf("TupleExp(this = %p)\n", this);
            this.e0 = e0;
            this.exps = exps;
        }

        extern (D) this(const ref Loc loc, Expressions* exps)
        {
            super(loc, TOK.tuple, __traits(classInstanceSize, TupleExp));
            //printf("TupleExp(this = %p)\n", this);
            this.exps = exps;
        }

        extern (D) this(const ref Loc loc, TupleDeclaration tup)
        {
            super(loc, TOK.tuple, __traits(classInstanceSize, TupleExp));
            this.exps = new Expressions();

            this.exps.reserve(tup.objects.dim);
            for (size_t i = 0; i < tup.objects.dim; i++)
            {
                RootObject o = (*tup.objects)[i];
                if (Dsymbol s = getDsymbol(o))
                {
                    Expression e = new DsymbolExp(loc, s);
                    this.exps.push(e);
                }
                else if (o.dyncast() == DYNCAST.expression)
                {
                    auto e = (cast(Expression)o).copy();
                    e.loc = loc;    // Bugzilla 15669
                    this.exps.push(e);
                }
                else if (o.dyncast() == DYNCAST.type)
                {
                    Type t = cast(Type)o;
                    Expression e = new TypeExp(loc, t);
                    this.exps.push(e);
                }
                else
                {
                    error("%s is not an expression", o.toChars());
                }
            }
        }

        extern (C++) Dsymbol isDsymbol(RootObject o)
        {
            if (!o || o.dyncast || DYNCAST.dsymbol)
                return null;
            return cast(Dsymbol)o;
        }

        extern (C++) Dsymbol getDsymbol(RootObject oarg)
        {
            Dsymbol sa;
            Expression ea = isExpression(oarg);
            if (ea)
            {
                // Try to convert Expression to symbol
                if (ea.op == TOK.variable)
                    sa = (cast(VarExp)ea).var;
                else if (ea.op == TOK.function_)
                {
                    if ((cast(FuncExp)ea).td)
                        sa = (cast(FuncExp)ea).td;
                    else
                        sa = (cast(FuncExp)ea).fd;
                }
                else if (ea.op == TOK.template_)
                    sa = (cast(TemplateExp)ea).td;
                else
                    sa = null;
            }
            else
            {
                // Try to convert Type to symbol
                Type ta = isType(oarg);
                if (ta)
                    sa = ta.toDsymbol(null);
                else
                    sa = isDsymbol(oarg); // if already a symbol
            }
            return sa;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class DollarExp : IdentifierExp
    {
        extern (D) this(const ref Loc loc)
        {
            super(loc, Id.dollar);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) class ThisExp : Expression
    {
        final extern (D) this(const ref Loc loc)
        {
            super(loc, TOK.this_, __traits(classInstanceSize, ThisExp));
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class SuperExp : ThisExp
    {
        extern (D) this(const ref Loc loc)
        {
            super(loc);
            op = TOK.super_;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class AddrExp : UnaExp
    {
        extern (D) this(const ref Loc loc, Expression e)
        {
            super(loc, TOK.address, __traits(classInstanceSize, AddrExp), e);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class PreExp : UnaExp
    {
        extern (D) this(TOK op, Loc loc, Expression e)
        {
            super(loc, op, __traits(classInstanceSize, PreExp), e);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class PtrExp : UnaExp
    {
        extern (D) this(const ref Loc loc, Expression e)
        {
            super(loc, TOK.star, __traits(classInstanceSize, PtrExp), e);
        }
        extern (D) this(const ref Loc loc, Expression e, Type t)
        {
            super(loc, TOK.star, __traits(classInstanceSize, PtrExp), e);
            type = t;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class NegExp : UnaExp
    {
        extern (D) this(const ref Loc loc, Expression e)
        {
            super(loc, TOK.negate, __traits(classInstanceSize, NegExp), e);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class UAddExp : UnaExp
    {
        extern (D) this(const ref Loc loc, Expression e)
        {
            super(loc, TOK.uadd, __traits(classInstanceSize, UAddExp), e);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class NotExp : UnaExp
    {
        extern (D) this(const ref Loc loc, Expression e)
        {
            super(loc, TOK.not, __traits(classInstanceSize, NotExp), e);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class ComExp : UnaExp
    {
        extern (D) this(const ref Loc loc, Expression e)
        {
            super(loc, TOK.tilde, __traits(classInstanceSize, ComExp), e);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class DeleteExp : UnaExp
    {
        bool isRAII;

        extern (D) this(const ref Loc loc, Expression e, bool isRAII)
        {
            super(loc, TOK.delete_, __traits(classInstanceSize, DeleteExp), e);
            this.isRAII = isRAII;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class CastExp : UnaExp
    {
        Type to;
        ubyte mod = cast(ubyte)~0;

        extern (D) this(const ref Loc loc, Expression e, Type t)
        {
            super(loc, TOK.cast_, __traits(classInstanceSize, CastExp), e);
            this.to = t;
        }
        extern (D) this(const ref Loc loc, Expression e, ubyte mod)
        {
            super(loc, TOK.cast_, __traits(classInstanceSize, CastExp), e);
            this.mod = mod;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class CallExp : UnaExp
    {
        Expressions* arguments;

        extern (D) this(const ref Loc loc, Expression e, Expressions* exps)
        {
            super(loc, TOK.call, __traits(classInstanceSize, CallExp), e);
            this.arguments = exps;
        }

        extern (D) this(const ref Loc loc, Expression e)
        {
            super(loc, TOK.call, __traits(classInstanceSize, CallExp), e);
        }

        extern (D) this(const ref Loc loc, Expression e, Expression earg1)
        {
            super(loc, TOK.call, __traits(classInstanceSize, CallExp), e);
            auto arguments = new Expressions();
            if (earg1)
            {
                arguments.setDim(1);
                (*arguments)[0] = earg1;
            }
            this.arguments = arguments;
        }

        extern (D) this(const ref Loc loc, Expression e, Expression earg1, Expression earg2)
        {
            super(loc, TOK.call, __traits(classInstanceSize, CallExp), e);
            auto arguments = new Expressions();
            arguments.setDim(2);
            (*arguments)[0] = earg1;
            (*arguments)[1] = earg2;
            this.arguments = arguments;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class DotIdExp : UnaExp
    {
        Identifier ident;

        extern (D) this(const ref Loc loc, Expression e, Identifier ident)
        {
            super(loc, TOK.dotIdentifier, __traits(classInstanceSize, DotIdExp), e);
            this.ident = ident;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class AssertExp : UnaExp
    {
        Expression msg;

        extern (D) this(const ref Loc loc, Expression e, Expression msg = null)
        {
            super(loc, TOK.assert_, __traits(classInstanceSize, AssertExp), e);
            this.msg = msg;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class MixinExp : Expression
    {
        Expressions* exps;

        extern (D) this(const ref Loc loc, Expressions* exps)
        {
            super(loc, TOK.mixin_, __traits(classInstanceSize, MixinExp));
            this.exps = exps;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class ImportExp : UnaExp
    {
        extern (D) this(const ref Loc loc, Expression e)
        {
            super(loc, TOK.import_, __traits(classInstanceSize, ImportExp), e);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class DotTemplateInstanceExp : UnaExp
    {
        TemplateInstance ti;

        extern (D) this(const ref Loc loc, Expression e, Identifier name, Objects* tiargs)
        {
            super(loc, TOK.dotTemplateInstance, __traits(classInstanceSize, DotTemplateInstanceExp), e);
            this.ti = new TemplateInstance(loc, name, tiargs);
        }
        extern (D) this(const ref Loc loc, Expression e, TemplateInstance ti)
        {
            super(loc, TOK.dotTemplateInstance, __traits(classInstanceSize, DotTemplateInstanceExp), e);
            this.ti = ti;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class ArrayExp : UnaExp
    {
        Expressions* arguments;

        extern (D) this(const ref Loc loc, Expression e1, Expression index = null)
        {
            super(loc, TOK.array, __traits(classInstanceSize, ArrayExp), e1);
            arguments = new Expressions();
            if (index)
                arguments.push(index);
        }

        extern (D) this(const ref Loc loc, Expression e1, Expressions* args)
        {
            super(loc, TOK.array, __traits(classInstanceSize, ArrayExp), e1);
            arguments = args;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class FuncInitExp : DefaultInitExp
    {
        extern (D) this(const ref Loc loc)
        {
            super(loc, TOK.functionString, __traits(classInstanceSize, FuncInitExp));
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class PrettyFuncInitExp : DefaultInitExp
    {
        extern (D) this(const ref Loc loc)
        {
            super(loc, TOK.prettyFunction, __traits(classInstanceSize, PrettyFuncInitExp));
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class FileInitExp : DefaultInitExp
    {
        extern (D) this(const ref Loc loc, TOK tok)
        {
            super(loc, tok, __traits(classInstanceSize, FileInitExp));
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class LineInitExp : DefaultInitExp
    {
        extern (D) this(const ref Loc loc)
        {
            super(loc, TOK.line, __traits(classInstanceSize, LineInitExp));
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class ModuleInitExp : DefaultInitExp
    {
        extern (D) this(const ref Loc loc)
        {
            super(loc, TOK.moduleString, __traits(classInstanceSize, ModuleInitExp));
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class CommaExp : BinExp
    {
        const bool isGenerated;
        bool allowCommaExp;

        extern (D) this(const ref Loc loc, Expression e1, Expression e2, bool generated = true)
        {
            super(loc, TOK.comma, __traits(classInstanceSize, CommaExp), e1, e2);
            allowCommaExp = isGenerated = generated;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class PostExp : BinExp
    {
        extern (D) this(TOK op, Loc loc, Expression e)
        {
            super(loc, op, __traits(classInstanceSize, PostExp), e, new IntegerExp(loc, 1, Type.tint32));
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class PowExp : BinExp
    {
        extern (D) this(const ref Loc loc, Expression e1, Expression e2)
        {
            super(loc, TOK.pow, __traits(classInstanceSize, PowExp), e1, e2);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class MulExp : BinExp
    {
        extern (D) this(const ref Loc loc, Expression e1, Expression e2)
        {
            super(loc, TOK.mul, __traits(classInstanceSize, MulExp), e1, e2);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class DivExp : BinExp
    {
        extern (D) this(const ref Loc loc, Expression e1, Expression e2)
        {
            super(loc, TOK.div, __traits(classInstanceSize, DivExp), e1, e2);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class ModExp : BinExp
    {
        extern (D) this(const ref Loc loc, Expression e1, Expression e2)
        {
            super(loc, TOK.mod, __traits(classInstanceSize, ModExp), e1, e2);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class AddExp : BinExp
    {
        extern (D) this(const ref Loc loc, Expression e1, Expression e2)
        {
            super(loc, TOK.add, __traits(classInstanceSize, AddExp), e1, e2);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class MinExp : BinExp
    {
        extern (D) this(const ref Loc loc, Expression e1, Expression e2)
        {
            super(loc, TOK.min, __traits(classInstanceSize, MinExp), e1, e2);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class CatExp : BinExp
    {
        extern (D) this(const ref Loc loc, Expression e1, Expression e2)
        {
            super(loc, TOK.concatenate, __traits(classInstanceSize, CatExp), e1, e2);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class ShlExp : BinExp
    {
        extern (D) this(const ref Loc loc, Expression e1, Expression e2)
        {
            super(loc, TOK.leftShift, __traits(classInstanceSize, ShlExp), e1, e2);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class ShrExp : BinExp
    {
        extern (D) this(const ref Loc loc, Expression e1, Expression e2)
        {
            super(loc, TOK.rightShift, __traits(classInstanceSize, ShrExp), e1, e2);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class UshrExp : BinExp
    {
        extern (D) this(const ref Loc loc, Expression e1, Expression e2)
        {
            super(loc, TOK.unsignedRightShift, __traits(classInstanceSize, UshrExp), e1, e2);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class EqualExp : BinExp
    {
        extern (D) this(TOK op, Loc loc, Expression e1, Expression e2)
        {
            super(loc, op, __traits(classInstanceSize, EqualExp), e1, e2);
            assert(op == TOK.equal || op == TOK.notEqual);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class InExp : BinExp
    {
        extern (D) this(const ref Loc loc, Expression e1, Expression e2)
        {
            super(loc, TOK.in_, __traits(classInstanceSize, InExp), e1, e2);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class IdentityExp : BinExp
    {
        extern (D) this(TOK op, Loc loc, Expression e1, Expression e2)
        {
            super(loc, op, __traits(classInstanceSize, IdentityExp), e1, e2);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class CmpExp : BinExp
    {
        extern (D) this(TOK op, Loc loc, Expression e1, Expression e2)
        {
            super(loc, op, __traits(classInstanceSize, CmpExp), e1, e2);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class AndExp : BinExp
    {
        extern (D) this(const ref Loc loc, Expression e1, Expression e2)
        {
            super(loc, TOK.and, __traits(classInstanceSize, AndExp), e1, e2);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class XorExp : BinExp
    {
        extern (D) this(const ref Loc loc, Expression e1, Expression e2)
        {
            super(loc, TOK.xor, __traits(classInstanceSize, XorExp), e1, e2);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class OrExp : BinExp
    {
        extern (D) this(const ref Loc loc, Expression e1, Expression e2)
        {
            super(loc, TOK.or, __traits(classInstanceSize, OrExp), e1, e2);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class LogicalExp : BinExp
    {
        extern (D) this(const ref Loc loc, TOK op, Expression e1, Expression e2)
        {
            super(loc, op, __traits(classInstanceSize, LogicalExp), e1, e2);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class CondExp : BinExp
    {
        Expression econd;

        extern (D) this(const ref Loc loc, Expression econd, Expression e1, Expression e2)
        {
            super(loc, TOK.question, __traits(classInstanceSize, CondExp), e1, e2);
            this.econd = econd;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class AssignExp : BinExp
    {
        extern (D) this(const ref Loc loc, Expression e1, Expression e2)
        {
            super(loc, TOK.assign, __traits(classInstanceSize, AssignExp), e1, e2);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) class BinAssignExp : BinExp
    {
        final extern (D) this(const ref Loc loc, TOK op, int size, Expression e1, Expression e2)
        {
            super(loc, op, size, e1, e2);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class AddAssignExp : BinAssignExp
    {
        extern (D) this(const ref Loc loc, Expression e1, Expression e2)
        {
            super(loc, TOK.addAssign, __traits(classInstanceSize, AddAssignExp), e1, e2);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class MinAssignExp : BinAssignExp
    {
        extern (D) this(const ref Loc loc, Expression e1, Expression e2)
        {
            super(loc, TOK.minAssign, __traits(classInstanceSize, MinAssignExp), e1, e2);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class MulAssignExp : BinAssignExp
    {
        extern (D) this(const ref Loc loc, Expression e1, Expression e2)
        {
            super(loc, TOK.mulAssign, __traits(classInstanceSize, MulAssignExp), e1, e2);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class DivAssignExp : BinAssignExp
    {
        extern (D) this(const ref Loc loc, Expression e1, Expression e2)
        {
            super(loc, TOK.divAssign, __traits(classInstanceSize, DivAssignExp), e1, e2);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class ModAssignExp : BinAssignExp
    {
        extern (D) this(const ref Loc loc, Expression e1, Expression e2)
        {
            super(loc, TOK.modAssign, __traits(classInstanceSize, ModAssignExp), e1, e2);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class PowAssignExp : BinAssignExp
    {
        extern (D) this(const ref Loc loc, Expression e1, Expression e2)
        {
            super(loc, TOK.powAssign, __traits(classInstanceSize, PowAssignExp), e1, e2);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class AndAssignExp : BinAssignExp
    {
        extern (D) this(const ref Loc loc, Expression e1, Expression e2)
        {
            super(loc, TOK.andAssign, __traits(classInstanceSize, AndAssignExp), e1, e2);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class OrAssignExp : BinAssignExp
    {
        extern (D) this(const ref Loc loc, Expression e1, Expression e2)
        {
            super(loc, TOK.orAssign, __traits(classInstanceSize, OrAssignExp), e1, e2);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class XorAssignExp : BinAssignExp
    {
        extern (D) this(const ref Loc loc, Expression e1, Expression e2)
        {
            super(loc, TOK.xorAssign, __traits(classInstanceSize, XorAssignExp), e1, e2);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class ShlAssignExp : BinAssignExp
    {
        extern (D) this(const ref Loc loc, Expression e1, Expression e2)
        {
            super(loc, TOK.leftShiftAssign, __traits(classInstanceSize, ShlAssignExp), e1, e2);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class ShrAssignExp : BinAssignExp
    {
        extern (D) this(const ref Loc loc, Expression e1, Expression e2)
        {
            super(loc, TOK.rightShiftAssign, __traits(classInstanceSize, ShrAssignExp), e1, e2);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class UshrAssignExp : BinAssignExp
    {
        extern (D) this(const ref Loc loc, Expression e1, Expression e2)
        {
            super(loc, TOK.unsignedRightShiftAssign, __traits(classInstanceSize, UshrAssignExp), e1, e2);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class CatAssignExp : BinAssignExp
    {
        extern (D) this(const ref Loc loc, Expression e1, Expression e2)
        {
            super(loc, TOK.concatenateAssign, __traits(classInstanceSize, CatAssignExp), e1, e2);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) class TemplateParameter : ASTNode
    {
        Loc loc;
        Identifier ident;

        final extern (D) this(const ref Loc loc, Identifier ident)
        {
            this.loc = loc;
            this.ident = ident;
        }

        TemplateParameter syntaxCopy(){ return null;}

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class TemplateAliasParameter : TemplateParameter
    {
        Type specType;
        RootObject specAlias;
        RootObject defaultAlias;

        extern (D) this(const ref Loc loc, Identifier ident, Type specType, RootObject specAlias, RootObject defaultAlias)
        {
            super(loc, ident);
            this.ident = ident;
            this.specType = specType;
            this.specAlias = specAlias;
            this.defaultAlias = defaultAlias;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) class TemplateTypeParameter : TemplateParameter
    {
        Type specType;
        Type defaultType;

        final extern (D) this(const ref Loc loc, Identifier ident, Type specType, Type defaultType)
        {
            super(loc, ident);
            this.ident = ident;
            this.specType = specType;
            this.defaultType = defaultType;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class TemplateTupleParameter : TemplateParameter
    {
        extern (D) this(const ref Loc loc, Identifier ident)
        {
            super(loc, ident);
            this.ident = ident;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class TemplateValueParameter : TemplateParameter
    {
        Type valType;
        Expression specValue;
        Expression defaultValue;

        extern (D) this(const ref Loc loc, Identifier ident, Type valType,
            Expression specValue, Expression defaultValue)
        {
            super(loc, ident);
            this.ident = ident;
            this.valType = valType;
            this.specValue = specValue;
            this.defaultValue = defaultValue;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class TemplateThisParameter : TemplateTypeParameter
    {
        extern (D) this(const ref Loc loc, Identifier ident, Type specType, Type defaultType)
        {
            super(loc, ident, specType, defaultType);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) abstract class Condition : ASTNode
    {
        Loc loc;

        final extern (D) this(const ref Loc loc)
        {
            this.loc = loc;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class StaticForeach : RootObject
    {
        Loc loc;

        ForeachStatement aggrfe;
        ForeachRangeStatement rangefe;

        final extern (D) this(const ref Loc loc, ForeachStatement aggrfe, ForeachRangeStatement rangefe)
        in
        {
            assert(!!aggrfe ^ !!rangefe);
        }
        do
        {
            this.loc = loc;
            this.aggrfe = aggrfe;
            this.rangefe = rangefe;
        }
    }

    extern (C++) final class StaticIfCondition : Condition
    {
        Expression exp;

        final extern (D) this(const ref Loc loc, Expression exp)
        {
            super(loc);
            this.exp = exp;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) class DVCondition : Condition
    {
        uint level;
        Identifier ident;
        Module mod;

        final extern (D) this(const ref Loc loc, Module mod, uint level, Identifier ident)
        {
            super(loc);
            this.mod = mod;
            this.ident = ident;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class DebugCondition : DVCondition
    {
        extern (D) this(const ref Loc loc, Module mod, uint level, Identifier ident)
        {
            super(loc, mod, level, ident);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class VersionCondition : DVCondition
    {
        extern (D) this(const ref Loc loc, Module mod, uint level, Identifier ident)
        {
            super(loc, mod, level, ident);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    enum InitKind : ubyte
    {
        void_,
        error,
        struct_,
        array,
        exp,
    }

    extern (C++) class Initializer : ASTNode
    {
        Loc loc;
        InitKind kind;

        final extern (D) this(const ref Loc loc, InitKind kind)
        {
            this.loc = loc;
            this.kind = kind;
        }

        // this should be abstract and implemented in child classes
        Expression toExpression(Type t = null)
        {
            return null;
        }

        final ExpInitializer isExpInitializer()
        {
            return kind == InitKind.exp ? cast(ExpInitializer)cast(void*)this : null;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class ExpInitializer : Initializer
    {
        Expression exp;

        extern (D) this(const ref Loc loc, Expression exp)
        {
            super(loc, InitKind.exp);
            this.exp = exp;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class StructInitializer : Initializer
    {
        Identifiers field;
        Initializers value;

        extern (D) this(const ref Loc loc)
        {
            super(loc, InitKind.struct_);
        }

        void addInit(Identifier field, Initializer value)
        {
            this.field.push(field);
            this.value.push(value);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class ArrayInitializer : Initializer
    {
        Expressions index;
        Initializers value;
        uint dim;
        Type type;

        extern (D) this(const ref Loc loc)
        {
            super(loc, InitKind.array);
        }

        void addInit(Expression index, Initializer value)
        {
            this.index.push(index);
            this.value.push(value);
            dim = 0;
            type = null;
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class VoidInitializer : Initializer
    {
        extern (D) this(const ref Loc loc)
        {
            super(loc, InitKind.void_);
        }

        override void accept(Visitor v)
        {
            v.visit(this);
        }
    }

    extern (C++) final class Tuple : RootObject
    {
        Objects objects;

        // kludge for template.isType()
        override DYNCAST dyncast() const
        {
            return DYNCAST.tuple;
        }

        override const(char)* toChars() const
        {
            return objects.toChars();
        }
    }

    struct BaseClass
    {
        Type type;
    }

    struct ModuleDeclaration
    {
        Loc loc;
        Identifier id;
        Identifiers *packages;
        bool isdeprecated;
        Expression msg;

        extern (D) this(const ref Loc loc, Identifiers* packages, Identifier id, Expression msg, bool isdeprecated)
        {
            this.loc = loc;
            this.packages = packages;
            this.id = id;
            this.msg = msg;
            this.isdeprecated = isdeprecated;
        }

        extern (C++) const(char)* toChars() const
        {
            OutBuffer buf;
            if (packages && packages.dim)
            {
                for (size_t i = 0; i < packages.dim; i++)
                {
                    const Identifier pid = (*packages)[i];
                    buf.writestring(pid.toString());
                    buf.writeByte('.');
                }
            }
            buf.writestring(id.toString());
            return buf.extractChars();
        }
    }

    struct Prot
    {
        enum Kind : ubyte
        {
            undefined,
            none,
            private_,
            package_,
            protected_,
            public_,
            export_,
        }
        Kind kind;
        Package pkg;
    }

    struct Scope
    {

    }

    static extern (C++) Tuple isTuple(RootObject o)
    {
        //return dynamic_cast<Tuple *>(o);
        if (!o || o.dyncast() != DYNCAST.tuple)
            return null;
        return cast(Tuple)o;
    }

    static extern (C++) Type isType(RootObject o)
    {
        if (!o || o.dyncast() != DYNCAST.type)
            return null;
        return cast(Type)o;
    }

    static extern (C++) Expression isExpression(RootObject o)
    {
        if (!o || o.dyncast() != DYNCAST.expression)
            return null;
        return cast(Expression)o;
    }

    static extern (C++) TemplateParameter isTemplateParameter(RootObject o)
    {
        if (!o || o.dyncast() != DYNCAST.templateparameter)
            return null;
        return cast(TemplateParameter)o;
    }


    static const(char)* protectionToChars(Prot.Kind kind)
    {
        final switch (kind)
        {
        case Prot.Kind.undefined:
            return null;
        case Prot.Kind.none:
            return "none";
        case Prot.Kind.private_:
            return "private";
        case Prot.Kind.package_:
            return "package";
        case Prot.Kind.protected_:
            return "protected";
        case Prot.Kind.public_:
            return "public";
        case Prot.Kind.export_:
            return "export";
        }
    }

    static bool stcToBuffer(OutBuffer* buf, StorageClass stc)
    {
        bool result = false;
        if ((stc & (STC.return_ | STC.scope_)) == (STC.return_ | STC.scope_))
            stc &= ~STC.scope_;
        while (stc)
        {
            const(char)* p = stcToChars(stc);
            if (!p) // there's no visible storage classes
                break;
            if (!result)
                result = true;
            else
                buf.writeByte(' ');
            buf.writestring(p);
        }
        return result;
    }

    static extern (C++) Expression typeToExpression(Type t)
    {
        return t.toExpression;
    }

    static const(char)* stcToChars(ref StorageClass stc)
    {
        struct SCstring
        {
            StorageClass stc;
            TOK tok;
            const(char)* id;
        }

        __gshared SCstring* table =
        [
            SCstring(STC.auto_, TOK.auto_),
            SCstring(STC.scope_, TOK.scope_),
            SCstring(STC.static_, TOK.static_),
            SCstring(STC.extern_, TOK.extern_),
            SCstring(STC.const_, TOK.const_),
            SCstring(STC.final_, TOK.final_),
            SCstring(STC.abstract_, TOK.abstract_),
            SCstring(STC.synchronized_, TOK.synchronized_),
            SCstring(STC.deprecated_, TOK.deprecated_),
            SCstring(STC.override_, TOK.override_),
            SCstring(STC.lazy_, TOK.lazy_),
            SCstring(STC.alias_, TOK.alias_),
            SCstring(STC.out_, TOK.out_),
            SCstring(STC.in_, TOK.in_),
            SCstring(STC.manifest, TOK.enum_),
            SCstring(STC.immutable_, TOK.immutable_),
            SCstring(STC.shared_, TOK.shared_),
            SCstring(STC.nothrow_, TOK.nothrow_),
            SCstring(STC.wild, TOK.inout_),
            SCstring(STC.pure_, TOK.pure_),
            SCstring(STC.ref_, TOK.ref_),
            SCstring(STC.tls),
            SCstring(STC.gshared, TOK.gshared),
            SCstring(STC.nogc, TOK.at, "@nogc"),
            SCstring(STC.property, TOK.at, "@property"),
            SCstring(STC.safe, TOK.at, "@safe"),
            SCstring(STC.trusted, TOK.at, "@trusted"),
            SCstring(STC.system, TOK.at, "@system"),
            SCstring(STC.live, TOK.at, "@live"),
            SCstring(STC.disable, TOK.at, "@disable"),
            SCstring(STC.future, TOK.at, "@__future"),
            SCstring(0, TOK.reserved)
        ];
        for (int i = 0; table[i].stc; i++)
        {
            StorageClass tbl = table[i].stc;
            assert(tbl & STCStorageClass);
            if (stc & tbl)
            {
                stc &= ~tbl;
                if (tbl == STC.tls) // TOKtls was removed
                    return "__thread";
                TOK tok = table[i].tok;
                if (tok == TOK.at)
                    return table[i].id;
                else
                    return Token.toChars(tok);
            }
        }
        //printf("stc = %llx\n", stc);
        return null;
    }

    static const(char)* linkageToChars(LINK linkage)
    {
        final switch (linkage)
        {
        case LINK.default_:
        case LINK.system:
            return null;
        case LINK.d:
            return "D";
        case LINK.c:
            return "C";
        case LINK.cpp:
            return "C++";
        case LINK.windows:
            return "Windows";
        case LINK.pascal:
            return "Pascal";
        case LINK.objc:
            return "Objective-C";
        }
    }

    struct Target
    {
        extern (C++) __gshared int ptrsize;

        extern (C++) static Type va_listType(const ref Loc loc, Scope* sc)
        {
            if (global.params.isWindows)
            {
                return Type.tchar.pointerTo();
            }
            else if (global.params.isLinux || global.params.isFreeBSD || global.params.isOpenBSD  || global.params.isDragonFlyBSD ||
                global.params.isSolaris || global.params.isOSX)
            {
                if (global.params.is64bit)
                {
                    return (new TypeIdentifier(Loc.initial, Identifier.idPool("__va_list_tag"))).pointerTo();
                }
                else
                {
                    return Type.tchar.pointerTo();
                }
            }
            else
            {
                assert(0);
            }
        }
    }
}
