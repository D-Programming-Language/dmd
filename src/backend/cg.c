// Copyright (C) 1984-1995 by Symantec
// Copyright (C) 2000-2009 by Digital Mars
// All Rights Reserved
// http://www.digitalmars.com
// Written by Walter Bright
/*
 * This source file is made available for personal use
 * only. The license is in /dmd/src/dmd/backendlicense.txt
 * or /dm/src/dmd/backendlicense.txt
 * For any other uses, please contact Digital Mars.
 */

#include        <stdio.h>
#include        <time.h>
#include        <string.h>
#include        <stdlib.h>

#include        "cc.h"
#include        "global.h"
#include        "code.h"
#include        "type.h"
#include        "filespec.h"

///////////////////// GLOBALS /////////////////////

#include        "fltables.c"

targ_size_t     Poffset;        /* size of func parameter variables     */
targ_size_t     framehandleroffset;     // offset of C++ frame handler
#if TARGET_OSX
targ_size_t     localgotoffset; // offset of where localgot refers to
#endif

int cseg = CODE;                // current code segment
                                // (negative values mean it is the negative
                                // of the public name index of a COMDAT)

/* Stack offsets        */
targ_size_t localsize,          /* amt subtracted from SP for local vars */
        Toff,                   /* base for temporaries                 */
        Poff,Aoff;              // comsubexps, params, regs, autos

// Global register settings, initialized in cod3_set[16|32|64]
int     BPRM       = 0;         // R/M value for [BP] or [EBP]
regm_t  fregsaved  = 0;         // mask of registers saved across function calls
regm_t  ALLREGS    = 0;
regm_t  BYTEREGS   = 0;
regm_t  FLOATREGS  = 0;
regm_t  FLOATREGS2 = 0;
regm_t  DOUBLEREGS = 0;

symbol *localgot;               // reference to GOT for this function
symbol *tls_get_addr_sym;       // function __tls_get_addr

#if TARGET_OSX
int STACKALIGN = 16;
#else
int STACKALIGN = 0;
#endif
