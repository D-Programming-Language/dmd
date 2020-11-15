/**
 * Convert an AST that went through all semantic phases into an object file.
 *
 * Copyright:   Copyright (C) 1999-2020 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 http://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/src/tocsym.d, _toobj.d)
 * Documentation:  https://dlang.org/phobos/dmd_toobj.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/toobj.d
 */

module dmd.toobj;

import core.stdc.stdio;
import core.stdc.stddef;
import core.stdc.string;
import core.stdc.time;

import dmd.root.array;
import dmd.root.outbuffer;
import dmd.root.rmem;
import dmd.root.rootobject;

import dmd.aggregate;
import dmd.arraytypes;
import dmd.attrib;
import dmd.dclass;
import dmd.declaration;
import dmd.denum;
import dmd.dmodule;
import dmd.dscope;
import dmd.dstruct;
import dmd.dsymbol;
import dmd.dtemplate;
import dmd.errors;
import dmd.expression;
import dmd.func;
import dmd.globals;
import dmd.glue;
import dmd.hdrgen;
import dmd.id;
import dmd.init;
import dmd.mtype;
import dmd.nspace;
import dmd.objc_glue;
import dmd.statement;
import dmd.staticassert;
import dmd.target;
import dmd.tocsym;
import dmd.toctype;
import dmd.tocvdebug;
import dmd.todt;
import dmd.tokens;
import dmd.traits;
import dmd.typinf;
import dmd.visitor;

import dmd.backend.cc;
import dmd.backend.cdef;
import dmd.backend.cgcv;
import dmd.backend.code;
import dmd.backend.code_x86;
import dmd.backend.cv4;
import dmd.backend.dt;
import dmd.backend.el;
import dmd.backend.global;
import dmd.backend.obj;
import dmd.backend.oper;
import dmd.backend.ty;
import dmd.backend.type;

extern (C++):

alias toSymbol = dmd.tocsym.toSymbol;
alias toSymbol = dmd.glue.toSymbol;


/* ================================================================== */

// Put out instance of ModuleInfo for this Module

void genModuleInfo(Module m)
{
    //printf("Module.genmoduleinfo() %s\n", m.toChars());

    if (!Module.moduleinfo)
    {
        ObjectNotFound(Id.ModuleInfo);
    }

    Symbol *msym = toSymbol(m);

    //////////////////////////////////////////////

    m.csym.Sclass = SCglobal;
    m.csym.Sfl = FLdata;

    auto dtb = DtBuilder(0);
    ClassDeclarations aclasses;

    //printf("members.dim = %d\n", members.dim);
    foreach (i; 0 .. m.members.dim)
    {
        Dsymbol member = (*m.members)[i];

        //printf("\tmember '%s'\n", member.toChars());
        member.addLocalClass(&aclasses);
    }

    // importedModules[]
    size_t aimports_dim = m.aimports.dim;
    for (size_t i = 0; i < m.aimports.dim; i++)
    {
        Module mod = m.aimports[i];
        if (!mod.needmoduleinfo)
            aimports_dim--;
    }

    FuncDeclaration sgetmembers = m.findGetMembers();

    // These must match the values in druntime/src/object_.d
    enum
    {
        MIstandalone      = 0x4,
        MItlsctor         = 0x8,
        MItlsdtor         = 0x10,
        MIctor            = 0x20,
        MIdtor            = 0x40,
        MIxgetMembers     = 0x80,
        MIictor           = 0x100,
        MIunitTest        = 0x200,
        MIimportedModules = 0x400,
        MIlocalClasses    = 0x800,
        MIname            = 0x1000,
    }

    uint flags = 0;
    if (!m.needmoduleinfo)
        flags |= MIstandalone;
    if (m.sctor)
        flags |= MItlsctor;
    if (m.sdtor)
        flags |= MItlsdtor;
    if (m.ssharedctor)
        flags |= MIctor;
    if (m.sshareddtor)
        flags |= MIdtor;
    if (sgetmembers)
        flags |= MIxgetMembers;
    if (m.sictor)
        flags |= MIictor;
    if (m.stest)
        flags |= MIunitTest;
    if (aimports_dim)
        flags |= MIimportedModules;
    if (aclasses.dim)
        flags |= MIlocalClasses;
    flags |= MIname;

    dtb.dword(flags);        // _flags
    dtb.dword(0);            // _index

    if (flags & MItlsctor)
        dtb.xoff(m.sctor, 0, TYnptr);
    if (flags & MItlsdtor)
        dtb.xoff(m.sdtor, 0, TYnptr);
    if (flags & MIctor)
        dtb.xoff(m.ssharedctor, 0, TYnptr);
    if (flags & MIdtor)
        dtb.xoff(m.sshareddtor, 0, TYnptr);
    if (flags & MIxgetMembers)
        dtb.xoff(toSymbol(sgetmembers), 0, TYnptr);
    if (flags & MIictor)
        dtb.xoff(m.sictor, 0, TYnptr);
    if (flags & MIunitTest)
        dtb.xoff(m.stest, 0, TYnptr);
    if (flags & MIimportedModules)
    {
        dtb.size(aimports_dim);
        foreach (i; 0 .. m.aimports.dim)
        {
            Module mod = m.aimports[i];

            if (!mod.needmoduleinfo)
                continue;

            Symbol *s = toSymbol(mod);

            /* Weak references don't pull objects in from the library,
             * they resolve to 0 if not pulled in by something else.
             * Don't pull in a module just because it was imported.
             */
            s.Sflags |= SFLweak;
            dtb.xoff(s, 0, TYnptr);
        }
    }
    if (flags & MIlocalClasses)
    {
        dtb.size(aclasses.dim);
        foreach (i; 0 .. aclasses.dim)
        {
            ClassDeclaration cd = aclasses[i];
            dtb.xoff(toSymbol(cd), 0, TYnptr);
        }
    }
    if (flags & MIname)
    {
        // Put out module name as a 0-terminated string, to save bytes
        m.nameoffset = dtb.length();
        const(char) *name = m.toPrettyChars();
        m.namelen = strlen(name);
        dtb.nbytes(cast(uint)m.namelen + 1, name);
        //printf("nameoffset = x%x\n", nameoffset);
    }

    objc.generateModuleInfo(m);
    m.csym.Sdt = dtb.finish();
    out_readonly(m.csym);
    outdata(m.csym);

    //////////////////////////////////////////////

    objmod.moduleinfo(msym);
}

