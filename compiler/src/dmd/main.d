
/**
 * Entry point for DMD console version.
 *
 * This modules defines the entry point (main) for DMD, as well as related
 * utilities needed for arguments parsing, path manipulation, etc...
 * This file is not shared with other compilers which use the DMD front-end.
 *
 * Copyright:   Copyright (C) 1999-2024 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 https://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/src/dmd/main.d, _main.d)
 * Documentation:  https://dlang.org/phobos/dmd_main.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/main.d
 */

module dmd.main;

version (NoMain) {} else
{

import core.stdc.stdio;
import core.stdc.stdlib;
import core.stdc.string;

import dmd.arraytypes : Modules, Strings;
import dmd.astenums;
import dmd.common.outbuffer;
import dmd.compiler;
import dmd.cond;
import dmd.console;
import dmd.cpreprocess;
import dmd.dinifile;
import dmd.dinterpret;
import dmd.dmdparams;
import dmd.dsymbolsem;
import dmd.dtemplate;
import dmd.dtoh;
import dmd.glue : generateCodeAndWrite;
import dmd.dmodule;
import dmd.dmsc : backend_init, backend_term;
import dmd.doc;
import dmd.dsymbol;
import dmd.errors;
import dmd.expression;
import dmd.file_manager;
import dmd.hdrgen;
import dmd.globals;
import dmd.hdrgen;
import dmd.id;
import dmd.identifier;
import dmd.inline;
import dmd.link;
import dmd.location;
import dmd.mars;
import dmd.mtype;
import dmd.objc;
import dmd.root.env;
import dmd.root.file;
import dmd.root.filename;
import dmd.root.man;
import dmd.root.response;
import dmd.root.rmem;
import dmd.root.string;
import dmd.root.stringtable;
import dmd.semantic2;
import dmd.semantic3;
import dmd.target;
import dmd.utils;
import dmd.vsoptions;

/**
 * DMD's entry point, C main.
 *
 * Without `-lowmem`, we need to switch to the bump-pointer allocation scheme
 * right from the start, before any module ctors are run, so we need this hook
 * before druntime is initialized and `_Dmain` is called.
 *
 * Returns:
 * Return code of the application
 */
extern (C) int main(int argc, char** argv)
{
    bool lowmem = false;
    foreach (i; 1 .. argc)
    {
        if (strcmp(argv[i], "-lowmem") == 0)
        {
            lowmem = true;
            break;
        }
    }
    if (!lowmem)
    {
        __gshared string[] disable_options = [ "gcopt=disable:1" ];
        rt_options = disable_options;
        mem.disableGC();
    }
    // initialize druntime and call _Dmain() below
    return _d_run_main(argc, argv, &_Dmain);
}
/**
 * Manual D main (for druntime initialization), which forwards to `tryMain`.
 *
 * Returns:
 * Return code of the application
 */
extern (C) int _Dmain(char[][])
{
    // possibly install memory error handler
    version (DigitalMars)
    {
        installMemErrHandler();
    }
    import core.runtime;
    version(D_Coverage)
    {
        // for now we need to manually set the source path
        string dirName(string path, char separator)
        {
            for (size_t i = path.length - 1; i > 0; i--)
            {
                if (path[i] == separator)
                    return path[0..i];
            }
            return path;
        }
        version (Windows)
            enum sourcePath = dirName(dirName(dirName(__FILE_FULL_PATH__, '\\'), '\\'), '\\');
        else
            enum sourcePath = dirName(dirName(dirName(__FILE_FULL_PATH__, '/'), '/'), '/');
        dmd_coverSourcePath(sourcePath);
        dmd_coverDestPath(sourcePath);
        dmd_coverSetMerge(true);
    }
    scope(failure) stderr.printInternalFailure;
    auto args = Runtime.cArgs();
    return tryMain(args.argc, cast(const(char)**)args.argv, global.params);
}

/************************************************************************************/

private:

/**
 * DMD's real entry point
 *
 * Parses command line arguments and config file, open and read all
 * provided source file and do semantic analysis on them.
 *
 * Params:
 *   argc = Number of arguments passed via command line
 *   argv = Array of string arguments passed via command line
 *
 * Returns:
 *   Application return code
 */
private int tryMain(size_t argc, const(char)** argv, ref Param params)
{
    import dmd.common.charactertables;

    Strings files;
    Strings libmodules;
    global._init();
    target.setTargetBuildDefaults();

    if (parseCommandlineAndConfig(argc, argv, params, files))
        return EXIT_FAILURE;

    global.compileEnv.previewIn        = global.params.previewIn;
    global.compileEnv.ddocOutput       = global.params.ddoc.doOutput;

    final switch(global.params.cIdentifierTable)
    {
        case CLIIdentifierTable.C99:
            global.compileEnv.cCharLookupTable = IdentifierCharLookup.forTable(IdentifierTable.C99);
            break;

        case CLIIdentifierTable.C11:
        case CLIIdentifierTable.default_:
            // ImportC is defined against C11, not C23.
            // If it was C23 this needs to be changed to UAX31 instead.
            global.compileEnv.cCharLookupTable = IdentifierCharLookup.forTable(IdentifierTable.C11);
            break;

        case CLIIdentifierTable.UAX31:
            global.compileEnv.cCharLookupTable = IdentifierCharLookup.forTable(IdentifierTable.UAX31);
            break;

        case CLIIdentifierTable.All:
            global.compileEnv.cCharLookupTable = IdentifierCharLookup.forTable(IdentifierTable.LR);
            break;
    }

    final switch(global.params.dIdentifierTable)
    {
        case CLIIdentifierTable.C99:
            global.compileEnv.dCharLookupTable = IdentifierCharLookup.forTable(IdentifierTable.C99);
            break;

        case CLIIdentifierTable.C11:
            global.compileEnv.dCharLookupTable = IdentifierCharLookup.forTable(IdentifierTable.C11);
            break;

        case CLIIdentifierTable.UAX31:
            global.compileEnv.dCharLookupTable = IdentifierCharLookup.forTable(IdentifierTable.UAX31);
            break;

        case CLIIdentifierTable.All:
        case CLIIdentifierTable.default_:
            // @@@DEPRECATED_2.119@@@
            // Change the default to UAX31,
            //  this is a breaking change as C99 (what D used for ~23 years),
            //  has characters that are not in UAX31.
            global.compileEnv.dCharLookupTable = IdentifierCharLookup.forTable(IdentifierTable.LR);
            break;
    }

    if (params.help.usage)
    {
        usage();
        return EXIT_SUCCESS;
    }

    if (params.v.logo)
    {
        logo();
        return EXIT_SUCCESS;
    }

    /*
    Prints a supplied usage text to the console and
    returns the exit code for the help usage page.

    Returns:
        `EXIT_SUCCESS` if no errors occurred, `EXIT_FAILURE` otherwise
    */
    static int printHelpUsage(string help)
    {
        printf("%.*s", cast(int)help.length, &help[0]);
        return global.errors ? EXIT_FAILURE : EXIT_SUCCESS;
    }

    /*
    Print a message to make it clear when warnings are treated as errors.
    */
    static void errorOnWarning()
    {
        error(Loc.initial, "warnings are treated as errors");
        errorSupplemental(Loc.initial, "Use -wi if you wish to treat warnings only as informational.");
    }

    // In case deprecation messages were omitted, inform the user about it
    static void mentionOmittedDeprecations()
    {
        if (global.params.v.errorLimit != 0 &&
            global.deprecations > global.params.v.errorLimit)
        {
            const omitted = global.deprecations - global.params.v.errorLimit;
            message(Loc.initial, "%d deprecation warning%s omitted, use `-verrors=0` to show all",
                omitted, omitted == 1 ? "".ptr : "s".ptr);
        }
    }

    /*
    Generates code to check for all `params` whether any usage page
    has been requested.
    If so, the generated code will print the help page of the flag
    and return with an exit code.

    Params:
        params = parameters with `Usage` suffices in `params` for which
        their truthness should be checked.

    Returns: generated code for checking the usage pages of the provided `params`.
    */
    static string generateUsageChecks(string[] params)
    {
        string s;
        foreach (n; params)
        {
            s ~= q{
                if (params.help.}~n~q{)
                    return printHelpUsage(CLIUsage.}~n~q{Usage);
            };
        }
        return s;
    }
    import dmd.cli : CLIUsage;
    mixin(generateUsageChecks(["mcpu", "transition", "check", "checkAction",
        "preview", "revert", "externStd", "hc"]));

    if (params.help.manual)
    {
        version (Windows)
        {
            browse("https://dlang.org/dmd-windows.html");
        }
        version (linux)
        {
            browse("https://dlang.org/dmd-linux.html");
        }
        version (OSX)
        {
            browse("https://dlang.org/dmd-osx.html");
        }
        version (FreeBSD)
        {
            browse("https://dlang.org/dmd-freebsd.html");
        }
        /*NOTE: No regular builds for openbsd/dragonflybsd (yet) */
        /*
        version (OpenBSD)
        {
            browse("https://dlang.org/dmd-openbsd.html");
        }
        version (DragonFlyBSD)
        {
            browse("https://dlang.org/dmd-dragonflybsd.html");
        }
        */
        return EXIT_SUCCESS;
    }

    if (params.v.color)
        global.console = cast(void*) createConsole(core.stdc.stdio.stderr);

    target.setCPU();
    Loc.set(params.v.showColumns, params.v.messageStyle);

    if (global.errors)
    {
        fatal();
    }
    if (files.length == 0)
    {
        if (params.jsonFieldFlags)
        {
            Modules modules;            // empty
            if (generateJson(modules, global.errorSink))
                fatal();
            return EXIT_SUCCESS;
        }
        usage();
        return EXIT_FAILURE;
    }

    reconcileCommands(params, target);
    setDefaultLibraries(target, driverParams.defaultlibname, driverParams.debuglibname);

    // Initialization
    target._init(params);
    Type._init();
    Id.initialize();
    Module._init();
    Expression._init();
    Objc._init();

    reconcileLinkRunLib(params, files.length, target.obj_ext);
    version(CRuntime_Microsoft)
    {
        import dmd.root.longdouble;
        initFPU();
    }
    import dmd.root.ctfloat : CTFloat;
    CTFloat.initialize();

    // Predefined version identifiers
    addDefaultVersionIdentifiers(params, target);

    if (params.v.verbose)
    {
        stdout.printPredefinedVersions();
        stdout.printGlobalConfigs();
    }
    //printf("%d source files\n", cast(int) files.length);

    // Build import search path

    static void buildPath(ref Strings imppath, ref Strings result)
    {
        Strings array;
        foreach (const path; imppath)
        {
            FileName.appendSplitPath(path, array);
        }
        result.append(&array);
    }

    if (params.mixinOut.doOutput)
    {
        params.mixinOut.buffer = cast(OutBuffer*)Mem.check(calloc(1, OutBuffer.sizeof));
        atexit(&flushMixins); // see comment for flushMixins
    }
    scope(exit) flushMixins();
    buildPath(params.imppath, global.path);
    buildPath(params.fileImppath, global.filePath);

    // Create Modules
    Modules modules;
    modules.reserve(files.length);
    if (createModules(files, libmodules, target, global.errorSink, modules))
        fatal();

    // Read files
    foreach (m; modules)
    {
        m.read(Loc.initial);
    }

    OutBuffer ddocbuf;          // buffer for contents of .ddoc files
    bool ddocbufIsRead;         // set when ddocbuf is filled

    /* Read ddoc macro files named by the DDOCFILE environment variable and command line
     * and concatenate the text into ddocbuf
     */
    void readDdocFiles(ref const Loc loc, ref const Strings ddocfiles, ref OutBuffer ddocbuf)
    {
        foreach (file; ddocfiles)
        {
            if (readFile(loc, file.toDString(), ddocbuf))
                fatal();
            // BUG: convert file contents to UTF-8 before use
            //printf("file: '%.*s'\n", cast(int)buffer.data.length, buffer.data.ptr);
        }
        ddocbufIsRead = true;
    }

    // Parse files
    bool anydocfiles = false;
    OutBuffer ddocOutputText;
    size_t filecount = modules.length;
    for (size_t filei = 0, modi = 0; filei < filecount; filei++, modi++)
    {
        Module m = modules[modi];
        if (params.v.verbose)
            message("parse     %s", m.toChars());
        if (!Module.rootModule)
            Module.rootModule = m;
        m.importedFrom = m; // m.isRoot() == true
//        if (!driverParams.oneobj || modi == 0 || m.isDocFile)
//            m.deleteObjFile();

        m.parse();
        if (m.filetype == FileType.dhdr)
        {
            // Remove m's object file from list of object files
            for (size_t j = 0; j < params.objfiles.length; j++)
            {
                if (m.objfile.toChars() == params.objfiles[j])
                {
                    params.objfiles.remove(j);
                    break;
                }
            }
            if (params.objfiles.length == 0)
                driverParams.link = false;
        }
        if (m.filetype == FileType.ddoc)
        {
            anydocfiles = true;
            if (!ddocbufIsRead)
                readDdocFiles(m.loc, global.params.ddoc.files, ddocbuf);

            ddocOutputText.setsize(0);
            gendocfile(m, ddocbuf[], global.datetime.ptr, global.errorSink, ddocOutputText);

            if (!writeFile(m.loc, m.docfile.toString(), ddocOutputText[]))
                fatal();

            // Remove m from list of modules
            modules.remove(modi);
            modi--;
            // Remove m's object file from list of object files
            for (size_t j = 0; j < params.objfiles.length; j++)
            {
                if (m.objfile.toChars() == params.objfiles[j])
                {
                    params.objfiles.remove(j);
                    break;
                }
            }
            if (params.objfiles.length == 0)
                driverParams.link = false;
        }
    }

    if (anydocfiles && modules.length && (driverParams.oneobj || params.objname))
    {
        error(Loc.initial, "conflicting Ddoc and obj generation options");
        fatal();
    }
    if (global.errors)
        fatal();

    if (params.dihdr.doOutput)
    {
        /* Generate 'header' import files.
         * Since 'header' import files must be independent of command
         * line switches and what else is imported, they are generated
         * before any semantic analysis.
         */
        OutBuffer buf;
        foreach (m; modules)
        {
            if (m.filetype == FileType.dhdr)
                continue;
            if (params.v.verbose)
                message("import    %s", m.toChars());

            buf.reset();         // reuse the buffer
            genhdrfile(m, params.dihdr.fullOutput, buf);
            if (!writeFile(m.loc, m.hdrfile.toString(), buf[]))
                fatal();
        }
    }
    if (global.errors)
        removeHdrFilesAndFail(params, modules);

    // load all unconditional imports for better symbol resolving
    foreach (m; modules)
    {
        if (params.v.verbose)
            message("importall %s", m.toChars());
        m.importAll(null);
    }
    if (global.errors)
        removeHdrFilesAndFail(params, modules);

    backend_init(params, driverParams, target);

    // Do semantic analysis
    foreach (m; modules)
    {
        if (params.v.verbose)
            message("semantic  %s", m.toChars());
        m.dsymbolSemantic(null);
    }
    //if (global.errors)
    //    fatal();
    Module.runDeferredSemantic();
    if (Module.deferred.length)
    {
        for (size_t i = 0; i < Module.deferred.length; i++)
        {
            Dsymbol sd = Module.deferred[i];
            error(sd.loc, "%s `%s` unable to resolve forward reference in definition", sd.kind(), sd.toPrettyChars());
        }
        //fatal();
    }

    // Do pass 2 semantic analysis
    foreach (m; modules)
    {
        if (params.v.verbose)
            message("semantic2 %s", m.toChars());
        m.semantic2(null);
    }
    Module.runDeferredSemantic2();
    if (global.errors)
        removeHdrFilesAndFail(params, modules);

    // Do pass 3 semantic analysis
    foreach (m; modules)
    {
        if (params.v.verbose)
            message("semantic3 %s", m.toChars());
        m.semantic3(null);
    }

    // Will be empty if no module has pragma(compileOnImport) or -i is passed to compiler.
    // Note: DO NOT USE foreach here because Module.amodules.length can
    //       change on each iteration of the loop
    for (size_t i = 0; i < compiledImports.length; i++)
    {
        auto m = compiledImports[i];
        assert(m.isRoot);
        if (params.v.verbose)
            message("semantic3 %s", m.toChars());
        m.semantic3(null);
        modules.push(m);
    }

    Module.runDeferredSemantic3();
    if (global.errors)
        removeHdrFilesAndFail(params, modules);

    // Scan for functions to inline
    foreach (m; modules)
    {
        if (params.useInline || m.hasAlwaysInlines)
        {
            if (params.v.verbose)
                message("inline scan %s", m.toChars());
            inlineScanModule(m);
        }
    }

    if (global.warnings)
        errorOnWarning();

    if (global.params.useDeprecated == DiagnosticReporting.inform)
        mentionOmittedDeprecations();

    // Do not attempt to generate output files if errors or warnings occurred
    if (global.errors || global.warnings)
        removeHdrFilesAndFail(params, modules);

    // inlineScan incrementally run semantic3 of each expanded functions.
    // So deps file generation should be moved after the inlining stage.
    if (OutBuffer* ob = params.moduleDeps.buffer)
    {
        foreach (i; 1 .. modules[0].aimports.length)
            semantic3OnDependencies(modules[0].aimports[i]);
        Module.runDeferredSemantic3();

        const data = (*ob)[];
        if (params.moduleDeps.name)
        {
            if (!writeFile(Loc.initial, params.moduleDeps.name, data))
                fatal();
        }
        else
            printf("%.*s", cast(int)data.length, data.ptr);
    }

    printCtfePerformanceStats();
    printTemplateStats(global.params.v.templatesListInstances, global.errorSink);

    // Generate output files
    if (params.json.doOutput)
    {
        if (generateJson(modules, global.errorSink))
            fatal();
    }
    if (!global.errors && params.ddoc.doOutput)
    {
        foreach (m; modules)
        {
            if (!ddocbufIsRead)
                readDdocFiles(m.loc, global.params.ddoc.files, ddocbuf);

            ddocOutputText.setsize(0);
            gendocfile(m, ddocbuf[], global.datetime.ptr, global.errorSink, ddocOutputText);

            if (!writeFile(m.loc, m.docfile.toString(), ddocOutputText[]))
                fatal();
        }
    }
    if (params.vcg_ast)
    {
        import dmd.hdrgen;
        foreach (mod; modules)
        {
            auto buf = OutBuffer();
            buf.doindent = 1;
            moduleToBuffer(buf, params.vcg_ast, mod);

            // write the output to $(filename).cg
            auto cgFilename = FileName.addExt(mod.srcfile.toString(), "cg");
            File.write(cgFilename.ptr, buf[]);
        }
    }

    if (global.params.cxxhdr.doOutput)
        genCppHdrFiles(modules);

    if (global.errors)
        fatal();

    if (driverParams.lib && params.objfiles.length == 0)
    {
        error(Loc.initial, "no input files");
        return EXIT_FAILURE;
    }

    if (params.addMain && !global.hasMainFunction)
    {
        auto mainModule = moduleWithEmptyMain();
        modules.push(mainModule);
        if (!driverParams.oneobj || modules.length == 1)
            params.objfiles.push(mainModule.objfile.toChars());
    }

    generateCodeAndWrite(modules[], libmodules[], params.libname, params.objdir,
                         driverParams.lib, params.obj, driverParams.oneobj, params.multiobj,
                         params.v.verbose);

    backend_term();

    if (global.errors)
        fatal();
    int status = EXIT_SUCCESS;
    if (!params.objfiles.length)
    {
        if (driverParams.link)
            error(Loc.initial, "no object files to link");
    }
    else
    {
        if (driverParams.link)
            status = runLINK(global.params.v.verbose, global.errorSink);
        if (params.run)
        {
            if (!status)
            {
                restoreEnvVars();
                status = runProgram(global.params.exefile, global.params.runargs[], global.params.v.verbose, global.errorSink);
                /* Delete .obj files and .exe file
                 */
                foreach (m; modules)
                {
                    m.deleteObjFile();
                    if (driverParams.oneobj)
                        break;
                }
                params.exefile.toCStringThen!(ef => File.remove(ef.ptr));
            }
        }
    }

    // Output the makefile dependencies
    if (params.makeDeps.doOutput)
        emitMakeDeps(params);

    if (global.warnings)
        errorOnWarning();

    if (global.errors || global.warnings)
        removeHdrFilesAndFail(params, modules);

    return status;
}

/**
 * Parses the command line arguments and configuration files
 *
 * Params:
 *   argc = Number of arguments passed via command line
 *   argv = Array of string arguments passed via command line
 *   params = parameters from argv
 *   files = files from argv
 * Returns: true on failure
 */
bool parseCommandlineAndConfig(size_t argc, const(char)** argv, ref Param params, ref Strings files)
{
    // Detect malformed input
    static bool badArgs()
    {
        error(Loc.initial, "missing or null command line arguments");
        return true;
    }

    if (argc < 1 || !argv)
        return badArgs();
    // Convert argc/argv into arguments[] for easier handling
    Strings arguments = Strings(argc);
    for (size_t i = 0; i < argc; i++)
    {
        if (!argv[i])
            return badArgs();
        arguments[i] = argv[i];
    }
    if (const(char)* missingFile = responseExpand(arguments)) // expand response files
        error(Loc.initial, "cannot open response file '%s'", missingFile);
    //for (size_t i = 0; i < arguments.length; ++i) printf("arguments[%d] = '%s'\n", i, arguments[i]);
    // Set default values
    params.argv0 = arguments[0].toDString;

    version (Windows)
        enum iniName = "sc.ini";
    else version (Posix)
        enum iniName = "dmd.conf";
    else
        static assert(0, "fix this");

    global.inifilename = parse_conf_arg(&arguments);
    if (global.inifilename)
    {
        // can be empty as in -conf=
        if (global.inifilename.length && !FileName.exists(global.inifilename))
            error(Loc.initial, "config file '%.*s' does not exist.",
                  cast(int)global.inifilename.length, global.inifilename.ptr);
    }
    else
    {
        global.inifilename = findConfFile(params.argv0, iniName);
    }
    // Read the configuration file
    OutBuffer inifileBuffer;
    File.read(global.inifilename, inifileBuffer);
    inifileBuffer.writeByte(0);         // ensure sentinel

    /* Need path of configuration file, for use in expanding @P macro
     */
    const(char)[] inifilepath = FileName.path(global.inifilename);
    Strings sections;
    StringTable!(char*) environment;
    environment._init(7);
    /* Read the [Environment] section, so we can later
     * pick up any DFLAGS settings.
     */
    sections.push("Environment");
    if (parseConfFile(environment, global.inifilename, inifilepath, cast(ubyte[])inifileBuffer[], &sections))
        return true;

    const(char)[] arch = target.isX86_64 ? "64" : "32"; // use default
    arch = parse_arch_arg(&arguments, arch);

    // parse architecture from DFLAGS read from [Environment] section
    {
        Strings dflags;
        getenv_setargv(readFromEnv(environment, "DFLAGS"), &dflags);
        environment.reset(7); // erase cached environment updates
        arch = parse_arch_arg(&dflags, arch);
    }

    bool isX86_64 = arch[0] == '6';

    version(Windows) // delete LIB entry in [Environment] (necessary for optlink) to allow inheriting environment for MS-COFF
        environment.update("LIB", 3).value = null;

    // read from DFLAGS in [Environment{arch}] section
    char[80] envsection = void;
    snprintf(envsection.ptr, envsection.length, "Environment%.*s", cast(int) arch.length, arch.ptr);
    sections.push(envsection.ptr);
    if (parseConfFile(environment, global.inifilename, inifilepath, cast(ubyte[])inifileBuffer[], &sections))
        return true;
    getenv_setargv(readFromEnv(environment, "DFLAGS"), &arguments);
    updateRealEnvironment(environment);
    environment.reset(1); // don't need environment cache any more

    if (parseCommandLine(arguments, argc, params, files, target, driverParams, global.errorSink))
    {
        Loc loc;
        errorSupplemental(loc, "run `dmd` to print the compiler manual");
        errorSupplemental(loc, "run `dmd -man` to open browser on manual");
        return true;
    }

    // DDOCFILE specified in the sc.ini file comes first and gets overridden by user specified files
    if (char* p = getenv("DDOCFILE"))
        global.params.ddoc.files.shift(p);

    if (target.isX86_64 != isX86_64)
        error(Loc.initial, "the architecture must not be changed in the %s section of %.*s",
              envsection.ptr, cast(int)global.inifilename.length, global.inifilename.ptr);

    global.preprocess = &preprocess;
    return false;
}

/// Emit the makefile dependencies for the -makedeps switch
void emitMakeDeps(ref Param params)
{
    assert(params.makeDeps.doOutput);

    OutBuffer buf;

    // start by resolving and writing the target (which is sometimes resolved during link phase)
    if (driverParams.link && params.exefile)
    {
        buf.writeEscapedMakePath(&params.exefile[0]);
    }
    else if (driverParams.lib)
    {
        const(char)[] libname = params.libname ? params.libname : FileName.name(params.objfiles[0].toDString);
        libname = FileName.forceExt(libname,target.lib_ext);

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

    const data = buf[];
    if (params.makeDeps.name)
    {
        if (!writeFile(Loc.initial, params.makeDeps.name, data))
            fatal();
    }
    else
        printf("%.*s", cast(int) data.length, data.ptr);
}

// in druntime:
alias MainFunc = extern(C) int function(char[][] args);
extern (C) int _d_run_main(int argc, char** argv, MainFunc dMain);


// When using a C main, host DMD may not link against host druntime by default.
version (DigitalMars)
{
    version (Win64)
        pragma(lib, "phobos64");
    else version (Win32)
    {
        version (CRuntime_Microsoft)
            pragma(lib, "phobos32mscoff");
        else
            pragma(lib, "phobos");
    }
}

extern extern(C) __gshared string[] rt_options;

/***********************************************
 * Adjust gathered command line switches and reconcile them.
 * Params:
 *      params = switches gathered from command line,
 *               and update in place
 *      target = more switches from the command line,
 *               update in place
 *      numSrcFiles = number of source files
 */
void reconcileCommands(ref Param params, ref Target target)
{
    if (target.os == Target.OS.OSX)
    {
        driverParams.pic = PIC.pic;
    }
    else if (target.os == Target.OS.Windows)
    {
        if (driverParams.pic)
            error(Loc.initial, "`-fPIC` and `-fPIE` cannot be used when targetting windows");
        if (driverParams.dwarf)
            error(Loc.initial, "`-gdwarf` cannot be used when targetting windows");
    }
    else if (target.os == Target.OS.DragonFlyBSD)
    {
        if (!target.isX86_64)
            error(Loc.initial, "`-m32` is not supported on DragonFlyBSD, it is 64-bit only");
    }

    if (target.os & (Target.OS.linux | Target.OS.FreeBSD | Target.OS.OpenBSD | Target.OS.Solaris | Target.OS.DragonFlyBSD))
    {
        if (driverParams.lib && driverParams.dll)
            error(Loc.initial, "cannot mix `-lib` and `-shared`");
    }
    if (target.os == Target.OS.Windows)
    {
        foreach(b; params.linkswitchIsForCC[])
        {
            if (b)
            {
                // Linking code is guarded by version (Posix):
                error(Loc.initial, "`Xcc=` link switches not available for this operating system");
                break;
            }
        }
    }
    else
    {
        if (driverParams.mscrtlib)
            error(Loc.initial, "`-mscrtlib` can only be used when targetting windows");
    }

    if (params.boundscheck != CHECKENABLE._default)
    {
        if (params.useArrayBounds == CHECKENABLE._default)
            params.useArrayBounds = params.boundscheck;
    }

    if (params.useUnitTests)
    {
        if (params.useAssert == CHECKENABLE._default)
            params.useAssert = CHECKENABLE.on;
    }

    if (params.release)
    {
        if (params.useInvariants == CHECKENABLE._default)
            params.useInvariants = CHECKENABLE.off;

        if (params.useIn == CHECKENABLE._default)
            params.useIn = CHECKENABLE.off;

        if (params.useOut == CHECKENABLE._default)
            params.useOut = CHECKENABLE.off;

        if (params.useArrayBounds == CHECKENABLE._default)
            params.useArrayBounds = CHECKENABLE.safeonly;

        if (params.useAssert == CHECKENABLE._default)
            params.useAssert = CHECKENABLE.off;

        if (params.useSwitchError == CHECKENABLE._default)
            params.useSwitchError = CHECKENABLE.off;
    }
    else
    {
        if (params.useInvariants == CHECKENABLE._default)
            params.useInvariants = CHECKENABLE.on;

        if (params.useIn == CHECKENABLE._default)
            params.useIn = CHECKENABLE.on;

        if (params.useOut == CHECKENABLE._default)
            params.useOut = CHECKENABLE.on;

        if (params.useArrayBounds == CHECKENABLE._default)
            params.useArrayBounds = CHECKENABLE.on;

        if (params.useAssert == CHECKENABLE._default)
            params.useAssert = CHECKENABLE.on;

        if (params.useSwitchError == CHECKENABLE._default)
            params.useSwitchError = CHECKENABLE.on;
    }

    if (params.betterC)
    {
        if (params.checkAction != CHECKACTION.halt)
            params.checkAction = CHECKACTION.C;

        params.useModuleInfo = false;
        params.useTypeInfo = false;
        params.useExceptions = false;
        params.useGC = false;
    }
}

/***********************************************
 * Adjust link, run and lib line switches and reconcile them.
 * Params:
 *      params = switches gathered from command line,
 *               and update in place
 *      numSrcFiles = number of source files
 *      obj_ext = object file extension
 */
void reconcileLinkRunLib(ref Param params, size_t numSrcFiles, const char[] obj_ext)
{
    if (!params.obj || driverParams.lib)
        driverParams.link = false;

    if (target.os == Target.OS.Windows)
    {
        if (!driverParams.mscrtlib)
        {
            version (Windows)
            {
                VSOptions vsopt;
                vsopt.initialize();
                driverParams.mscrtlib = vsopt.defaultRuntimeLibrary(target.isX86_64).toDString;
            }
            else
            {
                if (driverParams.link)
                    error(Loc.initial, "must supply `-mscrtlib` manually when cross compiling to windows");
            }
        }
    }

    if (driverParams.link)
    {
        params.exefile = params.objname;
        driverParams.oneobj = true;
        if (params.objname)
        {
            /* Use this to name the one object file with the same
             * name as the exe file.
             */
            params.objname = FileName.forceExt(params.objname, obj_ext);
            /* If output directory is given, use that path rather than
             * the exe file path.
             */
            if (params.objdir)
            {
                const(char)[] name = FileName.name(params.objname);
                params.objname = FileName.combine(params.objdir, name);
            }
        }
    }
    else if (params.run)
    {
        error(Loc.initial, "flags conflict with -run");
        fatal();
    }
    else if (driverParams.lib)
    {
        params.libname = params.objname;
        params.objname = null;
        // Haven't investigated handling these options with multiobj
        if (!params.cov && !params.trace)
            params.multiobj = true;
    }
    else
    {
        if (params.objname && numSrcFiles)
        {
            driverParams.oneobj = true;
            //error("multiple source files, but only one .obj name");
            //fatal();
        }
    }
}

}
