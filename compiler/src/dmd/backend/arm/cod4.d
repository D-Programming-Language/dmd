/**
 * Code generation 4
 *
 * Includes:
 * - assignemt variations of operators (+= -= *= /= %= <<= >>=)
 * - integer comparison (< > <= >=)
 * - converting integers to a different size (e.g. short to int)
 * - bit instructions (bit scan, population count)
 *
 * Compiler implementation of the
 * $(LINK2 https://www.dlang.org, D programming language).
 *
 * Mostly code generation for assignment operators.
 *
 * Copyright:   Copyright (C) 1985-1998 by Symantec
 *              Copyright (C) 2000-2024 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 https://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/src/dmd/backend/arm/cod4.d, backend/cod4.d)
 * Documentation:  https://dlang.org/phobos/dmd_backend_arm_cod4.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/backend/arm/cod4.d
 */

module dmd.backend.arm.cod4;

import core.stdc.stdio;
import core.stdc.stdlib;
import core.stdc.string;

import dmd.backend.cc;
import dmd.backend.cdef;
import dmd.backend.cg : datafl;
import dmd.backend.code;
import dmd.backend.x86.code_x86;
import dmd.backend.codebuilder;
import dmd.backend.divcoeff : choose_multiplier, udiv_coefficients;
import dmd.backend.mem;
import dmd.backend.el;
import dmd.backend.global;
import dmd.backend.oper;
import dmd.backend.ty;
import dmd.backend.evalu8 : el_toldoubled;
import dmd.backend.x86.xmm;
import dmd.backend.arm.cod1 : getlvalue, loadFromEA, storeToEA;
import dmd.backend.arm.cod3 : COND, conditionCode, gentstreg;
import dmd.backend.arm.instr;


nothrow:
@safe:

/************************
 * Generate code for an assignment, OPeq.
 */
@trusted
void cdeq(ref CGstate cg, ref CodeBuilder cdb,elem* e,ref regm_t pretregs)
{
    //printf("cdeq(e = %p, pretregs = %s)\n",e,regm_str(pretregs));
    //elem_print(e);

    reg_t reg;
    code cs;
    elem* e11;
    bool regvar;                  // true means evaluate into register variable
    regm_t varregm = 0;
    reg_t varreg;
    targ_int postinc;

    elem* e1 = e.E1;
    elem* e2 = e.E2;
    int e2oper = e2.Eoper;
    tym_t tyml = tybasic(e1.Ety);              // type of lvalue
    regm_t retregs = pretregs;
    regm_t allregs = tyfloating(tyml) ? INSTR.FLOATREGS : cgstate.allregs;

    if (0 && tyxmmreg(tyml))
    {
        xmmeq(cdb, e, CMP, e1, e2, pretregs);
        return;
    }

    uint sz = _tysize[tyml];           // # of bytes to transfer
    assert(cast(int)sz > 0);

    if (retregs == 0)                     // if no return value
    {
        /* If registers are tight, and we might need them for the lvalue,
         * prefer to not use them for the rvalue
         */
        bool plenty = true;
        if (e1.Eoper == OPind)
        {
            /* Will need 1 register for evaluation, +2 registers for
             * e1's addressing mode
             */
            regm_t m = allregs & ~cgstate.regcon.mvar;  // mask of non-register variables
            m &= m - 1;         // clear least significant bit
            m &= m - 1;         // clear least significant bit
            plenty = m != 0;    // at least 3 registers
        }

        if (e2oper == OPconst &&       // if rvalue is a constant
            !(evalinregister(e2) && plenty) &&
            !e1.Ecount)        // and no CSE headaches
        {
            // Look for special case of (*p++ = ...), where p is a register variable
            if (e1.Eoper == OPind &&
                ((e11 = e1.E1).Eoper == OPpostinc || e11.Eoper == OPpostdec) &&
                e11.E1.Eoper == OPvar &&
                e11.E1.Vsym.Sfl == FL.reg
               )
            {
                Symbol* s = e11.E1.Vsym;
                if (s.Sclass == SC.fastpar || s.Sclass == SC.shadowreg)
                {
                    cgstate.regcon.params &= ~s.Spregm();
                }
                postinc = e11.E2.Vint;
                if (e11.Eoper == OPpostdec)
                    postinc = -postinc;
                getlvalue(cdb,cs,e1,0,RM.store);
                freenode(e11.E2);
            }
            else
            {
                postinc = 0;
                getlvalue(cdb,cs,e1,0,RM.store);
            }

            // If loading result into a register
            if (cs.reg != NOREG)
            {
                getregs(cdb, cs.reg);
                const p = cast(targ_size_t*) &(e2.EV);
                movregconst(cdb,cs.reg,*p,sz == 8);
                freenode(e2);
                goto Lp;
            }
        }
        retregs = allregs;        // pick a reg, any reg
    }
    if (retregs == mPSW)
    {
        retregs = allregs;
    }
    cs.Iop = 0;
    regvar = false;
    if (config.flags4 & CFG4optimized)
    {
        // Be careful of cases like (x = x+x+x). We cannot evaluate in
        // x if x is in a register.
        if (isregvar(e1,varregm,varreg) &&    // if lvalue is register variable
            doinreg(e1.Vsym,e2) &&       // and we can compute directly into it
            !(sz == 1 && e1.Voffset == 1)
           )
        {
            if (0 && varregm & XMMREGS)
            {
                // Could be an integer vector in the XMMREGS
                xmmeq(cdb, e, CMP, e1, e2, pretregs);
                return;
            }
            regvar = true;
            retregs = varregm;
            reg = varreg;       // evaluate directly in target register
        }
    }
    if (pretregs & mPSW && OTleaf(e1.Eoper))     // if evaluating e1 couldn't change flags
    {   // Be careful that this lines up with jmpopcode()
        retregs |= mPSW;
        pretregs &= ~mPSW;
    }
    scodelem(cgstate,cdb,e2,retregs,0,true);    // get rvalue

    // Look for special case of (*p++ = ...), where p is a register variable
    if (e1.Eoper == OPind &&
        ((e11 = e1.E1).Eoper == OPpostinc || e11.Eoper == OPpostdec) &&
        e11.E1.Eoper == OPvar &&
        e11.E1.Vsym.Sfl == FL.reg)
    {
        Symbol* s = e11.E1.Vsym;
        if (s.Sclass == SC.fastpar || s.Sclass == SC.shadowreg)
        {
            cgstate.regcon.params &= ~s.Spregm();
        }

        postinc = e11.E2.Vint;
        if (e11.Eoper == OPpostdec)
            postinc = -postinc;
        getlvalue(cdb,cs,e1,retregs,RM.store);
        freenode(e11.E2);
    }
    else
    {
        postinc = 0;
        getlvalue(cdb,cs,e1,retregs,RM.store);     // get lvalue (cl == null if regvar)
    }

    getregs(cdb,varregm);

    reg = findreg(retregs & allregs);
    storeToEA(cs,reg,sz);
    cdb.gen(&cs);

    if (e1.Ecount ||                    // if lvalue is a CSE or
        regvar)                         // rvalue can't be a CSE
    {
        getregs_imm(cdb,retregs);       // necessary if both lvalue and
                                        //  rvalue are CSEs (since a reg
                                        //  can hold only one e at a time)
        cssave(e1,retregs,!OTleaf(e1.Eoper));     // if lvalue is a CSE
    }

    fixresult(cdb,e,retregs,pretregs);
Lp:
    if (postinc)
    {
        reg_t ireg = cs.base;
        uint sh = 0;
        uint op = postinc > 0 ? 0 : 1; // ADD/SUB
        uint imm12 = postinc > 0 ? postinc : -postinc;
        if (postinc && (imm12 & 0xFFF) == 0)
        {
            imm12 >>= 12;
            sh = 1;
        }
        assert(imm12 < 0x1000);  // should use movregconst() if this assert trips
        uint ins = INSTR.addsub_imm(sz == 8,0,op,sh,postinc,ireg,ireg); // ADD/SUB ireg,ireg,imm12,shift
        cdb.gen1(ins);
    }
    freenode(e1);
}

/************************
 * Generate code for += -= &= |= ^= negass
 */

