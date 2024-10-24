/**
 * Transition from intermediate representation to code generator
 *
 * Compiler implementation of the
 * $(LINK2 https://www.dlang.org, D programming language).
 *
 * Copyright:   Copyright (C) 1984-1998 by Symantec
 *              Copyright (C) 2000-2024 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 https://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/src/dmd/backend/dout.d, backend/dout.d)
 * Documentation:  https://dlang.org/phobos/dmd_backend_dout.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/backend/dout.d
 */

module dmd.backend.dout;

import core.stdc.stdio;
import core.stdc.string;

import dmd.backend.barray;
import dmd.backend.cc;
import dmd.backend.cdef;
import dmd.backend.cgcv;
import dmd.backend.code;
import dmd.backend.x86.code_x86;
import dmd.backend.dt;
import dmd.backend.dlist;
import dmd.backend.el;
import dmd.backend.global;
import dmd.backend.goh;
import dmd.backend.inliner;
import dmd.backend.obj;
import dmd.backend.oper;
import dmd.backend.symtab;
import dmd.backend.ty;
import dmd.backend.type;

nothrow:
@safe:

// Determine if this Symbol is stored in a COMDAT
@trusted
bool symbol_iscomdat2(Symbol* s)
{
    return s.Sclass == SC.comdat ||
        config.flags2 & CFG2comdat && s.Sclass == SC.inline ||
        config.flags4 & CFG4allcomdat && s.Sclass == SC.global;
}

/***********************************
 * Output function thunk.
 */
@trusted
void outthunk(Symbol* sthunk, Symbol* sfunc, uint p, tym_t thisty,
        targ_size_t d, int i, targ_size_t d2)
{
    sthunk.Sseg = cseg;
    cod3_thunk(sthunk,sfunc,p,thisty,cast(uint)d,i,cast(uint)d2);
    sthunk.Sfunc.Fflags &= ~Fpending;
    sthunk.Sfunc.Fflags |= Foutput;   /* mark it as having been output */
}


/***************************
 * Write out statically allocated data.
 * Input:
 *      s               symbol to be initialized
 */