/*****************************************
 * write pointer references for typed data to the object file
 * a class type is considered to mean a reference to a class instance
 * Params:
 *      type   = type of the data to check for pointers
 *      s      = symbol that contains the data
 *      offset = offset of the data inside the Symbol's memory
 */
void write_pointers(Type type, Symbol *s, uint offset)
{
    uint ty = type.toBasetype().ty;
    if (ty == Tclass)
        return objmod.write_pointerRef(s, offset);

    write_instance_pointers(type, s, offset);
}

/*****************************************
* write pointer references for typed data to the object file
* a class type is considered to mean the instance, not a reference
* Params:
*      type   = type of the data to check for pointers
*      s      = symbol that contains the data
*      offset = offset of the data inside the Symbol's memory
*/
void write_instance_pointers(Type type, Symbol *s, uint offset)
{
    if (!type.hasPointers())
        return;

    Array!(d_uns64) data;
    d_uns64 sz = getTypePointerBitmap(Loc.initial, type, &data);
    if (sz == d_uns64.max)
        return;

    const bytes_size_t = cast(size_t)Type.tsize_t.size(Loc.initial);
    const bits_size_t = bytes_size_t * 8;
    auto words = cast(size_t)(sz / bytes_size_t);
    for (size_t i = 0; i < data.dim; i++)
    {
        size_t bits = words < bits_size_t ? words : bits_size_t;
        for (size_t b = 0; b < bits; b++)
            if (data[i] & (1L << b))
            {
                auto off = cast(uint) ((i * bits_size_t + b) * bytes_size_t);
                objmod.write_pointerRef(s, off + offset);
            }
        words -= bits;
    }
}

/* ================================================================== */