@trusted
void cdaddass(ref CGstate cg, ref CodeBuilder cdb,elem* e,ref regm_t pretregs)
{
    //printf("cdaddass(e=%p, pretregs = %s)\n",e,regm_str(pretregs));
    OPER op = e.Eoper;
    regm_t retregs = 0;
    elem* e1 = e.E1;
    tym_t tyml = tybasic(e1.Ety);            // type of lvalue
    int sz = _tysize[tyml];
    int isbyte = (sz == 1);                     // 1 for byte operation, else 0

    // See if evaluate in XMM registers
    if (0 && config.fpxmmregs && tyxmmreg(tyml) && op != OPnegass)
    {
        xmmopass(cdb,e,pretregs);
        return;
    }

    if (tyfloating(tyml))
    {
	floatOpAss(cdb,e,pretregs);
	return;
    }
    regm_t forccs = pretregs & mPSW;            // return result in flags
    regm_t forregs = pretregs & ~mPSW;          // return result in regs
    // true if we want the result in a register
    uint wantres = forregs || (e1.Ecount && !OTleaf(e1.Eoper));
    wantres = true; // dunno why the above is conditional

    reg_t reg;
    code cs;
    elem* e2;
    uint jop;


    switch (op)                   // select instruction opcodes
    {
        case OPpostinc: op = OPaddass;                  // i++ => +=
                        goto case OPaddass;

        case OPpostdec: op = OPminass;                  // i-- => -=
                        goto case OPminass;

        case OPaddass:
        case OPminass:
        case OPandass:
        case OPorass:
        case OPxorass:
        case OPnegass:  break;

        default:
                assert(0);
    }

    if (op == OPnegass)
    {
        getlvalue(cdb,cs,e1,0);
        if (cs.reg == NOREG)
        {
            regm_t keepmsk = mask(cs.base) | mask(cs.index);
            retregs = forregs & ~keepmsk;
            if (!retregs)
                retregs = cg.allregs & ~keepmsk;
            reg = allocreg(cdb,retregs,tyml);
        }
        else
        {
            retregs = mask(cs.reg);
            getregs(cdb,retregs);
            reg = cs.reg;
        }
        uint szw = sz == 8 ? 8 : 4;
        loadFromEA(cs, reg, szw, sz);
        cdb.gen(&cs);
        // negate reg
        uint sf = sz == 8;
        uint S = forccs != 0;
        uint ins = INSTR.neg_sub_addsub_shift(sf,S,0,reg,0,cs.reg);
        cdb.gen1(ins);
        storeToEA(cs, reg, sz);
        cdb.gen(&cs);

        retregs = mask(reg);
        forccs = 0;             // flags already set by NEGS
        pretregs &= ~mPSW;
    }
    else if (0 && (op == OPaddass || op == OPminass) &&
        !e2.Ecount &&
        ((jop = jmpopcode(e2)) == JC || jop == JNC ||
         (OTconv(e2.Eoper) && !e2.E1.Ecount && ((jop = jmpopcode(e2.E1)) == JC || jop == JNC)))
       )
    {
        /* e1 += (x < y)    ADC EA,0
         * e1 -= (x < y)    SBB EA,0
         * e1 += (x >= y)   SBB EA,-1
         * e1 -= (x >= y)   ADC EA,-1
         */
        getlvalue(cdb,cs,e1,0);             // get lvalue
        modEA(cdb,&cs);
        regm_t keepmsk = idxregm(&cs);
        retregs = mPSW;
        if (OTconv(e2.Eoper))
        {
            scodelem(cgstate,cdb,e2.E1,retregs,keepmsk,true);
            freenode(e2);
        }
        else
            scodelem(cgstate,cdb,e2,retregs,keepmsk,true);
        cs.Iop = 0x81 ^ isbyte;                   // ADC EA,imm16/32
        uint regop = 2;                     // ADC
        if ((op == OPaddass) ^ (jop == JC))
            regop = 3;                          // SBB
        code_newreg(&cs,regop);
        //cs.Iflags |= opsize;
        if (forccs)
            cs.Iflags |= CFpsw;
        cs.IFL2 = FL.const_;
        cs.IEV2.Vsize_t = (jop == JC) ? 0 : ~cast(targ_size_t)0;
        cdb.gen(&cs);
        retregs = 0;            // to trigger a bug if we attempt to use it
    }
    else // evaluate e2 into register
    {
        retregs = cg.allregs;                        // pick working reg
        scodelem(cgstate,cdb,e.E2,retregs,0,true);   // get rvalue
        getlvalue(cdb,cs,e1,retregs);                // get lvalue
        reg_t reg1;
        if (cs.reg)
            reg1 = cs.reg;
        else
        {
            regm_t posregs = cg.allregs & ~(retregs | mask(cs.base) | mask(cs.index));
            reg1 = allocreg(cdb,posregs,tyml);
        }
        getregs(cdb,mask(reg1));
        loadFromEA(cs,reg1,sz == 8 ? 8 : 4, sz);
        cdb.gen(&cs);

        reg_t reg2 = findreg(retregs);

        // OP reg1,reg2
        uint sf = sz == 8;
        uint imm3 = 0;                // shift amount
        uint S = forccs != 0;
        uint opt = 0;
        uint option = 0;
        reg_t Rm = reg2;
        reg_t Rn = reg1;
        reg_t Rd = reg1;
        uint ins;
        switch (op)                   // select instruction opcodes
        {
            case OPaddass:
                ins = INSTR.addsub_ext(sf,0,S,opt,Rm,option,imm3,Rn,Rd); // ADD/ADDS
                pretregs &= ~mPSW;                                       // flags are already set
                break;
            case OPminass:
                ins = INSTR.addsub_ext(sf,1,S,opt,Rm,option,imm3,Rn,Rd); // SUB/SUBS
                pretregs &= ~mPSW;                                       // flags are already set
                break;
            case OPandass:
                ins = INSTR.log_shift(sf,S?3:0,0,0,Rm,0,Rn,Rd);  // AND/ANDS
                pretregs &= ~mPSW;                               // flags are already set
                break;
            case OPorass:
                ins = INSTR.log_shift(sf,1,0,0,Rm,0,Rn,Rd);      // ORR
                break;
            case OPxorass:
                ins = INSTR.log_shift(sf,2,0,0,Rm,0,Rn,Rd);      // EOR
                break;
            default:
                assert(0);
        }
        cdb.gen1(ins);

        storeToEA(cs,reg1,sz);
        if (forccs)
            cs.Iflags |= CFpsw;
        cdb.gen(&cs);
        retregs = mask(reg1);
    }

    // See if we need to reload result into a register.
    // Need result in registers in case we have a 32 bit
    // result and we want the flags as a result.
    if (wantres)
    {
        if (e1.Ecount)                 // if we gen a CSE
            cssave(e1,retregs,!OTleaf(e1.Eoper));
    }
    freenode(e1);
    fixresult(cdb,e,retregs,pretregs);
}

/********************************
 * Generate code for op=
 */
@trusted
void floatOpAss(ref CodeBuilder cdb,elem* e,ref regm_t pretregs)
{
    printf("floatOpass(e=%p, pretregs = %s)\n",e,regm_str(pretregs));
    elem_print(e);
    elem* e1 = e.E1;
    elem* e2 = e.E2;
    tym_t ty1 = tybasic(e1.Ety);
    const sz1 = _tysize[ty1];
    regm_t rretregs = INSTR.FLOATREGS & ~pretregs;
    if (!rretregs)
        rretregs = INSTR.FLOATREGS;

rretregs = 1L << 34; // until loaddata() works
    codelem(cgstate,cdb,e2,rretregs,false); // eval right leaf
    reg_t rreg = findreg(rretregs);

    code cs;
    regm_t retregs;
    reg_t reg;
    bool regvar = false;
    if (config.flags4 & CFG4optimized)
    {
        // Be careful of cases like (x = x+x+x). We cannot evaluate in
        // x if x is in a register.
        reg_t varreg;
        regm_t varregm;
        if (isregvar(e1,varregm,varreg) && // if lvalue is register variable
            doinreg(e1.Vsym,e2)            // and we can compute directly into it
           )
        {   regvar = true;
            retregs = varregm;
            reg = varreg;               // evaluate directly in target register
            getregs(cdb,retregs);       // destroy these regs
        }
    }

    if (!regvar)
    {
        getlvalue(cdb,cs,e1,rretregs,RM.rw);         // get EA
        retregs = pretregs & INSTR.FLOATREGS & ~rretregs;
        if (!retregs)
            retregs = INSTR.FLOATREGS & ~rretregs;
        reg = allocreg(cdb,retregs,ty1);
	loadFromEA(cs,reg,sz1,sz1);
	cdb.gen(&cs);
    }

    reg_t Rd = reg, Rn = rreg, Rm = reg;
    uint ftype = sz1 == 2 ? 3 :
		 sz1 == 4 ? 0 : 1;
    switch (e.Eoper)
    {
	// FADD/FSUB (extended register)
	// http://www.scs.stanford.edu/~zyedidia/arm64/encodingindex.html#addsub_ext
	case OPaddass:
	    cdb.gen1(INSTR.fadd_float(ftype,Rm,Rn,Rd));     // FADD Rd,Rn,Rm
	    break;

	case OPminass:
	    cdb.gen1(INSTR.fsub_float(ftype,Rm,Rn,Rd));     // FSUB Rd,Rn,Rm
	    break;

	case OPmulass:
	    cdb.gen1(INSTR.fmul_float(ftype,Rm,Rn,Rd));     // FMUL Rd,Rn,Rm
	    break;

	case OPdivass:
	    cdb.gen1(INSTR.fdiv_float(ftype,Rm,Rn,Rd));     // FDIV Rd,Rn,Rm
	    break;

	default:
	    assert(0);
    }

    if (!regvar)
    {
        storeToEA(cs,reg,sz1);
        cdb.gen(&cs);
    }

    if (e1.Ecount ||                     // if lvalue is a CSE or
        regvar)                          // rvalue can't be a CSE
    {
        getregs_imm(cdb,retregs);        // necessary if both lvalue and
                                         //  rvalue are CSEs (since a reg
                                         //  can hold only one e at a time)
        cssave(e1,retregs,!OTleaf(e1.Eoper)); // if lvalue is a CSE
    }

    fixresult(cdb,e,retregs,pretregs);
    freenode(e1);
}

