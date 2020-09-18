/**
 * Symbol table array.
 *
 * Copyright:   Copyright (C) 1985-1998 by Symantec
 *              Copyright (C) 2000-2020 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 http://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/src/dmd/backend/symtab.d, backend/_symtab.d)
 * Documentation:  https://dlang.org/phobos/dmd_backend_symtab.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/backend/symtab.d
 */

module dmd.backend.symtab;

import core.stdc.stdio;
import core.stdc.stdlib;

import dmd.backend.cdef;
import dmd.backend.cc;
import dmd.backend.mem;


extern (C++):

nothrow:

alias SYMIDX = size_t;    // symbol table index

alias MEM_PH_MALLOC = mem_malloc;
alias MEM_PH_CALLOC = mem_calloc;
alias MEM_PH_FREE = mem_free;
alias MEM_PH_FREEFP = mem_freefp;
alias MEM_PH_STRDUP = mem_strdup;
alias MEM_PH_REALLOC = mem_realloc;

private void err_nomem();

struct symtab_t
{
  nothrow:
    alias T = Symbol*;

    ref inout(T) opIndex(size_t i) inout nothrow pure @nogc
    {
        assert(i < length);
        return tab[i];
    }

    extern (D) inout(T)[] opSlice() inout nothrow pure @nogc
    {
        return tab[0 .. length];
    }

    extern (D) inout(T)[] opSlice(size_t a, size_t b) inout nothrow pure @nogc
    {
        assert(a <= b && b <= length);
        return tab[a .. b];
    }

    void dtor()
    {
        if (config.flags2 & (CFG2phgen | CFG2phuse | CFG2phauto | CFG2phautoy))
            MEM_PH_FREE(tab);
        else
            free(tab);
        length = 0;
        tab = null;
        symmax = 0;
    }

    SYMIDX length;              // 1 past end
    SYMIDX symmax;              // max # of entries in tab[] possible
    T* tab;                     // local Symbol table
}

/*********************************
 * Allocate/free symbol table.
 */

extern (C) Symbol **symtab_realloc(Symbol **tab, size_t symmax)
{   Symbol **newtab;

    if (config.flags2 & (CFG2phgen | CFG2phuse | CFG2phauto | CFG2phautoy))
    {
        newtab = cast(Symbol **) MEM_PH_REALLOC(tab, symmax * (Symbol *).sizeof);
    }
    else
    {
        newtab = cast(Symbol **) realloc(tab, symmax * (Symbol *).sizeof);
        if (!newtab)
            err_nomem();
    }
    return newtab;
}

Symbol **symtab_malloc(size_t symmax)
{   Symbol **newtab;

    if (config.flags2 & (CFG2phgen | CFG2phuse | CFG2phauto | CFG2phautoy))
    {
        newtab = cast(Symbol **) MEM_PH_MALLOC(symmax * (Symbol *).sizeof);
    }
    else
    {
        newtab = cast(Symbol **) malloc(symmax * (Symbol *).sizeof);
        if (!newtab)
            err_nomem();
    }
    return newtab;
}



