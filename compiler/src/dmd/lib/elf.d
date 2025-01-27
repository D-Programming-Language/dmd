/**
 * A library in the ELF format, used on Unix.
 *
 * Copyright:   Copyright (C) 1999-2024 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 https://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/src/dmd/libelf.d, _libelf.d)
 * Documentation:  https://dlang.org/phobos/dmd_libelf.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/libelf.d
 */

module dmd.lib.elf;

import core.stdc.time;
import core.stdc.string;
import core.stdc.stdlib;
import core.stdc.stdio;

version (Posix)
{
    import core.sys.posix.sys.stat;
    import core.sys.posix.unistd;
    alias Statbuf = stat_t;
}
else version (Windows)
{
    import core.sys.windows.stat;
    alias Statbuf = struct_stat;
}
else
    static assert(0, "unsupported operating system");

import dmd.errors : fatal;
import dmd.lib;
import dmd.location;
import dmd.utils;

import dmd.root.array;
import dmd.root.file;
import dmd.root.filename;
import dmd.common.outbuffer;
import dmd.root.port;
import dmd.root.rmem;
import dmd.root.string;
import dmd.root.stringtable;

import dmd.lib.scanelf;

// Entry point (only public symbol in this module).
package(dmd.lib) extern (C++) Library LibElf_factory()
{
    return new LibElf();
}

private: // for the remainder of this module
nothrow:

enum LOG = false;

struct ElfObjSymbol
{
    const(char)[] name;
    ElfObjModule* om;
}

alias ElfObjModules = Array!(ElfObjModule*);
alias ElfObjSymbols = Array!(ElfObjSymbol*);

final class LibElf : Library
{
    ElfObjModules objmodules; // ElfObjModule[]
    ElfObjSymbols objsymbols; // ElfObjSymbol[]
    StringTable!(ElfObjSymbol*) tab;

    extern (D) this()
    {
        tab._init(14_000);
    }