/********************************
 * Generate code for *=
 */

@trusted
void cdmulass(ref CGstate cg, ref CodeBuilder cdb,elem* e,ref regm_t pretregs)
{
    code cs;

    //printf("cdmulass(e=%p, pretregs = %s)\n",e,regm_str(pretregs));
    elem* e1 = e.E1;
    elem* e2 = e.E2;
    OPER op = e.Eoper;                     // OPxxxx

    tym_t tyml = tybasic(e1.Ety);              // type of lvalue
    uint sz = _tysize[tyml];

    // See if evaluate in XMM registers
    if (0 && config.fpxmmregs && tyxmmreg(tyml) && !(pretregs & mST0))
    {
        xmmopass(cdb,e,pretregs);
        return;
    }

    if (tyfloating(tyml))
    {
	floatOpAss(cdb,e,pretregs);
	return;
    }

    assert(sz <= REGSIZE);
    regm_t regm2 = ~pretregs & cg.allregs;
    if (!regm2)
        regm2 = cg.allregs;
    codelem(cgstate,cdb,e2,regm2,false); // load rvalue in reg2
    reg_t reg2 = findreg(regm2);
    getlvalue(cdb,cs,e1,regm2);  // get EA
    regm_t earegm = mask(cs.base) | mask(cs.index);
    regm_t retregs;
    reg_t reg;
    if (cs.reg)
    {
        reg = cs.reg;
        retregs = mask(reg);
    }
    else
    {
        retregs = cg.allregs & ~earegm & ~regm2;
        reg = allocreg(cdb,retregs,tyml);
        loadFromEA(cs,reg,sz,sz == 8 ? 8 : 4);
        cdb.gen(&cs);
    }
    getregs(cdb,retregs);           // destroy these regs
                                // MUL reg,reg,reg2
    // http://www.scs.stanford.edu/~zyedidia/arm64/mul_madd.html
    // MADD Rd,Rn,Rm,Rzr  Rd = Rn * Rm + Rzr
    reg_t Rd = reg;
    reg_t Rn = reg;
    reg_t Rm = reg2;
    cdb.gen1(INSTR.madd(sz == 8, Rm, 31, Rn, Rd));

    storeToEA(cs,reg,sz);
    cdb.gen(&cs);

    if (e1.Ecount)                 // if we gen a CSE
        cssave(e1,retregs,!OTleaf(e1.Eoper));
    freenode(e1);

    fixresult(cdb,e,retregs,pretregs);
}

/********************************
 * Generate code for /= %=
 */

@trusted
void cddivass(ref CGstate cg, ref CodeBuilder cdb,elem* e,ref regm_t pretregs)
{
    elem* e1 = e.E1;
    elem* e2 = e.E2;

    tym_t tyml = tybasic(e1.Ety);              // type of lvalue
    OPER op = e.Eoper;                     // OPxxxx

    // See if evaluate in XMM registers
    if (0 && config.fpxmmregs && tyxmmreg(tyml) && op != OPmodass && !(pretregs & mST0))
    {
        xmmopass(cdb,e,pretregs);
        return;
    }

    if (tyfloating(tyml))
    {
	floatOpAss(cdb,e,pretregs);
	return;
    }

    code cs;

    //printf("cddivass(e=%p, pretregs = %s)\n",e,regm_str(pretregs));
    bool uns = tyuns(tyml) || tyuns(e2.Ety);
    uint sz = _tysize[tyml];

    assert(sz <= REGSIZE);

    regm_t Rdivisorm = ~pretregs & cg.allregs;
    if (!Rdivisorm)
        Rdivisorm = cg.allregs;
    codelem(cgstate,cdb,e2,Rdivisorm,false); // load rvalue in Rdivisor
    reg_t Rdivisor = findreg(Rdivisorm);
    getlvalue(cdb,cs,e1,Rdivisorm);  // get EA
    regm_t earegm = mask(cs.base) | mask(cs.index);
    regm_t retregs;
    reg_t Rdividend;
    if (cs.reg)
    {
        Rdividend = cs.reg;
        retregs = mask(Rdividend);
    }
    else
    {
        retregs = cg.allregs & ~earegm & ~Rdivisorm;
        Rdividend = allocreg(cdb,retregs,tyml);
        loadFromEA(cs,Rdividend,sz,sz == 8 ? 8 : 4);
        cdb.gen(&cs);
    }

    reg_t Rquo;
    if (e.Eoper == OPmodass)
    {
        retregs = cg.allregs & ~earegm & ~Rdivisorm & ~mask(Rdividend);
        Rquo = allocreg(cdb,retregs,tyml);
    }
    else
        Rquo = Rdividend;

    getregs(cdb,mask(Rquo));           // destroy these regs

    // DIV Rd, Rn, Rm
    uint ins = INSTR.sdiv_udiv(sz == 8,uns,Rdivisor,Rdividend,Rquo);
    cdb.gen1(ins);
    reg_t reg = Rquo;

    if (e.Eoper == OPmodass)
    {
        retregs = cg.allregs & ~earegm;
        reg_t Rmod = allocreg(cdb,retregs,tyml);
        getregs(cdb,mask(Rmod));
        uint ins2 = INSTR.msub(sz == 8,Rdivisor,Rdividend,Rquo,Rmod);
        cdb.gen1(ins2);
        reg = Rmod;
    }

    storeToEA(cs,reg,sz);
    cdb.gen(&cs);

    retregs = mask(reg);
    if (e1.Ecount)                 // if we gen a CSE
        cssave(e1,retregs,!OTleaf(e1.Eoper));
    freenode(e1);

    fixresult(cdb,e,retregs,pretregs);
}

/********************************
 * Generate code for OPshrass, OPashrass, OPshlass (>>=, >>>=, <<=)
 */

