/**
 * Compiler implementation of the
 * $(LINK2 http://www.dlang.org, D programming language).
 *
 * Copyright:   Copyright (C) 2015-2018 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 http://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/src/dmd/objc_glue.d, _objc_glue.d)
 * Documentation:  https://dlang.org/phobos/dmd_objc_glue.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/objc_glue.d
 */

module dmd.objc_glue;

import core.stdc.stdio;
import core.stdc.stdlib;
import core.stdc.string;

import dmd.aggregate;
import dmd.declaration;
import dmd.dmodule;
import dmd.func;
import dmd.globals;
import dmd.identifier;
import dmd.mtype;
import dmd.objc;

import dmd.root.stringtable;

import dmd.backend.dt;
import dmd.backend.cc;
import dmd.backend.cdef;
import dmd.backend.el;
import dmd.backend.global;
import dmd.backend.oper;
import dmd.backend.outbuf;
import dmd.backend.ty;
import dmd.backend.type;
import dmd.backend.mach;
import dmd.backend.obj;

private __gshared ObjcGlue _objc;

ObjcGlue objc()
{
    return _objc;
}

// Should be an interface
extern(C++) abstract class ObjcGlue
{
    static void initialize()
    {
        if (global.params.isOSX && global.params.is64bit)
            _objc = new Supported;
        else
            _objc = new Unsupported;
    }

    abstract void setupMethodSelector(FuncDeclaration fd, elem** esel);
    abstract void setupMethodCall(elem** ec, elem* ehidden, elem* ethis, TypeFunction tf);
    abstract void setupEp(elem* esel, elem** ep, int leftToRight);
    abstract void generateModuleInfo();
}

private:

extern(C++) final class Unsupported : ObjcGlue
{
    override void setupMethodSelector(FuncDeclaration fd, elem** esel)
    {
        // noop
    }

    override void setupMethodCall(elem** ec, elem* ehidden, elem* ethis, TypeFunction tf)
    {
        assert(0, "Should never be called when Objective-C is not supported");
    }

    override void setupEp(elem* esel, elem** ep, int reverse)
    {
        // noop
    }

    override void generateModuleInfo()
    {
        // noop
    }
}

extern(C++) final class Supported : ObjcGlue
{
    extern (D) this()
    {
        Symbols.initialize();
    }

    override void setupMethodSelector(FuncDeclaration fd, elem** esel)
    {
        if (fd && fd.selector && !*esel)
        {
            *esel = el_var(Symbols.getMethVarRef(fd.selector.toString()));
        }
    }

    override void setupMethodCall(elem** ec, elem* ehidden, elem* ethis, TypeFunction tf)
    {
        // make objc-style "virtual" call using dispatch function
        assert(ethis);
        Type tret = tf.next;
        *ec = el_var(Symbols.getMsgSend(tret, ehidden !is null));
    }

    override void setupEp(elem* esel, elem** ep, int leftToRight)
    {
        if (esel)
        {
            // using objc-style "virtual" call
            // add hidden argument (second to 'this') for selector used by dispatch function
            if (leftToRight)
                *ep = el_param(esel, *ep);
            else
                *ep = el_param(*ep, esel);
        }
    }

    override void generateModuleInfo()
    {
        if (Symbols.hasSymbols)
            Symbols.getModuleInfo();
    }
}

struct Segments
{
    enum Id
    {
        cString,
        imageInfo,
        methodName,
        moduleInfo,
        selectorRefs
    }

    private
    {
        __gshared static int[segmentData.length] segments;

        __gshared static Segments[__traits(allMembers, Id).length] segmentData = [
            Segments("__cstring", "__TEXT", S_CSTRING_LITERALS),
            Segments("__objc_imageinfo", "__DATA", S_REGULAR | S_ATTR_NO_DEAD_STRIP),
            Segments("__objc_methname", "__TEXT", S_CSTRING_LITERALS),
            Segments("__objc_classlist", "__DATA", S_REGULAR | S_ATTR_NO_DEAD_STRIP),
            Segments("__objc_selrefs", "__DATA", S_ATTR_NO_DEAD_STRIP | S_LITERAL_POINTERS)
        ];

        const(char)* sectionName;
        const(char)* segmentName;
        int flags;
        int alignment = 3;
    }

    static int opIndex(Id id)
    {
        auto segmentsPtr = segments.ptr;

        if (segmentsPtr[id] != 0)
            return segmentsPtr[id];

        foreach (i, seg ; segmentData)
        {
            version (OSX)
            {
                segmentsPtr[i] = MachObj.getsegment(
                    seg.sectionName,
                    seg.segmentName,
                    seg.alignment,
                    seg.flags
                );
            }
            else
            {
                // This should never happen. If the platform is not OSX an error
                // should have occurred sooner which should have prevented the
                // code from getting here.
                assert(0);
            }
        }

        return segmentsPtr[id];
    }
}

struct Symbols
{
static:

    private __gshared
    {
        bool hasSymbols_ = false;

        Symbol* objc_msgSend = null;
        Symbol* objc_msgSend_stret = null;
        Symbol* objc_msgSend_fpret = null;
        Symbol* objc_msgSend_fp2ret = null;

        Symbol* imageInfo = null;
        Symbol* moduleInfo = null;

        StringTable* methVarNameTable = null;
        StringTable* methVarRefTable = null;
    }

