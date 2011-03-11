/*
 * Copyright (c) 1994-1998 by Symantec
 * Copyright (c) 2000-2011 by Digital Mars
 * All Rights Reserved
 * http://www.digitalmars.com
 * http://www.dsource.org/projects/dmd/browser/branches/dmd-1.x/src/eh.c
 * http://www.dsource.org/projects/dmd/browser/trunk/src/eh.c
 * Written by Walter Bright
 *
 * This source file is made available for personal use
 * only. The license is in /dmd/src/dmd/backendlicense.txt
 * For any other uses, please contact Digital Mars.
 */

// Support for D exception handling

#include        <stdio.h>
#include        <string.h>
#include        <time.h>

#include        "cc.h"
#include        "el.h"
#include        "code.h"
#include        "oper.h"
#include        "global.h"
#include        "type.h"
#include        "dt.h"
#include        "exh.h"

static char __file__[] = __FILE__;      /* for tassert.h                */
#include        "tassert.h"

/****************************
 * Generate and output scope table.
 */

symbol *except_gentables()
{
    //printf("except_gentables()\n");
#if TARGET_LINUX || TARGET_OSX || TARGET_FREEBSD || TARGET_SOLARIS

    // BUG: alloca() changes the stack size, which is not reflected
    // in the fixed eh tables.
    assert(!usedalloca);

    symbol *s = symbol_generate(SCstatic,tsint);
    s->Sseg = UNKNOWN;
    symbol_keep(s);
    symbol_debug(s);

    except_fillInEHTable(s);

    outdata(s);                 // output the scope table

    obj_ehtables(funcsym_p,funcsym_p->Ssize,s);
#endif
    return NULL;
}

/**********************************************
 * Initializes the symbol s with the contents of the exception handler table.
 */