@trusted
void cdshass(ref CGstate cg, ref CodeBuilder cdb,elem* e,ref regm_t pretregs)
{
    //printf("cdshass(e=%p, pretregs = %s)\n",e,regm_str(pretregs));
    elem* e1 = e.E1;
    elem* e2 = e.E2;

    tym_t tyml = tybasic(e1.Ety);              // type of lvalue

    code cs;

    uint sz = _tysize[tyml];
    assert(sz <= REGSIZE);

    regm_t Rshiftcntm = ~pretregs & cg.allregs;
    if (!Rshiftcntm)
        Rshiftcntm = cg.allregs;
    codelem(cgstate,cdb,e2,Rshiftcntm,false); // load rvalue in Rshiftcnt
    reg_t Rshiftcnt = findreg(Rshiftcntm);
    getlvalue(cdb,cs,e1,Rshiftcntm);  // get EA
    regm_t earegm = mask(cs.base) | mask(cs.index);
    regm_t retregs;
    reg_t Rshiftee;
    if (cs.reg)
    {
        Rshiftee = cs.reg;
        retregs = mask(Rshiftee);
    }
    else
    {
        retregs = cg.allregs & ~earegm & ~Rshiftcntm;
        Rshiftee = allocreg(cdb,retregs,tyml);
        loadFromEA(cs,Rshiftee,sz,sz == 8 ? 8 : 4);
        cdb.gen(&cs);
    }

    reg_t Rresult;
    if (e.Eoper == OPmodass)
    {
        retregs = cg.allregs & ~earegm & ~Rshiftcntm & ~mask(Rshiftee);
        Rresult = allocreg(cdb,retregs,tyml);
    }
    else
        Rresult = Rshiftee;

    getregs(cdb,mask(Rresult));           // destroy these regs

    /* https://www.scs.stanford.edu/~zyedidia/arm64/encodingindex.html#dp_2src
     * https://www.scs.stanford.edu/~zyedidia/arm64/lsl_lslv.html
     * https://www.scs.stanford.edu/~zyedidia/arm64/lsr_lsrv.html
     * https://www.scs.stanford.edu/~zyedidia/arm64/asr_asrv.html
     * https://www.scs.stanford.edu/~zyedidia/arm64/ror_rorv.html
     */
    uint S = 0;
    uint opcode;
    switch (e.Eoper)
    {
        case OPshl:     opcode = 0x8;   break;
        case OPshr:     opcode = 0x9;   break;
        case OPashr:    opcode = 0xA;   break;
        //case OPror:     opcode = 0xB;   break;
        default:
            assert(0);
    }

    // DIV Rd, Rn, Rm

    uint ins = INSTR.dp_2src(sz == 8,S,Rshiftcnt,opcode,Rshiftee,Rresult);
    cdb.gen1(ins);
    reg_t reg = Rresult;

    storeToEA(cs,reg,sz);
    cdb.gen(&cs);

    retregs = mask(reg);
    if (e1.Ecount)                 // if we gen a CSE
        cssave(e1,retregs,!OTleaf(e1.Eoper));
    freenode(e1);

    fixresult(cdb,e,retregs,pretregs);
}

/**********************************
 * Generate code for compares.
 * Handles lt,gt,le,ge,eqeq,ne for all data types.
 */

