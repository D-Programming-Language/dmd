/**
 * Compiler implementation of the
 * $(LINK2 http://www.dlang.org, D programming language).
 *
 * Copyright:   Copyright (C) 1985-1998 by Symantec
 *              Copyright (C) 2000-2019 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 http://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/src/dmd/backend/code.d, backend/_code.d)
 */

module dmd.backend.code;

// Online documentation: https://dlang.org/phobos/dmd_backend_code.html

import dmd.backend.cc;
import dmd.backend.cdef;
import dmd.backend.code_x86;
import dmd.backend.codebuilder : CodeBuilder;
import dmd.backend.el : elem;
import dmd.backend.oper : OPMAX;
import dmd.backend.outbuf;
import dmd.backend.ty;
import dmd.backend.type;

extern (C++):

nothrow:

alias segidx_t = int;           // index into SegData[]

/**********************************
 * Code data type
 */

struct _Declaration;
struct _LabelDsymbol;

union evc
{
    targ_int    Vint;           /// also used for tmp numbers (FLtmp)
    targ_uns    Vuns;
    targ_long   Vlong;
    targ_llong  Vllong;
    targ_size_t Vsize_t;
    struct
    {
        targ_size_t Vpointer;
        int Vseg;               /// segment the pointer is in
    }
    Srcpos      Vsrcpos;        /// source position for OPlinnum
    elem       *Vtor;           /// OPctor/OPdtor elem
    block      *Vswitch;        /// when FLswitch and we have a switch table
    code       *Vcode;          /// when code is target of a jump (FLcode)
    block      *Vblock;         /// when block " (FLblock)
    struct
    {
        targ_size_t Voffset;    /// offset from symbol
        Symbol  *Vsym;          /// pointer to symbol table (FLfunc,FLextern)
    }

    struct
    {
        targ_size_t Vdoffset;   /// offset from symbol
        _Declaration *Vdsym;    /// pointer to D symbol table
    }

    struct
    {
        targ_size_t Vloffset;   /// offset from symbol
        _LabelDsymbol *Vlsym;   /// pointer to D Label
    }

    struct
    {
        size_t len;
        char *bytes;
    }                           // asm node (FLasm)
}

/********************** PUBLIC FUNCTIONS *******************/

code *code_calloc();
void code_free(code *);
void code_term();

code *code_next(code *c) { return c.next; }

code *code_chunk_alloc();
extern __gshared code *code_list;

code *code_malloc()
{
    //printf("code %d\n", sizeof(code));
    code *c = code_list ? code_list : code_chunk_alloc();
    code_list = code_next(c);
    //printf("code_malloc: %p\n",c);
    return c;
}

extern __gshared con_t regcon;

/************************************
 * Register save state.
 */

struct REGSAVE
{
    targ_size_t off;            // offset on stack
    uint top;                   // high water mark
    uint idx;                   // current number in use
    int alignment;              // 8 or 16

  nothrow:
    void reset() { off = 0; top = 0; idx = 0; alignment = _tysize[TYnptr]/*REGSIZE*/; }
    void save(ref CodeBuilder cdb, reg_t reg, uint *pidx) { REGSAVE_save(this, cdb, reg, *pidx); }
    void restore(ref CodeBuilder cdb, reg_t reg, uint idx) { REGSAVE_restore(this, cdb, reg, idx); }
}

void REGSAVE_save(ref REGSAVE regsave, ref CodeBuilder cdb, reg_t reg, out uint idx);
void REGSAVE_restore(const ref REGSAVE regsave, ref CodeBuilder cdb, reg_t reg, uint idx);

extern __gshared REGSAVE regsave;

/************************************
 * Local sections on the stack
 */
struct LocalSection
{
    targ_size_t offset;         // offset of section from frame pointer
    targ_size_t size;           // size of section
    int alignment;              // alignment size

  nothrow:
    void init()                 // initialize
    {   offset = 0;
        size = 0;
        alignment = 0;
    }
}

/*******************************
 * As we generate code, collect information about
 * what parts of NT exception handling we need.
 */

extern __gshared uint usednteh;