    /***************************************
     * Add object module or library to the library.
     * Examine the buffer to see which it is.
     * If the buffer is NULL, use module_name as the file name
     * and load the file.
     */
    override void addObject(const(char)[] module_name, const(ubyte)[] buffer)
    {
        static if (LOG)
        {
            printf("LibElf::addObject(%.*s)\n",
                   cast(int)module_name.length, module_name.ptr);
        }

        void corrupt(int reason)
        {
            eSink.error(Loc.initial, "corrupt ELF object `%.*s` module %.*s %d",
                cast(int) filename.length, filename.ptr, cast(int) module_name.length, module_name.ptr, reason);
        }

        int fromfile = 0;
        if (!buffer.length)
        {
            assert(module_name.length);
            // read file and take buffer ownership
            OutBuffer b;
            if (readFile(Loc.initial, module_name, b))
                fatal();
            buffer = cast(ubyte[])b.extractSlice();
            fromfile = 1;
        }
        if (buffer.length < 16)
        {
            static if (LOG)
            {
                printf("buf = %p, buffer.length = %d\n", buffer.ptr, buffer.length);
            }
            return corrupt(__LINE__);
        }
        if (memcmp(buffer.ptr, "!<arch>\n".ptr, 8) == 0)
        {
            /* Library file.
             * Pull each object module out of the library and add it
             * to the object module array.
             */
            static if (LOG)
            {
                printf("archive, buf = %p, buffer.length = %d\n", buffer.ptr, buffer.length);
            }
            uint offset = 8;
            char* symtab = null;
            uint symtab_size = 0;
            char* filenametab = null;
            uint filenametab_size = 0;
            uint mstart = cast(uint)objmodules.length;
            while (offset < buffer.length)
            {
                if (offset + ElfLibHeader.sizeof >= buffer.length)
                    return corrupt(__LINE__);
                ElfLibHeader* header = cast(ElfLibHeader*)(cast(ubyte*)buffer.ptr + offset);
                offset += ElfLibHeader.sizeof;
                char* endptr = null;
                uint size = cast(uint)strtoul(header.file_size.ptr, &endptr, 10);
                if (endptr >= header.file_size.ptr + 10 || *endptr != ' ')
                    return corrupt(__LINE__);
                if (offset + size > buffer.length)
                    return corrupt(__LINE__);
                if (header.object_name[0] == '/' && header.object_name[1] == ' ')
                {
                    /* Instead of rescanning the object modules we pull from a
                     * library, just use the already created symbol table.
                     */
                    if (symtab)
                        return corrupt(__LINE__);
                    symtab = cast(char*)buffer.ptr + offset;
                    symtab_size = size;
                    if (size < 4)
                        return corrupt(__LINE__);
                }
                else if (header.object_name[0] == '/' && header.object_name[1] == '/')
                {
                    /* This is the file name table, save it for later.
                     */
                    if (filenametab)
                        return corrupt(__LINE__);
                    filenametab = cast(char*)buffer.ptr + offset;
                    filenametab_size = size;
                }
                else
                {
                    auto om = new ElfObjModule();
                    om.base = cast(ubyte*)buffer.ptr + offset; /*- sizeof(ElfLibHeader)*/
                    om.length = size;
                    om.offset = 0;
                    if (header.object_name[0] == '/')
                    {
                        /* Pick long name out of file name table
                         */
                        uint foff = cast(uint)strtoul(header.object_name.ptr + 1, &endptr, 10);
                        uint i;
                        for (i = 0; 1; i++)
                        {
                            if (foff + i >= filenametab_size)
                                return corrupt(__LINE__);
                            char c = filenametab[foff + i];
                            if (c == '/')
                                break;
                        }
                        auto n = cast(char*)Mem.check(malloc(i + 1));
                        memcpy(n, filenametab + foff, i);
                        n[i] = 0;
                        om.name = n[0 .. i];
                    }
                    else
                    {
                        /* Pick short name out of header
                         */
                        auto n = cast(char*)Mem.check(malloc(ELF_OBJECT_NAME_SIZE));
                        for (int i = 0; 1; i++)
                        {
                            if (i == ELF_OBJECT_NAME_SIZE)
                                return corrupt(__LINE__);
                            char c = header.object_name[i];
                            if (c == '/')
                            {
                                n[i] = 0;
                                om.name = n[0 .. i];
                                break;
                            }
                            n[i] = c;
                        }
                    }
                    om.name_offset = -1;
                    om.file_time = strtoul(header.file_time.ptr, &endptr, 10);
                    om.user_id = cast(uint)strtoul(header.user_id.ptr, &endptr, 10);
                    om.group_id = cast(uint)strtoul(header.group_id.ptr, &endptr, 10);
                    om.file_mode = cast(uint)strtoul(header.file_mode.ptr, &endptr, 8);
                    om.scan = 0; // don't scan object module for symbols
                    objmodules.push(om);
                }
                offset += (size + 1) & ~1;
            }
            if (offset != buffer.length)
                return corrupt(__LINE__);
            /* Scan the library's symbol table, and insert it into our own.
             * We use this instead of rescanning the object module, because
             * the library's creator may have a different idea of what symbols
             * go into the symbol table than we do.
             * This is also probably faster.
             */
            uint nsymbols = Port.readlongBE(symtab);
            char* s = symtab + 4 + nsymbols * 4;
            if (4 + nsymbols * (4 + 1) > symtab_size)
                return corrupt(__LINE__);
            for (uint i = 0; i < nsymbols; i++)
            {
                const(char)[] name = s.toDString();
                s += name.length + 1;
                if (s - symtab > symtab_size)
                    return corrupt(__LINE__);
                uint moff = Port.readlongBE(symtab + 4 + i * 4);
                //printf("symtab[%d] moff = %x  %x, name = %s\n", i, moff, moff + ElfLibHeader.sizeof, name.ptr);
                for (uint m = mstart; 1; m++)
                {
                    if (m == objmodules.length)
                        return corrupt(__LINE__);  // didn't find it
                    ElfObjModule* om = objmodules[m];
                    //printf("\t%x\n", cast(char *)om.base - cast(char *)buffer.ptr);
                    if (moff + ElfLibHeader.sizeof == cast(char*)om.base - cast(char*)buffer.ptr)
                    {
                        addSymbol(om, name, 1);
                        //if (mstart == m)
                        //    mstart++;
                        break;
                    }
                }
            }
            return;
        }
        /* It's an object module
         */
        auto om = new ElfObjModule();
        om.base = cast(ubyte*)buffer.ptr;
        om.length = cast(uint)buffer.length;
        om.offset = 0;
        // remove path, but not extension
        om.name = toCString(FileName.name(module_name));
        om.name_offset = -1;
        om.scan = 1;
        if (fromfile)
        {
            Statbuf statbuf;
            int i = module_name.toCStringThen!(name => stat(name.ptr, &statbuf));
            if (i == -1) // error, errno is set
                return corrupt(__LINE__);
            om.file_time = statbuf.st_ctime;
            om.user_id = statbuf.st_uid;
            om.group_id = statbuf.st_gid;
            om.file_mode = statbuf.st_mode;
        }
        else
        {
            /* Mock things up for the object module file that never was
             * actually written out.
             */
            version (Posix)
            {
                __gshared uid_t uid;
                __gshared gid_t gid;
                __gshared int _init;
                if (!_init)
                {
                    _init = 1;
                    uid = getuid();
                    gid = getgid();
                }
                om.user_id = uid;
                om.group_id = gid;
            }
            else version (Windows)
            {
                om.user_id = 0;  // meaningless on Windows
                om.group_id = 0; // meaningless on Windows
            }
            else
                static assert(0, "unsupported operating system");

            time_t file_time = 0;
            time(&file_time);
            om.file_time = cast(long)file_time;
            om.file_mode = (1 << 15) | (6 << 6) | (4 << 3) | (4 << 0); // 0100644
        }
        objmodules.push(om);
    }