@trusted
void cdcmp(ref CGstate cg, ref CodeBuilder cdb,elem* e,ref regm_t pretregs)
{
    //printf("cdcmp(e = %p, pretregs = %s)\n",e,regm_str(pretregs));
    //elem_print(e);

    regm_t retregs,rretregs;
    reg_t reg,rreg;

    // Collect extra parameter. This is pretty ugly...
    int flag = cg.cmp_flag;
    cg.cmp_flag = 0;

    elem* e1 = e.E1;
    elem* e2 = e.E2;
    if (pretregs == 0)                 // if don't want result
    {
        codelem(cgstate,cdb,e1,pretregs,false);
        pretregs = 0;                  // in case e1 changed it
        codelem(cgstate,cdb,e2,pretregs,false);
        return;
    }

    if (tyvector(tybasic(e1.Ety)))
        return orthxmm(cdb,e,pretregs);

    COND jop = conditionCode(e);        // must be computed before
                                        // leaves are free'd
    uint reverse = 0;

    OPER op = e.Eoper;
    assert(OTrel(op));
    //bool eqorne = (op == OPeqeq) || (op == OPne);

    tym_t tym = tybasic(e1.Ety);
    uint sz = _tysize[tym];
    uint isbyte = sz == 1;

    uint rex = (I64 && sz == 8) ? REX_W : 0;
    uint grex = rex << 16;          // 64 bit operands

    code cs;
    code* ce;
    if (tyfloating(tym))                  // if floating operation
    {
        if (config.fpxmmregs)
        {
            retregs = mPSW;
            if (tyxmmreg(tym))
                orthxmm(cdb,e,retregs);
            else
                assert(0);
        }
        else
        {
            assert(0);
        }
        goto L3;
    }

    /* See if we should reverse the comparison, so a JA => JC, and JBE => JNC
     * (This is already reflected in the jop)
     */
    if ((jop == COND.cs || jop == COND.cc) &&
        (op == OPgt || op == OPle) &&
        (tyuns(tym) || tyuns(e2.Ety))
       )
    {   // jmpopcode() sez comparison should be reversed
        assert(e2.Eoper != OPconst && e2.Eoper != OPrelconst);
        reverse ^= 1;
    }

    /* See if we should swap operands     */
    if (e1.Eoper == OPvar && e2.Eoper == OPvar && evalinregister(e2))
    {
        e1 = e.E2;
        e2 = e.E1;
        reverse ^= 1;
    }

    retregs = cgstate.allregs;

    ce = null;
    cs.Iflags = (sz == SHORTSIZE) ? CFopsize : 0;
    cs.Irex = cast(ubyte)rex;
    if (sz > REGSIZE)
        ce = gennop(ce);

    switch (e2.Eoper)
    {
        default:
            scodelem(cgstate,cdb,e1,retregs,0,true);        // compute left leaf
            rretregs = cgstate.allregs & ~retregs;
            scodelem(cgstate,cdb,e2,rretregs,retregs,true); // get right leaf
            if (sz <= REGSIZE)                              // CMP reg,rreg
            {
                reg = findreg(retregs);                     // get reg that e1 is in
                rreg = findreg(rretregs);
                uint ins;
                uint sf = sz == 8;
                if (reverse)
                    ins = INSTR.cmp_shift(sf, reg, 0, 0, rreg); // CMP rreg, reg
                else
                    ins = INSTR.cmp_shift(sf, rreg, 0, 0, reg); // CMP reg, rreg
                cdb.gen1(ins);
            }
            else
            {
                assert(sz == 2 * REGSIZE);

                // Compare MSW, if they're equal then compare the LSW
                reg = findregmsw(retregs);
                rreg = findregmsw(rretregs);
                uint ins = INSTR.cmp_shift(1, rreg, 0, 0, reg); // CMP reg, rreg
                cdb.gen1(ins);
                genjmp(cdb,JNE,FL.code,cast(block*) ce);      // JNE nop

                reg = findreglsw(retregs);
                rreg = findreglsw(rretregs);
                ins = INSTR.cmp_shift(1, rreg, 0, 0, reg);      // CMP reg, rreg
                cdb.gen1(ins);
            }
            break;

static if (0)
{
        case OPconst:
printf("OPconst:\n");
            // If compare against 0
            if (sz <= REGSIZE && pretregs == mPSW && !boolres(e2) &&
                isregvar(e1,retregs,reg)
               )
            {
                gentstreg(cdb, reg, sz == 8);           // CMP reg,#0
                retregs = mPSW;
                break;
            }

            if (!tyuns(tym) && !tyuns(e2.Ety) &&
                !boolres(e2) && !(pretregs & mPSW) &&
                (sz == REGSIZE || (I64 && sz == 4)) &&
                (!I16 || op == OPlt || op == OPge))
            {
                assert(pretregs & (cgstate.allregs));
                codelem(cgstate,cdb,e1,pretregs,false);
                reg = findreg(pretregs);
                getregs(cdb,mask(reg));
                switch (op)
                {
                    case OPle:
                        cdb.genc2(0x81,grex | modregrmx(3,0,reg),cast(uint)-1);   // ADD reg,-1
                        code_orflag(cdb.last(), CFpsw);
                        cdb.genc2(0x81,grex | modregrmx(3,2,reg),0);          // ADC reg,0
                        goto oplt;

                    case OPgt:
                        cdb.gen2(0xF7,grex | modregrmx(3,3,reg));         // NEG reg
                            /* Flips the sign bit unless the value is 0 or int.min.
                            Also sets the carry bit when the value is not 0. */
                        code_orflag(cdb.last(), CFpsw);
                        cdb.genc2(0x81,grex | modregrmx(3,3,reg),0);  // SBB reg,0
                            /* Subtracts the carry bit. This turns int.min into
                            int.max, flipping the sign bit.
                            For other negative and positive values, subtracting 1
                            doesn't affect the sign bit.
                            For 0, the carry bit is not set, so this does nothing
                            and the sign bit is not affected. */
                        goto oplt;

                    case OPlt:
                    oplt:
                        // Get the sign bit, i.e. 1 if the value is negative.
                        if (!I16)
                            cdb.genc2(0xC1,grex | modregrmx(3,5,reg),sz * 8 - 1); // SHR reg,31
                        else
                        {   /* 8088-286 do not have a barrel shifter, so use this
                               faster sequence
                             */
                            genregs(cdb,0xD1,0,reg);   // ROL reg,1
                            reg_t regi;
                            if (reghasvalue(cgstate.allregs,1,regi))
                                genregs(cdb,0x23,reg,regi);  // AND reg,regi
                            else
                                cdb.genc2(0x81,modregrm(3,4,reg),1); // AND reg,1
                        }
                        break;

                    case OPge:
                        genregs(cdb,0xD1,4,reg);        // SHL reg,1
                        code_orrex(cdb.last(),rex);
                        code_orflag(cdb.last(), CFpsw);
                        genregs(cdb,0x19,reg,reg);      // SBB reg,reg
                        code_orrex(cdb.last(),rex);
                        if (I64)
                        {
                            cdb.gen2(0xFF,modregrmx(3,0,reg));       // INC reg
                            code_orrex(cdb.last(), rex);
                        }
                        else
                            cdb.gen1(0x40 + reg);                    // INC reg
                        break;

                    default:
                        assert(0);
                }
                freenode(e2);
                goto ret;
            }

            cs.IFL2 = FL.const_;
            if (sz == 16)
                cs.IEV2.Vsize_t = cast(targ_size_t)e2.Vcent.hi;
            else if (sz > REGSIZE)
                cs.IEV2.Vint = cast(int)MSREG(e2.Vllong);
            else
                cs.IEV2.Vsize_t = cast(targ_size_t)e2.Vllong;

            // The cmp immediate relies on sign extension of the 32 bit immediate value
            if (I64 && sz >= REGSIZE && cs.IEV2.Vsize_t != cast(int)cs.IEV2.Vint)
                goto default;
            cs.Iop = 0x81 ^ isbyte;

            /* if ((e1 is data or a '*' reference) and it's not a
             * common subexpression
             */

            if ((e1.Eoper == OPvar && datafl[el_fl(e1)] ||
                 e1.Eoper == OPind) &&
                !evalinregister(e1))
            {
                getlvalue(cdb,cs,e1,0,RM.load);
                freenode(e1);
                if (evalinregister(e2))
                {
                    retregs = idxregm(&cs);
                    rretregs = cgstate.allregs & ~retregs;
                    scodelem(cgstate,cdb,e2,rretregs,retregs,true);
                    cs.Iop = 0x39 ^ isbyte ^ reverse;
                    if (sz > REGSIZE)
                    {
                        rreg = findregmsw(rretregs);
                        cs.Irm |= modregrm(0,rreg,0);
                        getlvalue_msw(cs);
                        cdb.gen(&cs);              // CMP EA+2,rreg
                        if (I64 && isbyte && rreg >= 4)
                            cdb.last().Irex |= REX;
                        genjmp(cdb,JNE,FL.code,cast(block*) ce); // JNE nop
                        rreg = findreglsw(rretregs);
                        NEWREG(cs.Irm,rreg);
                        getlvalue_lsw(cs);
                    }
                    else
                    {
                        rreg = findreg(rretregs);
                        code_newreg(&cs, rreg);
                        if (I64 && isbyte && rreg >= 4)
                            cs.Irex |= REX;
                    }
                }
                else
                {
                    cs.Irm |= modregrm(0,7,0);
                    if (sz > REGSIZE)
                    {
                        if (sz == 6)
                            assert(0);
                        if (e2.Eoper == OPrelconst)
                        {   cs.Iflags = (cs.Iflags & ~(CFoff | CFseg)) | CFseg;
                            cs.IEV2.Voffset = 0;
                        }
                        getlvalue_msw(cs);
                        cdb.gen(&cs);              // CMP EA+2,const
                        genjmp(cdb,JNE,FL.code, cast(block*) ce); // JNE nop
                        if (e2.Eoper == OPconst)
                            cs.IEV2.Vint = cast(int)e2.Vllong;
                        else if (e2.Eoper == OPrelconst)
                        {   // Turn off CFseg, on CFoff
                            cs.Iflags ^= CFseg | CFoff;
                            cs.IEV2.Voffset = e2.Voffset;
                        }
                        else
                            assert(0);
                        getlvalue_lsw(cs);
                    }
                    freenode(e2);
                }
                cdb.gen(&cs);
                break;
            }

            regm_t regmx;
            reg_t regx;
            if (evalinregister(e2) && !OTassign(e1.Eoper) &&
                !isregvar(e1,regmx,regx))
            {
                regm_t m;

                m = cgstate.allregs & ~cgstate.regcon.mvar;
                if (isbyte)
                    m &= BYTEREGS;
                if (m & (m - 1))    // if more than one free register
                    goto default;
            }
            if ((e1.Eoper == OPstrcmp || (OTassign(e1.Eoper) && sz <= REGSIZE)) &&
                !boolres(e2) && !evalinregister(e1))
            {
                retregs = mPSW;
                scodelem(cgstate,cdb,e1,retregs,0,false);
                freenode(e2);
                break;
            }
            if (sz <= REGSIZE && !boolres(e2) && e1.Eoper == OPadd && pretregs == mPSW)
            {
                retregs |= mPSW;
                scodelem(cgstate,cdb,e1,retregs,0,false);
                freenode(e2);
                break;
            }
            scodelem(cgstate,cdb,e1,retregs,0,true);  // compute left leaf
            if (sz <= REGSIZE)
            {   // CMP reg,const
                reg = findreg(retregs & cgstate.allregs);   // get reg that e1 is in
                rretregs = cgstate.allregs & ~retregs;
                if (cs.IFL2 == FL.const_ && reghasvalue(rretregs,cs.IEV2.Vint,rreg))
                {
                    genregs(cdb,0x3B,reg,rreg);
                    code_orrex(cdb.last(), rex);
                    if (!I16)
                        cdb.last().Iflags |= cs.Iflags & CFopsize;
                    freenode(e2);
                    break;
                }
                cs.Irm = modregrm(3,7,reg & 7);
                if (reg & 8)
                    cs.Irex |= REX_B;
            }
            else
                assert(0);
            cdb.gen(&cs);                         // CMP sucreg,LSW
            freenode(e2);
            break;

        case OPind:
            if (e2.Ecount)
                goto default;
            goto L5;

        case OPvar:
            if (config.exe & (EX_OSX | EX_OSX64))
            {
                if (movOnly(e2))
                    goto default;
            }
            if ((e1.Eoper == OPvar &&
                 isregvar(e2,rretregs,reg) &&
                 sz <= REGSIZE
                ) ||
                (e1.Eoper == OPind &&
                 isregvar(e2,rretregs,reg) &&
                 !evalinregister(e1) &&
                 sz <= REGSIZE
                )
               )
            {
                // CMP EA,e2
                getlvalue(cdb,cs,e1,0,RM.load);
                freenode(e1);
                cs.Iop = 0x39 ^ isbyte ^ reverse;
                code_newreg(&cs,reg);
                if (I64 && isbyte && reg >= 4)
                    cs.Irex |= REX;                 // address byte registers
                cdb.gen(&cs);
                freenode(e2);
                break;
            }
          L5:
            scodelem(cgstate,cdb,e1,retregs,0,true);      // compute left leaf
            if (sz <= REGSIZE)                      // CMP reg,EA
            {
                reg = findreg(retregs & cgstate.allregs);   // get reg that e1 is in
                uint opsize = cs.Iflags & CFopsize;
                loadea(cdb,e2,cs,0x3B ^ isbyte ^ reverse,reg,0,retregs,0,RM.load);
                code_orflag(cdb.last(),opsize);
            }
            else if (sz <= 2 * REGSIZE)
            {
                reg = findregmsw(retregs);   // get reg that e1 is in
                // CMP reg,EA
                loadea(cdb,e2,cs,0x3B ^ reverse,reg,REGSIZE,retregs,0,RM.load);
                if (I32 && sz == 6)
                    cdb.last().Iflags |= CFopsize;        // seg is only 16 bits
                genjmp(cdb,JNE,FL.code, cast(block*) ce);  // JNE ce
                reg = findreglsw(retregs);
                if (e2.Eoper == OPind)
                {
                    NEWREG(cs.Irm,reg);
                    getlvalue_lsw(cs);
                    cdb.gen(&cs);
                }
                else
                    loadea(cdb,e2,cs,0x3B ^ reverse,reg,0,retregs,0,RM.load);
            }
            else
                assert(0);
            freenode(e2);
            break;
}
    }
    cdb.append(ce);

L3:
    if ((retregs = (pretregs & cg.allregs)) != 0) // if return result in register
    {
        if (1 && !flag && !(jop & 0xFF00))
        {
            regm_t resregs = retregs;
            reg = allocreg(cdb,resregs,TYint);
            uint ins = INSTR.csinc(sz == 8,0x1F,jop ^ 1,0x1F,reg); // CSET reg,invcond
            cdb.gen1(ins);
            pretregs &= ~mPSW;
            fixresult(cdb,e,resregs,pretregs);
        }
        else
        {
            code* nop = null;
            regm_t save = cgstate.regcon.immed.mval;
            reg = allocreg(cdb,retregs,TYint);
            cgstate.regcon.immed.mval = save;
            if ((pretregs & mPSW) == 0 &&
                (jop == COND.cs || jop == COND.cc))
            {
                getregs(cdb,retregs);
                genregs(cdb,0x19,reg,reg);     // SBB reg,reg
                if (rex || flag & REX_W)
                    code_orrex(cdb.last(), REX_W);
                if (flag)
                { }                                         // cdcond() will handle it
                else if (jop == JNC)
                {
                    if (I64)
                    {
                        cdb.gen2(0xFF,modregrmx(3,0,reg));  // INC reg
                        code_orrex(cdb.last(), rex);
                    }
                    else
                        cdb.gen1(0x40 + reg);               // INC reg
                }
                else
                {
                    cdb.gen2(0xF7,modregrmx(3,3,reg));      // NEG reg
                    code_orrex(cdb.last(), rex);
                }
            }
            else if (I64 && sz == 8)
            {
                assert(!flag);
                movregconst(cdb,reg,1,64|8);   // MOV reg,1
                nop = gennop(nop);
                genjmp(cdb,jop,FL.code,cast(block*) nop);  // Jtrue nop
                                                            // MOV reg,0
                movregconst(cdb,reg,0,(pretregs & mPSW) ? 64|8 : 64);
                cgstate.regcon.immed.mval &= ~mask(reg);
            }
            else
            {
                assert(!flag);
                movregconst(cdb,reg,1,8);      // MOV reg,1
                nop = gennop(nop);
                genjmp(cdb,jop,FL.code,cast(block*) nop);  // Jtrue nop
                                                            // MOV reg,0
                movregconst(cdb,reg,0,(pretregs & mPSW) ? 8 : 0);
                cgstate.regcon.immed.mval &= ~mask(reg);
            }
            pretregs = retregs;
            cdb.append(nop);
        }
    }
ret:
    { }
}