@trusted
void outdata(Symbol *s)
{
    int seg;
    targ_size_t offset;
    int flags;
    const int codeseg = cseg;

    symbol_debug(s);

    debug
    debugy && printf("outdata('%s')\n",s.Sident.ptr);

    //printf("outdata('%s', ty=x%x)\n",s.Sident.ptr,s.Stype.Tty);
    //symbol_print(s);

    // Data segment variables are always live on exit from a function
    s.Sflags |= SFLlivexit;

    dt_t *dtstart = s.Sdt;
    s.Sdt = null;                      // it will be free'd
    targ_size_t datasize = 0;
    tym_t ty = s.ty();
    if (ty & mTYexport && config.wflags & WFexpdef && s.Sclass != SC.static_)
        objmod.export_symbol(s,0);        // export data definition
    for (dt_t *dt = dtstart; dt; dt = dt.DTnext)
    {
        //printf("\tdt = %p, dt = %d\n",dt,dt.dt);
        switch (dt.dt)
        {   case DT_abytes:
            {   // Put out the data for the string, and
                // reserve a spot for a pointer to that string
                datasize += size(dt.Dty);      // reserve spot for pointer to string
                if (tybasic(dt.Dty) == TYcptr)
                {   dt.DTseg = codeseg;
                    dt.DTabytes += Offset(codeseg);
                    goto L1;
                }
                else if (tybasic(dt.Dty) == TYfptr &&
                         dt.DTnbytes > config.threshold)
                {
                L1:
                    objmod.write_bytes(SegData[dt.DTseg],dt.DTpbytes[0 .. dt.DTnbytes]);
                    break;
                }
                else
                {
                    alignOffset(CDATA, 1 << dt.DTalign);
                    dt.DTabytes += objmod.data_readonly(cast(char*)dt.DTpbytes,dt.DTnbytes,&dt.DTseg);
                }
                break;
            }

            case DT_ibytes:
                datasize += dt.DTn;
                break;

            case DT_nbytes:
                //printf("DT_nbytes %d\n", dt.DTnbytes);
                datasize += dt.DTnbytes;
                break;

            case DT_azeros:
                /* A block of zeros
                 */
                //printf("DT_azeros %d\n", dt.DTazeros);
                datasize += dt.DTazeros;
                if (dt == dtstart && !dt.DTnext && s.Sclass != SC.comdat &&
                    (s.Sseg == UNKNOWN || s.Sseg <= UDATA))
                {   /* first and only, so put in BSS segment
                     */
                    switch (ty & mTYLINK)
                    {
                        case mTYcs:
                            s.Sseg = codeseg;
                            Offset(codeseg) = _align(datasize,Offset(codeseg));
                            s.Soffset = Offset(codeseg);
                            Offset(codeseg) += datasize;
                            s.Sfl = FLcsdata;
                            break;

                        case mTYthreadData:
                            assert(config.objfmt == OBJ_MACH && I64);
                            goto case;
                        case mTYthread:
                        {   seg_data *pseg = objmod.tlsseg_bss();
                            s.Sseg = pseg.SDseg;
                            objmod.data_start(s, datasize, pseg.SDseg);
                            if (config.objfmt == OBJ_OMF)
                                pseg.SDoffset += datasize;
                            else
                                objmod.lidata(pseg.SDseg, pseg.SDoffset, datasize);
                            s.Sfl = FLtlsdata;
                            break;
                        }

                        default:
                            s.Sseg = UDATA;
                            objmod.data_start(s,datasize,UDATA);
                            objmod.lidata(s.Sseg,s.Soffset,datasize);
                            s.Sfl = FLudata;           // uninitialized data
                            break;
                    }
                    assert(s.Sseg && s.Sseg != UNKNOWN);
                    if (s.Sclass == SC.global || (s.Sclass == SC.static_ && config.objfmt != OBJ_OMF)) // if a pubdef to be done
                        objmod.pubdefsize(s.Sseg,s,s.Soffset,datasize);   // do the definition
                    if (config.fulltypes &&
                        !(s.Sclass == SC.static_ && funcsym_p)) // not local static
                    {
                        if (config.objfmt == OBJ_ELF || config.objfmt == OBJ_MACH)
                            dwarf_outsym(s);
                        else
                            cv_outsym(s);
                    }
                    goto Lret;
                }
                break;

            case DT_common:
                assert(!dt.DTnext);
                outcommon(s,dt.DTazeros);
                goto Lret;

            case DT_xoff:
            {   Symbol *sb = dt.DTsym;

                if (tyfunc(sb.ty()))
                {
                }
                else if (sb.Sdt)               // if initializer for symbol
{ if (!s.Sseg) s.Sseg = DATA;
                    outdata(sb);                // write out data for symbol
}
            }
                goto case;
            case DT_coff:
                datasize += size(dt.Dty);
                break;
            default:
                debug
                printf("dt = %p, dt = %d\n",dt,dt.dt);
                assert(0);
        }
    }

    if (s.Sclass == SC.comdat)          // if initialized common block
    {
        seg = objmod.comdatsize(s, datasize);
        switch (ty & mTYLINK)
        {
            case mTYfar:                // if far data
                s.Sfl = FLfardata;
                break;

            case mTYcs:
                s.Sfl = FLcsdata;
                break;

            case mTYnear:
            case 0:
                s.Sfl = FLdata;        // initialized data
                break;

            case mTYthread:
                s.Sfl = FLtlsdata;
                break;

            case mTYweakLinkage:
                s.Sfl = FLdata;        // initialized data
                break;

            default:
                assert(0);
        }
    }
    else
    {
      switch (ty & mTYLINK)
      {
        case mTYcs:
            seg = codeseg;
            Offset(codeseg) = _align(datasize,Offset(codeseg));
            s.Soffset = Offset(codeseg);
            s.Sfl = FLcsdata;
            break;

        case mTYthreadData:
        {
            assert(config.objfmt == OBJ_MACH && I64);

            seg_data *pseg = objmod.tlsseg_data();
            s.Sseg = pseg.SDseg;
            objmod.data_start(s, datasize, s.Sseg);
            seg = pseg.SDseg;
            s.Sfl = FLtlsdata;
            break;
        }
        case mTYthread:
        {
            seg_data *pseg = objmod.tlsseg();
            s.Sseg = pseg.SDseg;
            objmod.data_start(s, datasize, s.Sseg);
            seg = pseg.SDseg;
            s.Sfl = FLtlsdata;
            break;
        }
        case mTYnear:
        case 0:
            if (
                s.Sseg == 0 ||
                s.Sseg == UNKNOWN)
                s.Sseg = DATA;
            seg = objmod.data_start(s,datasize,DATA);
            s.Sfl = FLdata;            // initialized data
            break;

        default:
            assert(0);
      }
    }
    if (s.Sseg == UNKNOWN && (config.objfmt == OBJ_ELF || config.objfmt == OBJ_MACH))
        s.Sseg = seg;
    else if (config.objfmt == OBJ_OMF)
        s.Sseg = seg;
    else
        seg = s.Sseg;

    if (s.Sclass == SC.global || (s.Sclass == SC.static_ && config.objfmt != OBJ_OMF))
        objmod.pubdefsize(seg,s,s.Soffset,datasize);    /* do the definition            */

    assert(s.Sseg != UNKNOWN);
    if (config.fulltypes &&
        !(s.Sclass == SC.static_ && funcsym_p)) // not local static
    {
        if (config.objfmt == OBJ_ELF || config.objfmt == OBJ_MACH)
            dwarf_outsym(s);
        else
            cv_outsym(s);
    }

    /* Go back through list, now that we know its size, and send out    */
    /* the data.                                                        */

    offset = s.Soffset;

    dt_writeToObj(objmod, dtstart, seg, offset);
    Offset(seg) = offset;
Lret:
    dt_free(dtstart);
}


