/**
 * Implement the `-deps` and `-makedeps` switches, which output dependencies of modules for build tools.
 *
 * The grammar of the `-deps` output is:
 * ---
 *      ImportDeclaration
 *          ::= BasicImportDeclaration [ " : " ImportBindList ] [ " -> "
 *      ModuleAliasIdentifier ] "\n"
 *
 *      BasicImportDeclaration
 *          ::= ModuleFullyQualifiedName " (" FilePath ") : " Protection|"string"
 *              " [ " static" ] : " ModuleFullyQualifiedName " (" FilePath ")"
 *
 *      FilePath
 *          - any string with '(', ')' and '\' escaped with the '\' character
 * ---
 *
 * Make dependencies as generated by `-makedeps` look like this:
 * ---
 * source/app.d:
 *   source/importa.d \
 *   source/importb.d
 * ---
 *
 * Copyright:   Copyright (C) 1999-2024 by The D Language Foundation, All Rights Reserved
 * License:     $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/src/dmd/deps.d, makedeps.d)
 * Documentation:  https://dlang.org/phobos/dmd_deps.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/deps.d
 */
module dmd.deps;

import core.stdc.stdio : printf;
import core.stdc.string : strcmp;
import dmd.common.outbuffer;
import dmd.dimport : Import;
import dmd.dmodule : Module;
import dmd.globals : Param, Output;
import dmd.hdrgen : visibilityToBuffer;
import dmd.id : Id;
import dmd.location : Loc;
import dmd.root.filename;
import dmd.root.string : toDString;
import dmd.utils : escapePath;

/**
 * Output the makefile dependencies for the -makedeps switch
 *
 * Params:
 *   buf = outbuffer to write into
 *   params = dmd params
 *   link = an executable is being generated
 *   lib = a library is being generated
 *   libExt = file extension of libraries for current target
 */
void writeMakeDeps(ref OutBuffer buf, const ref Param params, bool link, bool lib, const(char)[] libExt) pure
{
    // start by resolving and writing the target (which is sometimes resolved during link phase)
    if (link && params.exefile)
    {
        buf.writeEscapedMakePath(&params.exefile[0]);
    }
    else if (lib)
    {
        const(char)[] libname = params.libname ? params.libname : FileName.name(params.objfiles[0].toDString);
        libname = FileName.forceExt(libname, libExt);

        buf.writeEscapedMakePath(&libname[0]);
    }
    else if (params.objname)
    {
        buf.writeEscapedMakePath(&params.objname[0]);
    }
    else if (params.objfiles.length)
    {
        buf.writeEscapedMakePath(params.objfiles[0]);
        foreach (of; params.objfiles[1 .. $])
        {
            buf.writestring(" ");
            buf.writeEscapedMakePath(of);
        }
    }
    else
    {
        assert(false, "cannot resolve makedeps target");
    }

    buf.writestring(":");

    // then output every dependency
    foreach (dep; params.makeDeps.files)
    {
        buf.writestringln(" \\");
        buf.writestring("  ");
        buf.writeEscapedMakePath(dep);
    }
    buf.writenl();
}

/**
 * Add an import expression to module dependencies
 * Params:
 *   moduleDeps = output settings for `-deps`
 *   makeDeps = output settings for `-makedeps`
 *   fileNameZ = 0-termminated string containing the import expression's resolved filename
 *   importString = raw string passed to import exp
 *   imod = module import exp is in
 */
void addImportExpDep(ref Output moduleDeps, ref Output makeDeps, const(char)[] fileNameZ, const(char)[] importString, Module imod)
{
    if (moduleDeps.buffer !is null)
    {
        OutBuffer* ob = moduleDeps.buffer;

        if (!moduleDeps.name)
            ob.writestring("depsFile ");
        ob.writestring(imod.toPrettyChars());
        ob.writestring(" (");
        escapePath(ob, imod.srcfile.toChars());
        ob.writestring(") : ");
        if (moduleDeps.name)
            ob.writestring("string : ");
        ob.write(importString);
        ob.writestring(" (");
        escapePath(ob, fileNameZ.ptr);
        ob.writestring(")");
        ob.writenl();
    }
    if (makeDeps.doOutput)
    {
        makeDeps.files.push(fileNameZ.ptr);
    }
}