void toObjFile(Dsymbol ds, bool multiobj)
{
    //printf("toObjFile(%s)\n", ds.toChars());
    extern (C++) final class ToObjFile : Visitor
    {
        alias visit = Visitor.visit;
    public:
        bool multiobj;

        this(bool multiobj)
        {
            this.multiobj = multiobj;
        }

        void visitNoMultiObj(Dsymbol ds)
        {
            bool multiobjsave = multiobj;
            multiobj = false;
            ds.accept(this);
            multiobj = multiobjsave;
        }

        override void visit(Dsymbol ds)
        {
            //printf("Dsymbol.toObjFile('%s')\n", ds.toChars());
            // ignore
        }

        override void visit(FuncDeclaration fd)
        {
            // in glue.c
            FuncDeclaration_toObjFile(fd, multiobj);
        }

        override void visit(ClassDeclaration cd)
        {
            //printf("ClassDeclaration.toObjFile('%s')\n", cd.toChars());

            if (cd.type.ty == Terror)
            {
                cd.error("had semantic errors when compiling");
                return;
            }

            if (!cd.members)
                return;

            if (multiobj && !cd.hasStaticCtorOrDtor())
            {
                obj_append(cd);
                return;
            }

            if (global.params.symdebugref)
                Type_toCtype(cd.type); // calls toDebug() only once
            else if (global.params.symdebug)
                toDebug(cd);

            assert(cd.semanticRun >= PASS.semantic3done);     // semantic() should have been run to completion

            enum_SC scclass = SCcomdat;

            // Put out the members
            /* There might be static ctors in the members, and they cannot
             * be put in separate obj files.
             */
            cd.members.foreachDsymbol( (s) { s.accept(this); } );

            if (cd.classKind == ClassKind.objc)
            {
                objc.toObjFile(cd);
                return;
            }

            // If something goes wrong during this pass don't bother with the
            // rest as we may have incomplete info
            // https://issues.dlang.org/show_bug.cgi?id=17918
            if (!finishVtbl(cd))
            {
                return;
            }

            const bool gentypeinfo = global.params.useTypeInfo && Type.dtypeinfo;
            const bool genclassinfo = gentypeinfo || !(cd.isCPPclass || cd.isCOMclass);

            // Generate C symbols
            if (genclassinfo)
                toSymbol(cd);                           // __ClassZ symbol
            toVtblSymbol(cd);                           // __vtblZ symbol
            Symbol *sinit = toInitializer(cd);          // __initZ symbol

            //////////////////////////////////////////////

            // Generate static initializer
            {
                sinit.Sclass = scclass;
                sinit.Sfl = FLdata;
                auto dtb = DtBuilder(0);
                ClassDeclaration_toDt(cd, dtb);
                sinit.Sdt = dtb.finish();
                out_readonly(sinit);
                outdata(sinit);
            }

            //////////////////////////////////////////////

            // Put out the TypeInfo
            if (gentypeinfo)
                genTypeInfo(cd.loc, cd.type, null);
            //toObjFile(cd.type.vtinfo, multiobj);

            if (genclassinfo)
            {
                genClassInfoForClass(cd, sinit);
            }

            //////////////////////////////////////////////

            // Put out the vtbl[]
            //printf("putting out %s.vtbl[]\n", toChars());
            auto dtbv = DtBuilder(0);
            if (cd.vtblOffset())
                dtbv.xoff(cd.csym, 0, TYnptr);           // first entry is ClassInfo reference
            foreach (i; cd.vtblOffset() .. cd.vtbl.dim)
            {
                FuncDeclaration fd = cd.vtbl[i].isFuncDeclaration();

                //printf("\tvtbl[%d] = %p\n", i, fd);
                if (fd && (fd.fbody || !cd.isAbstract()))
                {
                    dtbv.xoff(toSymbol(fd), 0, TYnptr);
                }
                else
                    dtbv.size(0);
            }
            if (dtbv.isZeroLength())
            {
                /* Someone made an 'extern (C++) class C { }' with no virtual functions.
                 * But making an empty vtbl[] causes linking problems, so make a dummy
                 * entry.
                 */
                dtbv.size(0);
            }
            cd.vtblsym.csym.Sdt = dtbv.finish();
            cd.vtblsym.csym.Sclass = scclass;
            cd.vtblsym.csym.Sfl = FLdata;
            out_readonly(cd.vtblsym.csym);
            outdata(cd.vtblsym.csym);
            if (cd.isExport())
                objmod.export_symbol(cd.vtblsym.csym,0);
        }

        override void visit(InterfaceDeclaration id)
        {
            //printf("InterfaceDeclaration.toObjFile('%s')\n", id.toChars());

            if (id.type.ty == Terror)
            {
                id.error("had semantic errors when compiling");
                return;
            }

            if (!id.members)
                return;

            if (global.params.symdebugref)
                Type_toCtype(id.type); // calls toDebug() only once
            else if (global.params.symdebug)
                toDebug(id);

            // Put out the members
            id.members.foreachDsymbol( (s) { visitNoMultiObj(s); } );

            // Generate C symbols
            toSymbol(id);

            //////////////////////////////////////////////

            // Put out the TypeInfo
            if (global.params.useTypeInfo && Type.dtypeinfo)
            {
                genTypeInfo(id.loc, id.type, null);
                id.type.vtinfo.accept(this);
            }

            //////////////////////////////////////////////

            genClassInfoForInterface(id);
        }

        override void visit(StructDeclaration sd)
        {
            //printf("StructDeclaration.toObjFile('%s')\n", sd.toChars());

            if (sd.type.ty == Terror)
            {
                sd.error("had semantic errors when compiling");
                return;
            }

            if (multiobj && !sd.hasStaticCtorOrDtor())
            {
                obj_append(sd);
                return;
            }

            // Anonymous structs/unions only exist as part of others,
            // do not output forward referenced structs's
            if (!sd.isAnonymous() && sd.members)
            {
                if (global.params.symdebugref)
                    Type_toCtype(sd.type); // calls toDebug() only once
                else if (global.params.symdebug)
                    toDebug(sd);

                if (global.params.useTypeInfo && Type.dtypeinfo)
                    genTypeInfo(sd.loc, sd.type, null);

                // Generate static initializer
                auto sinit = toInitializer(sd);
                if (sinit.Sclass == SCextern)
                {
                    if (sinit == bzeroSymbol) assert(0);
                    sinit.Sclass = sd.isInstantiated() ? SCcomdat : SCglobal;
                    sinit.Sfl = FLdata;
                    auto dtb = DtBuilder(0);
                    StructDeclaration_toDt(sd, dtb);
                    sinit.Sdt = dtb.finish();

                    /* fails to link on OBJ_MACH 64 with:
                     *  ld: in generated/osx/release/64/libphobos2.a(dwarfeh_8dc_56a.o),
                     *  in section __TEXT,__textcoal_nt reloc 6:
                     *  symbol index out of range for architecture x86_64
                     */
                    if (config.objfmt != OBJ_MACH &&
                        dtallzeros(sinit.Sdt))
                    {
                        sinit.Sclass = SCglobal;
                        dt2common(&sinit.Sdt);
                    }
                    else
                        out_readonly(sinit);    // put in read-only segment
                    outdata(sinit);
                }

                // Put out the members
                /* There might be static ctors in the members, and they cannot
                 * be put in separate obj files.
                 */
                sd.members.foreachDsymbol( (s) { s.accept(this); } );

                if (sd.xeq && sd.xeq != StructDeclaration.xerreq)
                    sd.xeq.accept(this);
                if (sd.xcmp && sd.xcmp != StructDeclaration.xerrcmp)
                    sd.xcmp.accept(this);
                if (sd.xhash)
                    sd.xhash.accept(this);
            }
        }

        override void visit(VarDeclaration vd)
        {

            //printf("VarDeclaration.toObjFile(%p '%s' type=%s) protection %d\n", vd, vd.toChars(), vd.type.toChars(), vd.protection);
            //printf("\talign = %d\n", vd.alignment);

            if (vd.type.ty == Terror)
            {
                vd.error("had semantic errors when compiling");
                return;
            }

            if (vd.aliassym)
            {
                visitNoMultiObj(vd.toAlias());
                return;
            }

            // Do not store variables we cannot take the address of
            if (!vd.canTakeAddressOf())
            {
                return;
            }

            if (!vd.isDataseg() || vd.storage_class & STC.extern_)
                return;

            Symbol *s = toSymbol(vd);
            d_uns64 sz64 = vd.type.size(vd.loc);
            if (sz64 == SIZE_INVALID)
            {
                vd.error("size overflow");
                return;
            }
            if (sz64 >= target.maxStaticDataSize)
            {
                vd.error("size of 0x%llx exceeds max allowed size 0x%llx", sz64, target.maxStaticDataSize);
            }
            uint sz = cast(uint)sz64;

            Dsymbol parent = vd.toParent();
            s.Sclass = SCglobal;

            do
            {
                /* Global template data members need to be in comdat's
                 * in case multiple .obj files instantiate the same
                 * template with the same types.
                 */
                if (parent.isTemplateInstance() && !parent.isTemplateMixin())
                {
                    s.Sclass = SCcomdat;
                    break;
                }
                parent = parent.parent;
            } while (parent);
            s.Sfl = FLdata;

            if (!sz && vd.type.toBasetype().ty != Tsarray)
                assert(0); // this shouldn't be possible

            auto dtb = DtBuilder(0);
            if (config.objfmt == OBJ_MACH && global.params.is64bit && (s.Stype.Tty & mTYLINK) == mTYthread)
            {
                tlsToDt(vd, s, sz, dtb);
            }
            else if (!sz)
            {
                /* Give it a byte of data
                 * so we can take the 'address' of this symbol
                 * and avoid problematic behavior of object file format
                 */
                dtb.nzeros(1);
            }
            else if (vd._init)
            {
                initializerToDt(vd, dtb);
            }
            else
            {
                Type_toDt(vd.type, dtb);
            }
            s.Sdt = dtb.finish();

            // See if we can convert a comdat to a comdef,
            // which saves on exe file space.
            if (s.Sclass == SCcomdat &&
                s.Sdt &&
                dtallzeros(s.Sdt) &&
                !vd.isThreadlocal())
            {
                s.Sclass = SCglobal;
                dt2common(&s.Sdt);
            }

            outdata(s);
            if (vd.type.isMutable() || !vd._init)
                write_pointers(vd.type, s, 0);
            if (vd.isExport())
                objmod.export_symbol(s, 0);
        }

        override void visit(EnumDeclaration ed)
        {
            if (ed.semanticRun >= PASS.obj)  // already written
                return;
            //printf("EnumDeclaration.toObjFile('%s')\n", ed.toChars());

            if (ed.errors || ed.type.ty == Terror)
            {
                ed.error("had semantic errors when compiling");
                return;
            }

            if (ed.isAnonymous())
                return;

            if (global.params.symdebugref)
                Type_toCtype(ed.type); // calls toDebug() only once
            else if (global.params.symdebug)
                toDebug(ed);

            if (global.params.useTypeInfo && Type.dtypeinfo)
                genTypeInfo(ed.loc, ed.type, null);

            TypeEnum tc = cast(TypeEnum)ed.type;
            if (!tc.sym.members || ed.type.isZeroInit(Loc.initial))
            {
            }
            else
            {
                enum_SC scclass = SCglobal;
                if (ed.isInstantiated())
                    scclass = SCcomdat;

                // Generate static initializer
                toInitializer(ed);
                ed.sinit.Sclass = scclass;
                ed.sinit.Sfl = FLdata;
                auto dtb = DtBuilder(0);
                Expression_toDt(tc.sym.defaultval, dtb);
                ed.sinit.Sdt = dtb.finish();
                outdata(ed.sinit);
            }
            ed.semanticRun = PASS.obj;
        }

        override void visit(TypeInfoDeclaration tid)
        {
            if (isSpeculativeType(tid.tinfo))
            {
                //printf("-speculative '%s'\n", tid.toPrettyChars());
                return;
            }
            //printf("TypeInfoDeclaration.toObjFile(%p '%s') protection %d\n", tid, tid.toChars(), tid.protection);

            if (multiobj)
            {
                obj_append(tid);
                return;
            }

            Symbol *s = toSymbol(tid);
            s.Sclass = SCcomdat;
            s.Sfl = FLdata;

            auto dtb = DtBuilder(0);
            TypeInfo_toDt(dtb, tid);
            s.Sdt = dtb.finish();

            // See if we can convert a comdat to a comdef,
            // which saves on exe file space.
            if (s.Sclass == SCcomdat &&
                dtallzeros(s.Sdt))
            {
                s.Sclass = SCglobal;
                dt2common(&s.Sdt);
            }

            outdata(s);
            if (tid.isExport())
                objmod.export_symbol(s, 0);
        }

        override void visit(TypeInfoStructDeclaration tid)
        {
            if (!isError((cast(TypeStruct)tid.tinfo).sym))
                visit(cast(TypeInfoDeclaration)tid);
        }

        override void visit(TypeInfoClassDeclaration tid)
        {
            if (!isError((cast(TypeClass)tid.tinfo).sym))
                visit(cast(TypeInfoDeclaration)tid);
        }

        override void visit(TypeInfoInterfaceDeclaration tid)
        {
            if (!isError((cast(TypeClass)tid.tinfo).sym))
                visit(cast(TypeInfoDeclaration)tid);
        }

        override void visit(AttribDeclaration ad)
        {
            Dsymbols *d = ad.include(null);

            if (d)
            {
                for (size_t i = 0; i < d.dim; i++)
                {
                    Dsymbol s = (*d)[i];
                    s.accept(this);
                }
            }
        }

        override void visit(PragmaDeclaration pd)
        {
            if (pd.ident == Id.lib)
            {
                assert(pd.args && pd.args.dim == 1);

                Expression e = (*pd.args)[0];

                assert(e.op == TOK.string_);

                StringExp se = cast(StringExp)e;
                char *name = cast(char *)mem.xmalloc(se.numberOfCodeUnits() + 1);
                se.writeTo(name, true);

                /* Embed the library names into the object file.
                 * The linker will then automatically
                 * search that library, too.
                 */
                if (!obj_includelib(name))
                {
                    /* The format does not allow embedded library names,
                     * so instead append the library name to the list to be passed
                     * to the linker.
                     */
                    global.params.libfiles.push(name);
                }
            }
            else if (pd.ident == Id.startaddress)
            {
                assert(pd.args && pd.args.dim == 1);
                Expression e = (*pd.args)[0];
                Dsymbol sa = getDsymbol(e);
                FuncDeclaration f = sa.isFuncDeclaration();
                assert(f);
                Symbol *s = toSymbol(f);
                obj_startaddress(s);
            }
            else if (pd.ident == Id.linkerDirective)
            {
                assert(pd.args && pd.args.dim == 1);

                Expression e = (*pd.args)[0];

                assert(e.op == TOK.string_);

                StringExp se = cast(StringExp)e;
                char *directive = cast(char *)mem.xmalloc(se.numberOfCodeUnits() + 1);
                se.writeTo(directive, true);

                obj_linkerdirective(directive);
            }
            else if (pd.ident == Id.crt_constructor || pd.ident == Id.crt_destructor)
            {
                immutable isCtor = pd.ident == Id.crt_constructor;

                static uint recurse(Dsymbol s, bool isCtor)
                {
                    if (auto ad = s.isAttribDeclaration())
                    {
                        uint nestedCount;
                        auto decls = ad.include(null);
                        if (decls)
                        {
                            for (size_t i = 0; i < decls.dim; ++i)
                                nestedCount += recurse((*decls)[i], isCtor);
                        }
                        return nestedCount;
                    }
                    else if (auto f = s.isFuncDeclaration())
                    {
                        f.isCrtCtorDtor |= isCtor ? 1 : 2;
                        if (f.linkage != LINK.c)
                            f.error("must be `extern(C)` for `pragma(%s)`", isCtor ? "crt_constructor".ptr : "crt_destructor".ptr);
                        return 1;
                    }
                    else
                        return 0;
                    assert(0);
                }

                if (recurse(pd, isCtor) > 1)
                    pd.error("can only apply to a single declaration");
            }

            visit(cast(AttribDeclaration)pd);
        }

        override void visit(TemplateInstance ti)
        {
            //printf("TemplateInstance.toObjFile(%p, '%s')\n", ti, ti.toChars());
            if (!isError(ti) && ti.members)
            {
                if (!ti.needsCodegen())
                {
                    //printf("-speculative (%p, %s)\n", ti, ti.toPrettyChars());
                    return;
                }
                //printf("TemplateInstance.toObjFile(%p, '%s')\n", ti, ti.toPrettyChars());

                if (multiobj)
                {
                    // Append to list of object files to be written later
                    obj_append(ti);
                }
                else
                {
                    ti.members.foreachDsymbol( (s) { s.accept(this); } );
                }
            }
        }

        override void visit(TemplateMixin tm)
        {
            //printf("TemplateMixin.toObjFile('%s')\n", tm.toChars());
            if (!isError(tm))
            {
                tm.members.foreachDsymbol( (s) { s.accept(this); } );
            }
        }

        override void visit(StaticAssert sa)
        {
        }

        override void visit(Nspace ns)
        {
            //printf("Nspace.toObjFile('%s', this = %p)\n", ns.toChars(), ns);
            if (!isError(ns) && ns.members)
            {
                if (multiobj)
                {
                    // Append to list of object files to be written later
                    obj_append(ns);
                }
                else
                {
                    ns.members.foreachDsymbol( (s) { s.accept(this); } );
                }
            }
        }

    private:
        static void initializerToDt(VarDeclaration vd, ref DtBuilder dtb)
        {
            Initializer_toDt(vd._init, dtb);

            // Look for static array that is block initialized
            ExpInitializer ie = vd._init.isExpInitializer();

            Type tb = vd.type.toBasetype();
            if (tb.ty == Tsarray && ie &&
                !tb.nextOf().equals(ie.exp.type.toBasetype().nextOf()) &&
                ie.exp.implicitConvTo(tb.nextOf())
                )
            {
                auto dim = (cast(TypeSArray)tb).dim.toInteger();

                // Duplicate Sdt 'dim-1' times, as we already have the first one
                while (--dim > 0)
                {
                    Expression_toDt(ie.exp, dtb);
                }
            }
        }

        /**
         * Output a TLS symbol for Mach-O.
         *
         * A TLS variable in the Mach-O format consists of two symbols.
         * One symbol for the data, which contains the initializer, if any.
         * The name of this symbol is the same as the variable, but with the
         * "$tlv$init" suffix. If the variable has an initializer it's placed in
         * the __thread_data section. Otherwise it's placed in the __thread_bss
         * section.
         *
         * The other symbol is for the TLV descriptor. The symbol has the same
         * name as the variable and is placed in the __thread_vars section.
         * A TLV descriptor has the following structure, where T is the type of
         * the variable:
         *
         * struct TLVDescriptor(T)
         * {
         *     extern(C) T* function(TLVDescriptor*) thunk;
         *     size_t key;
         *     size_t offset;
         * }
         *
         * Params:
         *      vd = the variable declaration for the symbol
         *      s = the backend Symbol corresponsing to vd
         *      sz = data size of s
         *      dtb = where to put the data
         */
        static void tlsToDt(VarDeclaration vd, Symbol *s, uint sz, ref DtBuilder dtb)
        {
            assert(config.objfmt == OBJ_MACH && global.params.is64bit && (s.Stype.Tty & mTYLINK) == mTYthread);

            Symbol *tlvInit = createTLVDataSymbol(vd, s);
            auto tlvInitDtb = DtBuilder(0);

            if (sz == 0)
                tlvInitDtb.nzeros(1);
            else if (vd._init)
                initializerToDt(vd, tlvInitDtb);
            else
                Type_toDt(vd.type, tlvInitDtb);

            tlvInit.Sdt = tlvInitDtb.finish();
            outdata(tlvInit);

            if (global.params.is64bit)
                tlvInit.Sclass = SCextern;

            Symbol* tlvBootstrap = objmod.tlv_bootstrap();
            dtb.xoff(tlvBootstrap, 0, TYnptr);
            dtb.size(0);
            dtb.xoff(tlvInit, 0, TYnptr);
        }

        /**
         * Creates the data symbol used to initialize a TLS variable for Mach-O.
         *
         * Params:
         *      vd = the variable declaration for the symbol
         *      s = the back end symbol corresponding to vd
         *
         * Returns: the newly created symbol
         */
        static Symbol *createTLVDataSymbol(VarDeclaration vd, Symbol *s)
        {
            assert(config.objfmt == OBJ_MACH && global.params.is64bit && (s.Stype.Tty & mTYLINK) == mTYthread);

            // Compute identifier for tlv symbol
            OutBuffer buffer;
            buffer.writestring(s.Sident);
            buffer.writestring("$tlv$init");
            const(char) *tlvInitName = buffer.peekChars();

            // Compute type for tlv symbol
            type *t = type_fake(vd.type.ty);
            type_setty(&t, t.Tty | mTYthreadData);
            type_setmangle(&t, mangle(vd));

            Symbol *tlvInit = symbol_name(tlvInitName, SCstatic, t);
            tlvInit.Sdt = null;
            tlvInit.Salignment = type_alignsize(s.Stype);
            if (vd.linkage == LINK.cpp)
                tlvInit.Sflags |= SFLpublic;

            return tlvInit;
        }

        /**
         * Returns the target mangling mangle_t for the given variable.
         *
         * Params:
         *      vd = the variable declaration
         *
         * Returns:
         *      the mangling that should be used for variable
         */
        static mangle_t mangle(const VarDeclaration vd)
        {
            final switch (vd.linkage)
            {
                case LINK.windows:
                    return global.params.is64bit ? mTYman_c : mTYman_std;

                case LINK.pascal:
                    return mTYman_pas;

                case LINK.objc:
                case LINK.c:
                    return mTYman_c;

                case LINK.d:
                    return mTYman_d;

                case LINK.cpp:
                    return mTYman_cpp;

                case LINK.default_:
                case LINK.system:
                    printf("linkage = %d\n", vd.linkage);
                    assert(0);
            }
        }
    }

    scope v = new ToObjFile(multiobj);
    ds.accept(v);
}