/********************************************
 * Write dt to Object file.
 * Params:
 *      objmod = reference to object file
 *      dt = data to write
 *      seg = segment to write it to
 *      offset = starting offset in segment - will get updated to reflect ending offset
 */

@trusted
void dt_writeToObj(Obj objmod, dt_t *dt, int seg, ref targ_size_t offset)
{
    for (; dt; dt = dt.DTnext)
    {
        switch (dt.dt)
        {
            case DT_abytes:
            {
                int flags;
                if (tyreg(dt.Dty))
                    flags = CFoff;
                else
                    flags = CFoff | CFseg;
                if (I64)
                    flags |= CFoffset64;
                if (tybasic(dt.Dty) == TYcptr)
                    objmod.reftocodeseg(seg,offset,dt.DTabytes);
                else
                {
if (config.exe & EX_posix)
{
                    objmod.reftodatseg(seg,offset,dt.DTabytes,dt.DTseg,flags);
}
else
{
                    if (dt.DTseg == DATA)
                        objmod.reftodatseg(seg,offset,dt.DTabytes,DATA,flags);
                    else
                    {
                        if (dt.DTseg == CDATA)
                            objmod.reftodatseg(seg,offset,dt.DTabytes,CDATA,flags);
                        else
                            assert(0);
                    }
}
                }
                offset += size(dt.Dty);
                break;
            }

            case DT_ibytes:
                objmod.bytes(seg,offset,dt.DTn,dt.DTdata.ptr);
                offset += dt.DTn;
                break;

            case DT_nbytes:
                objmod.bytes(seg,offset,dt.DTnbytes,dt.DTpbytes);
                offset += dt.DTnbytes;
                break;

            case DT_azeros:
                //printf("objmod.lidata(seg = %d, offset = %d, azeros = %d)\n", seg, offset, dt.DTazeros);
                SegData[seg].SDoffset = offset;
                objmod.lidata(seg,offset,dt.DTazeros);
                offset = SegData[seg].SDoffset;
                break;

            case DT_xoff:
            {
                Symbol *sb = dt.DTsym;          // get external symbol pointer
                targ_size_t a = dt.DToffset;    // offset from it
                int flags;
                if (tyreg(dt.Dty))
                    flags = CFoff;
                else
                    flags = CFoff | CFseg;
                if (I64 && tysize(dt.Dty) == 8)
                    flags |= CFoffset64;
                offset += objmod.reftoident(seg,offset,sb,a,flags);
                break;
            }

            case DT_coff:
                objmod.reftocodeseg(seg,offset,dt.DToffset);
                offset += _tysize[TYint];
                break;

            default:
                //printf("dt = %p, dt = %d\n",dt,dt.dt);
                assert(0);
        }
    }
}


/******************************
 * Output n bytes of a common block, n > 0.
 */

@trusted
void outcommon(Symbol *s,targ_size_t n)
{
    //printf("outcommon('%s',%d)\n",s.Sident.ptr,n);
    if (n != 0)
    {
        assert(s.Sclass == SC.global);
        if (s.ty() & mTYcs) // if store in code segment
        {
            /* COMDEFs not supported in code segment
             * so put them out as initialized 0s
             */
            auto dtb = DtBuilder(0);
            dtb.nzeros(cast(uint)n);
            s.Sdt = dtb.finish();
            outdata(s);
        }
        else if (s.ty() & mTYthread) // if store in thread local segment
        {
            if (config.objfmt == OBJ_ELF)
            {
                s.Sclass = SC.comdef;
                objmod.common_block(s, 0, n, 1);
            }
            else
            {
                /* COMDEFs not supported in tls segment
                 * so put them out as COMDATs with initialized 0s
                 */
                s.Sclass = SC.comdat;
                auto dtb = DtBuilder(0);
                dtb.nzeros(cast(uint)n);
                s.Sdt = dtb.finish();
                outdata(s);
            }
        }
        else
        {
            s.Sclass = SC.comdef;
            if (config.objfmt == OBJ_OMF)
            {
                s.Sxtrnnum = objmod.common_block(s,(s.ty() & mTYfar) == 0,n,1);
                if (s.ty() & mTYfar)
                    s.Sfl = FLfardata;
                else
                    s.Sfl = FLextern;
                s.Sseg = UNKNOWN;
                pstate.STflags |= PFLcomdef;
            }
            else
                objmod.common_block(s, 0, n, 1);
        }
        if (config.fulltypes)
        {
            if (config.objfmt == OBJ_ELF || config.objfmt == OBJ_MACH)
                dwarf_outsym(s);
            else
                cv_outsym(s);
        }
    }
}