    /*****************************************************************************/

    void addSymbol(ElfObjModule* om, const(char)[] name, int pickAny = 0) nothrow
    {
        static if (LOG)
        {
            printf("LibElf::addSymbol(%s, %s, %d)\n", om.name.ptr, name.ptr, pickAny);
        }
        auto s = tab.insert(name.ptr, name.length, null);
        if (!s)
        {
            // already in table
            if (!pickAny)
            {
                s = tab.lookup(name.ptr, name.length);
                assert(s);
                ElfObjSymbol* os = s.value;
                eSink.error(Loc.initial, "multiple definition of %s: %s and %s: %s", om.name.ptr, name.ptr, os.om.name.ptr, os.name.ptr);
            }
        }
        else
        {
            auto os = new ElfObjSymbol();
            os.name = xarraydup(name);
            os.om = om;
            s.value = os;
            objsymbols.push(os);
        }
    }

private:
    /************************************
     * Scan single object module for dictionary symbols.
     * Send those symbols to LibElf::addSymbol().
     */
    void scanObjModule(ElfObjModule* om)
    {
        static if (LOG)
        {
            printf("LibElf::scanObjModule(%s)\n", om.name.ptr);
        }

        extern (D) void addSymbol(const(char)[] name, int pickAny) nothrow
        {
            this.addSymbol(om, name, pickAny);
        }

        scanElfObjModule(&addSymbol, om.base[0 .. om.length], om.name.ptr, filename, eSink);
    }

    /*****************************************************************************/
    /*****************************************************************************/
    /**********************************************
     * Create and write library to libbuf.
     * The library consists of:
     *      !<arch>\n
     *      header
     *      dictionary
     *      object modules...
     */
    protected override void writeLibToBuffer(ref OutBuffer libbuf)
    {
        static if (LOG)
        {
            printf("LibElf::WriteLibToBuffer()\n");
        }
        /************* Scan Object Modules for Symbols ******************/
        foreach (om; objmodules)
        {
            if (om.scan)
            {
                scanObjModule(om);
            }
        }
        /************* Determine string section ******************/
        /* The string section is where we store long file names.
         */
        uint noffset = 0;
        foreach (om; objmodules)
        {
            size_t len = om.name.length;
            if (len >= ELF_OBJECT_NAME_SIZE)
            {
                om.name_offset = noffset;
                noffset += len + 2;
            }
            else
                om.name_offset = -1;
        }
        static if (LOG)
        {
            printf("\tnoffset = x%x\n", noffset);
        }
        /************* Determine module offsets ******************/
        uint moffset = 8 + ElfLibHeader.sizeof + 4;
        foreach (os; objsymbols)
        {
            moffset += 4 + os.name.length + 1;
        }
        uint hoffset = moffset;
        static if (LOG)
        {
            printf("\tmoffset = x%x\n", moffset);
        }
        moffset += moffset & 1;
        if (noffset)
            moffset += ElfLibHeader.sizeof + noffset;
        foreach (om; objmodules)
        {
            moffset += moffset & 1;
            om.offset = moffset;
            moffset += ElfLibHeader.sizeof + om.length;
        }
        libbuf.reserve(moffset);
        /************* Write the library ******************/
        libbuf.write("!<arch>\n");
        ElfObjModule om;
        om.name_offset = -1;
        om.base = null;
        om.length = cast(uint)(hoffset - (8 + ElfLibHeader.sizeof));
        om.offset = 8;
        om.name = "";
        .time(&om.file_time);
        om.user_id = 0;
        om.group_id = 0;
        om.file_mode = 0;
        ElfLibHeader h;
        ElfOmToHeader(&h, &om);
        libbuf.write((&h)[0 .. 1]);
        char[4] buf;
        Port.writelongBE(cast(uint)objsymbols.length, buf.ptr);
        libbuf.write(buf[0 .. 4]);
        foreach (os; objsymbols)
        {
            Port.writelongBE(os.om.offset, buf.ptr);
            libbuf.write(buf[0 .. 4]);
        }
        foreach (os; objsymbols)
        {
            libbuf.writestring(os.name);
            libbuf.writeByte(0);
        }
        static if (LOG)
        {
            printf("\tlibbuf.moffset = x%x\n", libbuf.length);
        }
        /* Write out the string section
         */
        if (noffset)
        {
            if (libbuf.length & 1)
                libbuf.writeByte('\n');
            // header
            memset(&h, ' ', ElfLibHeader.sizeof);
            h.object_name[0] = '/';
            h.object_name[1] = '/';
            size_t len = snprintf(h.file_size.ptr, ELF_FILE_SIZE_SIZE, "%u", noffset);
            assert(len < 10);
            h.file_size[len] = ' ';
            h.trailer[0] = '`';
            h.trailer[1] = '\n';
            libbuf.write((&h)[0 .. 1]);
            foreach (om2; objmodules)
            {
                if (om2.name_offset >= 0)
                {
                    libbuf.writestring(om2.name);
                    libbuf.writeByte('/');
                    libbuf.writeByte('\n');
                }
            }
        }
        /* Write out each of the object modules
         */
        foreach (om2; objmodules)
        {
            if (libbuf.length & 1)
                libbuf.writeByte('\n'); // module alignment
            assert(libbuf.length == om2.offset);
            ElfOmToHeader(&h, om2);
            libbuf.write((&h)[0 .. 1]); // module header
            libbuf.write(om2.base[0 .. om2.length]); // module contents
        }
        static if (LOG)
        {
            printf("moffset = x%x, libbuf.length = x%x\n", moffset, libbuf.length);
        }
        assert(libbuf.length == moffset);
    }
}

