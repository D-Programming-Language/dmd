/**
 * Extract symbols from an ELF object file.
 *
 * Copyright:   Copyright (C) 1999-2024 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 https://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/src/dmd/scanelf.d, _scanelf.d)
 * Documentation:  https://dlang.org/phobos/dmd_scanelf.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/scanelf.d
 */

module dmd.lib.scanelf;

import core.stdc.string;
import core.stdc.stdint;
import core.checkedint;

import dmd.errorsink;
import dmd.location;

nothrow:

enum LOG = false;

/*****************************************
 * Reads an object module from base[] and passes the names
 * of any exported symbols to (*pAddSymbol)().
 * Params:
 *      pAddSymbol =  function to pass the names to
 *      base =        array of contents of object module
 *      module_name = name of the object module (used for error messages)
 *      filename =    object file name for error printing
 *      eSink =       where the error messages go
 */
package(dmd.lib)
void scanElfObjModule(void delegate(const(char)[] name, int pickAny) nothrow pAddSymbol,
        scope const ubyte[] base, const char* module_name, const(char)[] filename, ErrorSink eSink)
{
    static if (LOG)
    {
        printf("scanElfObjModule(%s)\n", module_name);
    }

    void corrupt(int reason)
    {
        eSink.error(Loc.initial, "corrupt ELF object `%.*s` module `%s` %d", cast(int) filename.length, filename.ptr, module_name, reason);
    }

    if (base.length < Elf32_Ehdr.sizeof)
        return corrupt(__LINE__); // must be at least large enough for ELF32
    static immutable ubyte[4] elf = [0x7F, 'E', 'L', 'F']; // ELF file signature
    if (base[0 .. elf.length] != elf[])
        return corrupt(__LINE__);

    if (base[EI_VERSION] != EV_CURRENT)
    {
        return eSink.error(Loc.initial, "ELF object module `%s` has EI_VERSION = %d, should be %d",
            module_name, base[EI_VERSION], EV_CURRENT);
    }
    if (base[EI_DATA] != ELFDATA2LSB)
    {
        return eSink.error(Loc.initial, "ELF object module `%s` is byte swapped and unsupported", module_name);
    }
    if (base[EI_CLASS] != ELFCLASS32 && base[EI_CLASS] != ELFCLASS64)
    {
        return eSink.error(Loc.initial, "ELF object module `%s` is unrecognized class %d", module_name, base[EI_CLASS]);
    }

    void scanELF(uint model)() nothrow
    {
        static if (model == 32)
        {
            alias ElfXX_Ehdr = Elf32_Ehdr;
            alias ElfXX_Shdr = Elf32_Shdr;
            alias ElfXX_Sym = Elf32_Sym;
        }
        else
        {
            static assert(model == 64);
            alias ElfXX_Ehdr = Elf64_Ehdr;
            alias ElfXX_Shdr = Elf64_Shdr;
            alias ElfXX_Sym = Elf64_Sym;
        }

        if (base.length < ElfXX_Ehdr.sizeof)
            return corrupt(__LINE__);

        const eh = cast(const(ElfXX_Ehdr)*) base.ptr;
        if (eh.e_type != ET_REL)
            return eSink.error(Loc.initial, "ELF object module `%s` is not relocatable", module_name);
        if (eh.e_version != EV_CURRENT)
            return corrupt(__LINE__);

        bool overflow;
        const end = addu(eh.e_shoff, mulu(eh.e_shentsize, eh.e_shnum, overflow), overflow);
        if (overflow || end > base.length)
            return corrupt(__LINE__);

        /* For each Section
         */
        const sections = (cast(const(ElfXX_Shdr)*)(base.ptr + eh.e_shoff))[0 .. eh.e_shnum];
        foreach (ref const section; sections)
        {
            if (section.sh_type != SHT_SYMTAB)
                continue;

            bool checkShdrXX(const ref ElfXX_Shdr shdr)
            {
                bool overflow;
                return addu(shdr.sh_offset, shdr.sh_size, overflow) > base.length || overflow;
            }

            if (checkShdrXX(section))
                return corrupt(__LINE__);

            /* sh_link gives the particular string table section
             * used for the symbol names.
             */
            if (section.sh_link >= eh.e_shnum)
                return corrupt(__LINE__);

            const string_section = &sections[section.sh_link];
            if (string_section.sh_type != SHT_STRTAB)
                return corrupt(__LINE__);

            if (checkShdrXX(*string_section))
                return corrupt(__LINE__);

            const string_tab = (cast(const(char)[])base)
                [cast(size_t)string_section.sh_offset ..
                 cast(size_t)(string_section.sh_offset + string_section.sh_size)];

            /* Get the array of symbols this section refers to
             */
            const symbols = (cast(ElfXX_Sym*)(base.ptr + cast(size_t)section.sh_offset))
                [0 .. cast(size_t)(section.sh_size / ElfXX_Sym.sizeof)];

            foreach (ref const sym; symbols)
            {
                const stb = sym.st_info >> 4;
                if (stb != STB_GLOBAL && stb != STB_WEAK || sym.st_shndx == SHN_UNDEF)
                    continue; // it's extern

                if (sym.st_name >= string_tab.length)
                    return corrupt(__LINE__);

                const name = &string_tab[sym.st_name];
                //printf("sym st_name = x%x\n", sym.st_name);
                const pend = cast(const(char*)) memchr(name, 0, string_tab.length - sym.st_name);
                if (!pend)       // if didn't find terminating 0 inside the string section
                    return corrupt(__LINE__);
                pAddSymbol(name[0 .. pend - name], 1);
            }
        }
    }

    if (base[EI_CLASS] == ELFCLASS32)
    {
        scanELF!32;
    }
    else
    {
        assert(base[EI_CLASS] == ELFCLASS64);
        scanELF!64;
    }
}