/*************************************
 * Mark a Symbol as going into a read-only segment.
 */

@trusted
void out_readonly(Symbol *s)
{
    if (config.flags2 & CFG2noreadonly)
        return;
    if (config.objfmt == OBJ_ELF || config.objfmt == OBJ_MACH)
    {
        /* Cannot have pointers in CDATA when compiling PIC code, because
         * they require dynamic relocations of the read-only segment.
         * Instead use the .data.rel.ro section.
         * https://issues.dlang.org/show_bug.cgi?id=11171
         */
        if (config.flags3 & CFG3pic && dtpointers(s.Sdt))
            s.Sseg = CDATAREL;
        else
            s.Sseg = CDATA;
    }
    else
    {
        s.Sseg = CDATA;
    }
}

/*************************************
 * Write out a readonly string literal in an implementation-defined
 * manner.
 * Params:
 *      str = pointer to string data (need not have terminating 0)
 *      len = number of characters in string
 *      sz = size of each character (1, 2 or 4)
 * Returns: a Symbol pointing to it.
 */
@trusted
Symbol *out_string_literal(const(char)* str, uint len, uint sz)
{
    tym_t ty = TYchar;
    if (sz == 2)
        ty = TYchar16;
    else if (sz == 4)
        ty = TYdchar;
    else if (sz == 8)
        ty = TYulong;

    Symbol *s = symbol_generate(SC.static_,type_static_array(len, tstypes[ty]));
    switch (config.objfmt)
    {
        case OBJ_ELF:
        case OBJ_MACH:
            s.Sseg = objmod.string_literal_segment(sz);
            break;

        case OBJ_MSCOFF:
        case OBJ_OMF:   // goes into COMDATs, handled elsewhere
        default:
            assert(0);
    }

    /* If there are any embedded zeros, this can't go in the special string segments
     * which assume that 0 is the end of the string.
     */
    switch (sz)
    {
        case 1:
            if (memchr(str, 0, len))
                s.Sseg = CDATA;
            break;

        case 2:
            foreach (i; 0 .. len)
            {
                auto p = cast(const(ushort)*)str;
                if (p[i] == 0)
                {
                    s.Sseg = CDATA;
                    break;
                }
            }
            break;

        case 4:
            foreach (i; 0 .. len)
            {
                auto p = cast(const(uint)*)str;
                if (p[i] == 0)
                {
                    s.Sseg = CDATA;
                    break;
                }
            }
            break;

        case 8:
            foreach (i; 0.. len)
            {
                auto p = cast(const(ulong)*)str;
                if (p[i] == 0)
                {
                    s.Sseg = CDATA;
                    break;
                }
            }
            break;

        default:
            assert(0);
    }

    auto dtb = DtBuilder(0);
    dtb.nbytes(cast(uint)(len * sz), str);
    dtb.nzeros(cast(uint)sz);       // include terminating 0
    s.Sdt = dtb.finish();
    s.Sfl = FLdata;
    s.Salignment = sz;
    outdata(s);
    return s;
}


/******************************
 * Walk expression tree, converting it from a PARSER tree to
 * a code generator tree.
 */