/**
 * Add an import statement to module dependencies
 * Params:
 *   moduleDeps = output settings
 *   imp = import to add
 *   imod = module that the import is in
 */
void addImportDep(ref Output moduleDeps, Import imp, Module imod)
{
    // object self-imports itself, so skip that
    // https://issues.dlang.org/show_bug.cgi?id=7547
    // don't list pseudo modules __entrypoint.d, __main.d
    // https://issues.dlang.org/show_bug.cgi?id=11117
    // https://issues.dlang.org/show_bug.cgi?id=11164
    if (moduleDeps.buffer is null || (imp.id == Id.object && imod.ident == Id.object) ||
        strcmp(imod.ident.toChars(), "__main") == 0)
        return;

    OutBuffer* ob = moduleDeps.buffer;
    if (!moduleDeps.name)
        ob.writestring("depsImport ");
    ob.writestring(imod.toPrettyChars());
    ob.writestring(" (");
    escapePath(ob, imod.srcfile.toChars());
    ob.writestring(") : ");
    // use visibility instead of sc.visibility because it couldn't be
    // resolved yet, see the comment above
    visibilityToBuffer(*ob, imp.visibility);
    ob.writeByte(' ');
    if (imp.isstatic)
    {
        ob.writestring("static ");
    }
    ob.writestring(": ");
    foreach (pid; imp.packages)
    {
        ob.printf("%s.", pid.toChars());
    }
    ob.writestring(imp.id.toString());
    ob.writestring(" (");
    if (imp.mod)
        escapePath(ob, imp.mod.srcfile.toChars());
    else
        ob.writestring("???");
    ob.writeByte(')');
    foreach (i, name; imp.names)
    {
        if (i == 0)
            ob.writeByte(':');
        else
            ob.writeByte(',');
        auto _alias = imp.aliases[i];
        if (!_alias)
        {
            ob.printf("%s", name.toChars());
            _alias = name;
        }
        else
            ob.printf("%s=%s", _alias.toChars(), name.toChars());
    }
    if (imp.aliasId)
        ob.printf(" -> %s", imp.aliasId.toChars());
    ob.writenl();
}

/**
 * Takes a path, and make it compatible with GNU Makefile format.
 *
 * GNU make uses a weird quoting scheme for white space.
 * A space or tab preceded by 2N+1 backslashes represents N backslashes followed by space;
 * a space or tab preceded by 2N backslashes represents N backslashes at the end of a file name;
 * and backslashes in other contexts should not be doubled.
 *
 * Params:
 *   buf = Buffer to write the escaped path to
 *   fname = Path to escape
 */
void writeEscapedMakePath(ref OutBuffer buf, const(char)* fname) pure
{
    uint slashes;

    while (*fname)
    {
        switch (*fname)
        {
        case '\\':
            slashes++;
            break;
        case '$':
            buf.writeByte('$');
            goto default;
        case ' ':
        case '\t':
            while (slashes--)
                buf.writeByte('\\');
            goto case;
        case '#':
            buf.writeByte('\\');
            goto default;
        case ':':
            // ':' not escaped on Windows because it can
            // create problems with absolute paths (e.g. C:\Project)
            version (Windows) {}
            else
            {
                buf.writeByte('\\');
            }
            goto default;
        default:
            slashes = 0;
            break;
        }

        buf.writeByte(*fname);
        fname++;
    }
}

///
unittest
{
    version (Windows)
    {
        enum input = `C:\My Project\file#4$.ext`;
        enum expected = `C:\My\ Project\file\#4$$.ext`;
    }
    else
    {
        enum input = `/foo\bar/weird$.:name#\ with spaces.ext`;
        enum expected = `/foo\bar/weird$$.\:name\#\\\ with\ spaces.ext`;
    }

    OutBuffer buf;
    buf.writeEscapedMakePath(input);
    assert(buf[] == expected);
}