void except_fillInEHTable(symbol *s)
{
    unsigned fsize = NPTRSIZE;             // target size of function pointer
    dt_t **pdt = &s->Sdt;

    /*
        void*           pointer to start of function
        unsigned        offset of ESP from EBP
        unsigned        offset from start of function to return code
        unsigned nguards;       // dimension of guard[] (Linux)
        {   unsigned offset;    // offset of start of guarded section (Linux)
            unsigned endoffset; // ending offset of guarded section (Linux)
            int last_index;     // previous index (enclosing guarded section)
            unsigned catchoffset;       // offset to catch block from symbol
            void *finally;      // finally code to execute
        } guard[];
      catchoffset:
        unsigned ncatches;      // number of catch blocks
        {   void *type;         // symbol representing type
            unsigned bpoffset;  // EBP offset of catch variable
            void *handler;      // catch handler code
        } catch[];
     */

#if TARGET_LINUX || TARGET_OSX || TARGET_FREEBSD || TARGET_SOLARIS
#define GUARD_SIZE      (I64 ? 3*8 : 5*4)     // number of bytes in one guard
#else
#define GUARD_SIZE      (3*4)
#endif

    int sz = 0;

    // Address of start of function
    symbol_debug(funcsym_p);
    pdt = dtxoff(pdt,funcsym_p,0,TYnptr);
    sz += fsize;

    //printf("ehtables: func = %s, offset = x%x, startblock->Boffset = x%x\n", funcsym_p->Sident, funcsym_p->Soffset, startblock->Boffset);

    // Get offset of ESP from EBP
    long spoff = cod3_spoff();
    pdt = dtdword(pdt,spoff);
    sz += 4;

    // Offset from start of function to return code
    pdt = dtdword(pdt,retoffset);
    sz += 4;

    // First, calculate starting catch offset
    int guarddim = 0;                               // max dimension of guard[]
    for (block *b = startblock; b; b = b->Bnext)
    {
        if (b->BC == BC_try && b->Bscope_index >= guarddim)
            guarddim = b->Bscope_index + 1;
//      printf("b->BC = %2d, Bscope_index = %2d, last_index = %2d, offset = x%x\n",
//              b->BC, b->Bscope_index, b->Blast_index, b->Boffset);
    }

#if TARGET_LINUX || TARGET_OSX || TARGET_FREEBSD || TARGET_SOLARIS
    pdt = dtsize_t(pdt,guarddim);
    sz += NPTRSIZE;
#endif

    unsigned catchoffset = sz + guarddim * GUARD_SIZE;

    // Generate guard[]
    int i = 0;
    for (block *b = startblock; b; b = b->Bnext)
    {
        //printf("b = %p, b->Btry = %p, b->offset = %x\n", b, b->Btry, b->Boffset);
        if (b->BC == BC_try)
        {
            assert(b->Bscope_index >= i);
            if (i < b->Bscope_index)
            {   int fillsize = (b->Bscope_index - i) * GUARD_SIZE;
                pdt = dtnzeros(pdt, fillsize);
                sz += fillsize;
            }
            i = b->Bscope_index + 1;

            int nsucc = list_nitems(b->Bsucc);

#if TARGET_LINUX || TARGET_OSX || TARGET_FREEBSD || TARGET_SOLARIS
            //printf("DHandlerInfo: offset = %x", (int)(b->Boffset - startblock->Boffset));
            pdt = dtdword(pdt,b->Boffset - startblock->Boffset);        // offset to start of block

            // Compute ending offset
            unsigned endoffset;
            for (block *bn = b->Bnext; 1; bn = bn->Bnext)
            {
                //printf("\tbn = %p, bn->Btry = %p, bn->offset = %x\n", bn, bn->Btry, bn->Boffset);
                assert(bn);
                if (bn->Btry == b->Btry)
                {    endoffset = bn->Boffset - startblock->Boffset;
                     break;
                }
            }
            //printf(" endoffset = %x, prev_index = %d\n", endoffset, b->Blast_index);
            pdt = dtdword(pdt,endoffset);               // offset past end of guarded block
#endif

            pdt = dtdword(pdt,b->Blast_index);          // parent index

            if (b->jcatchvar)                           // if try-catch
            {
                pdt = dtdword(pdt,catchoffset);
                pdt = dtsize_t(pdt,0);                  // no finally handler

                catchoffset += NPTRSIZE + (nsucc - 1) * (3 * NPTRSIZE);
            }
            else                                        // else try-finally
            {
                assert(nsucc == 2);
                pdt = dtdword(pdt,0);           // no catch offset
                block *bhandler = list_block(list_next(b->Bsucc));
                assert(bhandler->BC == BC_finally);
                // To successor of BC_finally block
                bhandler = list_block(bhandler->Bsucc);
#if TARGET_LINUX || TARGET_OSX || TARGET_FREEBSD || TARGET_SOLARIS
                pdt = dtxoff(pdt,funcsym_p,bhandler->Boffset - startblock->Boffset, TYnptr);    // finally handler address
#else
                pdt = dtcoff(pdt,bhandler->Boffset);  // finally handler address
#endif
            }
            sz += GUARD_SIZE;
        }
    }

    // Generate catch[]
    for (block *b = startblock; b; b = b->Bnext)
    {
        if (b->BC == BC_try)
        {   block *bhandler;
            int nsucc;

            if (b->jcatchvar)                           // if try-catch
            {   list_t bl;

                nsucc = list_nitems(b->Bsucc);
                pdt = dtsize_t(pdt,nsucc - 1);           // # of catch blocks
                sz += NPTRSIZE;

                for (bl = list_next(b->Bsucc); bl; bl = list_next(bl))
                {
                    block *bcatch = list_block(bl);

                    pdt = dtxoff(pdt,bcatch->Bcatchtype,0,TYjhandle);

                    pdt = dtsize_t(pdt,cod3_bpoffset(b->jcatchvar));     // EBP offset

#if TARGET_LINUX || TARGET_OSX || TARGET_FREEBSD || TARGET_SOLARIS
                    pdt = dtxoff(pdt,funcsym_p,bcatch->Boffset - startblock->Boffset, TYnptr);  // catch handler address
#else
                    pdt = dtcoff(pdt,bcatch->Boffset);        // catch handler address
#endif
                    sz += 3 * NPTRSIZE;
                }
            }
        }
    }
    assert(sz != 0);
}