alias Elf32_Half = uint16_t;
alias Elf64_Half = uint16_t;

alias Elf32_Word  = uint32_t;
alias Elf32_Sword = int32_t;
alias Elf64_Word  = uint32_t;
alias Elf64_Sword = int32_t;

alias Elf32_Xword  = uint64_t;
alias Elf32_Sxword = int64_t;
alias Elf64_Xword  = uint64_t;
alias Elf64_Sxword = int64_t;

alias Elf32_Addr = uint32_t;
alias Elf64_Addr = uint64_t;

alias Elf32_Off = uint32_t;
alias Elf64_Off = uint64_t;

alias Elf32_Section = uint16_t;
alias Elf64_Section = uint16_t;

alias Elf32_Versym = Elf32_Half;
alias Elf64_Versym = Elf64_Half;

struct Elf32_Ehdr
{
    char[EI_NIDENT] e_ident = 0;
    Elf32_Half    e_type;
    Elf32_Half    e_machine;
    Elf32_Word    e_version;
    Elf32_Addr    e_entry;
    Elf32_Off     e_phoff;
    Elf32_Off     e_shoff;
    Elf32_Word    e_flags;
    Elf32_Half    e_ehsize;
    Elf32_Half    e_phentsize;
    Elf32_Half    e_phnum;
    Elf32_Half    e_shentsize;
    Elf32_Half    e_shnum;
    Elf32_Half    e_shstrndx;
}

struct Elf64_Ehdr
{
    char[EI_NIDENT] e_ident = 0;
    Elf64_Half    e_type;
    Elf64_Half    e_machine;
    Elf64_Word    e_version;
    Elf64_Addr    e_entry;
    Elf64_Off     e_phoff;
    Elf64_Off     e_shoff;
    Elf64_Word    e_flags;
    Elf64_Half    e_ehsize;
    Elf64_Half    e_phentsize;
    Elf64_Half    e_phnum;
    Elf64_Half    e_shentsize;
    Elf64_Half    e_shnum;
    Elf64_Half    e_shstrndx;
}

enum EI_NIDENT = 16;
enum EI_VERSION =      6;
enum EI_CLASS =        4;
enum EI_DATA =         5;
enum EV_CURRENT =      1;

enum ELFDATANONE =     0;
enum ELFDATA2LSB =     1;
enum ELFDATA2MSB =     2;
enum ELFDATANUM =      3;
enum ELFCLASSNONE =    0;
enum ELFCLASS32 =      1;
enum ELFCLASS64 =      2;
enum ELFCLASSNUM =     3;

enum ET_REL =          1;

struct Elf32_Shdr
{
    Elf32_Word    sh_name;
    Elf32_Word    sh_type;
    Elf32_Word    sh_flags;
    Elf32_Addr    sh_addr;
    Elf32_Off     sh_offset;
    Elf32_Word    sh_size;
    Elf32_Word    sh_link;
    Elf32_Word    sh_info;
    Elf32_Word    sh_addralign;
    Elf32_Word    sh_entsize;
}

struct Elf64_Shdr
{
    Elf64_Word    sh_name;
    Elf64_Word    sh_type;
    Elf64_Xword   sh_flags;
    Elf64_Addr    sh_addr;
    Elf64_Off     sh_offset;
    Elf64_Xword   sh_size;
    Elf64_Word    sh_link;
    Elf64_Word    sh_info;
    Elf64_Xword   sh_addralign;
    Elf64_Xword   sh_entsize;
}

enum SHT_SYMTAB =        2;
enum SHT_STRTAB =        3;

struct Elf32_Sym
{
    Elf32_Word    st_name;
    Elf32_Addr    st_value;
    Elf32_Word    st_size;
    ubyte st_info;
    ubyte st_other;
    Elf32_Section st_shndx;
}

struct Elf64_Sym
{
    Elf64_Word    st_name;
    ubyte st_info;
    ubyte st_other;
    Elf64_Section st_shndx;
    Elf64_Addr    st_value;
    Elf64_Xword   st_size;
}

enum STB_GLOBAL =      1;
enum STB_WEAK =        2;

enum SHN_UNDEF =       0;