@trusted
/*private*/ void outelem(elem *e, ref bool addressOfParam)
{
    Symbol *s;
    tym_t tym;
    elem *e1;

again:
    assert(e);
    elem_debug(e);

debug
{
    if (OTbinary(e.Eoper))
        assert(e.E1 && e.E2);
//    else if (OTunary(e.Eoper))
//      assert(e.E1 && !e.E2);
}

    switch (e.Eoper)
    {
    default:
    Lop:
debug
{
        //if (!EOP(e)) printf("e.Eoper = x%x\n",e.Eoper);
}
        if (OTbinary(e.Eoper))
        {   outelem(e.E1, addressOfParam);
            e = e.E2;
        }
        else if (OTunary(e.Eoper))
        {
            e = e.E1;
        }
        else
            break;
        goto again;                     /* iterate instead of recurse   */
    case OPaddr:
        e1 = e.E1;
        if (e1.Eoper == OPvar)
        {   // Fold into an OPrelconst
            tym = e.Ety;
            el_copy(e,e1);
            e.Ety = tym;
            e.Eoper = OPrelconst;
            el_free(e1);
            goto again;
        }
        goto Lop;

    case OPrelconst:
    case OPvar:
        s = e.Vsym;
        assert(s);
        symbol_debug(s);
        switch (s.Sclass)
        {
            case SC.regpar:
            case SC.parameter:
            case SC.shadowreg:
                if (e.Eoper == OPrelconst)
                {
                    if (I16)
                        addressOfParam = true;   // taking addr of param list
                    else
                        s.Sflags &= ~(SFLunambig | GTregcand);
                }
                break;

            case SC.static_:
            case SC.locstat:
            case SC.extern_:
            case SC.global:
            case SC.comdat:
            case SC.comdef:
            case SC.pseudo:
            case SC.inline:
            case SC.sinline:
            case SC.einline:
                s.Sflags |= SFLlivexit;
                goto case;
            case SC.auto_:
            case SC.register:
            case SC.fastpar:
            case SC.bprel:
                if (e.Eoper == OPrelconst)
                {
                    s.Sflags &= ~(SFLunambig | GTregcand);
                }
                else if (s.ty() & mTYfar)
                    e.Ety |= mTYfar;
                break;
            default:
                break;
        }
        break;

    case OPstring:
    case OPconst:
    case OPstrthis:
        break;

    case OPsizeof:
        assert(0);

    }
}

/*************************************
 * Determine register candidates.
 */

@trusted
void out_regcand(symtab_t *psymtab)
{
    //printf("out_regcand()\n");
    const bool ifunc = (tybasic(funcsym_p.ty()) == TYifunc);
    for (SYMIDX si = 0; si < psymtab.length; si++)
    {   Symbol *s = (*psymtab)[si];

        symbol_debug(s);
        //assert(sytab[s.Sclass] & SCSS);      // only stack variables
        s.Ssymnum = si;                        // Ssymnum trashed by cpp_inlineexpand
        if (!(s.ty() & (mTYvolatile | mTYshared)) &&
            !(ifunc && (s.Sclass == SC.parameter || s.Sclass == SC.regpar)) &&
            s.Sclass != SC.static_)
            s.Sflags |= (GTregcand | SFLunambig);      // assume register candidate
        else
            s.Sflags &= ~(GTregcand | SFLunambig);
    }

    bool addressOfParam = false;                  // haven't taken addr of param yet
    for (block *b = bo.startblock; b; b = b.Bnext)
    {
        if (b.Belem)
            out_regcand_walk(b.Belem, addressOfParam);

        // Any assembler blocks make everything ambiguous
        if (b.BC == BCasm)
            for (SYMIDX si = 0; si < psymtab.length; si++)
                (*psymtab)[si].Sflags &= ~(SFLunambig | GTregcand);
    }

    // If we took the address of one parameter, assume we took the
    // address of all non-register parameters.
    if (addressOfParam)                      // if took address of a parameter
    {
        for (SYMIDX si = 0; si < psymtab.length; si++)
            if ((*psymtab)[si].Sclass == SC.parameter || (*psymtab)[si].Sclass == SC.shadowreg)
                (*psymtab)[si].Sflags &= ~(SFLunambig | GTregcand);
    }

}

@trusted
private void out_regcand_walk(elem *e, ref bool addressOfParam)
{
    while (1)
    {   elem_debug(e);

        if (OTbinary(e.Eoper))
        {   if (e.Eoper == OPstreq)
            {   if (e.E1.Eoper == OPvar)
                {
                    Symbol *s = e.E1.Vsym;
                    s.Sflags &= ~(SFLunambig | GTregcand);
                }
                if (e.E2.Eoper == OPvar)
                {
                    Symbol *s = e.E2.Vsym;
                    s.Sflags &= ~(SFLunambig | GTregcand);
                }
            }
            out_regcand_walk(e.E1, addressOfParam);
            e = e.E2;
        }
        else if (OTunary(e.Eoper))
        {
            // Don't put 'this' pointers in registers if we need
            // them for EH stack cleanup.
            if (e.Eoper == OPctor)
            {   elem *e1 = e.E1;

                if (e1.Eoper == OPadd)
                    e1 = e1.E1;
                if (e1.Eoper == OPvar)
                    e1.Vsym.Sflags &= ~GTregcand;
            }
            e = e.E1;
        }
        else
        {   if (e.Eoper == OPrelconst)
            {
                Symbol *s = e.Vsym;
                assert(s);
                symbol_debug(s);
                switch (s.Sclass)
                {
                    case SC.regpar:
                    case SC.parameter:
                    case SC.shadowreg:
                        if (I16)
                            addressOfParam = true;       // taking addr of param list
                        else
                            s.Sflags &= ~(SFLunambig | GTregcand);
                        break;

                    case SC.auto_:
                    case SC.register:
                    case SC.fastpar:
                    case SC.bprel:
                        s.Sflags &= ~(SFLunambig | GTregcand);
                        break;

                    default:
                        break;
                }
            }
            else if (e.Eoper == OPvar)
            {
                if (e.Voffset)
                {   if (!(e.Voffset == 1 && tybyte(e.Ety)) &&
                        !(e.Voffset == REGSIZE && tysize(e.Ety) == REGSIZE))
                    {
                        e.Vsym.Sflags &= ~GTregcand;
                    }
                }
            }
            break;
        }
    }
}