// longcmp

/*****************************
 * Do floating point conversions.
 * Depends on OPd_s32 and CLIB.dbllng being in sequence.
    OPvp_fp
    OPcvp_fp
    OPd_s32
    OPs32_d
    OPd_s16
    OPs16_d
    OPd_u16
    OPu16_d
    OPd_u32
    OPu32_d
    OPd_f
    OPf_d
    OPd_ld
    OPld_d
 */
@trusted
void cdcnvt(ref CGstate cg, ref CodeBuilder cdb,elem* e, ref regm_t pretregs)
{
    //printf("cdcnvt: %p pretregs = %s\n", e, regm_str(pretregs));
    //elem_print(e);

    if (!pretregs)
    {
        codelem(cgstate,cdb,e.E1,pretregs,false);
        return;
    }

    uint sf;
    uint ftype;
    switch (e.Eoper)
    {
        case OPd_s16:                               // fcvtzs w0,d31  // sxth w0,w0
        case OPd_s32: ftype = 1; sf = 0; goto L2;   // fcvtzs w0,d31
        case OPd_s64: ftype = 1; sf = 1; goto L2;   // fcvtzs d31,d31 // fmov x0,d31
        case OPd_u16:                               // fcvtzu w0,d31  // and w0,w0,#0xFFFF
        case OPd_u32:                               // fcvtzu w0,d31
        case OPd_u64:                               // fcvtzu d31,d31 // fmov x0,d31
        L2:
            regm_t retregs1 = ALLREGS; //INSTR.FLOATREGS;
static if (1)
            retregs1 = mCX;  // hack because no floating support in rest of code
else
            codelem(cgstate,cdb,e.E1,retregs1,false);
            const reg_t V1 = findreg(retregs1);         // source floating point register

            regm_t retregs = pretregs & cg.allregs;
            if (retregs == 0)
                retregs = ALLREGS & cgstate.allregs;
            const tym = tybasic(e.Ety);
            reg_t Rd = allocreg(cdb,retregs,tym);       // destination integer register

            switch (e.Eoper)
            {
                case OPd_s16:
                    cdb.gen1(INSTR.fcvtzs(0,ftype,V1,Rd));              // fcvtzs Rd,V1
                    cdb.gen1(INSTR.sxth_sbfm(0,Rd,Rd));                 // sxth Rd,Rd
                    break;
                case OPd_s32:
                    cdb.gen1(INSTR.fcvtzs(0,1,V1,Rd));                  // fcvtzs Rd,V1
                    break;
                case OPd_s64:
                    cdb.gen1(INSTR.fcvtzs_asisdmisc(1,V1,V1));          // fcvtzs V1,V1
                    cdb.gen1(INSTR.fmov_float_gen(1,1,0,6,V1,Rd));      // fmov Rd,V1
                    break;
                case OPd_u16:
                    cdb.gen1(INSTR.fcvtzu(0,ftype,V1,Rd));              // fcvtzu Rd,V1
                    uint N,immr,imms;
                    assert(encodeNImmrImms(0xFFFF,N,immr,imms));
                    cdb.gen1(INSTR.log_imm(0,0,0,immr,imms,Rd,Rd));     // and Rd,Rd,#0xFFFF
                    break;
                case OPd_u32:
                    cdb.gen1(INSTR.fcvtzu(0,1,V1,Rd));                  // fcvtzu Rd,V1
                    break;
                case OPd_u64:
                    cdb.gen1(INSTR.fcvtzu_asisdmisc(1,V1,V1));          // fcvtzu V1,V1
                    cdb.gen1(INSTR.fmov_float_gen(1,1,0,6,V1,Rd));      // fmov Rd,V1
                    break;
                default:
                    assert(0);
            }

            fixresult(cdb,e,retregs,pretregs);
            break;

        case OPs16_d:    // sxth w0,w0 // scvtf d31,w0
        case OPs32_d:    // scvtf d31,w0
        case OPs64_d:    // scvtf d31,x0
        case OPu16_d:    // and w0,w0,#0xFFFF // ucvtf d31,w0
        case OPu32_d:    // ucvtf d31,w0
        case OPu64_d:    // ucvtf d31,x0
            regm_t retregs1 = ALLREGS;
            codelem(cgstate,cdb,e.E1,retregs1,false);
            reg_t R1 = findreg(retregs1);

static if (1)
{
            regm_t retregs = mCX; // hack because no floating support in rest of code
            reg_t Vd = CX;
}
else
{
            regm_t retregs = FLOATREGS;
            const tym = tybasic(e.Ety);
            reg_t Vd = allocreg(cdb,retregs,tym);       // destination integer register
}
            switch (e.Eoper)
            {
                case OPs16_d:
                    cdb.gen1(INSTR.sxth_sbfm(0,R1,R1));             // sxth w0,w0
                    cdb.gen1(INSTR.scvtf_float_int(0,1,Vd,R1));     // scvtf d31,w0
                    break;
                case OPs32_d:
                    cdb.gen1(INSTR.scvtf_float_int(0,1,Vd,R1));     // scvtf d31,w0
                    break;
                case OPs64_d:
                    cdb.gen1(INSTR.scvtf_float_int(1,1,Vd,R1));     // scvtf d31,x0
                    break;
                case OPu16_d:
                    /* not executed because OPu16_d was converted to OPu16_32 then OP32_d */
                    uint N,immr,imms;
                    assert(encodeNImmrImms(0xFFFF,N,immr,imms));
                    cdb.gen1(INSTR.log_imm(0,0,0,immr,imms,R1,R1)); // and w0,w0,#0xFFFF
                    cdb.gen1(INSTR.ucvtf_float_int(0,1,Vd,R1));     // ucvtf d31,w0
                    break;
                case OPu32_d:
                    cdb.gen1(INSTR.ucvtf_float_int(0,1,Vd,R1));     // ucvtf d31,w0
                    break;
                case OPu64_d:
                    cdb.gen1(INSTR.ucvtf_float_int(1,1,Vd,R1));     // ucvtf d31,x0
                    break;
                default:
                    assert(0);
            }

            fixresult(cdb,e,retregs,pretregs);
            break;

        case OPd_f:     // fcvt d31,s31
        case OPf_d:     // fcvt s31,d31
            regm_t retregs1 = ALLREGS; //INSTR.FLOATREGS;
static if (1)
            retregs1 = mCX;  // hack because no floating support in rest of code
else
            codelem(cgstate,cdb,e.E1,retregs1,false);
            const reg_t V1 = findreg(retregs1);         // source floating point register

static if (1)
{
            regm_t retregs = mDX;
}
else
{
            regm_t retregs = pretregs & INSTR.FLOATREGS;
            if (retregs == 0)
                retregs = INSTR.FLOATREGS & cgstate.allregs;
}
            const tym = tybasic(e.Ety);
            reg_t Vd = allocreg(cdb,retregs,tym);       // destination integer register

            switch (e.Eoper)
            {
                case OPd_f:     // fcvt s31,d31
                    cdb.gen1(INSTR.fcvt_float(1,4,V1,Vd));
                    break;
                case OPf_d:     // fcvt d31,s31
                    cdb.gen1(INSTR.fcvt_float(0,5,V1,Vd));
                    break;
                default:
                    assert(0);
            }

            fixresult(cdb,e,retregs,pretregs);
            break;

        default:
            assert(0);
    }
}