/*********************************
 * Finish semantic analysis of functions in vtbl[].
 * Params:
 *    cd = class which has the vtbl[]
 * Returns:
 *    true for success (no errors)
 */
private bool finishVtbl(ClassDeclaration cd)
{
    bool hasError = false;

    foreach (i; cd.vtblOffset() .. cd.vtbl.dim)
    {
        FuncDeclaration fd = cd.vtbl[i].isFuncDeclaration();

        //printf("\tvtbl[%d] = %p\n", i, fd);
        if (!fd || !fd.fbody && cd.isAbstract())
        {
            // Nothing to do
            continue;
        }
        // Ensure function has a return value
        // https://issues.dlang.org/show_bug.cgi?id=4869
        if (!fd.functionSemantic())
        {
            hasError = true;
        }

        if (!cd.isFuncHidden(fd) || fd.isFuture())
        {
            // All good, no name hiding to check for
            continue;
        }

        /* fd is hidden from the view of this class.
         * If fd overlaps with any function in the vtbl[], then
         * issue 'hidden' error.
         */
        foreach (j; 1 .. cd.vtbl.dim)
        {
            if (j == i)
                continue;
            FuncDeclaration fd2 = cd.vtbl[j].isFuncDeclaration();
            if (!fd2.ident.equals(fd.ident))
                continue;
            if (fd2.isFuture())
                continue;
            if (!fd.leastAsSpecialized(fd2) && !fd2.leastAsSpecialized(fd))
                continue;
            // Hiding detected: same name, overlapping specializations
            TypeFunction tf = fd.type.toTypeFunction();
            cd.error("use of `%s%s` is hidden by `%s`; use `alias %s = %s.%s;` to introduce base class overload set",
                fd.toPrettyChars(),
                parametersTypeToChars(tf.parameterList),
                cd.toChars(),
                fd.toChars(),
                fd.parent.toChars(),
                fd.toChars());
            hasError = true;
            break;
        }
    }

    return !hasError;
}