/**************************
 * Optimize function,
 * generate code for it,
 * and write it out.
 */

@trusted
void writefunc(Symbol *sfunc)
{
    import dmd.backend.var : go;
    cstate.CSpsymtab = &globsym;
    writefunc2(sfunc, go);
    cstate.CSpsymtab = null;
}

@trusted
private void writefunc2(Symbol *sfunc, ref GlobalOptimizer go)
{
    func_t *f = sfunc.Sfunc;

    debugb && printf("===================== writefunc %s =================\n",sfunc.Sident.ptr);
    //symbol_print(sfunc);
    debug debugy && printf("writefunc(%s)\n",sfunc.Sident.ptr);

    /* Signify that function has been output                    */
    /* (before inline_do() to prevent infinite recursion!)      */
    f.Fflags &= ~Fpending;
    f.Fflags |= Foutput;

    if (eecontext.EEcompile && eecontext.EEfunc != sfunc)
        return;

    /* Copy local symbol table onto main one, making sure       */
    /* that the symbol numbers are adjusted accordingly */
    //printf("f.Flocsym.length = %d\n",f.Flocsym.length);
    debug debugy && printf("appending symbols to symtab...\n");
    const nsymbols = f.Flocsym.length;
    globsym.setLength(nsymbols);
    foreach (si; 0 .. nsymbols)
        globsym[si] = f.Flocsym[si];

    assert(bo.startblock == null);
    bo.startblock = sfunc.Sfunc.Fstartblock;
    sfunc.Sfunc.Fstartblock = null;
    assert(bo.startblock);

    assert(funcsym_p == null);
    funcsym_p = sfunc;
    tym_t tyf = tybasic(sfunc.ty());

    // TX86 computes parameter offsets in stackoffsets()
    //printf("globsym.length = %d\n", globsym.length);

    foreach (si, s; globsym[])
    {
        symbol_debug(s);
        //printf("symbol %d '%s'\n",si,s.Sident.ptr);

        type_size(s.Stype);    // do any forward template instantiations

        s.Ssymnum = si;        // Ssymnum trashed by cpp_inlineexpand
        s.Sflags &= ~(SFLunambig | GTregcand);
        switch (s.Sclass)
        {
            case SC.bprel:
                s.Sfl = FLbprel;
                goto L3;

            case SC.auto_:
            case SC.register:
                s.Sfl = FLauto;
                goto L3;

            case SC.fastpar:
                s.Sfl = FLfast;
                goto L3;

            case SC.regpar:
            case SC.parameter:
            case SC.shadowreg:
                s.Sfl = FLpara;
                if (tyf == TYifunc)
                {   s.Sflags |= SFLlivexit;
                    break;
                }
            L3:
                if (!(s.ty() & (mTYvolatile | mTYshared)))
                    s.Sflags |= GTregcand | SFLunambig; // assume register candidate   */
                break;

            case SC.pseudo:
                s.Sfl = FLpseudo;
                break;

            case SC.static_:
                break;                  // already taken care of by datadef()

            case SC.stack:
                s.Sfl = FLstack;
                break;

            default:
                symbol_print(*s);
                assert(0);
        }
    }

    bool addressOfParam = false;  // see if any parameters get their address taken
    bool anyasm = false;
    for (block *b = bo.startblock; b; b = b.Bnext)
    {
        memset(&b._BLU,0,block.sizeof - block._BLU.offsetof);
        if (b.Belem)
        {   outelem(b.Belem, addressOfParam);
            if (b.Belem.Eoper == OPhalt)
            {   b.BC = BCexit;
                list_free(&b.Bsucc,FPNULL);
            }
        }
        if (b.BC == BCasm)
            anyasm = true;
        if (sfunc.Sflags & SFLexit && (b.BC == BCret || b.BC == BCretexp))
        {   b.BC = BCexit;
            list_free(&b.Bsucc,FPNULL);
        }
        assert(b != b.Bnext);
    }
    if (eecontext.EEelem)
    {
        const marksi = globsym.length;
        eecontext.EEin++;
        outelem(eecontext.EEelem, addressOfParam);
        eecontext.EEelem = doptelem(eecontext.EEelem, Goal.value);
        eecontext.EEin--;
        eecontext_convs(marksi);
    }

    // If we took the address of one parameter, assume we took the
    // address of all non-register parameters.
    if (addressOfParam | anyasm)        // if took address of a parameter
    {
        foreach (s; globsym[])
            if (anyasm || s.Sclass == SC.parameter)
                s.Sflags &= ~(SFLunambig | GTregcand);
    }

    block_pred();                       // compute predecessors to blocks
    block_compbcount(go);               // eliminate unreachable blocks

    debug { } else
    {
        if (debugb)
        {
            WRfunc("codegen", funcsym_p, bo.startblock);
        }
    }

    if (go.mfoptim)
    {
        OPTIMIZER = 1;
        optfunc(go);                    /* optimize function            */
        OPTIMIZER = 0;
    }
    else
    {
        //printf("blockopt()\n");
        blockopt(go, 0);                /* optimize                     */
    }

    assert(funcsym_p == sfunc);
    const int CSEGSAVE_DEFAULT = -10_000;        // some unlikely number
    int csegsave = CSEGSAVE_DEFAULT;
    if (eecontext.EEcompile != 1)
    {
        if (symbol_iscomdat2(sfunc))
        {
            csegsave = cseg;
            objmod.comdat(sfunc);
            cseg = sfunc.Sseg;
        }
        else if (config.flags & CFGsegs) // if user set switch for this
        {
            objmod.codeseg(&funcsym_p.Sident[0], 1);
                                        // generate new code segment
        }
        cod3_align(cseg);               // align start of function
        objmod.func_start(sfunc);
    }

    //printf("codgen()\n");
    codgen(sfunc);                  // generate code
    //printf("after codgen for %s Coffset %x\n",sfunc.Sident.ptr,Offset(cseg));
    sfunc.Sfunc.Fstartblock = bo.startblock;
    bool saveForInlining = canInlineFunction(sfunc);
    if (saveForInlining)
    {
        bo.startblock = null;
    }
    else
    {
        sfunc.Sfunc.Fstartblock = null;
        blocklist_free(&bo.startblock);
    }

    objmod.func_term(sfunc);
    if (eecontext.EEcompile == 1)
        goto Ldone;
    if (sfunc.Sclass == SC.global)
    {
        if ((config.objfmt == OBJ_OMF || config.objfmt == OBJ_MSCOFF) && !(config.flags4 & CFG4allcomdat))
        {
            assert(sfunc.Sseg == cseg);
            objmod.pubdef(sfunc.Sseg,sfunc,sfunc.Soffset);       // make a public definition
        }

        addStartupReference(sfunc);
    }

    if (config.wflags & WFexpdef &&
        sfunc.Sclass != SC.static_ &&
        sfunc.Sclass != SC.sinline &&
        !(sfunc.Sclass == SC.inline && !(config.flags2 & CFG2comdat)) &&
        sfunc.ty() & mTYexport)
        objmod.export_symbol(sfunc,cast(uint)cgstate.Para.offset);      // export function definition

    if (config.fulltypes && config.fulltypes != CV8)
    {
        if (config.objfmt == OBJ_OMF || config.objfmt == OBJ_MSCOFF)
            cv_func(sfunc);                 // debug info for function
    }

    /* This is to make uplevel references to SCfastpar variables
     * from nested functions work.
     */
    foreach (s; globsym[])
    {
        switch (s.Sclass)
        {   case SC.fastpar:
                s.Sclass = SC.auto_;
                break;

            default:
                break;
        }
    }
    /* After codgen() and writing debug info for the locals,
     * readjust the offsets of all stack variables so they
     * are relative to the frame pointer.
     * Necessary for nested function access to lexically enclosing frames.
     */
     cod3_adjSymOffsets();

    if (symbol_iscomdat2(sfunc))         // if generated a COMDAT
    {
        assert(csegsave != CSEGSAVE_DEFAULT);
        objmod.setcodeseg(csegsave);       // reset to real code seg
        if (config.objfmt == OBJ_MACH)
            assert(cseg == CODE);
    }

    /* Check if function is a constructor or destructor, by     */
    /* seeing if the function name starts with _STI or _STD     */
    {
version (LittleEndian)
{
        short *p = cast(short *) sfunc.Sident.ptr;
        if (p[0] == (('S' << 8) | '_') && (p[1] == (('I' << 8) | 'T') || p[1] == (('D' << 8) | 'T')))
            objmod.setModuleCtorDtor(sfunc, sfunc.Sident.ptr[3] == 'I');
}
else
{
        char *p = sfunc.Sident.ptr;
        if (p[0] == '_' && p[1] == 'S' && p[2] == 'T' &&
            (p[3] == 'I' || p[3] == 'D'))
            objmod.setModuleCtorDtor(sfunc, sfunc.Sident.ptr[3] == 'I');
}
    }

Ldone:
    funcsym_p = null;

    if (saveForInlining)
    {
        f.Flocsym.setLength(globsym.length);
        foreach (si, s; globsym[])
            f.Flocsym[si] = s;
    }
    else
    {
    }
    globsym.setLength(0);

    //printf("done with writefunc()\n");
    //dfo.dtor();       // save allocation for next time
}