/***************************
 * Convert short to long.
    OPs16_32
    OPu16_32
    OPu32_64
    OPs32_64
    OPu64_128
    OPs64_128
 */

@trusted
void cdshtlng(ref CGstate cg, ref CodeBuilder cdb,elem* e,ref regm_t pretregs)
{
    reg_t reg;
    regm_t retregs;

    //printf("cdshtlng(e = %p, pretregs = %s)\n", e, regm_str(pretregs));
    int e1comsub = e.E1.Ecount;
    OPER op = e.Eoper;
    if ((pretregs & cg.allregs) == 0)    // if don't need result in regs
    {
        codelem(cgstate,cdb,e.E1,pretregs,false);     // then conversion isn't necessary
        return;
    }

    if (op == OPu32_64)
    {
        elem* e1 = e.E1;
        retregs = pretregs;
        if (e1.Eoper == OPvar || (e1.Eoper == OPind && !e1.Ecount))
        {
            // EA:  LDR w0,[sp,#8]
            // reg: MOV w0,w1
            code cs;
            getlvalue(cdb,cs,e,0,RM.load);
            cs.Sextend = (cs.Sextend & 0x100) | Extend.LSL;
            reg = allocreg(cdb,retregs,TYint);
            loadFromEA(cs,reg,4,4);
            cdb.gen(&cs);
            freenode(e1);
        }
        else
        {
            pretregs &= ~mPSW;                 // flags are set by eval of e1
            codelem(cgstate,cdb,e1,retregs,false);
            /* Determine if high 32 bits are already 0
             */
            if (e1.Eoper == OPu16_32 && !e1.Ecount)
            {
            }
            else
            {
                // Zero high 32 bits
                // reg: MOV w0,w1
                getregs(cdb,retregs);
                reg = findreg(retregs);
                cdb.gen1(INSTR.mov_register(0,reg,reg));
            }
        }
        fixresult(cdb,e,retregs,pretregs);
        return;
    }
    else if (op == OPs32_64 && OTrel(e.E1.Eoper) && !e.E1.Ecount)
    {
        /* Due to how e1 is calculated, the high 32 bits of the register
         * are already 0.
         */
        retregs = pretregs;
        codelem(cgstate,cdb,e.E1,retregs,false);
        fixresult(cdb,e,retregs,pretregs);
        return;
    }
    else if (op == OPs16_32 || op == OPu16_32 || op == OPs32_64)
    {
        elem* e11;
        elem* e1 = e.E1;

        if (e1.Eoper == OPu8_16 && !e1.Ecount &&
            ((e11 = e1.E1).Eoper == OPvar || (e11.Eoper == OPind && !e11.Ecount))
           )
        {
            code cs;

            getlvalue(cdb,cs,e11,0,RM.load);
            retregs = pretregs;
            if (!retregs)
                retregs = cg.allregs;
            reg = allocreg(cdb,retregs,TYint);
            if (cs.reg != NOREG)
            {
                //    INSTR.log_imm(sf,opc,N,immr,imms,Rn,Rd)
                uint N,immr,imms;
                assert(encodeNImmrImms(0xFF,N,immr,imms));
                uint ins = INSTR.log_imm(0,0,N,immr,imms,cs.reg,reg); // AND reg,cs.reg,#0xFF
                cdb.gen1(ins);
            }
            else
            {
                loadFromEA(cs,reg,4,1);                 // LDRB Wreg,[sp,offset]
                cdb.gen(&cs);
            }
            freenode(e11);
            freenode(e1);
        }
        else if (e1.Eoper == OPvar ||
            (e1.Eoper == OPind && !e1.Ecount))
        {
            // OPs16_32
            //   EA:  LDRSH x0,[sp,#8]
            //   reg: SXTH  x0,w5
            // OPu16_32
            //   EA:  LDRH  w0,[sp,#8]
            //   reg: AND   x0,x5,#0xFFFF
            // OPs32_64
            //   EA:  LDRSW x0,[sp,#8]
            //   reg: SXTW  x0,w5
            code cs;
            getlvalue(cdb,cs,e11,0,RM.load);
            retregs = pretregs;
            if (!retregs)
                retregs = cg.allregs;
            reg = allocreg(cdb,retregs,TYint);

            switch (op)
            {
                case OPs16_32:
                    if (cs.reg != NOREG)
                    {
                        uint ins = INSTR.sxth_sbfm(1,cs.reg,reg);  // SXTH Xreg,Wcs.reg
                        cdb.gen1(ins);
                    }
                    else
                    {
                        // BUG: not generating LDRSH
                        loadFromEA(cs,reg,8,2);               // LDRSH Xreg,[sp,#8]
                        cdb.gen(&cs);
                    }
                    break;

                case OPu16_32:
                    if (cs.reg != NOREG)
                    {
                        uint N,immr,imms;
                        assert(encodeNImmrImms(0xFFFF,N,immr,imms));
                        uint ins = INSTR.log_imm(0,0,0,immr,imms,reg,reg); // AND Xreg,Xreg,#0xFFFF
                        cdb.gen1(ins);
                    }
                    else
                    {
                        loadFromEA(cs,reg,4,2);                 // LDRH Wreg,[sp,#8]
                        cdb.gen(&cs);
                    }
                    break;

                case OPs32_64:
                    if (cs.reg != NOREG)
                    {
                        uint ins = INSTR.sxtw_sbfm(cs.reg,reg);   // SXTW Xreg,Wcs.reg
                        cdb.gen1(ins);
                    }
                    else
                    {
                        // BUG: not generating LDRSW
                        loadFromEA(cs,reg,8,4);              // LDRSW Xreg,[sp,#8]
                        cdb.gen(&cs);
                    }
                    break;

                default:
                    assert(0);
            }

            freenode(e1);
        }
        else
        {
            retregs = pretregs;
            pretregs &= ~mPSW;             // flags are already set
            codelem(cgstate,cdb,e1,retregs,false);
            getregs(cdb,retregs);
            reg = findreg(retregs);
            if (op == OPu16_32)
            {
                uint N,immr,imms;
                assert(encodeNImmrImms(0xFFFF,N,immr,imms));
                uint ins = INSTR.log_imm(0,0,0,immr,imms,reg,reg); // AND reg,reg,#0xFFFF
                cdb.gen1(ins);
            }
            else
            {
                uint ins = INSTR.sxtw_sbfm(reg, reg);   // SXTW reg,reg
                cdb.gen1(ins);
            }
            if (e1comsub)
                getregs(cdb,retregs);
        }
        fixresult(cdb,e,retregs,pretregs);
        return;
    }
    else if (pretregs & mPSW)
    {
        // OPs16_32, OPs32_64
        retregs = pretregs;                // want integer result in AX
        codelem(cgstate,cdb,e.E1,retregs,false);
        pretregs &= ~mPSW;                 // flags are already set
        getregs(cdb,retregs);
        reg = findreg(retregs);
        uint size = _tysize[tybasic(e.E1.Ety)];
        uint ins;
        if (op == OPs32_64)
            ins = INSTR.sxtw_sbfm(reg,reg);           // SXTW Xreg,Wreg
        else if (op == OPs16_32)
            ins = INSTR.sxtb_sbfm(size == 8,reg,reg); // SXTH Xreg,Wreg
        else
            assert(0);
        if (e1comsub)
            getregs(cdb,retregs);
        fixresult(cdb,e,retregs,pretregs);
        return;
    }
    else
    {
        assert(0);
        /*
        // OPs16_32, OPs32_64, OPs64_128
        reg_t msreg,lsreg;

        retregs = pretregs & mLSW;
        assert(retregs);
        codelem(cgstate,cdb,e.E1,retregs,false);
        retregs |= pretregs & mMSW;
        reg = allocreg(cdb,retregs,e.Ety);
        msreg = findregmsw(retregs);
        lsreg = findreglsw(retregs);
        genmovreg(cdb,msreg,lsreg);                // MOV msreg,lsreg
        assert(config.target_cpu >= TARGET_80286);              // 8088 can't handle SAR reg,imm8
        cdb.genc2(0xC1,modregrm(3,7,msreg),REGSIZE * 8 - 1);    // SAR msreg,31
        fixresult(cdb,e,retregs,pretregs);
        return;
        */
    }
}