/******************************************
 * Get offset of base class's vtbl[] initializer from start of csym.
 * Returns ~0 if not this csym.
 */

uint baseVtblOffset(ClassDeclaration cd, BaseClass *bc)
{
    //printf("ClassDeclaration.baseVtblOffset('%s', bc = %p)\n", cd.toChars(), bc);
    uint csymoffset = target.classinfosize;    // must be ClassInfo.size
    csymoffset += cd.vtblInterfaces.dim * (4 * target.ptrsize);

    for (size_t i = 0; i < cd.vtblInterfaces.dim; i++)
    {
        BaseClass *b = (*cd.vtblInterfaces)[i];

        if (b == bc)
            return csymoffset;
        csymoffset += b.sym.vtbl.dim * target.ptrsize;
    }

    // Put out the overriding interface vtbl[]s.
    // This must be mirrored with ClassDeclaration.baseVtblOffset()
    //printf("putting out overriding interface vtbl[]s for '%s' at offset x%x\n", toChars(), offset);
    ClassDeclaration cd2;

    for (cd2 = cd.baseClass; cd2; cd2 = cd2.baseClass)
    {
        foreach (k; 0 .. cd2.vtblInterfaces.dim)
        {
            BaseClass *bs = (*cd2.vtblInterfaces)[k];
            if (bs.fillVtbl(cd, null, 0))
            {
                if (bc == bs)
                {
                    //printf("\tcsymoffset = x%x\n", csymoffset);
                    return csymoffset;
                }
                csymoffset += bs.sym.vtbl.dim * target.ptrsize;
            }
        }
    }

    return ~0;
}

