/**
 * Defines the help texts for the CLI options offered by DMD.
 *
 * This file is not shared with other compilers which use the DMD front-end.
 * However, this file will be used to generate the
 * $(LINK2 https://dlang.org/dmd-linux.html, online documentation) and MAN pages.
 *
 * Copyright:   Copyright (C) 1999-2024 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 https://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/src/dmd/cli.d, _cli.d)
 * Documentation:  https://dlang.org/phobos/dmd_cli.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/cli.d
 */
module dmd.cli;

/* The enum TargetOS is an exact copy of the one in dmd.globals.
 * Duplicated here because this file is stand-alone.
 */

/// Bit decoding of the TargetOS
enum TargetOS : ubyte
{
    /* These are mutually exclusive; one and only one is set.
     * Match spelling and casing of corresponding version identifiers
     */
    linux        = 1,
    Windows      = 2,
    OSX          = 4,
    OpenBSD      = 8,
    FreeBSD      = 0x10,
    Solaris      = 0x20,
    DragonFlyBSD = 0x40,

    // Combination masks
    all = linux | Windows | OSX | OpenBSD | FreeBSD | Solaris | DragonFlyBSD,
    Posix = linux | OSX | OpenBSD | FreeBSD | Solaris | DragonFlyBSD,
}

// Detect the current TargetOS
version (linux)
{
    private enum targetOS = TargetOS.linux;
}
else version(Windows)
{
    private enum targetOS = TargetOS.Windows;
}
else version(OSX)
{
    private enum targetOS = TargetOS.OSX;
}
else version(OpenBSD)
{
    private enum targetOS = TargetOS.OpenBSD;
}
else version(FreeBSD)
{
    private enum targetOS = TargetOS.FreeBSD;
}
else version(DragonFlyBSD)
{
    private enum targetOS = TargetOS.DragonFlyBSD;
}
else version(Solaris)
{
    private enum targetOS = TargetOS.Solaris;
}
else
{
    private enum targetOS = TargetOS.all;
}

/**
Checks whether `os` is the current $(LREF TargetOS).
For `TargetOS.all` it will always return true.

Params:
    os = $(LREF TargetOS) to check

Returns: true iff `os` contains the current targetOS.
*/
bool isCurrentTargetOS(TargetOS os) @safe
{
    return (os & targetOS) > 0;
}

/**
Capitalize a the first character of a ASCII string.
Params:
    w = ASCII i string to capitalize
Returns: capitalized string
*/
static string capitalize(string w)
{
    char[] result = cast(char[]) w;
    char c1 = w.length ? w[0] : '\0';

    if (c1 >= 'a' && c1 <= 'z')
    {
        enum adjustment = 'A' - 'a';

        result = new char[] (w.length);
        result[0] = cast(char) (c1 + adjustment);
        result[1 .. $] = w[1 .. $];
    }

    return cast(string) result;
}

/**
Contains all available CLI $(LREF Usage.Option)s.

See_Also: $(LREF Usage.Option)
*/
struct Usage
{
    /**
    * Representation of a CLI `Option`
    *
    * The DDoc description `ddoxText` is only available when compiled with `-version=DdocOptions`.
    */
    struct Option
    {
        string flag; /// The CLI flag without leading `-`, e.g. `color`
        string helpText; /// A detailed description of the flag
        TargetOS os = TargetOS.all; /// For which `TargetOS` the flags are applicable
        bool documented = true; // whether this option should be shown in the documentation

        // Needs to be version-ed to prevent the text ending up in the binary
        // See also: https://issues.dlang.org/show_bug.cgi?id=18238
        version(DdocOptions) string ddocText; /// Detailed description of the flag (in Ddoc)

        /**
        * Params:
        *  flag = CLI flag without leading `-`, e.g. `color`
        *  helpText = detailed description of the flag
        *  os = for which `TargetOS` the flags are applicable
        *  ddocText = detailed description of the flag (in Ddoc)
        *  documented = whether this option should be shown in the documentation
        */
        this(string flag, string helpText, TargetOS os = TargetOS.all, bool documented = true) @safe
        {
            this.flag = flag;
            this.helpText = helpText;
            version(DdocOptions) this.ddocText = helpText;
            this.os = os;
            this.documented = documented;
        }

        /// ditto
        this(string flag, string helpText, string ddocText, TargetOS os = TargetOS.all, bool documented = true) @safe
        {
            this.flag = flag;
            this.helpText = helpText;
            version(DdocOptions) this.ddocText = ddocText;
            this.os = os;
            this.documented = documented;
        }
    }