/***************************
 * Convert byte to int.
 * For OPu8_16 and OPs8_16.
 */

@trusted
void cdbyteint(ref CGstate cg, ref CodeBuilder cdb,elem* e,ref regm_t pretregs)
{
    regm_t retregs;
    tym_t tyml = tybasic(e.Ety);              // type of lvalue
    uint sz = _tysize[tyml];

    if ((pretregs & cg.allregs) == 0) // if don't need result in regs
    {
        codelem(cgstate,cdb,e.E1,pretregs,false);      // then conversion isn't necessary
        return;
    }

    //printf("cdbyteint(e = %p, pretregs = %s\n", e, regm_str(pretregs));
    char op = e.Eoper;
    elem* e1 = e.E1;
    if (e1.Eoper == OPcomma)
        docommas(cdb,e1);

    if (e1.Eoper == OPvar || (e1.Eoper == OPind && !e1.Ecount))
    {
        code cs;
        getlvalue(cdb,cs,e,0,RM.load);
        Extend extend = OPu8_16 ? Extend.UXTB : Extend.SXTB;
        cs.Sextend = cast(ubyte)((cs.Sextend & 0x100) | extend);
        reg_t reg = allocreg(cdb,retregs,TYint);
        loadFromEA(cs,reg,4,1);
        cdb.gen(&cs);
        freenode(e1);
        fixresult(cdb,e,retregs,pretregs);
        return;
    }

    size = tysize(e.Ety);
    retregs = pretregs & cg.allregs;
    if (retregs == 0)
        retregs = cg.allregs;
    retregs |= pretregs & mPSW;
    pretregs &= ~mPSW;

    CodeBuilder cdb1;
    cdb1.ctor();
    codelem(cgstate,cdb1,e1,retregs,false);
    code* c1 = cdb1.finish();
    cdb.append(cdb1);
    reg_t reg = findreg(retregs);
    code* c;
    if (!c1)
        goto L1;

    // If previous instruction is an AND bytereg,value
    c = cdb.last();
    if (0 && c.Iop == 0x80 && c.Irm == modregrm(3,4,reg & 7) &&
        (op == OPu8_16 || (c.IEV2.Vuns & 0x80) == 0))
    {
        if (pretregs & mPSW)
            c.Iflags |= CFpsw;
        c.Iop |= 1;                    // convert to word operation
        c.IEV2.Vuns &= 0xFF;           // dump any high order bits
        pretregs &= ~mPSW;             // flags already set
    }
    else
    {
     L1:
        uint ins;
        if (op == OPs8_16)
            ins = INSTR.sxtb_sbfm(sz == 8,reg,reg); // SXTB reg,reg
        else
        {
            uint N,immr,imms;
            assert(encodeNImmrImms(0xFF,N,immr,imms));
            uint opc = (pretregs & mPSW) ? 3 : 0;
            if (sz < 8)
                N = 0;
            //printf("N %d immr x%x imms x%x, reg %x\n", N,immr,imms,reg);
            ins = INSTR.log_imm(sz == 8,opc,N,immr,imms,reg,reg); // AND/ANDS reg,reg,#0xFF
            pretregs &= ~mPSW;
        }
        cdb.gen1(ins);
    }
    getregs(cdb,retregs);
    fixresult(cdb,e,retregs,pretregs);
}


/***************************
 * Convert long to short.
    OPoffset
    OP32_16
    OP16_8
    OP64_32
    OP128_64
 */

@trusted
void cdlngsht(ref CGstate cg, ref CodeBuilder cdb,elem* e,ref regm_t pretregs)
{
    debug
    {
        switch (e.Eoper)
        {
            case OP32_16:
            case OPoffset:
            case OP16_8:
            case OP64_32:
            case OP128_64:
                break;

            default:
                assert(0);
        }
    }

    regm_t retregs;
    if (e.Eoper == OP16_8)
    {
        retregs = pretregs ? cg.allregs : 0;
        codelem(cgstate,cdb,e.E1,retregs,false);
    }
    else
    {
        if (e.E1.Eoper == OPrelconst)
            offsetinreg(cdb,e.E1,retregs);
        else
        {
            retregs = pretregs ? cg.allregs : 0;
            codelem(cgstate,cdb,e.E1,retregs,false);
            bool isOff = e.Eoper == OPoffset;
            if (isOff || e.Eoper == OP128_64)
                retregs &= mLSW;                // want LSW only
        }
    }

    /* We "destroy" a reg by assigning it the result of a new e, even
     * though the values are the same. Weakness of our CSE strategy that
     * a register can only hold the contents of one elem at a time.
     */
    if (e.Ecount)
        getregs(cdb,retregs);
    else
        useregs(retregs);

    debug
    if (!(!pretregs || retregs))
    {
        printf("%s pretregs = %s, retregs = %s, e = %p\n",oper_str(e.Eoper),regm_str(pretregs),regm_str(retregs),e);
    }

    assert(!pretregs || retregs);
    fixresult(cdb,e,retregs,pretregs);  // lsw only
}

/**********************************************
 * Get top 32 bits of 64 bit value (I32)
 * or top 16 bits of 32 bit value (I16)
 * or top 64 bits of 128 bit value (I64).
 * OPmsw
 */

@trusted
void cdmsw(ref CGstate cg, ref CodeBuilder cdb,elem* e,ref regm_t pretregs)
{
    assert(e.Eoper == OPmsw);

    regm_t retregs = pretregs ? cg.allregs : 0;
    codelem(cgstate,cdb,e.E1,retregs,false);
    retregs &= mMSW;                    // want MSW only

    /* We "destroy" a reg by assigning it the result of a new e, even
     * though the values are the same. Weakness of our CSE strategy that
     * a register can only hold the contents of one elem at a time.
     */
    if (e.Ecount)
        getregs(cdb,retregs);
    else
        useregs(retregs);

    debug
    if (!(!pretregs || retregs))
    {
        printf("%s pretregs = %s, retregs = %s\n",oper_str(e.Eoper),regm_str(pretregs),regm_str(retregs));
        elem_print(e);
    }

    assert(!pretregs || retregs);
    fixresult(cdb,e,retregs,pretregs);  // msw only
}

// cdport
// cdasm
// cdfar16
// cdbtst
// cdbt
// cdbscan

/************************
 * OPpopcnt operator
 */

@trusted
void cdpopcnt(ref CGstate cg, ref CodeBuilder cdb,elem* e,ref regm_t pretregs)
{
    //printf("cdpopcnt()\n");
    //elem_print(e);
    if (!pretregs)
    {
        codelem(cgstate,cdb,e.E1,pretregs,false);
        return;
    }

    const tyml = tybasic(e.E1.Ety);
    const sz = _tysize[tyml];
    assert(sz == 8);                    // popcnt only operates on 64 bits
    if (tyfloating(tyml))
    {
        assert(0);
    }

    const posregs = cgstate.allregs;
    regm_t retregs1 = posregs;
    codelem(cgstate,cdb,e.E1,retregs1,false);

    regm_t retregs = pretregs & cg.allregs;
    if (retregs == 0)                   /* if no return regs speced     */
                                        /* (like if wanted flags only)  */
        retregs = ALLREGS & posregs;    // give us some
    reg_t Rd = allocreg(cdb, retregs, tyml); // destination register

    const R1 = findreg(retregs1);       // source register

    regm_t vregs = INSTR.FLOATREGS;     // possible floating point registers
    reg_t Vx = allocreg(cdb, vregs, TYdouble);

    Vx &= 31;                                           // to AArch64 register number
    cdb.gen1(INSTR.fmov_float_gen(1,1,0,7,R1,Vx));      // FMOV Dx,X1
    cdb.gen1(INSTR.cnt_advsimd(0,0,Vx,Vx));             // CNT  Vx.8b,Vx.8b
    cdb.gen1(INSTR.addv_advsimd(0,0,Vx,Vx));            // ADDV Bx,Vx.8b
    cdb.gen1(INSTR.fmov_float_gen(0,0,0,6,Vx,Rd));      // FMOV Wd,Sx

    fixresult(cdb,e,retregs,pretregs);
}

// cdpair
// cdcmpxchg
// cdprefetch
// opAssLoadReg
// opAssLoadPair
// opAssStoreReg
// opAssStorePair