/*******************
 * Emit the vtbl[] to static data
 * Params:
 *    dtb = static data builder
 *    b = base class
 *    bvtbl = array of functions to put in this vtbl[]
 *    pc = classid for this vtbl[]
 *    k = offset from pc to classinfo
 * Returns:
 *    number of bytes emitted
 */
private size_t emitVtbl(ref DtBuilder dtb, BaseClass *b, ref FuncDeclarations bvtbl, ClassDeclaration pc, size_t k)
{
    //printf("\toverriding vtbl[] for %s\n", b.sym.toChars());
    ClassDeclaration id = b.sym;

    const id_vtbl_dim = id.vtbl.dim;
    assert(id_vtbl_dim <= bvtbl.dim);

    size_t jstart = 0;
    if (id.vtblOffset())
    {
        // First entry is struct Interface reference
        dtb.xoff(toSymbol(pc), cast(uint)(target.classinfosize + k * (4 * target.ptrsize)), TYnptr);
        jstart = 1;
    }

    foreach (j; jstart .. id_vtbl_dim)
    {
        FuncDeclaration fd = bvtbl[j];
        if (fd)
        {
            auto offset2 = b.offset;
            if (fd.interfaceVirtual)
            {
                offset2 -= fd.interfaceVirtual.offset;
            }
            dtb.xoff(toThunkSymbol(fd, offset2), 0, TYnptr);
        }
        else
            dtb.size(0);
    }
    return id_vtbl_dim * target.ptrsize;
}


/******************************************************
 * Generate the ClassInfo for a Class (__classZ) symbol.
 * Write it to the object file.
 * Similar to genClassInfoForInterface().
 * Params:
 *      cd = the class
 *      sinit = the Initializer (__initZ) symbol for the class
 */