    /// Returns all available CLI options
    static immutable options = [
        Option("allinst",
            "generate code for all template instantiations"
        ),
        Option("betterC",
            "omit generating some runtime information and helper functions",
            "Adjusts the compiler to implement D as a $(LINK2 $(ROOT_DIR)spec/betterc.html, better C):
            $(UL
                $(LI Predefines `D_BetterC` $(LINK2 $(ROOT_DIR)spec/version.html#predefined-versions, version).)
                $(LI $(LINK2 $(ROOT_DIR)spec/expression.html#AssertExpression, Assert Expressions), when they fail,
                call the C runtime library assert failure function
                rather than a function in the D runtime.)
                $(LI $(LINK2 $(ROOT_DIR)spec/arrays.html#bounds, Array overflows)
                call the C runtime library assert failure function
                rather than a function in the D runtime.)
                $(LI $(LINK2 spec/statement.html#final-switch-statement/, Final switch errors)
                call the C runtime library assert failure function
                rather than a function in the D runtime.)
                $(LI Does not automatically link with phobos runtime library.)
                $(UNIX
                $(LI Does not generate Dwarf `eh_frame` with full unwinding information, i.e. exception tables
                are not inserted into `eh_frame`.)
                )
                $(LI Module constructors and destructors are not generated meaning that
                $(LINK2 $(ROOT_DIR)spec/class.html#StaticConstructor, static) and
                $(LINK2 $(ROOT_DIR)spec/class.html#SharedStaticConstructor, shared static constructors) and
                $(LINK2 $(ROOT_DIR)spec/class.html#StaticDestructor, destructors)
                will not get called.)
                $(LI `ModuleInfo` is not generated.)
                $(LI $(LINK2 $(ROOT_DIR)phobos/object.html#.TypeInfo, `TypeInfo`)
                instances will not be generated for structs.)
            )",
        ),
        Option("boundscheck=[on|safeonly|off]",
            "bounds checks on, in @safe only, or off",
            `Controls if bounds checking is enabled.
                $(UL
                    $(LI $(I on): Bounds checks are enabled for all code. This is the default.)
                    $(LI $(I safeonly): Bounds checks are enabled only in $(D @safe) code.
                                        This is the default for $(SWLINK -release) builds.)
                    $(LI $(I off): Bounds checks are disabled completely (even in $(D @safe)
                                   code). This option should be used with caution and as a
                                   last resort to improve performance. Confirm turning off
                                   $(D @safe) bounds checks is worthwhile by benchmarking.)
                )`
        ),
        Option("c",
            "compile only, do not link"
        ),
        Option("check=[assert|bounds|in|invariant|out|switch][=[on|off]]",
            "enable or disable specific checks",
            `Overrides default, -boundscheck, -release and -unittest options to enable or disable specific checks.
                $(UL
                    $(LI $(B assert): assertion checking)
                    $(LI $(B bounds): array bounds)
                    $(LI $(B in): in contracts)
                    $(LI $(B invariant): class/struct invariants)
                    $(LI $(B out): out contracts)
                    $(LI $(B switch): $(D final switch) failure checking)
                )
                $(UL
                    $(LI $(B on) or not specified: specified check is enabled.)
                    $(LI $(B off): specified check is disabled.)
                )`
        ),
        Option("check=[h|help|?]",
            "list information on all available checks"
        ),
        Option("checkaction=[D|C|halt|context]",
            "behavior on assert/boundscheck/finalswitch failure",
            `Sets behavior when an assert or an array bounds check fails,
             or a $(D final switch) errors.
                $(UL
                    $(LI $(B D): Default behavior, which throws an unrecoverable $(D AssertError).)
                    $(LI $(B C): Calls the C runtime library assert failure function.)
                    $(LI $(B halt): Executes a halt instruction, terminating the program.)
                    $(LI $(B context): Prints the error context as part of the unrecoverable $(D AssertError).)
                )`
        ),
        Option("checkaction=[h|help|?]",
            "list information on all available check actions"
        ),
        Option("color",
            "turn colored console output on"
        ),
        Option("color=[on|off|auto]",
            "force colored console output on or off, or only when not redirected (default)",
            `Show colored console output. The default depends on terminal capabilities.
            $(UL
                $(LI $(B auto): use colored output if a tty is detected (default))
                $(LI $(B on): always use colored output.)
                $(LI $(B off): never use colored output.)
            )`
        ),
        Option("conf=<filename>",
            "use config file at filename"
        ),
        Option("cov",
            "do code coverage analysis"
        ),
        Option("cov=ctfe", "Include code executed during CTFE in coverage report"),
        Option("cov=<nnn>",
            "require at least nnn% code coverage",
            `Perform $(LINK2 $(ROOT_DIR)code_coverage.html, code coverage analysis) and generate
            $(TT .lst) file with report.)
---
dmd -cov -unittest myprog.d
---
            `,
        ),
        Option("cpp=<filename>",
            "use filename as the name of the C preprocessor to use for ImportC files",
            `Normally the C preprocessor used by the associated C compiler is used to
            preprocess ImportC files,
            this is overridden by the $(TT -cpp) switch.`
        ),
        Option("D",
            "generate documentation",
            `$(P Generate $(LINK2 $(ROOT_DIR)spec/ddoc.html, documentation) from source.)
            $(P Note: mind the $(LINK2 $(ROOT_DIR)spec/ddoc.html#security, security considerations).)
            `,
        ),
        Option("Dd<directory>",
            "write documentation file to directory",
            `Write documentation file to $(I directory) . $(SWLINK -op)
            can be used if the original package hierarchy should
            be retained`,
        ),
        Option("Df<filename>",
            "write documentation file to filename"
        ),
        Option("d",
            "silently allow deprecated features and symbols",
            `Silently allow $(DDLINK deprecate,deprecate,deprecated features) and use of symbols with
            $(DDSUBLINK $(ROOT_DIR)spec/attribute, deprecated, deprecated attributes).`,
        ),
        Option("de",
            "issue an error when deprecated features or symbols are used (halt compilation)"
        ),
        Option("dw",
            "issue a message when deprecated features or symbols are used (default)"
        ),
        Option("debug",
            "compile in debug code",
            `Compile in $(LINK2 spec/version.html#debug, debug) code`,
        ),
        Option("debug=<level>",
            "compile in debug code <= level",
            `Compile in $(LINK2 spec/version.html#debug, debug level) &lt;= $(I level)`,
        ),
        Option("debug=<ident>",
            "compile in debug code identified by ident",
            `Compile in $(LINK2 spec/version.html#debug, debug identifier) $(I ident)`,
        ),
        Option("debuglib=<name>",
            "set symbolic debug library to name",
            `Link in $(I libname) as the default library when
            compiling for symbolic debugging instead of $(B $(LIB)).
            If $(I libname) is not supplied, then no default library is linked in.`
        ),
        Option("defaultlib=<name>",
            "set default library to name",
            `Link in $(I libname) as the default library when
            not compiling for symbolic debugging instead of $(B $(LIB)).
            If $(I libname) is not supplied, then no default library is linked in.`,
        ),
        Option("deps",
            "print module dependencies (imports/file/version/debug/lib)"
        ),
        Option("deps=<filename>",
            "write module dependencies to filename (only imports)",
            `Without $(I filename), print module dependencies
            (imports/file/version/debug/lib).
            With $(I filename), write module dependencies as text to $(I filename)
            (only imports).`,
        ),
        Option("dllimport=<value>",
            "Windows only: select symbols to dllimport (none/defaultLibsOnly/all)",
            `Which global variables to dllimport implicitly if not defined in a root module
            $(UL
                $(LI $(I none): None)
                $(LI $(I defaultLibsOnly): Only druntime/Phobos symbols)
                $(LI $(I all): All)
            )`,
        ),
        Option("extern-std=<standard>",
            "set C++ name mangling compatibility with <standard>",
            "Standards supported are:
            $(UL
                $(LI $(I c++98): Use C++98 name mangling,
                    Sets `__traits(getTargetInfo, \"cppStd\")` to `199711`)
                $(LI $(I c++11) (default): Use C++11 name mangling,
                    Sets `__traits(getTargetInfo, \"cppStd\")` to `201103`)
                $(LI $(I c++14): Use C++14 name mangling,
                    Sets `__traits(getTargetInfo, \"cppStd\")` to `201402`)
                $(LI $(I c++17): Use C++17 name mangling,
                    Sets `__traits(getTargetInfo, \"cppStd\")` to `201703`)
                $(LI $(I c++20): Use C++20 name mangling,
                    Sets `__traits(getTargetInfo, \"cppStd\")` to `202002`)
            )",
        ),
        Option("extern-std=[h|help|?]",
            "list all supported standards"
        ),
        Option("fIBT",
            "generate Indirect Branch Tracking code"
        ),
        Option("fPIC",
            "generate position independent code",
            cast(TargetOS) (TargetOS.all & ~(TargetOS.Windows | TargetOS.OSX))
        ),
        Option("fPIE",
            "generate position independent executables",
            cast(TargetOS) (TargetOS.all & ~(TargetOS.Windows | TargetOS.OSX))
        ),
        Option("ftime-trace",
            "turn on compile time profiler, generate JSON file with results",
            "Per function, the time to analyze it, call it from CTFE, generate code for it etc. will be measured,
            and events with a time longer than 500 microseconds (adjustable with `-ftime-trace-granularity`)
            will be recorded.
            The profiling result is output in the Chrome Trace Event Format,
            $(LINK2 https://docs.google.com/document/d/1CvAClvFfyA5R-PhYUmn5OOQtYMH4h6I0nSsKchNAySU/preview, described here).
            This can be turned into a more readable text file with the included tool `timetrace2txt`, or inspected
            with an interactive viewer such as $(LINK2 https://ui.perfetto.dev/, Perfetto)."
        ),
        Option("ftime-trace-granularity=",
            "Minimum time granularity (in microseconds) traced by time profiler (default: 500)",
            "Measured events shorter than the specified time will be discarded from the output.
            Set it too high, and interesting events may not show up in the output.
            Set too low, and the profiler overhead will be larger, and the output will be cluttered with tiny events."
        ),
        Option("ftime-trace-file=<filename>",
            "specify output file for -ftime-trace",
            "By default, the output name is the same as the first object file name, but with the `.time-trace` extension appended.
            A different filename can be chosen with this option, including a path relative to the current directory or an absolute path."
        ),
        Option("g",
            "add symbolic debug info",
            `$(WINDOWS
                Add CodeView symbolic debug info. See
                $(LINK2 https://dlang.org/windbg.html, Debugging on Windows).
            )
            $(UNIX
                Add symbolic debug info in DWARF format
                for debuggers such as
                $(D gdb)
            )`,
        ),
        Option("gdwarf=<version>",
            "add DWARF symbolic debug info",
            "The value of version may be 3, 4 or 5, defaulting to 3.",
            cast(TargetOS) (TargetOS.all & ~cast(uint)TargetOS.Windows)
        ),
        Option("gf",
            "emit debug info for all referenced types",
            `Symbolic debug info is emitted for all types referenced by the compiled code,
             even if the definition is in an imported file not currently being compiled.`,
        ),
        Option("gs",
            "always emit stack frame"
        ),
        Option("gx",
            "add stack stomp code",
            `Adds stack stomp code, which overwrites the stack frame memory upon function exit.`,
        ),
        Option("H",
            "generate 'header' file",
            `Generate $(RELATIVE_LINK2 $(ROOT_DIR)interface-files, D interface file)`,
        ),
        Option("Hd=<directory>",
            "write 'header' file to directory",
            `Write D interface file to $(I directory). $(SWLINK -op)
            can be used if the original package hierarchy should
            be retained.`,
        ),
        Option("Hf=<filename>",
            "write 'header' file to filename"
        ),
        Option("HC[=[?|h|help|silent|verbose]]",
            "write C++ 'header' equivalent to stdout",
            `write C++ 'header' equivalent to stdout configured with:",
            $(DL
            $(DT ?|h|help)$(DD list available options for C++ 'header' file generation)
            $(DT silent)$(DD only list extern(C[++]) declarations (default))
            $(DT verbose)$(DD also add comments for ignored declarations (e.g. extern(D)))
            )`,
        ),
        Option("HCd=<directory>",
            "write C++ 'header' file to directory",
            "write C++ 'header' file to directory, ignored if -HCf=<filename> is not present",
        ),
        Option("HCf=<filename>",
            "write C++ 'header' file to filename instead of stdout"
        ),
        Option("-help",
            "print help and exit"
        ),
        Option("I=<directory>",
            "look for imports also in directory"
        ),
        Option("i[=<pattern>]",
            "include imported modules in the compilation",
            q"{$(P Enables "include imports" mode, where the compiler will include imported
             modules in the compilation, as if they were given on the command line. By default, when
             this option is enabled, all imported modules are included except those in
             druntime/phobos. This behavior can be overridden by providing patterns via `-i=<pattern>`.
             A pattern of the form `-i=<package>` is an "inclusive pattern", whereas a pattern
             of the form `-i=-<package>` is an "exclusive pattern". Inclusive patterns will include
             all module's whose names match the pattern, whereas exclusive patterns will exclude them.
             For example. all modules in the package `foo.bar` can be included using `-i=foo.bar` or excluded
             using `-i=-foo.bar`. Note that each component of the fully qualified name must match the
             pattern completely, so the pattern `foo.bar` would not match a module named `foo.barx`.)

             $(P The default behavior of excluding druntime/phobos is accomplished by internally adding a
             set of standard exclusions, namely, `-i=-std -i=-core -i=-etc -i=-object`. Note that these
             can be overridden with `-i=std -i=core -i=etc -i=object`.)

             $(P When a module matches multiple patterns, matches are prioritized by their component length, where
             a match with more components takes priority (i.e. pattern `foo.bar.baz` has priority over `foo.bar`).)

             $(P By default modules that don't match any pattern will be included. However, if at
             least one inclusive pattern is given, then modules not matching any pattern will
             be excluded. This behavior can be overridden by usig `-i=.` to include by default or `-i=-.` to
             exclude by default.)

             $(P Note that multiple `-i=...` options are allowed, each one adds a pattern.)}"
        ),
        Option("identifiers=<table>",
            "Specify the non-ASCII tables for D identifiers",
            `Set the identifier table to use for the non-ASCII values.
                $(UL
                    $(LI $(I UAX31): UAX31)
                    $(LI $(I c99): C99)
                    $(LI $(I c11): C11)
                    $(LI $(I all): All, the least restrictive set, which comes with all others (default))
                )`
        ),
        Option("identifiers-importc=<table>",
            "Specify the non-ASCII tables for ImportC identifiers",
            `Set the identifier table to use for the non-ASCII values.
                $(UL
                    $(LI $(I UAX31): UAX31)
                    $(LI $(I c99): C99)
                    $(LI $(I c11): C11 (default))
                    $(LI $(I all): All, the least restrictive set, which comes with all others)
                )`
        ),
        Option("ignore",
            "deprecated flag, unsupported pragmas are always ignored now"
        ),
        Option("inline",
            "do function inlining",
            `Inline functions at the discretion of the compiler.
            This can improve performance, at the expense of making
            it more difficult to use a debugger on it.`,
        ),
        Option("J=<directory>",
            "look for string imports also in directory",
            `Where to look for files for
            $(LINK2 $(ROOT_DIR)spec/expression.html#ImportExpression, $(I ImportExpression))s.
            This switch is required in order to use $(I ImportExpression)s.
            $(I path) is a ; separated
            list of paths. Multiple $(B -J)'s can be used, and the paths
            are searched in the same order.`,
        ),
        Option("L=<linkerflag>",
            "pass linkerflag to link",
            `Pass $(I linkerflag) to the
            $(WINDOWS linker $(OPTLINK))
            $(UNIX linker), for example, ld`,
        ),
        Option("lib",
            "generate library rather than object files",
            `Generate library file as output instead of object file(s).
            All compiled source files, as well as object files and library
            files specified on the command line, are inserted into
            the output library.
            Compiled source modules may be partitioned into several object
            modules to improve granularity.
            The name of the library is taken from the name of the first
            source module to be compiled. This name can be overridden with
            the $(SWLINK -of) switch.`,
        ),
        Option("lowmem",
            "enable garbage collection for the compiler",
            `Enable the garbage collector for the compiler, reducing the
            compiler memory requirements but increasing compile times.`,
        ),
        Option("m32",
            "generate 32 bit code",
            `$(UNIX Compile a 32 bit executable. This is the default for the 32 bit dmd.)`,
            cast(TargetOS) (TargetOS.all & ~cast(uint)TargetOS.DragonFlyBSD)  // available on all OS'es except DragonFly, which does not support 32-bit binaries
        ),
        Option("m32mscoff",
            "generate 32 bit code and write MS-COFF object files (deprecated use -m32)",
            TargetOS.Windows
        ),
        Option("m64",
            "generate 64 bit code",
            `$(UNIX Compile a 64 bit executable. This is the default for the 64 bit dmd.)
            $(WINDOWS The generated object code is in MS-COFF and is meant to be used with the
            $(LINK2 https://msdn.microsoft.com/en-us/library/dd831853(v=vs.100).aspx, Microsoft Visual Studio 10)
            or later compiler.`,
        ),
        Option("main",
            "add default main() if not present already (e.g. for unittesting)",
            `Add a default $(D main()) function when compiling. This is useful when
            unittesting a library, as it enables running the unittests
            in a library without having to manually define an entry-point function.`,
        ),
        Option("makedeps[=<filename>]",
            "print dependencies in Makefile compatible format to filename or stdout.",
            `Print dependencies in Makefile compatible format.
            If filename is omitted, it prints to stdout.
            The emitted targets are the compiled artifacts (executable, object files, libraries).
            The emitted dependencies are imported modules and imported string files (via $(B -J) switch).
            Special characters in a dependency or target filename are escaped in the GNU Make manner.
            `,
        ),
        Option("man",
            "open web browser on manual page",
            `$(WINDOWS
                Open default browser on this page
            )
            $(LINUX
                Open browser specified by the $(B BROWSER)
                environment variable on this page. If $(B BROWSER) is
                undefined, $(B x-www-browser) is assumed.
            )
            $(FREEBSD
                Open browser specified by the $(B BROWSER)
                environment variable on this page. If $(B BROWSER) is
                undefined, $(B x-www-browser) is assumed.
            )
            $(OSX
                Open browser specified by the $(B BROWSER)
                environment variable on this page. If $(B BROWSER) is
                undefined, $(B Safari) is assumed.
            )`,
        ),
        Option("map",
            "generate linker .map file",
            `Generate a $(TT .map) file`,
        ),
        Option("mcpu=<id>",
            "generate instructions for architecture identified by 'id'",
            `Set the target architecture for code generation,
            where:
            $(DL
            $(DT help)$(DD list alternatives)
            $(DT baseline)$(DD the minimum architecture for the target platform (default))
            $(DT avx)$(DD
            generate $(LINK2 https://en.wikipedia.org/wiki/Advanced_Vector_Extensions, AVX)
            instructions instead of $(LINK2 https://en.wikipedia.org/wiki/Streaming_SIMD_Extensions, SSE)
            instructions for vector and floating point operations.
            Not available for 32 bit memory models other than OSX32.
            )
            $(DT native)$(DD use the architecture the compiler is running on)
            )`,
        ),
        Option("mcpu=[h|help|?]",
            "list all architecture options"
        ),
        Option("mixin=<filename>",
            "expand and save mixins to file specified by <filename>"
        ),
        Option("mscrtlib=<libname>",
            "MS C runtime library to reference from main/WinMain/DllMain",
            "If building MS-COFF object files when targeting Windows, embed a reference to
            the given C runtime library $(I libname) into the object file containing `main`,
            `DllMain` or `WinMain` for automatic linking. The default is $(TT libcmt)
            (release version with static linkage), the other usual alternatives are
            $(TT libcmtd), $(TT msvcrt) and $(TT msvcrtd).
            If no Visual C installation is detected, a wrapper for the redistributable
            VC2010 dynamic runtime library and mingw based platform import libraries will
            be linked instead using the LLD linker provided by the LLVM project.
            The detection can be skipped explicitly if $(TT msvcrt120) is specified as
            $(I libname).
            If $(I libname) is empty, no C runtime library is automatically linked in.",
            TargetOS.Windows,
        ),
        Option("mv=<package.module>=<filespec>",
            "use <filespec> as source file for <package.module>",
            `Use $(I path/filename) as the source file for $(I package.module).
            This is used when the source file path and names are not the same
            as the package and module hierarchy.
            The rightmost components of the  $(I path/filename) and $(I package.module)
            can be omitted if they are the same.`,
        ),
        Option("noboundscheck",
            "no array bounds checking (deprecated, use -boundscheck=off)",
            `Turns off all array bounds checking, even for safe functions. $(RED Deprecated
            (use $(TT $(SWLINK -boundscheck)=off) instead).)`,
        ),
        Option("nothrow",
            "assume no Exceptions will be thrown",
            `Turns off generation of exception stack unwinding code, enables
            more efficient code for RAII objects.`,
        ),
        Option("O",
            "optimize",
            `Optimize generated code. For fastest executables, compile
            with the $(TT $(SWLINK -O) $(SWLINK -release) $(SWLINK -inline) $(SWLINK -boundscheck)=off)
            switches together.`,
        ),
        Option("o-",
            "do not write object file",
            `Suppress generation of object file. Useful in
            conjuction with $(SWLINK -D) or $(SWLINK -H) flags.`
        ),
        Option("od=<directory>",
            "write object & library files to directory",
            `Write object files relative to directory $(I objdir)
            instead of to the current directory. $(SWLINK -op)
            can be used if the original package hierarchy should
            be retained`,
        ),
        Option("of=<filename>",
            "name output file to filename",
            `Set output file name to $(I filename) in the output
            directory. The output file can be an object file,
            executable file, or library file depending on the other
            switches.`
        ),
        Option("op",
            "preserve source path for output files",
            `Normally the path for $(B .d) source files is stripped
            off when generating an object, interface, or Ddoc file
            name. $(SWLINK -op) will leave it on.`,
        ),
        Option("oq",
            "Write object files with fully qualified file names",
            `When compiling pkg/app.d, the resulting object file name will be pkg_app.obj
            instead of app.o. This helps to prevent name conflicts when compiling multiple
            packages in the same directory with the $(SWLINK -od) flag.`,
        ),
        Option("os=<os>",
            "sets target operating system to <os>",
            `Set the target operating system as other than the host.
                $(UL
                    $(LI $(I host): Target the host operating system (default).)
                    $(LI $(I dragonflybsd): DragonFlyBSD)
                    $(LI $(I freebsd): FreeBSD)
                    $(LI $(I linux): Linux)
                    $(LI $(I openbsd): OpenBSD)
                    $(LI $(I osx): OSX)
                    $(LI $(I solaris): Solaris)
                    $(LI $(I windows): Windows)
                )`
        ),
        Option("P=<preprocessorflag>",
            "pass preprocessorflag to C preprocessor",
            `Pass $(I preprocessorflag) to
            $(WINDOWS cl.exe)
            $(UNIX cpp)`,
        ),
        Option("preview=<name>",
            "enable an upcoming language change identified by 'name'",
            `Preview an upcoming language change identified by $(I id)`,
        ),
        Option("preview=[h|help|?]",
            "list all upcoming language changes"
        ),
        Option("profile",
            "profile runtime performance of generated code",
            `Instrument the generated code so that runtime performance data is collected
            when the generated program is run.
            Upon completion of the generated program, the files $(TT trace.log) and $(TT trace.def)
            are generated. $(TT trace.log) has two sections,
            $(OL
            $(LI Fan in and fan out for each profiled function. The name of the function is left-justified,
            the functions immediately preceding it are the other functions that call it (fan in) and how many times
            it is called. The functions immediately following are the functions that are called (fan out) and how
            many times it calls that function. The function itself has 3 numbers appended: the aggregate of the fan in counts,
            the tree time used by the function which is the function time plus the tree times of all the functions it calls,
            and the time used excluding
            the time used by fan out.
            )
            $(LI Timing data for each function, sorted from most used to least.)
            )
            The $(TT trace.def) file contains linker commands to associate functions which are strongly coupled
            so they appear adjacent in the resulting executable file.
            For more information see $(LINK2 https://www.digitalmars.com/ctg/trace.html, profile)
            `,
        ),
        Option("profile=gc",
            "profile runtime allocations",
            `$(UL
                $(LI $(B gc): Instrument calls to GC memory allocation and
                write a report to the file $(TT profilegc.log) upon program
                termination.  $(B Note:) Only instrumented calls will be
                logged. These include:
                   $(UL
                       $(LI Language constructs that allocate memory)
                       $(LI Phobos functions that allocate GC memory)
                       $(LI GC allocations via core.memory.GC)
                   )
                   Allocations made by other means will not be logged,
                   including direct calls to the GC's C API.)
            )`,
        ),
        Option("release",
            "contracts and asserts are not emitted, and bounds checking is performed only in @safe functions",
            `Compile release version, which means not emitting run-time
            checks for contracts and asserts. Array bounds checking is not
            done for system and trusted functions, and assertion failures
            are undefined behaviour.`
        ),
        Option("revert=<name>",
            "revert language change identified by 'name'",
            `Revert language change identified by $(I id)`,
        ),
        Option("revert=[h|help|?]",
            "list all revertable language changes"
        ),
        Option("run <srcfile>",
            "compile, link, and run the program srcfile",
            `Compile, link, and run the program $(I srcfile) with the
            rest of the
            command line, $(I args...), as the arguments to the program.
            No .$(OBJEXT) or executable file is left behind.`
        ),
        Option("shared",
            "generate shared library (DLL)",
            `$(UNIX Generate shared library)
             $(WINDOWS Generate DLL library)`,
        ),
        Option("target=<triple>",
               "use <triple> as <arch>-[<vendor>-]<os>[-<cenv>[-<cppenv]]",
               "$(I arch) is the architecture: either `x86`, `x64`, `x86_64` or `x32`,
               $(I vendor) is always ignored, but supported for easier interoperability,
               $(I os) is the operating system, this may have a trailing version number:
               `freestanding` for no operating system,
               `darwin` or `osx` for MacOS, `dragonfly` or `dragonflybsd` for DragonflyBSD,
               `freebsd`, `openbsd`, `linux`, `solaris` or `windows` for their respective operating systems.
               $(I cenv) is the C runtime environment and is optional: `musl` for musl-libc,
               `msvc` for the MSVC runtime, `bionic` for the Andriod libc, `gnu` or `glibc`
               for the GCC C runtime, `newlib` or `uclibc` for their respective C runtimes.
               ($ I cppenv) is the C++ runtime environment: `clang` for the LLVM C++ runtime,
               `gcc` for GCC's C++ runtime, `msvc` for microsoft's MSVC C++ runtime,
               `sun` for Sun's C++ runtime.
               "
        ),
        Option("transition=<name>",
            "help with language change identified by 'name'",
            `Show additional info about language change identified by $(I id)`,
        ),
        Option("transition=[h|help|?]",
            "list all language changes"
        ),
        Option("unittest",
            "compile in unit tests",
            `Compile in $(LINK2 spec/unittest.html, unittest) code, turns on asserts, and sets the
             $(D unittest) $(LINK2 spec/version.html#PredefinedVersions, version identifier)`,
        ),
        Option("v",
            "verbose",
            `Enable verbose output for each compiler pass`,
        ),
        Option("vasm",
            "list generated assembler for each function"
        ),
        Option("vcolumns",
            "print character (column) numbers in diagnostics"
        ),
        Option("verror-style=[digitalmars|gnu|sarif]",
            "set the style for file/line number annotations on compiler messages",
            `Set the style for file/line number annotations on compiler messages,
            where:
            $(DL
            $(DT digitalmars)$(DD 'file(line[,column]): message'. This is the default.)
            $(DT gnu)$(DD 'file:line[:column]: message', conforming to the GNU standard used by gcc and clang.)
            $(DT sarif)$(DD 'Generates JSON output conforming to the SARIF (Static Analysis Results Interchange Format) standard, useful for integration with tools like GitHub and other SARIF readers.')
            )`,
        ),
        Option("verror-supplements=<num>",
            "limit the number of supplemental messages for each error (0 means unlimited)"
        ),
        Option("verrors=<num>",
            "limit the number of error/deprecation messages (0 means unlimited)"
        ),
        Option("verrors=[context|simple]",
            "set the verbosity of error messages",
            `Set the verbosity of error messages:
            $(DL
            $(DT context)$(DD Show error messages with the context of the erroring source line (including caret).)
            $(DT simple)$(DD Show error messages without the context of the erroring source line.)
            )`,
        ),
        Option("verrors=spec",
            "show errors from speculative compiles such as __traits(compiles,...)"
        ),
        Option("-version",
            "print compiler version and exit"
        ),
        Option("version=<level>",
            "compile in version code >= level",
            `Compile in $(LINK2 $(ROOT_DIR)spec/version.html#version, version level) >= $(I level)`,
        ),
        Option("version=<ident>",
            "compile in version code identified by ident",
            `Compile in $(LINK2 $(ROOT_DIR)spec/version.html#version, version identifier) $(I ident)`
        ),
        Option("vgc",
            "list all gc allocations including hidden ones"
        ),
        Option("visibility=<value>",
            "default visibility of symbols (default/hidden/public)",
            "$(UL
               $(LI $(I default): Hidden for Windows targets without -shared, otherwise public)
               $(LI $(I hidden):  Only export symbols marked with 'export')
               $(LI $(I public):  Export all symbols)
            )",
        ),
        Option("vtls",
            "list all variables going into thread local storage"
        ),
        Option("vtemplates=[list-instances]",
            "list statistics on template instantiations",
            `An optional argument determines extra diagnostics,
            where:
            $(DL
            $(DT list-instances)$(DD Also shows all instantiation contexts for each template.)
            )`,
        ),
        Option("w",
            "warnings as errors (compilation will halt)",
            `Enable $(LINK2 $(ROOT_DIR)articles/warnings.html, warnings)`
        ),
        Option("wi",
            "warnings as messages (compilation will continue)",
            `Enable $(LINK2 $(ROOT_DIR)articles/warnings.html, informational warnings (i.e. compilation
            still proceeds normally))`,
        ),
        Option("wo",
            "warnings about use of obsolete features (compilation will continue)",
            `Enable warnings about use of obsolete features that may be problematic (compilation
            still proceeds normally)`, TargetOS.all, false,
        ),
        Option("X",
            "generate JSON file"
        ),
        Option("Xf=<filename>",
            "write JSON file to filename"
        ),
        Option("Xcc=<driverflag>",
            "pass driverflag to linker driver (cc)",
            "Pass $(I driverflag) to the linker driver (`$CC` or `cc`)",
            cast(TargetOS) (TargetOS.all & ~cast(uint)TargetOS.Windows)
        ),
    ];

    /// Representation of a CLI feature
    struct Feature
    {
        string name; /// name of the feature
        string paramName; // internal transition parameter name
        string helpText; // detailed description of the feature
        string link; // link for more info
        bool documented = true; // whether this option should be shown in the documentation
        bool deprecated_; /// whether the feature is still in use
    }

    /// Returns all available transitions
    static immutable transitions = [
        Feature("field", "v.field",
            "list all non-mutable fields which occupy an object instance"),
        Feature("complex", "v.complex",
            "give deprecation messages about all usages of complex or imaginary types", "", true, true),
        Feature("tls", "v.tls",
            "list all variables going into thread local storage"),
        Feature("in", "v.vin",
            "list all usages of 'in' on parameter"),
    ];

    /// Returns all available reverts
    static immutable reverts = [
        Feature("dip25", "useDIP25", "revert DIP25 changes",
        "https://github.com/dlang/DIPs/blob/master/DIPs/archive/DIP25.md", true, true),
        Feature("dip1000", "useDIP1000",
                "revert DIP1000 changes (Scoped Pointers)",
                "https://github.com/dlang/DIPs/blob/master/DIPs/other/DIP1000.md"),
        Feature("intpromote", "fix16997", "revert integral promotions for unary + - ~ operators"),
        Feature("dtorfields", "dtorFields", "don't destruct fields of partially constructed objects"),
        Feature("fieldwise", "fieldwise", "don't use fieldwise comparisons for struct equality",
            "https://dlang.org/changelog/2.085.0.html#no-cmpsb"),
        Feature("rvaluerefparam", "rvalueRefParam",
                "revert rvalue arguments to ref parameters",
                "https://gist.github.com/andralex/e5405a5d773f07f73196c05f8339435a"),
    ];

    /// Returns all available previews
    static immutable previews = [
        // Note: generally changelog entries should be added to the spec
        Feature("dip25", "useDIP25",
            "implement Sealed References DIP",
            "https://github.com/dlang/DIPs/blob/master/DIPs/archive/DIP25.md", true, true),
        Feature("dip1000", "useDIP1000",
            "implement Scoped Pointers DIP",
            "https://github.com/dlang/DIPs/blob/master/DIPs/other/DIP1000.md"),
        Feature("dip1008", "ehnogc",
            "implement @nogc Throwable DIP",
            "https://github.com/dlang/DIPs/blob/master/DIPs/other/DIP1008.md"),
        Feature("dip1021", "useDIP1021",
            "implement Mutable Function Arguments DIP",
            "https://github.com/dlang/DIPs/blob/master/DIPs/accepted/DIP1021.md"),
        Feature("bitfields", "bitfields", "add C-like bitfields",
            "https://github.com/dlang/dlang.org/pull/3190"),
        Feature("fieldwise", "fieldwise", "use fieldwise comparisons for struct equality",
            "https://dlang.org/changelog/2.085.0.html#no-cmpsb", false, false),
        Feature("fixAliasThis", "fixAliasThis",
            "when a symbol is resolved, check alias this scope before going to upper scopes",
            "https://github.com/dlang/dmd/pull/8885"),
        Feature("intpromote", "fix16997",
            "fix integral promotions for unary + - ~ operators",
            "https://dlang.org/changelog/2.078.0.html#fix16997", false, true),
        Feature("dtorfields", "dtorFields",
            "destruct fields of partially constructed objects",
            "https://dlang.org/changelog/2.098.0.html#dtorfileds", false, false),
        Feature("safer", "safer",
            "more safety checks by default",
            "https://github.com/WalterBright/documents/blob/38f0a846726b571f8108f6e63e5e217b91421c86/safer.md", true, false),
        Feature("nosharedaccess", "noSharedAccess",
            "disable access to shared memory objects",
            "https://dlang.org/spec/const3.html#shared"),
        Feature("in", "previewIn",
            "`in` on parameters means `scope const [ref]` and accepts rvalues",
            "https://dlang.org/spec/function.html#in-params"),
        Feature("inclusiveincontracts", "inclusiveInContracts",
            "'in' contracts of overridden methods must be a superset of parent contract",
            "https://dlang.org/changelog/2.095.0.html#inclusive-incontracts"),
        Feature("shortenedMethods", "shortenedMethods",
            "allow use of => for methods and top-level functions in addition to lambdas",
            "https://dlang.org/spec/function.html#ShortenedFunctionBody", false, true),
        Feature("fixImmutableConv", "fixImmutableConv",
            "disallow `void[]` data from holding immutable data",
            "https://dlang.org/changelog/2.101.0.html#dmd.fix-immutable-conv, https://issues.dlang.org/show_bug.cgi?id=17148"),
        Feature("systemVariables", "systemVariables",
            "disable access to variables marked '@system' from @safe code",
            "https://dlang.org/spec/attribute.html#system-variables"),
    ];
}

/**
Formats the `Options` for CLI printing.
*/
struct CLIUsage
{
    /**
    Returns a string of all available CLI options for the current targetOS.
    Options are separated by newlines.
    */
    static string usage() @safe
    {
        enum maxFlagLength = 18;
        enum s = () {
            char[] buf;
            foreach (option; Usage.options)
            {
                if (!option.documented)
                    continue;
                if (option.os.isCurrentTargetOS)
                {
                    buf ~= "  -" ~ option.flag;
                    // create new lines if the flag name is too long
                    if (option.flag.length >= 17)
                    {
                            buf ~= "\n                    ";
                    }
                    else if (option.flag.length <= maxFlagLength)
                    {
                        const spaces = maxFlagLength - option.flag.length - 1;
                        buf.length += spaces;
                        buf[$ - spaces .. $] = ' ';
                    }
                    else
                    {
                            buf ~= "  ";
                    }
                    buf ~= option.helpText;
                    buf ~= "\n";
                }
            }
            return cast(string) buf;
        }();
        return s;
    }

    /// CPU architectures supported -mcpu=id
    enum mcpuUsage = "CPU architectures supported by -mcpu=id:
  =[h|help|?]    list information on all available choices
  =baseline      use default architecture as determined by target
  =avx           use AVX 1 instructions
  =avx2          use AVX 2 instructions
  =native        use CPU architecture that this compiler is running on
";

    static string generateFeatureUsage(const Usage.Feature[] features, string flagName, string description)
    {
        enum maxFlagLength = 20;
        auto buf = description.capitalize ~ " listed by -"~flagName~"=name:
";
        auto allTransitions = [Usage.Feature("all", null,
            "Enables all available " ~ description)] ~ features;
        foreach (t; allTransitions)
        {
            if (!t.documented)
                continue;
            buf ~= "  =";
            buf ~= t.name;
            buf ~= " "; // at least one separating space
            auto lineLength = "  =".length + t.name.length + " ".length;
            foreach (i; lineLength .. maxFlagLength)
                buf ~= " ";
            buf ~= t.helpText;
            if (t.deprecated_)
                buf ~= " [DEPRECATED]";
            if (t.link.length)
                buf ~= " (" ~ t.link ~ ")";
            buf ~= "\n";
        }
        return buf;
    }

    /// Language changes listed by -transition=id
    enum transitionUsage = generateFeatureUsage(Usage.transitions, "transition", "language transitions");

    /// Language changes listed by -revert
    enum revertUsage = generateFeatureUsage(Usage.reverts, "revert", "revertable language changes");

    /// Language previews listed by -preview
    enum previewUsage = generateFeatureUsage(Usage.previews, "preview", "upcoming language changes");

    /// Options supported by -checkaction=
    enum checkActionUsage = "Behavior on assert/boundscheck/finalswitch failure:
  =[h|help|?]    List information on all available choices
  =D             Usual D behavior of throwing an AssertError
  =C             Call the C runtime library assert failure function
  =halt          Halt the program execution (very lightweight)
  =context       Use D assert with context information (when available)
";

    /// Options supported by -check
    enum checkUsage = "Enable or disable specific checks:
  =[h|help|?]           List information on all available choices
  =assert[=[on|off]]    Assertion checking
  =bounds[=[on|off]]    Array bounds checking
  =in[=[on|off]]        Generate In contracts
  =invariant[=[on|off]] Class/struct invariants
  =out[=[on|off]]       Out contracts
  =switch[=[on|off]]    Final switch failure checking
  =on                   Enable all assertion checking
                        (default for non-release builds)
  =off                  Disable all assertion checking
";

    /// Options supported by -extern-std
    enum externStdUsage = "Available C++ standards:
  =[h|help|?]           List information on all available choices
  =c++98                Sets `__traits(getTargetInfo, \"cppStd\")` to `199711`
  =c++11                Sets `__traits(getTargetInfo, \"cppStd\")` to `201103`
  =c++14                Sets `__traits(getTargetInfo, \"cppStd\")` to `201402`
  =c++17                Sets `__traits(getTargetInfo, \"cppStd\")` to `201703`
  =c++20                Sets `__traits(getTargetInfo, \"cppStd\")` to `202002`
";

    /// Options supported by -HC
    enum hcUsage = "Available header generation modes:
  =[h|help|?]           List information on all available choices
  =silent               Silently ignore non-extern(C[++]) declarations
  =verbose              Add a comment for ignored non-extern(C[++]) declarations
";

    /// Options supported by -gdwarf
    enum gdwarfUsage = "Available DWARF versions:
  =[h|help|?]           List information on choices
  =3                    Emit DWARF version 3 debug information
  =4                    Emit DWARF version 4 debug information
  =5                    Emit DWARF version 5 debug information
";

}