    void initialize()
    {
        initializeStringTables();
    }

    private void initializeStringTables()
    {
        alias This = typeof(this);

        foreach (m ; __traits(allMembers, This))
        {
            static if (is(typeof(__traits(getMember, This, m)) == StringTable*))
            {
                __traits(getMember, This, m) = new StringTable();
                __traits(getMember, This, m)._init();
            }
        }
    }

    bool hasSymbols()
    {
        if (hasSymbols_)
            return true;

        alias This = typeof(this);

        foreach (m ; __traits(allMembers, This))
        {
            static if (is(typeof(__traits(getMember, This, m)) == Symbol*))
            {
                if (__traits(getMember, This, m) !is null)
                    return true;
            }
        }

        return false;
    }

    Symbol* getCString(const(char)[] str, const(char)* symbolName, Segments.Id segment)
    {
        hasSymbols_ = true;

        // create data
        scope dtb = new DtBuilder();
        dtb.nbytes(cast(uint)(str.length + 1), str.ptr);

        // find segment
        auto seg = Segments[segment];

        // create symbol
        auto s = symbol_name(symbolName, SCstatic, type_allocn(TYarray, tstypes[TYchar]));
        s.Sdt = dtb.finish();
        s.Sseg = seg;
        return s;
    }

    Symbol* getMethVarName(const(char)[] name)
    {
        hasSymbols_ = true;

        auto stringValue = methVarNameTable.update(name.ptr, name.length);
        auto symbol = cast(Symbol*) stringValue.ptrvalue;

        if (!symbol)
        {
            __gshared size_t classNameCount = 0;
            char[42] nameString;
            sprintf(nameString.ptr, "L_OBJC_METH_VAR_NAME_%lu", classNameCount++);
            symbol = getCString(name, nameString.ptr, Segments.Id.methodName);
            stringValue.ptrvalue = symbol;
        }

        return symbol;
    }

    Symbol* getMethVarName(Identifier* ident)
    {
        return getMethVarName(ident.toString());
    }

    Symbol* getMsgSend(Type returnType, bool hasHiddenArgument)
    {
        static Symbol* setSymbol(string name)(tym_t ty = TYnfunc)
        {
            enum fieldName = name[1 .. $];

            if (!mixin(fieldName))
            {
                mixin(fieldName) = symbol_name(name.ptr, name.length, SCglobal,
                    type_fake(ty));
            }

            return mixin(fieldName);
        }

        if (hasHiddenArgument)
            return setSymbol!("_objc_msgSend_stret")(TYhfunc);
        // not sure if DMD can handle this
        else if (returnType.ty == TY.complex80)
            return setSymbol!("_objc_msgSend_fp2ret");
        else if (returnType.ty == TY.float80)
            return setSymbol!("_objc_msgSend_fpret");
        else
            return setSymbol!("_objc_msgSend");

        assert(0);
    }

    Symbol* getImageInfo()
    {
        if (imageInfo)
            return imageInfo;

        scope dtb = new DtBuilder();
        dtb.dword(0); // version
        dtb.dword(0); // flags

        imageInfo = symbol_name("L_OBJC_IMAGE_INFO", SCstatic, type_allocn(TYarray, tstypes[TYchar]));
        imageInfo.Sdt = dtb.finish();
        imageInfo.Sseg = Segments[Segments.Id.imageInfo];
        outdata(imageInfo);

        return imageInfo;
    }

    Symbol* getModuleInfo()
    {
        assert(!moduleInfo); // only allow once per object file

        scope dtb = new DtBuilder();

        Symbol* symbol = symbol_name("L_OBJC_LABEL_CLASS_$", SCstatic, type_allocn(TYarray, tstypes[TYchar]));
        symbol.Sdt = dtb.finish();
        symbol.Sseg = Segments[Segments.Id.moduleInfo];
        outdata(symbol);

        getImageInfo(); // make sure we also generate image info

        return moduleInfo;
    }

    Symbol* getMethVarRef(const(char)[] name)
    {
        hasSymbols_ = true;

        auto stringValue = methVarRefTable.update(name.ptr, name.length);
        auto refSymbol = cast(Symbol*) stringValue.ptrvalue;
        if (refSymbol is null)
        {
            // create data
            scope dtb = new DtBuilder();
            auto selector = getMethVarName(name);
            dtb.xoff(selector, 0, TYnptr);

            // find segment
            auto seg = Segments[Segments.Id.selectorRefs];

            // create symbol
            __gshared size_t selectorCount = 0;
            char[42] nameString;
            sprintf(nameString.ptr, "L_OBJC_SELECTOR_REFERENCES_%lu", selectorCount);
            refSymbol = symbol_name(nameString.ptr, SCstatic, type_fake(TYnptr));

            refSymbol.Sdt = dtb.finish();
            refSymbol.Sseg = seg;
            outdata(refSymbol);
            stringValue.ptrvalue = refSymbol;

            ++selectorCount;
        }
        return refSymbol;
    }

    Symbol* getMethVarRef(Identifier ident)
    {
        return getMethVarRef(ident.toString());
    }
}