private void genClassInfoForClass(ClassDeclaration cd, Symbol* sinit)
{
    // Put out the ClassInfo, which will be the __ClassZ symbol in the object file
    enum_SC scclass = SCcomdat;
    cd.csym.Sclass = scclass;
    cd.csym.Sfl = FLdata;

    /* The layout is:
       {
            void **vptr;
            monitor_t monitor;
            byte[] m_init;              // static initialization data
            string name;                // class name
            void*[] vtbl;
            Interface[] interfaces;
            ClassInfo base;             // base class
            void* destructor;
            void function(Object) classInvariant;   // class invariant
            ClassFlags m_flags;
            void* deallocator;
            OffsetTypeInfo[] offTi;
            void function(Object) defaultConstructor;
            //const(MemberInfo[]) function(string) xgetMembers;   // module getMembers() function
            immutable(void)* m_RTInfo;
            //TypeInfo typeinfo;
       }
     */
    uint offset = target.classinfosize;    // must be ClassInfo.size
    if (Type.typeinfoclass)
    {
        if (Type.typeinfoclass.structsize != target.classinfosize)
        {
            debug printf("target.classinfosize = x%x, Type.typeinfoclass.structsize = x%x\n", offset, Type.typeinfoclass.structsize);
            cd.error("mismatch between dmd and object.d or object.di found. Check installation and import paths with -v compiler switch.");
            fatal();
        }
    }

    auto dtb = DtBuilder(0);

    if (auto tic = Type.typeinfoclass)
    {
        dtb.xoff(toVtblSymbol(tic), 0, TYnptr); // vtbl for TypeInfo_Class : ClassInfo
        if (tic.hasMonitor())
            dtb.size(0);                        // monitor
    }
    else
    {
        dtb.size(0);                    // BUG: should be an assert()
        dtb.size(0);                    // call hasMonitor()?
    }

    // m_init[]
    assert(cd.structsize >= 8 || (cd.classKind == ClassKind.cpp && cd.structsize >= 4));
    dtb.size(cd.structsize);           // size
    dtb.xoff(sinit, 0, TYnptr);         // initializer

    // name[]
    const(char) *name = cd.ident.toChars();
    size_t namelen = strlen(name);
    if (!(namelen > 9 && memcmp(name, "TypeInfo_".ptr, 9) == 0))
    {
        name = cd.toPrettyChars();
        namelen = strlen(name);
    }
    dtb.size(namelen);
    dt_t *pdtname = dtb.xoffpatch(cd.csym, 0, TYnptr);

    // vtbl[]
    dtb.size(cd.vtbl.dim);
    if (cd.vtbl.dim)
        dtb.xoff(cd.vtblsym.csym, 0, TYnptr);
    else
        dtb.size(0);

    // interfaces[]
    dtb.size(cd.vtblInterfaces.dim);
    if (cd.vtblInterfaces.dim)
        dtb.xoff(cd.csym, offset, TYnptr);      // (*)
    else
        dtb.size(0);

    // base
    if (cd.baseClass)
        dtb.xoff(toSymbol(cd.baseClass), 0, TYnptr);
    else
        dtb.size(0);

    // destructor
    if (cd.tidtor)
        dtb.xoff(toSymbol(cd.tidtor), 0, TYnptr);
    else
        dtb.size(0);

    // classInvariant
    if (cd.inv)
        dtb.xoff(toSymbol(cd.inv), 0, TYnptr);
    else
        dtb.size(0);

    // flags
    ClassFlags flags = ClassFlags.hasOffTi;
    if (cd.isCOMclass()) flags |= ClassFlags.isCOMclass;
    if (cd.isCPPclass()) flags |= ClassFlags.isCPPclass;
    flags |= ClassFlags.hasGetMembers;
    flags |= ClassFlags.hasTypeInfo;
    if (cd.ctor)
        flags |= ClassFlags.hasCtor;
    for (ClassDeclaration pc = cd; pc; pc = pc.baseClass)
    {
        if (pc.dtor)
        {
            flags |= ClassFlags.hasDtor;
            break;
        }
    }
    if (cd.isAbstract())
        flags |= ClassFlags.isAbstract;

    flags |= ClassFlags.noPointers;     // initially assume no pointers
Louter:
    for (ClassDeclaration pc = cd; pc; pc = pc.baseClass)
    {
        if (pc.members)
        {
            for (size_t i = 0; i < pc.members.dim; i++)
            {
                Dsymbol sm = (*pc.members)[i];
                //printf("sm = %s %s\n", sm.kind(), sm.toChars());
                if (sm.hasPointers())
                {
                    flags &= ~ClassFlags.noPointers;  // not no-how, not no-way
                    break Louter;
                }
            }
        }
    }
    dtb.size(flags);

    // deallocator
    dtb.size(0);

    // offTi[]
    dtb.size(0);
    dtb.size(0);            // null for now, fix later

    // defaultConstructor
    if (cd.defaultCtor && !(cd.defaultCtor.storage_class & STC.disable))
        dtb.xoff(toSymbol(cd.defaultCtor), 0, TYnptr);
    else
        dtb.size(0);

    if (Type.rtinfo && !cd.getRTInfo)
        error(cd.loc, "ICE: RTInfo not evaluated for %s", cd.toPrettyChars(true));

    // m_RTInfo
    if (cd.getRTInfo)
        Expression_toDt(cd.getRTInfo, dtb);
    else if (flags & ClassFlags.noPointers)
        dtb.size(0);
    else
        dtb.size(1);

    //dtb.xoff(toSymbol(cd.type.vtinfo), 0, TYnptr); // typeinfo

    //////////////////////////////////////////////

    // Put out (*vtblInterfaces)[]. Must immediately follow csym, because
    // of the fixup (*)

    offset += cd.vtblInterfaces.dim * (4 * target.ptrsize);
    for (size_t i = 0; i < cd.vtblInterfaces.dim; i++)
    {
        BaseClass *b = (*cd.vtblInterfaces)[i];
        ClassDeclaration id = b.sym;

        /* The layout is:
         *  struct Interface
         *  {
         *      ClassInfo classinfo;
         *      void*[] vtbl;
         *      size_t offset;
         *  }
         */

        // Fill in vtbl[]
        b.fillVtbl(cd, &b.vtbl, 1);

        // classinfo
        dtb.xoff(toSymbol(id), 0, TYnptr);

        // vtbl[]
        dtb.size(id.vtbl.dim);
        dtb.xoff(cd.csym, offset, TYnptr);

        // offset
        dtb.size(b.offset);
    }

    // Put out the (*vtblInterfaces)[].vtbl[]
    // This must be mirrored with ClassDeclaration.baseVtblOffset()
    //printf("putting out %d interface vtbl[]s for '%s'\n", vtblInterfaces.dim, toChars());
    foreach (i; 0 .. cd.vtblInterfaces.dim)
    {
        BaseClass *b = (*cd.vtblInterfaces)[i];
        offset += emitVtbl(dtb, b, b.vtbl, cd, i);
    }

    // Put out the overriding interface vtbl[]s.
    // This must be mirrored with ClassDeclaration.baseVtblOffset()
    //printf("putting out overriding interface vtbl[]s for '%s' at offset x%x\n", toChars(), offset);
    for (ClassDeclaration pc = cd.baseClass; pc; pc = pc.baseClass)
    {
        foreach (i; 0 .. pc.vtblInterfaces.dim)
        {
            BaseClass *b = (*pc.vtblInterfaces)[i];
            FuncDeclarations bvtbl;
            if (b.fillVtbl(cd, &bvtbl, 0))
            {
                offset += emitVtbl(dtb, b, bvtbl, pc, i);
            }
        }
    }

    //////////////////////////////////////////////

    dtpatchoffset(pdtname, offset);

    dtb.nbytes(cast(uint)(namelen + 1), name);
    const size_t namepad = -(namelen + 1) & (target.ptrsize - 1); // align
    dtb.nzeros(cast(uint)namepad);

    cd.csym.Sdt = dtb.finish();
    // ClassInfo cannot be const data, because we use the monitor on it
    outdata(cd.csym);
    if (cd.isExport())
        objmod.export_symbol(cd.csym, 0);
}