/*************************
 * Align segment offset.
 * Input:
 *      seg             segment to be aligned
 *      datasize        size in bytes of object to be aligned
 */

@trusted
void alignOffset(int seg,targ_size_t datasize)
{
    targ_size_t alignbytes = _align(datasize,Offset(seg)) - Offset(seg);
    //printf("seg %d datasize = x%x, Offset(seg) = x%x, alignbytes = x%x\n",
      //seg,datasize,Offset(seg),alignbytes);
    if (alignbytes)
        objmod.lidata(seg,Offset(seg),alignbytes);
}

/***************************************
 * Write data into read-only data segment.
 * Return symbol for it.
 */

enum ROMAX = 32;
struct Readonly
{
    Symbol *sym;
    size_t length;
    ubyte[ROMAX] p;
}

enum RMAX = 16;
private __gshared
{
    Readonly[RMAX] readonly;
    size_t readonly_length;
    size_t readonly_i;
}

@trusted
void out_reset()
{
    readonly_length = 0;
    readonly_i = 0;
}

@trusted
Symbol *out_readonly_sym(tym_t ty, void *p, int len)
{
static if (0)
{
    printf("out_readonly_sym(ty = x%x)\n", ty);
    for (int i = 0; i < len; i++)
        printf(" [%d] = %02x\n", i, (cast(ubyte*)p)[i]);
}
    // Look for previous symbol we can reuse
    for (int i = 0; i < readonly_length; i++)
    {
        Readonly *r = &readonly[i];
        if (r.length == len && memcmp(p, r.p.ptr, len) == 0)
            return r.sym;
    }

    Symbol *s;

    bool cdata = config.objfmt == OBJ_ELF ||
                 config.objfmt == OBJ_OMF ||
                 config.objfmt == OBJ_MSCOFF;
    if (cdata)
    {
        /* MACHOBJ can't go here, because the const data segment goes into
         * the _TEXT segment, and one cannot have a fixup from _TEXT to _TEXT.
         */
        s = objmod.sym_cdata(ty, cast(char *)p, len);
    }
    else
    {
        uint sz = tysize(ty);

        alignOffset(DATA, sz);
        s = symboldata(Offset(DATA),ty | mTYconst);
        s.Sseg = DATA;
        objmod.write_bytes(SegData[DATA], p[0 .. len]);
        //printf("s.Sseg = %d:x%x\n", s.Sseg, s.Soffset);
    }

    if (len <= ROMAX)
    {   Readonly *r;

        if (readonly_length < RMAX)
        {
            r = &readonly[readonly_length];
            readonly_length++;
        }
        else
        {   r = &readonly[readonly_i];
            readonly_i++;
            if (readonly_i >= RMAX)
                readonly_i = 0;
        }
        r.length = len;
        r.sym = s;
        memcpy(r.p.ptr, p, len);
    }
    return s;
}

/*************************************
 * Output Symbol as a readonly comdat.
 * Params:
 *      s = comdat symbol
 *      p = pointer to the data to write
 *      len = length of that data
 *      nzeros = number of trailing zeros to append
 */
@trusted
void out_readonly_comdat(Symbol *s, const(void)* p, uint len, uint nzeros)
{
    objmod.readonly_comdat(s);         // create comdat segment
    objmod.write_bytes(SegData[s.Sseg], p[0 .. len]);
    objmod.lidata(s.Sseg, len, nzeros);
}

@trusted
void Srcpos_print(ref const Srcpos srcpos, const(char)* func)
{
    printf("%s(", func);
    printf("Sfilename = %s", srcpos.Sfilename ? srcpos.Sfilename : "null".ptr);
    printf(", Slinnum = %u", srcpos.Slinnum);
    printf(")\n");
}

/*********************************************
 * If sfunc is the entry point, add a reference to pull
 * in the startup code.
 * Params:
 *      sfunc = function
 */
private
@trusted
void addStartupReference(Symbol* sfunc)
{
}