enum
{
    NTEH_try        = 1,      // used _try statement
    NTEH_except     = 2,      // used _except statement
    NTEHexcspec     = 4,      // had C++ exception specification
    NTEHcleanup     = 8,      // destructors need to be called
    NTEHtry         = 0x10,   // had C++ try statement
    NTEHcpp         = (NTEHexcspec | NTEHcleanup | NTEHtry),
    EHcleanup       = 0x20,   // has destructors in the 'code' instructions
    EHtry           = 0x40,   // has BCtry or BC_try blocks
    NTEHjmonitor    = 0x80,   // uses Mars monitor
    NTEHpassthru    = 0x100,
}

/********************** Code Generator State ***************/

struct CGstate
{
    int stackclean;     // if != 0, then clean the stack after function call

    LocalSection funcarg;       // where function arguments are placed
    targ_size_t funcargtos;     // current high water level of arguments being moved onto
                                // the funcarg section. It is filled from top to bottom,
                                // as if they were 'pushed' on the stack.
                                // Special case: if funcargtos==~0, then no
                                // arguments are there.
    bool accessedTLS;           // set if accessed Thread Local Storage (TLS)
}

// nteh.c
void nteh_prolog(ref CodeBuilder cdb);
void nteh_epilog(ref CodeBuilder cdb);
void nteh_usevars();
void nteh_filltables();
void nteh_gentables(Symbol *sfunc);
void nteh_setsp(ref CodeBuilder cdb, opcode_t op);
void nteh_filter(ref CodeBuilder cdb, block *b);
void nteh_framehandler(Symbol *, Symbol *);
void nteh_gensindex(ref CodeBuilder, int);
enum GENSINDEXSIZE = 7;
void nteh_monitor_prolog(ref CodeBuilder cdb,Symbol *shandle);
void nteh_monitor_epilog(ref CodeBuilder cdb,regm_t retregs);
code *nteh_patchindex(code* c, int index);
void nteh_unwind(ref CodeBuilder cdb,regm_t retregs,uint index);

// cgen.c
code *code_last(code *c);
void code_orflag(code *c,uint flag);
void code_orrex(code *c,uint rex);
code *setOpcode(code *c, code *cs, opcode_t op);
code *cat(code *c1, code *c2);
code *gen (code *c , code *cs );
code *gen1 (code *c , opcode_t op );
code *gen2 (code *c , opcode_t op , uint rm );
code *gen2sib(code *c,opcode_t op,uint rm,uint sib);
code *genc2 (code *c , opcode_t op , uint rm , targ_size_t EV2 );
code *genc (code *c , opcode_t op , uint rm , uint FL1 , targ_size_t EV1 , uint FL2 , targ_size_t EV2 );
code *genlinnum(code *,Srcpos);
void cgen_prelinnum(code **pc,Srcpos srcpos);
code *gennop(code *);
void gencodelem(ref CodeBuilder cdb,elem *e,regm_t *pretregs,bool constflag);
bool reghasvalue (regm_t regm , targ_size_t value , reg_t *preg );
void regwithvalue(ref CodeBuilder cdb, regm_t regm, targ_size_t value, reg_t *preg, regm_t flags);

// cgreg.c
void cgreg_init();
void cgreg_term();
void cgreg_reset();
void cgreg_used(uint bi,regm_t used);
void cgreg_spillreg_prolog(block *b,Symbol *s,ref CodeBuilder cdbstore,ref CodeBuilder cdbload);
void cgreg_spillreg_epilog(block *b,Symbol *s,ref CodeBuilder cdbstore,ref CodeBuilder cdbload);
int cgreg_assign(Symbol *retsym);
void cgreg_unregister(regm_t conflict);

// cgsched.c
void cgsched_block(block *b);

alias IDXSTR = uint;
alias IDXSEC = uint;
alias IDXSYM = uint;

struct seg_data
{
    segidx_t             SDseg;         // index into SegData[]
    targ_size_t          SDoffset;      // starting offset for data
    int                  SDalignment;   // power of 2