/******************************************************
 * Generate the ClassInfo for an Interface (classZ symbol).
 * Write it to the object file.
 * Params:
 *      id = the interface
 */
private void genClassInfoForInterface(InterfaceDeclaration id)
{
    enum_SC scclass = SCcomdat;

    // Put out the ClassInfo
    id.csym.Sclass = scclass;
    id.csym.Sfl = FLdata;

    /* The layout is:
       {
            void **vptr;
            monitor_t monitor;
            byte[] m_init;              // static initialization data
            string name;                // class name
            void*[] vtbl;
            Interface[] interfaces;
            ClassInfo base;             // base class
            void* destructor;
            void function(Object) classInvariant;   // class invariant
            ClassFlags m_flags;
            void* deallocator;
            OffsetTypeInfo[] offTi;
            void function(Object) defaultConstructor;
            //const(MemberInfo[]) function(string) xgetMembers;   // module getMembers() function
            immutable(void)* m_RTInfo;
            //TypeInfo typeinfo;
       }
     */
    auto dtb = DtBuilder(0);

    if (auto tic = Type.typeinfoclass)
    {
        dtb.xoff(toVtblSymbol(tic), 0, TYnptr); // vtbl for ClassInfo
        if (tic.hasMonitor())
            dtb.size(0);                        // monitor
    }
    else
    {
        dtb.size(0);                    // BUG: should be an assert()
        dtb.size(0);                    // call hasMonitor()?
    }

    // m_init[]
    dtb.size(0);                        // size
    dtb.size(0);                        // initializer

    // name[]
    const(char) *name = id.toPrettyChars();
    size_t namelen = strlen(name);
    dtb.size(namelen);
    dt_t *pdtname = dtb.xoffpatch(id.csym, 0, TYnptr);

    // vtbl[]
    dtb.size(0);
    dtb.size(0);

    // interfaces[]
    uint offset = target.classinfosize;
    dtb.size(id.vtblInterfaces.dim);
    if (id.vtblInterfaces.dim)
    {
        if (Type.typeinfoclass)
        {
            if (Type.typeinfoclass.structsize != offset)
            {
                id.error("mismatch between dmd and object.d or object.di found. Check installation and import paths with -v compiler switch.");
                fatal();
            }
        }
        dtb.xoff(id.csym, offset, TYnptr);      // (*)
    }
    else
    {
        dtb.size(0);
    }

    // base
    assert(!id.baseClass);
    dtb.size(0);

    // destructor
    dtb.size(0);

    // classInvariant
    dtb.size(0);

    // flags
    ClassFlags flags = ClassFlags.hasOffTi | ClassFlags.hasTypeInfo;
    if (id.isCOMinterface()) flags |= ClassFlags.isCOMclass;
    dtb.size(flags);

    // deallocator
    dtb.size(0);

    // offTi[]
    dtb.size(0);
    dtb.size(0);            // null for now, fix later

    // defaultConstructor
    dtb.size(0);

    // xgetMembers
    //dtb.size(0);

    if (Type.rtinfo && !id.getRTInfo)
        error(id.loc, "ICE: RTInfo not evaluated for %s", id.toPrettyChars(true));

    // m_RTInfo
    if (id.getRTInfo)
        Expression_toDt(id.getRTInfo, dtb);
    else
        dtb.size(0);       // no pointers

    //dtb.xoff(toSymbol(id.type.vtinfo), 0, TYnptr); // typeinfo

    //////////////////////////////////////////////

    // Put out (*vtblInterfaces)[]. Must immediately follow csym, because
    // of the fixup (*)

    offset += id.vtblInterfaces.dim * (4 * target.ptrsize);
    for (size_t i = 0; i < id.vtblInterfaces.dim; i++)
    {
        BaseClass *b = (*id.vtblInterfaces)[i];
        ClassDeclaration base = b.sym;

        // classinfo
        dtb.xoff(toSymbol(base), 0, TYnptr);

        // vtbl[]
        dtb.size(0);
        dtb.size(0);

        // offset
        dtb.size(b.offset);
    }

    //////////////////////////////////////////////

    dtpatchoffset(pdtname, offset);

    dtb.nbytes(cast(uint)(namelen + 1), name);
    const size_t namepad =  -(namelen + 1) & (target.ptrsize - 1); // align
    dtb.nzeros(cast(uint)namepad);

    id.csym.Sdt = dtb.finish();
    out_readonly(id.csym);
    outdata(id.csym);
    if (id.isExport())
        objmod.export_symbol(id.csym, 0);
}