/*****************************************************************************/
/*****************************************************************************/
struct ElfObjModule
{
    ubyte* base; // where are we holding it in memory
    uint length; // in bytes
    uint offset; // offset from start of library
    const(char)[] name; // module name (file name) with terminating 0
    int name_offset; // if not -1, offset into string table of name
    time_t file_time; // file time
    uint user_id;
    uint group_id;
    uint file_mode;
    int scan; // 1 means scan for symbols
}

enum ELF_OBJECT_NAME_SIZE = 16;
enum ELF_FILE_TIME_SIZE = 12;
enum ELF_USER_ID_SIZE = 6;
enum ELF_GROUP_ID_SIZE = 6;
enum ELF_FILE_MODE_SIZE = 8;
enum ELF_FILE_SIZE_SIZE = 10;
enum ELF_TRAILER_SIZE = 2;

struct ElfLibHeader
{
    char[ELF_OBJECT_NAME_SIZE] object_name;
    char[ELF_FILE_TIME_SIZE] file_time;
    char[ELF_USER_ID_SIZE] user_id;
    char[ELF_GROUP_ID_SIZE] group_id;
    char[ELF_FILE_MODE_SIZE] file_mode; // in octal
    char[ELF_FILE_SIZE_SIZE] file_size;
    char[ELF_TRAILER_SIZE] trailer;
}

void ElfOmToHeader(ElfLibHeader* h, ElfObjModule* om)
{
    char* buffer = cast(char*)h;
    // user_id and group_id are padded on 6 characters in Header struct.
    // Squashing to 0 if more than 999999.
    if (om.user_id > 999_999)
        om.user_id = 0;
    if (om.group_id > 999_999)
        om.group_id = 0;
    size_t len;
    if (om.name_offset == -1)
    {
        // "name/           1423563789  5000  5000  100640  3068      `\n"
        //  |^^^^^^^^^^^^^^^|^^^^^^^^^^^|^^^^^|^^^^^|^^^^^^^|^^^^^^^^^|^^
        //        name       file_time   u_id gr_id  fmode    fsize   trailer
        len = snprintf(buffer, ElfLibHeader.sizeof, "%-16s%-12llu%-6u%-6u%-8o%-10u`", om.name.ptr, cast(long)om.file_time, om.user_id, om.group_id, om.file_mode, om.length);
        // adding '/' after the name field
        const(size_t) name_length = om.name.length;
        assert(name_length < ELF_OBJECT_NAME_SIZE);
        buffer[name_length] = '/';
    }
    else
    {
        // "/162007         1423563789  5000  5000  100640  3068      `\n"
        //  |^^^^^^^^^^^^^^^|^^^^^^^^^^^|^^^^^|^^^^^|^^^^^^^|^^^^^^^^^|^^
        //     name_offset   file_time   u_id gr_id  fmode    fsize   trailer
        len = snprintf(buffer, ElfLibHeader.sizeof, "/%-15d%-12llu%-6u%-6u%-8o%-10u`", om.name_offset, cast(long)om.file_time, om.user_id, om.group_id, om.file_mode, om.length);
    }
    assert(ElfLibHeader.sizeof > 0 && len == ElfLibHeader.sizeof - 1);
    // replace trailing \0 with \n
    buffer[len] = '\n';
}