    version (Windows) // OMFOBJ
    {
        bool isfarseg;
        int segidx;                     // internal object file segment number
        int lnameidx;                   // lname idx of segment name
        int classidx;                   // lname idx of class name
        uint attr;                      // segment attribute
        targ_size_t origsize;           // original size
        int seek;                       // seek position in output file
        void* ledata;                   // (Ledatarec) current one we're filling in
    }

    //ELFOBJ || MACHOBJ
    IDXSEC           SDshtidx;          // section header table index
    Outbuffer       *SDbuf;             // buffer to hold data
    Outbuffer       *SDrel;             // buffer to hold relocation info

    //ELFOBJ
    IDXSYM           SDsymidx;          // each section is in the symbol table
    IDXSEC           SDrelidx;          // section header for relocation info
    targ_size_t      SDrelmaxoff;       // maximum offset encountered
    int              SDrelindex;        // maximum offset encountered
    int              SDrelcnt;          // number of relocations added
    IDXSEC           SDshtidxout;       // final section header table index
    Symbol          *SDsym;             // if !=NULL, comdat symbol
    segidx_t         SDassocseg;        // for COMDATs, if !=0, this is the "associated" segment

    uint             SDaranges_offset;  // if !=0, offset in .debug_aranges

    uint             SDlinnum_count;
    uint             SDlinnum_max;
    linnum_data     *SDlinnum_data;     // array of line number / offset data

  nothrow:
    version (Windows)
        int isCode() { return seg_data_isCode(this); }
    version (OSX)
        int isCode() { return seg_data_isCode(this); }
}

extern int seg_data_isCode(const ref seg_data sd);

struct linnum_data
{
    const(char) *filename;
    uint filenumber;        // corresponding file number for DW_LNS_set_file

    uint linoff_count;
    uint linoff_max;
    uint[2]* linoff;        // [0] = line number, [1] = offset
}

extern __gshared seg_data **SegData;

ref targ_size_t Offset(int seg) { return SegData[seg].SDoffset; }
ref targ_size_t Doffset() { return Offset(DATA); }
ref targ_size_t CDoffset() { return Offset(CDATA); }

/**************************************************/

/* Allocate registers to function parameters
 */

struct FuncParamRegs
{
    //this(tym_t tyf);
    static FuncParamRegs create(tym_t tyf) { return FuncParamRegs_create(tyf); }

    int alloc(type *t, tym_t ty, ubyte *reg1, ubyte *reg2)
    { return FuncParamRegs_alloc(this, t, ty, reg1, reg2); }

  private:
  public: // for the moment
    tym_t tyf;                  // type of function
    int i;                      // ith parameter
    int regcnt;                 // how many general purpose registers are allocated
    int xmmcnt;                 // how many fp registers are allocated
    uint numintegerregs;        // number of gp registers that can be allocated
    uint numfloatregs;          // number of fp registers that can be allocated
    const(ubyte)* argregs;      // map to gp register
    const(ubyte)* floatregs;    // map to fp register
}

extern FuncParamRegs FuncParamRegs_create(tym_t tyf);
extern int FuncParamRegs_alloc(ref FuncParamRegs fpr, type *t, tym_t ty, reg_t *preg1, reg_t *preg2);

extern __gshared
{
    regm_t msavereg,mfuncreg,allregs;

    int BPRM;
    regm_t FLOATREGS;
    regm_t FLOATREGS2;
    regm_t DOUBLEREGS;
    //const char datafl[],stackfl[],segfl[],flinsymtab[];
    char needframe,gotref;
    targ_size_t localsize,
        funcoffset,
        framehandleroffset;
    segidx_t cseg;
    int STACKALIGN;
    int TARGET_STACKALIGN;
    LocalSection Para;
    LocalSection Fast;
    LocalSection Auto;
    LocalSection EEStack;
    LocalSection Alloca;
}

/* cgcod.d */
extern __gshared targ_size_t retoffset;
extern __gshared int refparam;

/* cod3.d */
targ_size_t cod3_bpoffset(Symbol *s);
targ_size_t cod3_spoff();
uint calccodsize(code *c);

/* cgxmm.d */
bool isXMMstore(opcode_t op);
void checkSetVex3(code *c);
