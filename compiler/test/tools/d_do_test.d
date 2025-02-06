#!/usr/bin/env rdmd
/**
 * D testing tool.
 *
 * This module implements the test runner for all tests except `unit`.
 *
 * The general procedure is:
 *
 *  1. Parse the environment variables (`processEnvironment`)
 *  2. Extract test parameters from the source file (`gatherTestParameters`)
 * [3. Compile non-D sources (` collectExtraSources`)]
 *  4. Compile the test file (`tryMain`)
 *  5. Verify the compiler output (`compareOutput`)
 * [6. Run the generated executable (`tryMain`) ]
 * [5. Verify the executable's output (`compareOutput`) ]
 * [7. Run post-test steps (`tryMain`) ]
 *  8. Remove intermediate files (`tryMain`)
 *
 * Optional steps are marked with [...]
*/
module d_do_test;

import std.algorithm;
import std.array;
import std.conv;
import std.datetime.stopwatch;
import std.datetime.systime;
import std.exception;
import std.file;
import std.format;
import std.meta : AliasSeq;
import std.process;
import std.random;
import std.range : chain, choose, roundRobin, takeOne;
import std.regex;
import std.path;
import std.stdio;
import std.string;
import core.sys.posix.sys.wait;

/// Absolute path to the test directory
const dmdTestDir = __FILE_FULL_PATH__.dirName.dirName;

version(Win32)
{
    extern(C) int putenv(const char*);
}

/// Prints the `--help` information
void usage()
{
    write("d_do_test <test_file>\n"
          ~ "\n"
          ~ "   Note: this program is normally called through the Makefile, it"
          ~ "         is not meant to be called directly by the user.\n"
          ~ "\n"
          ~ "   example: d_do_test runnable/pi.d\n"
          ~ "\n"
          ~ "   relevant environment variables:\n"
          ~ "      ARGS:          set to execute all combinations of\n"
          ~ "      REQUIRED_ARGS: arguments always passed to the compiler\n"
          ~ "      DMD:           compiler to use, ex: ../src/dmd (required)\n"
          ~ "      CC:            C compiler to use, ex: cl, cc\n"
          ~ "      CXX:           C++ compiler to use, ex: cl, g++\n"
          ~ "      OS:            windows, linux, freebsd, osx, openbsd, netbsd, dragonflybsd\n"
          ~ "      RESULTS_DIR:   base directory for test results\n"
          ~ "      MODEL:         32 or 64 (required)\n"
          ~ "      AUTO_UPDATE:   set to 1 to auto-update mismatching test output\n"
          ~ "      PRINT_RUNTIME: set to 1 to print test runtime\n"
          ~ "\n"
          ~ "   windows vs non-windows portability env vars:\n"
          ~ "      DSEP:          \\\\ or /\n"
          ~ "      SEP:           \\ or / (required)\n"
          ~ "      OBJ:          .obj or .o (required)\n"
          ~ "      EXE:          .exe or <null> (required)\n");
}

/// Type of test to execute (mapped to the subdirectories)
enum TestMode
{
    COMPILE,      /// compilable
    FAIL_COMPILE, /// fail_compilation
    RUN,          /// runnable, runnable_cxx
    DSHELL,       /// dshell
}

/// Test parameters specified in the source file
/// (conditionally expanded depending on the environment)
struct TestArgs
{
    TestMode mode;                  /// Test type based on the directory

    bool     compileSeparately;     /// `COMPILE_SEPARATELY`: compile each source file separately
    bool     link;                  /// `LINK`: force linking for `fail_compilation` & `compilable` tests
    bool     clearDflags;           /// `DFLAGS`: whether DFLAGS should be cleared before invoking dmd
    string   executeArgs;           /// `EXECUTE_ARGS`: arguments passed to the compiled executable (for `runnable[_cxx]`)
    string   cxxflags;              /// `CXXFLAGS`: arguments passed to $CXX when compiling `EXTRA_CPP_SOURCES`
    string[] sources;               /// `EXTRA_SOURCES`: additional D sources (+ main source file)
    string[] compiledImports;       /// `COMPILED_IMPORTS`: files compiled alongside the main source
    string[] cppSources;            /// `EXTRA_CPP_SOURCES`: additional C++ sources
    string[] objcSources;           /// `EXTRA_OBJC_SOURCES`: additional Objective-C sources
    string   permuteArgs;           /// `PERMUTE_ARGS`: set of dmd arguments to permute for multiple test runs
    string[] argSets;               /// `ARG_SETS`: selection of dmd arguments to use in different test runs
    string   compileOutput;         /// `TEST_OUTPUT`: expected output of dmd
    string   compileOutputFile;     /// `TEST_OUTPUT_FILE`: file containing the expected `TEST_OUTPUT`
    string   runOutput;             /// `RUN_OUTPUT`: expected output of the compiled executable
    ubyte    runReturn;             /// `RUN_RETURN` expected exit code of the executable when run
    string   gdbScript;             /// `GDB_SCRIPT`: script executed when running the compiled executable in GDB
    string   gdbMatch;              /// `GDB_MATCH`: regex describing the expected output from executing `GDB_SSCRIPT`
    string   postScript;            /// `POSTSCRIPT`: bash script executed after a successful test
    string[] outputFiles;           /// generated files appended to the compilation output
    string   transformOutput;       /// Transformations for the compiler output
    string   requiredArgs;          /// `REQUIRED_ARGS`: dmd arguments passed when compiling D sources
    string   requiredArgsForLink;   /// `COMPILE_SEPARATELY`: dmd arguments passed when linking separately compiled objects
    string   disabledReason;        /// `DISABLED`: reason to skip this test or empty, if the test is not disabled

    /// Returns: whether this disabled due to some reason
    bool isDisabled() const { return disabledReason.length != 0; }
}

/// Test parameters specified in the environment (e.g. target model)
/// which are shared between all tests
struct EnvData
{
    string all_args;             /// `ARGS`: arguments to test in permutations
    string dmd;                  /// `DMD`: compiler under test
    string results_dir;          /// `RESULTS_DIR`: directory for temporary files
    string sep;                  /// `SEP`: directory separator (`/` or `\`)
    string dsep;                 /// `DSEP`: double directory separator ( `/` or `\\`)
    string obj;                  /// `OBJ`: object file extension (`.o` or `.obj`)
    string exe;                  /// `EXE`: executable file extension (none or `.exe`)
    string os;                   /// `OS`: host operating system (`linux`, `windows`, ...)
    string compiler;             /// `HOST_DMD`: host D compiler
    string ccompiler;            /// `CC`: host C compiler
    string cxxcompiler;          /// `CXX`: host C++ compiler
    string model;                /// `MODEL`: target model (`32` or `64`)
    string required_args;        /// `REQUIRED_ARGS`: flags added to the tests `REQUIRED_ARGS` parameter
    string cxxCompatFlags;       /// Additional flags passed to $(compiler) when `EXTRA_CPP_SOURCES` is present
    string[] picFlag;            /// Compiler flag for PIC (if requested from environment)
    bool dobjc;                  /// `D_OBJC`: run Objective-C tests
    bool coverage_build;         /// `COVERAGE`: coverage build, skip linking & executing to save time
    bool autoUpdate;             /// `AUTO_UPDATE`: update `(TEST|RUN)_OUTPUT` on missmatch
    bool printRuntime;           /// `PRINT_RUNTIME`: Print time spent on a single test
    bool tryDisabled;            /// `TRY_DISABLED`:Silently try disabled tests (ignore failure and report success)
}

/++
Creates a new EnvData instance based on the current environment.
Other code should not read from the environment.

Returns: an initialized EnvData instance
++/
immutable(EnvData) processEnvironment()
{
    static string envGetRequired(in char[] name)
    {
        if (auto value = environment.get(name))
            return value;

        writefln("Error: Missing environment variable '%s', was this called through the Makefile?",
            name);
        throw new SilentQuit();
    }

    EnvData envData;
    envData.all_args       = environment.get("ARGS");
    envData.results_dir    = envGetRequired("RESULTS_DIR");
    envData.sep            = envGetRequired ("SEP");
    envData.dsep           = environment.get("DSEP");
    envData.obj            = envGetRequired ("OBJ");
    envData.exe            = envGetRequired ("EXE");
    envData.os             = environment.get("OS");
    envData.dmd            = replace(envGetRequired("DMD"), "/", envData.sep);
    envData.compiler       = "dmd"; //should be replaced for other compilers
    envData.ccompiler      = environment.get("CC");
    envData.cxxcompiler    = environment.get("CXX");
    envData.model          = envGetRequired("MODEL");
    envData.required_args  = environment.get("REQUIRED_ARGS");
    envData.dobjc          = environment.get("D_OBJC") == "1";
    envData.coverage_build = environment.get("DMD_TEST_COVERAGE") == "1";
    envData.autoUpdate     = environment.get("AUTO_UPDATE", "") == "1";
    envData.printRuntime   = environment.get("PRINT_RUNTIME", "") == "1";
    envData.tryDisabled    = environment.get("TRY_DISABLED") == "1";

    enforce(envData.sep.length == 1,
        "Path separator must be a single character, not: `"~envData.sep~"`");

    if (envData.ccompiler.empty)
    {
        if (envData.os == "windows")
            envData.ccompiler = "cl";
        else
            envData.ccompiler = "cc";
    }
    if (envData.cxxcompiler.empty)
    {
        if (envData.os == "windows")
            envData.cxxcompiler = "cl";
        else
            envData.cxxcompiler = "c++";
    }

    version (Windows) {} else
    {
        version(X86_64)
            envData.picFlag = ["-fPIC"];
        if (environment.get("PIC", null) == "1")
            envData.picFlag = ["-fPIC"];
    }

    switch (envData.compiler)
    {
        case "dmd":
        case "ldc":
            version (CppRuntime_GNU)
                envData.cxxCompatFlags = " -L-lstdc++ -L--no-demangle";
            else version (CppRuntime_LLVM)
                envData.cxxCompatFlags = " -L-lc++ -L--no-demangle";
            else version (CppRuntime_Gcc)
                envData.cxxCompatFlags = " -L-lstdc++ -L--no-demangle";
            else version (CppRuntime_Clang)
                envData.cxxCompatFlags = " -L-lc++ -L--no-demangle";
            break;

        case "gdc":
            envData.cxxCompatFlags = "-Xlinker -lstdc++ -Xlinker --no-demangle";
            break;

        default:
            writeln("Unknown compiler: ", envData.compiler);
            throw new SilentQuit();
    }

    return cast(immutable) envData;
}

/**
 * Read the single-line test parameter `token` from the source code which
 * might be defined multiple times. All definitions found will be joined
 * into a single string using `multilineDelimiter` as a separator.
 *
 * This will skip conditional parameters declared as `<token>(<environment>)`
 * if the specified environment doesn't match the passed `envData`, e.g.
 *
 * ---
 * REQURIRED_ARGS(linux): -ignore
 * PERMUTE_ARGS(windows64): -ignore
 * ---
 *
 * Params:
 *   envData            = environment data
 *   file               = source code
 *   token              = test parameter
 *   result             = variable to store the parameter
 *   multilineDelimiter = separator for multiple declarations
 *
 * Returns: whether the parameter was found in the source code
 */
bool findTestParameter(const ref EnvData envData, string file, string token, ref string result, string multiLineDelimiter = " ")
{
    if (!consumeNextToken(file, token, envData))
        return false;

    auto lineEndR = std.string.indexOf(file, "\r");
    auto lineEndN = std.string.indexOf(file, "\n");
    auto lineEnd  = lineEndR == -1 ?
        (lineEndN == -1 ? file.length : lineEndN) :
        (lineEndN == -1 ? lineEndR    : min(lineEndR, lineEndN));

    result = file[0 .. lineEnd];
    const commentStart = std.string.indexOf(result, "//");
    if (commentStart != -1)
        result = result[0 .. commentStart];
    result = strip(result);

    string result2;
    if (findTestParameter(envData, file[lineEnd .. $], token, result2, multiLineDelimiter))
    {
        if (result2.length > 0)
        {
            if (result.length == 0)
                result = result2;
            else
                result ~= multiLineDelimiter ~ result2;
        }
    }

    // fix-up separators
    result = result.unifyDirSep(envData.sep);

    return true;
}

unittest
{
    immutable file = `
/*
Here's a link
FOO: a b
FOO: c
*/

void main() {}

// BAR(windows): all_win
// BAR(windows64): 64_win

int i;

/* REQUIRED_ARGS: -O
 * PERMUTE_ARGS:
 */

// COMPILE_SEPARATELY:
import foo.bar;
`;
    immutable EnvData win32 = {
        os: "windows",
        model: "32",
    };

    immutable EnvData win64 = {
        os: "windows",
        model: "64",
    };

    immutable EnvData linux = {
        os: "linux",
        model: "64",
    };

    string found;
    assert(!findTestParameter(linux, file, "OTHER", found));
    assert(found is null);

    assert(findTestParameter(win64, file, "FOO", found));
    assert(found == "a b c");

    found = null;
    assert(findTestParameter(win64, file, "FOO", found, ";"));
    assert(found == "a b;c");

    found = null;
    assert(findTestParameter(win64, file, "BAR", found));
    assert(found == "all_win 64_win");

    found = null;
    assert(findTestParameter(win32, file, "BAR", found));
    assert(found == "all_win");

    found = null;
    assert(!findTestParameter(linux, file, "BAR", found));
    assert(found is null);

    assert(findTestParameter(linux, file, "PERMUTE_ARGS", found));
    assert(found == "");

    found = null;
    assert(findTestParameter(linux, file, "REQUIRED_ARGS", found));
    assert(found == "-O");

    found = null;
    assert(findTestParameter(linux, file, "COMPILE_SEPARATELY", found));
    assert(found == "");
}

/**
 * Read the multi-line test parameter `token` from the source code and joins
 * multiple definitions into a single string.
 *
 * ```
 * TEST_OUTPUT:
 * ---
 * Hello, World!
 * ---
 * ```
 *
 * Params:
 *   file    = source code
 *   token   = test parameter
 *   result  = variable to store the parameter
 *   envData = environment data
 *
 * Returns: whether the parameter was found in the source code
 */
bool findOutputParameter(string file, string token, out string result, ref const EnvData envData)
{
    bool found = false;

    while (consumeNextToken(file, token, envData))
    {
        found = true;

        enum embed_sep = "---";
        auto n = std.string.indexOf(file, embed_sep);

        enforce(n != -1, "invalid "~token~" format");
        n += embed_sep.length;
        while (file[n] == '-') ++n;
        if (file[n] == '\r') ++n;
        if (file[n] == '\n') ++n;

        file = file[n .. $];
        auto iend = std.string.indexOf(file, embed_sep);
        enforce(iend != -1, "invalid TEST_OUTPUT format");

        result ~= file[0 .. iend];

        while (file[iend] == '-') ++iend;
        file = file[iend .. $];
    }

    if (found)
    {
        result = std.string.strip(result);
        result = result.unifyNewLine().unifyDirSep(envData.sep);
        result = result ? result : ""; // keep non-null
    }
    return found;
}

unittest
{
    immutable EnvData linux = { os: "linux", model: "64", sep: "/ " };
    immutable file = `
/*
Here's a link
TEST_OUTPUT:
---
Hello, World
---
*/

void main() {}

/*
TEST_OUTPUT(linux):
---
Have a nice day
---
*/

/*
TEST_OUTPUT(linux32):
---
Ignored
---
*/

void foo() {}

/*
MISSING:
*/

/*
INCOMPLETE:
---
*/
`;

    string found;
    assert(!findOutputParameter(file, "UNKNOWN", found, linux));
    assert(found is null);

    assert(findOutputParameter(file, "TEST_OUTPUT", found, linux));
    assert(found == "Hello, World\nHave a nice day");

    found = null;
    auto ex = collectException(findOutputParameter(file, "MISSING", found, linux));
    assert(ex);
    assert(ex.msg == "invalid TEST_OUTPUT format");
    assert(found is null);

    ex = collectException(findOutputParameter(file, "INCOMPLETE", found, linux));
    assert(ex);
    assert(ex.msg == "invalid TEST_OUTPUT format");
}

/++
 + Reads the file content to find the next parameter specified by `token`.
 + Ignores conditional parameters that don't apply to the current environment.
 +
 + Params:
 +   file    = file content, will be advanced to the first non-whitespace character
 +             of the parameter value - if `token` was found
 +   token   = requested parameter
 +   envData = environment data
 +
 + Returns: true if `token` was found
 +/
private bool consumeNextToken(ref string file, const string token, ref const EnvData envData)
{
    import std.ascii : isWhite;

    while (true)
    {
        const istart = std.string.indexOf(file, token);
        if (istart == -1)
            return false;

        // Examine the preceeding character to avoid false matches
        const ch = istart ? file[istart - 1] : ' ';

        file = file[istart + token.length .. $];
        file = file.stripLeft!(ch => ch == ' '); // Don't read line breaks

        // Assume that real test token are preceeded by spaces or comment-related tokens
        if (!isWhite(ch) && !among(ch, '/', '*', '+'))
        {
            debug writeln("Ignoring partial match for token: ", token);
            continue;
        }

        // filter by OS specific setting (os1 os2 ...)
        if (file.startsWith("("))
        {
            auto close = std.string.indexOf(file, ")");
            if (close >= 0)
            {
                // Remove the (<oss>) list from the front of `file``
                const oss = split(file[1 .. close], " ");
                file = file[close + 1 .. $];
                file = file.stripLeft!(ch => ch == ' '); // Don't read line breaks

                // Check if the current environment matches an entry in oss, which can either
                // be an OS (e.g. "linux") or a combination of OS + MODEL (e.g. "windows32").
                if (!oss.canFind!(o => o.skipOver(envData.os) && (o.empty || o == envData.model)))
                    continue; // Parameter was skipped
            }
        }

        // Skip a trailing colon
        if (file.skipOver(":"))
        {
            file = file.stripLeft!(ch => ch == ' '); // Don't read line breaks
            return true;
        }

        writeln("Test directive `", token,"` must be followed by a `:`");
        throw new SilentQuit();
    }
}

unittest
{
    immutable EnvData linux = { os: "linux", model: "64", sep: "/ " };
    immutable file = q{

GOOD: foo

WITH_SPACE : bar
/*
BAD
---
---
*/

//BAD foo
//OPTLINK
// $(TINK foo.bar)

IgnoreSTUFF
IgnoreSTUFF: x
STUFF: someVal
*/

void main() {}
};

    string found = file;
    assert(!consumeNextToken(found, "UNKNOWN", linux));
    assert(found is file);

    assert(consumeNextToken(found, "GOOD", linux));
    assert(found.startsWith("foo"), found);

    found = file;
    assert(consumeNextToken(found, "WITH_SPACE", linux));
    assert(found.startsWith("bar"), found);

    found = file;
    assertThrown(consumeNextToken(found, "BAD", linux));

    found = file;
    assert(!consumeNextToken(found, "LINK", linux));

    found = file;
    assert(!consumeNextToken(found, "TINK", linux));

    found = file;
    assert(consumeNextToken(found, "STUFF", linux));
    assert(found.startsWith("someVal"), found);

}

/// Replaces the placeholer `${RESULTS_DIR}` with the actual path
/// to `test_results` stored in `envData`.
void replaceResultsDir(ref string arguments, const ref EnvData envData)
{
    // Bash would expand this automatically on Posix, but we need to manually
    // perform the replacement for Windows compatibility.
    arguments = replace(arguments, "${RESULTS_DIR}", envData.results_dir);
}

/// Returns: the reason why this test is disabled or null if it isn't skipped.
string getDisabledReason(string[] disabledPlatforms, const ref EnvData envData)
{
    if (disabledPlatforms.length == 0)
        return null;

    const target = ((envData.os == "windows") ? "win" : envData.os) ~ envData.model;

    // allow partial matching, e.g. `win` to disable both win32 and win64
    const i = disabledPlatforms.countUntil!(p => target.canFind(p));
    if (i != -1)
        return "on " ~ disabledPlatforms[i];

    return null;
}

unittest
{
    immutable EnvData win32 = { os: "windows",  model: "32" };
    immutable EnvData win64 = { os: "windows",  model: "64" };

    assert(getDisabledReason(null, win64) is null);

    assert(getDisabledReason([ "linux" ], win64) is null);
    assert(getDisabledReason([ "linux", "win" ], win64) == "on win");

    assert(getDisabledReason([ "linux", "win64" ], win64) == "on win64");
    assert(getDisabledReason([ "linux", "win32" ], win64) is null);

    assert(getDisabledReason([ "win32" ], win32) == "on win32");
    assert(getDisabledReason([ "win32" ], win64) is null);
}
/**
 * Reads the test configuration from the source code (using `findTestParameter` and
 * `findOutputParameter`) and initializes `testArgs` accordingly. Also merges
 * configurations/additional parameters specified in the environment, e.g.
 * `REQUIRED_ARGS`.
 *
 * Params:
 *   testArgs   = test configuration object
 *   input_dir  = test directory (e.g. `runnable`)
 *   input_file = path to the source file
 *   envData    = environment configurations
 *
 * Returns: whether this test should be executed (true) or skipped (false)
 * Throws: Exception if the test configuration is invalid
 */
bool gatherTestParameters(ref TestArgs testArgs, string input_dir, string input_file, const ref EnvData envData)
{
    string file = cast(string)std.file.read(input_file);

    string dflagsStr;
    testArgs.clearDflags = findTestParameter(envData, file, "DFLAGS", dflagsStr);
    enforce(dflagsStr.empty, "The DFLAGS test argument must be empty: It is '" ~ dflagsStr ~ "'");

    findTestParameter(envData, file, "REQUIRED_ARGS", testArgs.requiredArgs);
    if (envData.required_args.length)
    {
        if (testArgs.requiredArgs.length)
            testArgs.requiredArgs ~= " " ~ envData.required_args;
        else
            testArgs.requiredArgs = envData.required_args;
    }
    replaceResultsDir(testArgs.requiredArgs, envData);

    if (! findTestParameter(envData, file, "PERMUTE_ARGS", testArgs.permuteArgs))
    {
        if (testArgs.mode == TestMode.RUN)
            testArgs.permuteArgs = envData.all_args;
    }
    replaceResultsDir(testArgs.permuteArgs, envData);

    // remove permute args enforced as required anyway
    if (testArgs.requiredArgs.length && testArgs.permuteArgs.length)
    {
        const required = split(testArgs.requiredArgs);
        const newPermuteArgs = split(testArgs.permuteArgs)
            .filter!(a => !required.canFind(a))
            .join(" ");
        testArgs.permuteArgs = newPermuteArgs;
    }

    // tests can override -verrors by using REQUIRED_ARGS
    if (testArgs.mode == TestMode.FAIL_COMPILE)
        testArgs.requiredArgs = "-verrors=simple -verrors=0 " ~ testArgs.requiredArgs;

    // *.c tests: don't link druntime/Phobos
    if (input_file.extension() == ".c")
        testArgs.requiredArgs = "-defaultlib= " ~ testArgs.requiredArgs;

    {
        string argSetsStr;
        findTestParameter(envData, file, "ARG_SETS", argSetsStr, ";");
        foreach(s; split(argSetsStr, ";"))
        {
            replaceResultsDir(s, envData);
            testArgs.argSets ~= s;
        }
    }

    // win(32|64) doesn't support pic
    // -target/-os may compile for non-PIC targets, let the test take care of -fPIC
    if (envData.os == "windows" || testArgs.requiredArgs.canFind("-target", "-os"))
    {
        auto index = std.string.indexOf(testArgs.permuteArgs, "-fPIC");
        if (index != -1)
            testArgs.permuteArgs = testArgs.permuteArgs[0 .. index] ~ testArgs.permuteArgs[index+5 .. $];

        // Remove the first -fPIC when added via the REQUIRED_ARGS environment variable
        // This allows test to explicitly set `-fPIC` if necessary
        if (envData.required_args.canFind("-fPIC"))
            testArgs.requiredArgs = testArgs.requiredArgs.replaceFirst("-fPIC", "").strip();
    }

    // clean up extra spaces
    testArgs.permuteArgs = strip(replace(testArgs.permuteArgs, "  ", " "));

    if (findTestParameter(envData, file, "EXECUTE_ARGS", testArgs.executeArgs))
        replaceResultsDir(testArgs.executeArgs, envData);

    // Always run main even if compiled with '-unittest' but let
    // tests switch to another behaviour if necessary
    if (!testArgs.executeArgs.canFind("--DRT-testmode"))
        testArgs.executeArgs ~= " --DRT-testmode=run-main";

    string extraSourcesStr;
    findTestParameter(envData, file, "EXTRA_SOURCES", extraSourcesStr);
    testArgs.sources = [input_file];
    // prepend input_dir to each extra source file
    foreach(s; split(extraSourcesStr))
        testArgs.sources ~= input_dir ~ "/" ~ s;

    {
        string compiledImports;
        findTestParameter(envData, file, "COMPILED_IMPORTS", compiledImports);
        foreach(s; split(compiledImports))
            testArgs.compiledImports ~= input_dir ~ "/" ~ s;
    }

    findTestParameter(envData, file, "CXXFLAGS", testArgs.cxxflags);
    string extraCppSourcesStr;
    findTestParameter(envData, file, "EXTRA_CPP_SOURCES", extraCppSourcesStr);
    testArgs.cppSources = split(extraCppSourcesStr);

    if (testArgs.cppSources.length)
        testArgs.requiredArgs ~= envData.cxxCompatFlags;

    string extraObjcSourcesStr;
    auto objc = findTestParameter(envData, file, "EXTRA_OBJC_SOURCES", extraObjcSourcesStr);

    if (objc && !envData.dobjc)
        return false;

    testArgs.objcSources = split(extraObjcSourcesStr);

    // swap / with $SEP
    if (envData.sep && envData.sep != "/")
        foreach (ref s; testArgs.sources)
            s = replace(s, "/", to!string(envData.sep));
    //writeln ("sources: ", testArgs.sources);

    {
        string throwAway;
        testArgs.link = findTestParameter(envData, file, "LINK", throwAway);
    }

    // COMPILE_SEPARATELY can take optional compiler switches when link .o files
    testArgs.compileSeparately = findTestParameter(envData, file, "COMPILE_SEPARATELY", testArgs.requiredArgsForLink);

    string disabledPlatformsStr;
    findTestParameter(envData, file, "DISABLED", disabledPlatformsStr);

    version (DragonFlyBSD)
    {
        // DragonFlyBSD is x86_64 only, instead of adding DISABLED to a lot of tests, just exclude them from running
        if (testArgs.requiredArgs.canFind("-m32"))
            testArgs.disabledReason = "on DragonFlyBSD (no -m32)";
    }

    version (ARM)         enum supportsM64 = false;
    else version (MIPS32) enum supportsM64 = false;
    else version (PPC)    enum supportsM64 = false;
    else                  enum supportsM64 = true;

    static if (!supportsM64)
    {
        if (testArgs.requiredArgs.canFind("-m64"))
            testArgs.disabledReason = "because target doesn't support -m64";
    }

    if (!testArgs.isDisabled)
        testArgs.disabledReason = getDisabledReason(split(disabledPlatformsStr), envData);

    findTestParameter(envData, file, "TEST_OUTPUT_FILE", testArgs.compileOutputFile);

    // Only check for TEST_OUTPUT is no file was given because it would
    // partially match TEST_OUTPUT_FILE
    if (testArgs.compileOutputFile)
    {
        // Don't require tests to specify the test directory
        testArgs.compileOutputFile = input_dir.buildPath(testArgs.compileOutputFile);
        testArgs.compileOutput = readText(testArgs.compileOutputFile)
                                    .unifyNewLine() // Avoid CRLF issues
                                    .strip();

        // Only sanitize directory separators from file types that support standalone \
        if (!testArgs.compileOutputFile.endsWith(".json"))
            testArgs.compileOutput = testArgs.compileOutput.unifyDirSep(envData.sep);
    }
    else
        findOutputParameter(file, "TEST_OUTPUT", testArgs.compileOutput, envData);

    string outFilesStr;
    findTestParameter(envData, file, "OUTPUT_FILES", outFilesStr);
    testArgs.outputFiles = outFilesStr.split(';');

    findTestParameter(envData, file, "TRANSFORM_OUTPUT", testArgs.transformOutput);

    findOutputParameter(file, "RUN_OUTPUT", testArgs.runOutput, envData);

    string dummy;
    if (findTestParameter(envData, file, "RUN_RETURN", dummy))
    {
        import std.conv : to;
        scope(failure)
        {
            writeln("Something went wrong when parsing RUN_RETURN from " ~ dummy);
        }
        testArgs.runReturn = dummy.to!(typeof(testArgs.runReturn));
    }

    findOutputParameter(file, "GDB_SCRIPT", testArgs.gdbScript, envData);
    findTestParameter(envData, file, "GDB_MATCH", testArgs.gdbMatch);

    findTestParameter(envData, file, "POST_SCRIPT", testArgs.postScript);

    return true;
}

unittest
{
    immutable EnvData linux32 = { os: "linux",   model: "32", required_args: "-fPIC" };
    immutable EnvData linux64 = { os: "linux",   model: "64", required_args: "-fPIC" };
    immutable EnvData win64   = { os: "windows", model: "64", };

    immutable dir = "runnable";
    immutable file = ".d_do_test_unittest_target_example.d";
    immutable content = q{
/+
https://foo.bar.
REQUIRED_ARGS: -target=x86-unknown-windows-msvc
REQUIRED_ARGS(linux32): -fPIC
+/
    };

    std.file.write(file, content);
    scope (exit) std.file.remove(file);

    TestArgs args;
    assert(gatherTestParameters(args, dir, file, win64));
    assert(args.requiredArgs == "-target=x86-unknown-windows-msvc", args.requiredArgs);

    args = TestArgs.init;
    assert(gatherTestParameters(args, dir, file, linux64));
    assert(args.requiredArgs == "-target=x86-unknown-windows-msvc", args.requiredArgs);

    args = TestArgs.init;
    assert(gatherTestParameters(args, dir, file, linux32));
    assert(args.requiredArgs == "-target=x86-unknown-windows-msvc  -fPIC", args.requiredArgs);

    std.file.write(file, "REQUIRED_ARGS: -os=windows");
    args = TestArgs.init;
    assert(gatherTestParameters(args, dir, file, linux64));
    assert(args.requiredArgs == "-os=windows", args.requiredArgs);
}

/// Generates all permutations of the space-separated word contained in `argstr`
string[] combinations(string argstr)
{
    string[] results;
    string[] args = split(argstr);
    long combinations = 1 << args.length;
    for (size_t i = 0; i < combinations; i++)
    {
        string r;
        bool printed = false;

        for (size_t j = 0; j < args.length; j++)
        {
            if (i & 1 << j)
            {
                if (printed)
                    r ~= " ";
                r ~= args[j];
                printed = true;
            }
        }

        results ~= r;
    }

    return results;
}

/// Tries to remove the file identified by `filename` and prints warning on failure
void tryRemove(in char[] filename)
{
    if (auto ex = std.file.remove(filename).collectException())
        debug writeln("WARNING: Failed to remove ", filename);
}

/**
 * Executes `command` while logging the invocation and any output produced into f.
 *
 * Params:
 *  f           = the logfile
 *  command     = the command to execute
 *  expectPass  = whether the command should succeed
 *
 * Returns: the output produced by `command`
 * Throws:
 *   Exception if `command` returns another exit code than 0/1 (depending on expectPass)
 */
string execute(ref File f, string command, const ubyte expectedRc)
{
    f.writeln(command);
    const result = std.process.executeShell(command);
    f.write(result.output);

    if (result.status < 0)
    {
        enforce(false, "caught signal: " ~ to!string(result.status));
    }
    else
    {
        enforce(result.status == expectedRc, format("Expected rc == %d, but exited with rc == %d", expectedRc, result.status));
    }

    return result.output;
}

/// add quotes around the whole string if it contains spaces that are not in quotes
string quoteSpaces(string str)
{
    if (str.indexOf(' ') < 0)
        return str;
    bool inquote = false;
    foreach(dchar c; str)
        if (c == '"')
            inquote = !inquote;
        else if (c == ' ' && !inquote)
            return "\"" ~ str ~ "\"";
    return str;
}

/// Replaces non-Unix line endings in `str` with `\n`
string unifyNewLine(string str)
{
    // On Windows, Outbuffer.writenl() puts `\r\n` into the buffer,
    // then fprintf() adds another `\r` when formatting the message.
    // This is why there's a match for `\r\r\n` in this regex.
    static re = regex(`\r\r\n|\r\n|\r|\n`, "g");
    return std.regex.replace(str, re, "\n");
}

/**
Unifies a text `str` with words that could be DMD path references to a common
separator `sep`. This normalizes the text and allows comparing path output
results between different operating systems.

Params:
    str = text to be unified
    sep = unification separator to use
Returns: Text with path separator standardized to `sep`.
*/
string unifyDirSep(string str, string sep)
{
    static void unifyWordFromBack(char[] r, char sep)
    {
        foreach_reverse(ref ch; r)
        {
            // stop at common word boundaries
            if (ch == '\n' || ch == '\r' || ch == ' ')
                break;
            // normalize path characters
            if (ch == '\\' || ch == '/')
                ch = sep;
        }
    }
    auto mStr = str.dup;
    auto remaining = mStr;
    alias needles = AliasSeq!(".d", ".di", ".mixin", ".c", ".i", ".h");
    enum needlesArray = [needles];
    // simple multi-delimiter word identification
    while (!remaining.empty)
    {
        auto res = remaining.find(needles);
        if (res[0].empty) break;

        auto currentWord = remaining[0 .. res[0].ptr-remaining.ptr];
        // skip over current word and matched delimiter
        const needleLength = res[1] > 0 ? needlesArray[res[1] - 1].length : 0;
        remaining = remaining[currentWord.length + needleLength .. $];

        if (remaining.empty ||
            remaining.startsWith(" ", "\n", "\r", "-mixin",
                                 "(", ":", "'", "`", "\"", ".", ","))
            unifyWordFromBack(currentWord, sep[0]);
    }
    return mStr.assumeUnique;
}

unittest
{
    assert(`fail_compilation/test.d(1) Error: dummy error message for 'test'`.unifyDirSep(`\`)
        == `fail_compilation\test.d(1) Error: dummy error message for 'test'`);
    assert(`fail_compilation/test.d(1) Error: at fail_compilation/test.d(2)`.unifyDirSep(`\`)
        == `fail_compilation\test.d(1) Error: at fail_compilation\test.d(2)`);

    assert(`fail_compilation/test.d(1) Error: at fail_compilation/imports/test.d(2)`.unifyDirSep(`\`)
        == `fail_compilation\test.d(1) Error: at fail_compilation\imports\test.d(2)`);
    assert(`fail_compilation/diag.d(2): Error: fail_compilation/imports/fail.d must be imported`.unifyDirSep(`\`)
        == `fail_compilation\diag.d(2): Error: fail_compilation\imports\fail.d must be imported`);

    assert(`{{RESULTS_DIR}}/fail_compilation/mixin_test.mixin(7): Error:`.unifyDirSep(`\`)
        == `{{RESULTS_DIR}}\fail_compilation\mixin_test.mixin(7): Error:`);

    assert(`{{RESULTS_DIR}}/fail_compilation/mixin_test.d-mixin-50(7): Error:`.unifyDirSep(`\`)
        == `{{RESULTS_DIR}}\fail_compilation\mixin_test.d-mixin-50(7): Error:`);
    assert("runnable\\xtest46_gc.d-mixin-37(187): Error".unifyDirSep("/") == "runnable/xtest46_gc.d-mixin-37(187): Error");

    // optional columns
    assert(`{{RESULTS_DIR}}/fail_compilation/cols.d(12,7): Error:`.unifyDirSep(`\`)
        == `{{RESULTS_DIR}}\fail_compilation\cols.d(12,7): Error:`);

    // gnu style
    assert(`fail_compilation/test.d:1: Error: dummy error message for 'test'`.unifyDirSep(`\`)
        == `fail_compilation\test.d:1: Error: dummy error message for 'test'`);

    // in quotes as well
    assert("'imports\\foo.d'".unifyDirSep("/") == "'imports/foo.d'");
    assert("`imports\\foo.d`".unifyDirSep("/") == "`imports/foo.d`");
    assert("\"imports\\foo.d\"".unifyDirSep("/") == "\"imports/foo.d\"");

    assert("fail_compilation\\foo.d: Error:".unifyDirSep("/") == "fail_compilation/foo.d: Error:");

    // at the end of a sentence
    assert("fail_compilation\\foo.d. A".unifyDirSep("/") == "fail_compilation/foo.d. A");
    assert("fail_compilation\\foo.d(2). A".unifyDirSep("/") == "fail_compilation/foo.d(2). A");
    assert("fail_compilation\\foo.d, A".unifyDirSep("/") == "fail_compilation/foo.d, A");
    assert("fail_compilation\\foo.d(2), A".unifyDirSep("/") == "fail_compilation/foo.d(2), A");
    assert("fail_compilation\\foo.d".unifyDirSep("/") == "fail_compilation/foo.d");
    assert("fail_compilation\\foo.d\n".unifyDirSep("/") == "fail_compilation/foo.d\n");
    assert("fail_compilation\\foo.d\r\n".unifyDirSep("/") == "fail_compilation/foo.d\r\n");
    assert("\nfail_compilation\\foo.d".unifyDirSep("/") == "\nfail_compilation/foo.d");
    assert("\r\nfail_compilation\\foo.d".unifyDirSep("/") == "\r\nfail_compilation/foo.d");
    assert("fail_compilation\\imports\\cfoo.c. A".unifyDirSep("/") == "fail_compilation/imports/cfoo.c. A");
    assert(("runnable\\xtest46_gc.d-mixin-37(220): Deprecation: `opDot` is deprecated. Use `alias this`\n"~
            "runnable\\xtest46_gc.d-mixin-37(222): Deprecation: `opDot` is deprecated. Use `alias this`").unifyDirSep("/") ==
           "runnable/xtest46_gc.d-mixin-37(220): Deprecation: `opDot` is deprecated. Use `alias this`\n"~
           "runnable/xtest46_gc.d-mixin-37(222): Deprecation: `opDot` is deprecated. Use `alias this`");

    assert("".unifyDirSep("/") == "");
    assert(" \n ".unifyDirSep("/") == " \n ");
    assert("runnable/xtest46_gc.d-mixin-$n$(222): ".unifyDirSep("\\") ==
           "runnable\\xtest46_gc.d-mixin-$n$(222): ");

    assert(`S('\xff').this(1)`.unifyDirSep("/") == `S('\xff').this(1)`);
    assert(`invalid UTF character \U80000000`.unifyDirSep("/") == `invalid UTF character \U80000000`);
    assert("https://code.dlang.org".unifyDirSep("\\") == "https://code.dlang.org");
}

/**
 * Compiles all non-D sources using their respective compiler and flags
 * and appends the generated objects to `sources`.
 *
 * Params:
 *   input_dir    = test directory (e.g. `runnable`)
 *   output_dir   = directory for intermediate files
 *   extraSources = sources to compile
 *   sources      = list of D sources to extend with object files
 *   envData      = environment configuration
 *   compiler     = external compiler (E.g. clang)
 *   cxxflags     = external compiler flags
 *   logfile      = the logfile
 *
 * Returns: false if a compilation error occurred
 */
bool collectExtraSources (in string input_dir, in string output_dir, in string[] extraSources,
                          ref string[] sources, in EnvData envData, in string ccompiler,
                          in string cxxcompiler, const(char)[] cxxflags, ref File logfile)
{
    foreach (cur; extraSources)
    {
        auto curSrc = input_dir ~ envData.sep ~"extra-files" ~ envData.sep ~ cur;
        auto curObj = output_dir ~ envData.sep ~ cur ~ envData.obj;
        bool is_cpp_file = cur.extension() == ".cpp";
        string command = quoteSpaces(is_cpp_file ? cxxcompiler : ccompiler);
        if (envData.os == "windows") // cl.exe
        {
            command ~= ` /c /nologo `~curSrc~` /Fo`~curObj;
        }
        else
        {
            command ~= " -m"~envData.model~" -c "~curSrc~" -o "~curObj;
        }
        if (cxxflags)
            command ~= " " ~ cxxflags;

        logfile.writeln(command);
        logfile.flush(); // Avoid reordering due to buffering

        auto pid = spawnShell(command, stdin, logfile, logfile, null, Config.retainStdout | Config.retainStderr);
        if(wait(pid))
        {
            return false;
        }
        sources ~= curObj;
    }

    return true;
}

/++
Applies custom transformations defined in transformOutput to testOutput.

Currently the following actions are supported:
 * "sanitize_json"       = replace compiler/plattform specific data from generated JSON
 * "sanitize_timetrace"  = parse -ftime-trace profiler output, and only extract event names
 * "remove_lines(<re>)" = remove all lines matching a regex <re>

Params:
    testOutput      = the existing output to be modified
    transformOutput = list of transformation identifiers
++/
void applyOutputTransformations(ref string testOutput, string transformOutput)
{
    while (transformOutput.length)
    {
        string step, arg;

        const idx = transformOutput.countUntil(' ', '(');
        if (idx == -1)
        {
            step = transformOutput;
            transformOutput = null;
        }
        else
        {
            step = transformOutput[0 .. idx];
            const hasArgs = transformOutput[idx] == '(';
            transformOutput = transformOutput[idx + 1 .. $];
            if (hasArgs)
            {
                // "..." quotes are optional but necessary if the arg contains ')'
                const isQuoted = transformOutput[0] == '"';
                const end = isQuoted ? `"` : `)`;
                auto parts = transformOutput[isQuoted .. $].findSplit(end);
                enforce(parts, "Missing closing `" ~ end ~ "`!");
                arg = parts[0];
                transformOutput = parts[2][isQuoted .. $];
            }

            // Skip space between steps
            import std.ascii : isWhite;
            transformOutput.skipOver!isWhite();
        }

        switch (step)
        {
            case "sanitize_json":
            {
                import sanitize_json : sanitize;
                sanitize(testOutput);
                break;
            }

            case "remove_lines":
            {
                auto re = regex(arg);
                testOutput = testOutput
                    .splitter('\n')
                    .filter!(line => !line.matchFirst(re))
                    .join('\n');
                break;
            }

            case "sanitize_timetrace":
                import sanitize_timetrace;
                sanitizeTimeTrace(testOutput);
                break;

            default:
                throw new Exception(format(`Unknown transformation: "%s"!`, step));
        }
    }
}

unittest
{
    static void test(string input, const string transformations, const string expected)
    {
        applyOutputTransformations(input, transformations);
        assert(input == expected);
    }

    static void testJson(const string transformations, const string expectedJson)
    {
        test(`{
    "modules": [
        {
            "file": "/path/to/the/file",
            "kind": "module",
            "members": []
        }
    ]
}`, transformations, expectedJson);
    }


    testJson("sanitize_json", `{
    "modules": [
        {
            "file": "VALUE_REMOVED_FOR_TEST",
            "kind": "module",
            "members": []
        }
    ]
}`);

    testJson(`sanitize_json  remove_lines("kind")`, `{
    "modules": [
        {
            "file": "VALUE_REMOVED_FOR_TEST",
            "members": []
        }
    ]
}`);

    testJson(`sanitize_json remove_lines("kind") remove_lines("file")`, `{
    "modules": [
        {
            "members": []
        }
    ]
}`);

    test(`This is a text containing
        some words which is a text sample
        nevertheless`,
        `remove_lines(text sample)`,
        `This is a text containing
        nevertheless`);

    test(`This is a text with
        a random ) which should
        still work`,
        `remove_lines("random \)")`,
        `This is a text with
        still work`);

    test(`Tom bought
        12 apples
        and 6 berries
        from the store`,
        `remove_lines("(\d+)")`,
        `Tom bought
        from the store`);

    assertThrown(test("", "unknown", ""));
}

/// List of supported special sequences used in compareOutput
alias specialSequences = AliasSeq!("$n$", "$p:", "$r:", "$?:");

/++
Compares the output string to the reference string by character
except parts marked with one of the following special sequences:

$n$ = numbers (e.g. compiler generated unique identifiers)
$p:<path>$ = real paths ending with <path>
$?:<choices>$ = environment dependent content supplied as a list
                choices (either <condition>=<content> or <default>),
                separated by a '|'. Currently supported conditions are
                OS and model as supplied from the environment
$r:<regex>$   = text matching <regex> (using $ inside of regex is not
                supported, use multiple regexes instead)

Params:
    output    = the real output
    refoutput = the expected output
    envData   = test environment

Returns: whether output matches the expected refoutput
++/
bool compareOutput(string output, string refoutput, const ref EnvData envData)
{
    // If no output is expected, only check that nothing was captured.
    if (refoutput.length == 0)
        return (output.length == 0) ? true : false;

    for ( ; ; )
    {
        auto special = refoutput.find(specialSequences).rename!("remainder", "id");

        // Simple equality check if no special tokens remain
        if (special.id == 0)
            return refoutput == output;

        const expected = refoutput[0 .. $ - special.remainder.length];

        // Check until the special token
        if (!output.skipOver(expected))
            return false;

        // Discard the special token and progress output appropriately
        refoutput = special.remainder[3 .. $];

        if (special.id == 1) // $n$
        {
            import std.ascii : isDigit;
            output.skipOver!isDigit();
            continue;
        }

        // $<identifier>:<special content>$
        /// ( special content, "$", remaining expected output )
        auto refparts = refoutput.findSplit("$");
        enforce(refparts, "Malformed special sequence!");
        refoutput = refparts[2];

        if (special.id == 2) // $p:<some path>$
        {
            // special content is the expected path tail
            // Substitute / with the appropriate directory separator
            const pathTail = refparts[0].replace("/", envData.sep);

            const newlineIndex = output.indexOf('\n');
            const outputLine = newlineIndex == -1 ? output : output[0 .. newlineIndex];

            const path = outputLine.findLastSplitAfter(pathTail)[0];
            if (path.empty || !exists(path))
                return false;

            output = output[path.length .. $];
            continue;
        }

        else if (special.id == 3) // $r:<regex>$
        {
            // need some context behind this expression to stop the regex match
            // e.g. "$r:.*$ failed with..." uses " failed"
            auto context = refoutput[0 .. min(7, $)];
            const parts = context.findSplitBefore("$");
            // Avoid collisions with other special sequences
            if (!parts[1].empty)
            {
                context = parts[0];
                enforce(context.length, "Another sequence following $r:...$ is not supported!");
            }

            // Remove the context from the remaining expected output
            refoutput = refoutput[context.length .. $];

            // Use '^' to match <regex><context> at the beginning of output
            auto re = regex('^' ~ refparts[0] ~ context, "s");
            auto match = output.matchFirst(re);
            if (!match)
                return false;

            output = output[match.front.length .. $];
            continue;
        }

        // $?:<predicate>=<content>(;<predicate>=<content>)*(;<default>)?$
        string toSkip = null;

        foreach (const chunk; refparts[0].splitter('|'))
        {
            // ( <predicate> , "=", <content> )
            const searchResult = chunk.findSplit("=");

            if (searchResult[1].empty) // <default>
            {
                toSkip = chunk;
                break;
            }
            // Match against OS or model
            else if (searchResult[0].splitter('+').all!(c => c.among(envData.os, envData.model)))
            {
                toSkip = searchResult[2];
                break;
            }
        }

        if (toSkip !is null && !output.skipOver(toSkip))
            return false;
    }
}

private string[2] findLastSplitAfter(in string haystack, in string needle)
{
    string[2] r = [null, haystack];

    foreach_reverse (end; needle.length .. haystack.length + 1) // include haystack.length
    {
        const candidateTail = haystack[end - needle.length .. end];
        if (candidateTail == needle)
        {
            r[0] = haystack[0 .. end];
            r[1] = haystack[end .. $];
            break;
        }
    }

    return r;
}

unittest
{
    assert("abc".findLastSplitAfter("abcd") == ["", "abc"]);
    assert("abc".findLastSplitAfter("abc") == ["abc", ""]);
    assert("abc".findLastSplitAfter("ab") == ["ab", "c"]);
    assert("/phobos/bla/phobos/blub".findLastSplitAfter("phobos") == ["/phobos/bla/phobos", "/blub"]);
}

unittest
{
    EnvData ed;
    version (Windows)
        ed.sep = `\`;
    else
        ed.sep = `/`;

    assert( compareOutput(`Grass is green`, `Grass is green`, ed));
    assert(!compareOutput(`Grass is green`, `Grass was green`, ed));

    assert( compareOutput(`Bob took 12 apples`, `Bob took $n$ apples`, ed));
    assert(!compareOutput(`Bob took abc apples`, `Bob took $n$ apples`, ed));
    assert(!compareOutput(`Bob took 12 berries`, `Bob took $n$ apples`, ed));

    assert( compareOutput(`HINT: ` ~ __FILE_FULL_PATH__ ~ ` is important`, `HINT: $p:d_do_test.d$ is important`, ed));
    assert( compareOutput(`HINT: ` ~ __FILE_FULL_PATH__ ~ ` is important`, `HINT: $p:test/tools/d_do_test.d$ is important`, ed));

    ed.sep = "/";
    assert(!compareOutput(`See /path/to/druntime/import/object.d`, `See $p:druntime/import/object.d$`, ed));

    assertThrown(compareOutput(`Path /a/b/c.d!`, `Path $p:c.d!`, ed)); // Missing closing $

    const fmt = "This $?:windows=A|posix=B|C$ uses $?:64=1|32=2|3$ bytes";

    assert( compareOutput("This C uses 3 bytes", fmt, ed));

    ed.os = "posix";
    ed.model = "64";
    assert( compareOutput("This B uses 1 bytes", fmt, ed));
    assert(!compareOutput("This C uses 3 bytes", fmt, ed));

    const emptyFmt = "On <$?:windows=abc|$> use <$?:posix=$>!";
    assert(compareOutput("On <> use <>!", emptyFmt, ed));

    ed.model = "32";
    assert(compareOutput("size_t is uint!", "size_t is $?:32=uint|64=ulong$!", ed));

    assert(compareOutput("no", "$?:posix+64=yes|no$", ed));
    ed.model = "64";
    assert(compareOutput("yes", "$?:posix+64=yes|no$", ed));


    assert(compareOutput("This number 12", `This $r:\w+ \d+$`, ed));
    assert(compareOutput("This number 12", `This $r:\w+ (\d)+$`, ed));

    assert(compareOutput("This number 12 is nice", `This $r:.*$ 12 is nice`, ed));
    assert(compareOutput("This number 12", `This $r:.*$ 12`, ed));
    assert(!compareOutput("This number 12 is 24", `This $r:\d*$ 12`, ed));

    assert(compareOutput("This number 12 is 24", `This $r:.*$ 12 is $n$`, ed));

    string msg = collectExceptionMsg(compareOutput("12345", `$r:\d*$$n$`, ed));
    assert(msg == "Another sequence following $r:...$ is not supported!");
}

/++
Creates a diff of the expected and actual test output.

Params:
    expected     = the expected output
    expectedFile = file containing expected (if present, null otherwise)
    actual       = the actual output
    name         = the test files name

Returns: the comparison created by the `diff` utility
++/
string generateDiff(const string expected, string expectedFile,
    const string actual, const string name)
{
    string actualFile = tempDir.buildPath("actual_" ~ name);
    File(actualFile, "w").writeln(actual); // Append \n
    scope (exit) tryRemove(actualFile);

    const needTmp = !expectedFile;
    if (needTmp) // Create a temporary file
    {
        expectedFile = tempDir.buildPath("expected_" ~ name);
        File(expectedFile, "w").writeln(expected); // Append \n
    }
    // Remove temporary file
    scope (exit) if (needTmp)
        tryRemove(expectedFile);

    const cmd = ["diff", "-up", "--strip-trailing-cr", expectedFile, actualFile];
    try
    {
        string diff = std.process.execute(cmd).output;
        // Skip diff's status lines listing the diffed files and line count
        foreach (_; 0..3)
            diff = diff.findSplitAfter("\n")[1];
        return diff;
    }
    catch (Exception e)
        return format(`%-(%s, %) failed: %s`, cmd, e.msg);
}

/**
 * Exception thrown to abort the test without further error messages
 * (they were either already printed or suppressed due to the environment)
 */
class SilentQuit : Exception { this() { super(null); } }

/**
 * Exception thrown when the actual output doesn't match the expected
 * `TEST_OUTPUT`/`RUN_OUTPUT.`
 */
class CompareException : Exception
{
    string expected; /// expected output
    string actual;   /// actual output
    bool fromRun; /// Compared execution instead of compilation output
    string diff; /// diff between expected and actual output

    this(string expected, string actual, string diff, bool fromRun = false) {
        string msg = "\nexpected:\n----\n" ~ expected ~
            "\n----\nactual:\n----\n" ~ actual ~
            "\n----\ndiff:\n----\n" ~ diff ~ "----\n";
        super(msg);
        this.expected = expected;
        this.actual = actual;
        this.fromRun = fromRun;
        this.diff = diff;
    }
}

/// Return code indicating that the test should be restarted.
/// Issued when an OUTPUT section was changed due to AUTO_UPDATE=1.
enum RERUN_TEST = 2;

version(unittest) void main(){} else
int main(string[] args)
{
    try
    {
        // Test may be run multiple times with AUTO_UPDATE=1 because updates
        // to output sections may change line numbers.
        // Set a hard limit to avoid infinite loops in fringe cases
        foreach (_; 0 .. 10)
        {
            const res = tryMain(args);
            if (res == RERUN_TEST)
                writeln("==> Restarting test to verify new output section(s)...\n");
            else
                return res;
        }

        // Should never happen, but just to be sure
        writeln("Output sections changed too many times, please update manually.");
        return RERUN_TEST;
    }
    catch(SilentQuit) { return 1; }
}

int tryMain(string[] args)
{
    if (args.length != 2)
    {
        usage();
        return 1;
    }

    immutable envData = processEnvironment();

    const input_file     = args[1];
    const input_dir      = input_file.dirName();
    const test_base_name = input_file.baseName();
    const test_name      = test_base_name.stripExtension();
    const test_ext       = test_base_name.extension();

    // Previously we did not take into account the test file extension,
    //  because of ImportC we now have the ability to have conflicting source file basenames (when ignoring extension).
    // This can cause a race condition with the concurrent test runner,
    //  in which whilst one test is running another will try to clobber it and fail.
    // Unfortunately dshell does not take into account our output directory,
    //  at least not in a way that'll allow us to take advantage of the test extension.
    // However since its not really an issue for clobbering, we'll ignore it.
    const result_path     = envData.results_dir ~ envData.sep;
    const output_dir_base = result_path ~ input_dir;
    const output_dir      = (input_dir == "dshell" ? output_dir_base : (output_dir_base ~ envData.sep ~ test_ext[1 .. $]));
    const output_file     = result_path ~ input_file ~ ".out";

    // We are potentially creating a test extension specific directory
    mkdirRecurse(output_dir);

    TestArgs testArgs;
    switch (input_dir)
    {
        case "compilable":              testArgs.mode = TestMode.COMPILE;      break;
        case "fail_compilation":        testArgs.mode = TestMode.FAIL_COMPILE; break;
        case "runnable", "runnable_cxx":
            // running & linking costs time - for coverage builds we can save this
            testArgs.mode = envData.coverage_build ? TestMode.COMPILE : TestMode.RUN;
            break;

        case "dshell":
            testArgs.mode = TestMode.DSHELL;
            return runDShellTest(input_dir, test_name, envData, output_dir, output_file);

        default:
            writefln("Error: invalid test directory '%s', expected 'compilable', 'fail_compilation', 'runnable', 'runnable_cxx' or 'dshell'", input_dir);
            return 1;
    }

    if (test_ext == ".sh")
    {
        string file = cast(string) std.file.read(input_file);
        string disabledPlatforms;
        if (findTestParameter(envData, file, "DISABLED", disabledPlatforms))
        {
            const reason = getDisabledReason(split(disabledPlatforms), envData);
            if (reason.length != 0)
            {
                writefln(" ... %-30s [DISABLED %s]", input_file, reason);
                return 0;
            }
        }
        version (linux)
        {
            if (file.canFind("GDB_SCRIPT"))
            {
                return runGDBTestWithLock(envData, () {
                    return runBashTest(input_dir, test_name, envData);
                });
            }
        }
        return runBashTest(input_dir, test_name, envData);
    }

    // envData.sep is required as the results_dir path can be `generated`
    const absoluteResultDirPath = envData.results_dir.absolutePath ~ envData.sep;
    const resultsDirReplacement = "{{RESULTS_DIR}}" ~ envData.sep;
    const test_app_dmd_base = output_dir ~ envData.sep ~ test_name ~ "_";

    auto stopWatch = StopWatch(AutoStart.no);
    if (envData.printRuntime)
        stopWatch.start();

    if (!gatherTestParameters(testArgs, input_dir, input_file, envData))
        return 0;

    // Clear the DFLAGS environment variable if it was specified in the test file
    if (testArgs.clearDflags)
        environment["DFLAGS"] = "";

    writef(" ... %-30s %s%s(%s)",
            input_file,
            testArgs.requiredArgs,
            (!testArgs.requiredArgs.empty ? " " : ""),
            testArgs.permuteArgs);

    if (testArgs.isDisabled)
    {
        writef("!!! [DISABLED %s]", testArgs.disabledReason);
        if (!envData.tryDisabled)
        {
            writeln();
            return 0;
        }
    }

    auto f = File(output_file, "w");

    if (
        //prepare cpp extra sources
        !collectExtraSources(input_dir, output_dir, testArgs.cppSources, testArgs.sources, envData, envData.ccompiler, envData.cxxcompiler, testArgs.cxxflags, f) ||

        //prepare objc extra sources
        !collectExtraSources(input_dir, output_dir, testArgs.objcSources, testArgs.sources, envData, "clang", "clang++", null, f)
    )
    {
        writeln();

        // Ignore failed test
        if (testArgs.isDisabled)
            return 0;

        printTestFailure(input_file, f);
        return 1;
    }

    enum Result { continue_, return0, return1, returnRerun }

    // Runs the test with a specific combination of arguments
    Result testCombination(bool autoCompileImports, string argSet, size_t permuteIndex, string permutedArgs)
    {
        string test_app_dmd = test_app_dmd_base ~ to!string(permuteIndex) ~ envData.exe;
        string command; // copy of the last executed command so that it can be re-invoked on failures
        try
        {
            string[] toCleanup;

            auto thisRunName = output_file ~ to!string(permuteIndex);
            auto fThisRun = File(thisRunName, "w");
            scope(exit)
            {
                fThisRun.close();
                f.write(readText(thisRunName));
                f.writeln();
                tryRemove(thisRunName); // Never reached unless file is present
            }

            string compile_output;
            if (!testArgs.compileSeparately)
            {
                string objfile = output_dir ~ envData.sep ~ test_name ~ "_" ~ to!string(permuteIndex) ~ envData.obj;
                toCleanup ~= objfile;

                command = format("%s -conf= -m%s -I%s %s %s -od%s -of%s %s %s%s %s", envData.dmd, envData.model, input_dir,
                        testArgs.requiredArgs, permutedArgs, output_dir,
                        (testArgs.mode == TestMode.RUN || testArgs.link ? test_app_dmd : objfile),
                        argSet,
                        (testArgs.mode == TestMode.RUN || testArgs.link ? "" : "-c "),
                        join(testArgs.sources, " "),
                        (autoCompileImports ? "-i" : join(testArgs.compiledImports, " ")));

                try
                    compile_output = execute(fThisRun, command, testArgs.mode == TestMode.FAIL_COMPILE);
                catch (Exception e)
                {
                    writeln(""); // We're at "... runnable/xxxx.d (args)"
                    printCppSources(testArgs.sources);
                    throw e;
                }
            }
            else
            {
                foreach (filename; testArgs.sources ~ (autoCompileImports ? null : testArgs.compiledImports))
                {
                    string newo = output_dir ~ envData.sep ~ filename.baseName().setExtension(envData.obj);
                    toCleanup ~= newo;

                    command = format("%s -conf= -m%s -I%s %s %s -od%s -c %s %s", envData.dmd, envData.model, input_dir,
                        testArgs.requiredArgs, permutedArgs, output_dir, argSet, filename);
                    compile_output ~= execute(fThisRun, command, testArgs.mode == TestMode.FAIL_COMPILE);
                }

                if (testArgs.mode == TestMode.RUN || testArgs.link)
                {
                    // link .o's into an executable
                    command = format("%s -conf= -m%s%s%s %s %s -od%s -of%s %s", envData.dmd, envData.model,
                        autoCompileImports ? " -i" : "",
                        autoCompileImports ? "extraSourceIncludePaths" : "",
                        envData.required_args, testArgs.requiredArgsForLink, output_dir, test_app_dmd, join(toCleanup, " "));

                    execute(fThisRun, command, testArgs.runReturn);
                }
            }

            void prepare(ref string compile_output)
            {
                if (compile_output.empty)
                    return;

                compile_output = compile_output.unifyNewLine();
                compile_output = std.regex.replaceAll(compile_output, regex(`^DMD v2\.[0-9]+.*\n? DEBUG$`, "m"), "");
                compile_output = std.string.strip(compile_output);
                // replace test_result path with fixed ones
                compile_output = compile_output.replace(result_path, resultsDirReplacement);
                compile_output = compile_output.replace(absoluteResultDirPath, resultsDirReplacement);

                compile_output.applyOutputTransformations(testArgs.transformOutput);
            }

            prepare(compile_output);

            auto m = std.regex.match(compile_output, `Internal error: .*$`);
            enforce(!m, m.hit);
            m = std.regex.match(compile_output, `core.exception.AssertError@dmd.*`);
            enforce(!m, m.hit);

            // Prepare and append the content of each OUTPUT_FILE conforming to
            // the HAR (https://code.dlang.org/packages/har) format, e.g.
            // === <FILENAME_1>
            // <CONTENT_1>
            // === <FILENAME_2>
            // <CONTENT_2>
            // ...
            foreach (const outfile; testArgs.outputFiles)
            {
                string path = outfile;
                replaceResultsDir(path, envData);

                // Don't abort if a file is missing, at least verify the remaining output.
                string content = readText(path).ifThrown("<< File missing >>");
                prepare(content);

                // Make sure file starts on a new line
                if (!compile_output.empty && !compile_output.endsWith("\n"))
                    compile_output ~= '\n';

                // Prepend a header listing the explicit file
                compile_output.reserve(outfile.length + content.length + 5);

                compile_output ~= "=== ";
                compile_output ~= outfile;
                compile_output ~= '\n';
                compile_output ~= content;
            }

            if (!compareOutput(compile_output, testArgs.compileOutput, envData))
            {
                const diff = generateDiff(testArgs.compileOutput, testArgs.compileOutputFile,
                                            compile_output, test_base_name);
                throw new CompareException(testArgs.compileOutput, compile_output, diff);
            }

            if (testArgs.mode == TestMode.RUN)
            {
                toCleanup ~= test_app_dmd;
                version(Windows)
                {
                    toCleanup ~= test_app_dmd_base ~ to!string(permuteIndex) ~ ".ilk";
                    toCleanup ~= test_app_dmd_base ~ to!string(permuteIndex) ~ ".pdb";
                }

                if (testArgs.gdbScript is null)
                {
                    command = test_app_dmd;
                    if (testArgs.executeArgs) command ~= " " ~ testArgs.executeArgs;

                    string output = execute(fThisRun, command, testArgs.runReturn)
                                    .strip()
                                    .unifyNewLine();

                    output.applyOutputTransformations(testArgs.transformOutput);

                    if (testArgs.runOutput && !compareOutput(output, testArgs.runOutput, envData))
                    {
                        const diff = generateDiff(testArgs.runOutput, null, output, test_base_name);
                        throw new CompareException(testArgs.runOutput, output, diff, true);
                    }
                }
                else version (linux)
                {
                    runGDBTestWithLock(envData, () {
                        auto script = test_app_dmd_base ~ to!string(permuteIndex) ~ ".gdb";
                        toCleanup ~= script;
                        with (File(script, "w"))
                        {
                            writeln("set disable-randomization off");
                            write(testArgs.gdbScript);
                        }
                        string gdbCommand = "gdb "~test_app_dmd~" --batch -x "~script;
                        auto gdb_output = execute(fThisRun, gdbCommand, 0);
                        if (testArgs.gdbMatch !is null)
                        {
                            enforce(match(gdb_output, regex(testArgs.gdbMatch)),
                                    "\nGDB regex: '"~testArgs.gdbMatch~"' didn't match output:\n----\n"~gdb_output~"\n----\n");
                        }
                        return 0;
                    });
                }
            }

            fThisRun.close();

            if (testArgs.postScript && !envData.coverage_build)
            {
                f.write("Executing post-test script: ");
                string prefix = "";
                version (Windows) prefix = "bash ";
                execute(f, prefix ~ "tools/postscript.sh " ~ testArgs.postScript ~ " " ~ input_dir ~ " " ~ test_name ~ " " ~ thisRunName, 0);
            }

            foreach (file; chain(toCleanup, testArgs.outputFiles))
                tryRemove(file);
            return Result.continue_;
        }
        catch(Exception e)
        {
            // it failed but it was disabled, exit as if it was successful
            if (testArgs.isDisabled)
            {
                writeln();
                return Result.return0;
            }

            if (envData.autoUpdate)
            if (auto ce = cast(CompareException) e)
            {
                // remove the output file in test_results as its outdated
                // (might fail for runnable tests on Windows)
                if (output_file.remove().collectException())
                    writef("\nWARNING: Failed to remove `%s`!", output_file);

                // Don't overwrite TEST_OUTPUT sections which contain special
                // sequences because they must be manually adapted
                if (testArgs.compileOutput.canFind(specialSequences))
                {
                    writefln("\nWARNING: %s uses special sequences in `TEST_OUTPUT` blocks and can't be auto-updated", input_file);
                    return Result.return0;
                }

                if (testArgs.compileOutputFile && !ce.fromRun)
                {
                    std.file.write(testArgs.compileOutputFile, ce.actual);
                    writefln("\n==> `TEST_OUTPUT_FILE` `%s` has been updated", testArgs.compileOutputFile);
                    return Result.returnRerun;
                }

                auto existingText = input_file.readText;
                auto updatedText = existingText.replace(ce.expected, ce.actual);
                const type = ce.fromRun ? `RUN`:  `TEST`;
                if (existingText != updatedText)
                {
                    std.file.write(input_file, updatedText);
                    writefln("\n==> `%s_OUTPUT` of %s has been updated", type, input_file);
                    return Result.returnRerun;
                }
                else
                {
                    try
                    {
                        string diffUpdatedText = replaceFromDiff(existingText, ce.diff);
                        std.file.write(input_file, diffUpdatedText);
                        writefln("\n==> `%s_OUTPUT` of %s has been updated by applying a diff", type, input_file);
                        return Result.returnRerun;
                    }
                    catch (Exception e)
                    {
                        writefln("\nERROR: Couldn't update `%s_OUTPUT` blocks of %s through the diff: \"%s\"
                            Please update the file manually to make the tests pass.", type, input_file, e.msg);
                    }

                    return Result.return0;
                }
            }

            const outputText = printTestFailure(input_file, f, e.msg);

            // auto-update if a diff is found and can be updated
            if (envData.autoUpdate &&
                outputText.canFind("diff ") && outputText.canFind("--- ") && outputText.canFind("+++ "))
            {
                import std.range : dropOne;
                auto newFile = outputText.findSplitAfter("+++ ")[1].until("\t");
                auto baseFile = outputText.findSplitAfter("--- ")[1].until("\t");
                writefln("===> Updating %s with %s", baseFile, newFile);
                newFile.copy(baseFile);
                return Result.return0;
            }

            // automatically rerun a segfaulting test and print its stack trace
            version(linux)
            if (e.msg.canFind("exited with rc == 139"))
            {
                auto gdbCommand = "gdb -q -n -ex 'set backtrace limit 100' -ex run -ex bt -batch -args " ~ command;
                runGDBTestWithLock(envData, () => spawnShell(gdbCommand).wait);
            }

            return Result.return1;
        }
    }

    size_t index = 0; // index over all tests to avoid identical output names in consecutive tests
    auto argSets = (testArgs.argSets.length == 0) ? [""] : testArgs.argSets;
    for(auto autoCompileImports = false;; autoCompileImports = true)
    {
        foreach(argSet; argSets)
        {
            foreach (c; combinations(testArgs.permuteArgs))
            {
                final switch(testCombination(autoCompileImports, argSet, index, c))
                {
                    case Result.continue_: break;
                    case Result.return0: return 0;
                    case Result.return1: return 1;
                    case Result.returnRerun: return RERUN_TEST;
                }
                index++;
            }
        }
        if(autoCompileImports || testArgs.compiledImports.length == 0)
            break;
    }

    if (envData.printRuntime)
    {
        const long ms = stopWatch.peek.total!"msecs";
        writefln("   [%.3f secs]", ms / 1000.0);
    }
    else
        writeln();

    // it was disabled but it passed! print an informational message
    if (testArgs.isDisabled)
        writefln(" !!! %-30s DISABLED but PASSES!", input_file);

    return 0;
}

// Replace consecutive ---+++ diff lines with intertwined lines -+-+-+, which helps putting
// additions in the right TEST_OUTPUT block. Otherwise, sometimes all but the last TEST_OUTPUT blocks
// are emptied and the last TEST_OUTPUT block will be filled will all updated output.
string intertwineDiff(string diff)
{
    static if (__VERSION__ < 2097)
    {
        // `splitWhen` didn't exist, but the bootstrap compiler test doesn't need AUTO_UPDATE
        return diff;
    }
    else
    {
        // First, split diff lines into groups of deletions (-), additions (+), or other (@, ' ')
        auto editGroups = diff.splitter('\n').chunkBy!((a, b) => a.takeOne.equal(b.takeOne)).map!array;
        // Then split before every deletion (-) group
        auto deletionGroups = editGroups.splitWhen!((a, b) => b.front.startsWith("-")).map!array;

        // Then, if we have a deletion group followed by an addition group, roundRobin the first two editGroups, and append the rest
        // Otherwise, just join all editGroups to keep the original order
        return deletionGroups.map!(g => choose(
                g.length > 1 && g[0].front.startsWith("-") && g[1].front.startsWith("+"),
                g.length > 1 ? chain(roundRobin(g[0], g[1]), g[2 .. $].join).array : g.join.array,
                g.join
        )).join.join("\n");
    }
}

unittest
{
    string input = "@@@
-A0
-B1
+E2
+F3
+H4
-32
+33
+34
 35
 36
-C5";

    string expected = "@@@
-A0
+E2
-B1
+F3
+H4
-32
+33
+34
 35
 36
-C5";

    assert(intertwineDiff("") == "");
    static if (__VERSION__ >= 2097)
        assert(intertwineDiff(input) == expected);
}

/// Given test file with contents `input` and diff file with the diff of actual TEST_OUTPUT vs expected TEST_OUTPUT,
/// return new contents of the test file with updated TEST_OUTPUT blocks. Throws an Exception if the diff couldn't be
/// matched against the input.
string replaceFromDiff(string input, string diff)
{
    const string[] lines = input.splitLines;
    string result = "";
    size_t i = 0;
    foreach (diffLine; intertwineDiff(diff).splitLines)
    {
        const bool deletion = diffLine.skipOver("-");
        const bool seek = deletion || diffLine.skipOver(" ");

        if (seek)
        {
            while (i < lines.length && lines[i] != diffLine)
            {
                result ~= lines[i] ~ "\n";
                i++;
            }
            if (i >= lines.length)
                throw new Exception("Can't find diff line \"" ~ diffLine ~ "\" in the text to update");

            if (!deletion)
                result ~= lines[i] ~ "\n";

            i++;
        }
        else if (diffLine.skipOver("+"))
        {
            result ~= diffLine ~ "\n";
            continue;
        }
        else if (diffLine.skipOver("@"))
        {
            continue;
        }
        else
        {
            throw new Exception("Unrecognized first character in diff line: \"" ~ diffLine ~ "\"");
        }
    }
    while (i < lines.length)
    {
        result ~= lines[i] ~ "\n";
        i++;
    }
    return result;
}

unittest
{
    string input = "
TEST_OUTPUT:
---
Error: dummy
---

TEST_OUTPUT:
---
Error: something else
Deprecation: dummy
---
";

    string diff =
"-Error: dummy
-Error: something else
+Error: dummies
@@@ ...
 Deprecation: dummy
+Deprecation: another
";

    string expected = "
TEST_OUTPUT:
---
Error: dummies
---

TEST_OUTPUT:
---
Deprecation: dummy
Deprecation: another
---
";

    string result = replaceFromDiff(input, diff);

    static if (__VERSION__ >= 2097)
        assert(result == expected);

    try
    {
        replaceFromDiff(input, "-Nonexistend line");
        assert(0);
    }
    catch (Exception e)
    {
        assert(e.msg == `Can't find diff line "Nonexistend line" in the text to update`);
    }
}

/**
 * Executes a bash script (deprecated in favour of `dshell` tests).
 *
 * Params:
 *   input_dir = test directory (e.g. `runnable`)
 *   test_name = script filename
 *   envData   = environment configuration
 *
 * Returns: the script's exit code
 */
int runBashTest(string input_dir, string test_name, const ref EnvData envData)
{
    enum script = "tools/sh_do_test.sh";

    version(Windows)
    {
        const cmd = "bash " ~ script ~ ' ' ~ input_dir ~ ' ' ~  test_name;
        const env = [
            // Make sure the path is bash-friendly
            "DMD": envData.dmd.relativePath(dmdTestDir).replace("\\", "/")
        ];

        auto process = spawnShell(cmd, env, Config.none, dmdTestDir);
    }
    else
    {
        const scriptPath = dmdTestDir.buildPath(script);
        auto process = spawnProcess([scriptPath, input_dir, test_name]);
    }
    return process.wait();
}

/**
 * Executes `fun` mutually exclusive to other instances of `d_do_test`
 * using the lockfile `$RESULTS_DIR/gdb.lock`.
 *
 * Params:
 *   envData = environment configuration
 *   fun     = task to execute
 *
 * Returns: the return value of `fun`
 */
int runGDBTestWithLock(const ref EnvData envData, int delegate() fun)
{
    // Tests failed on SemaphoreCI when multiple GDB tests were run at once
    scope lockfile = File(envData.results_dir.buildPath("gdb.lock"), "w");
    lockfile.lock();
    scope (exit) lockfile.unlock();

    return fun();
}

/**
 * Executes a `dshell` test.
 *
 * Params:
 *   input_dir   = test directory (e.g. `runnable`)
 *   test_name   = script filename
 *   envData     = environment configuration
 *   output_dir  = directory for intermediate files (usually `${RESULTS_DIR}/dshell`)
 *   output_file = logfile path
 *
 * Returns: the script's exit code (or dmd's exit code upon compilation failure)
 */
int runDShellTest(string input_dir, string test_name, const ref EnvData envData,
    string output_dir, string output_file)
{
    const testScriptDir = buildPath(dmdTestDir, input_dir);
    const testScriptPath = buildPath(testScriptDir, test_name ~ ".d");
    const testOutDir = buildPath(output_dir, test_name);
    const testLogName = format("%s/%s.d", input_dir, test_name);

    writefln(" ... %s", testLogName);

    if (exists(testOutDir))
        rmdirRecurse(testOutDir);
    mkdirRecurse(testOutDir);

    // create the "dshell" module for the tests
    {
        auto dshellFile = File(buildPath(testOutDir, "dshell.d"), "w");
        dshellFile.writeln(`module dshell;
public import dshell_prebuilt;
static this()
{
    dshellPrebuiltInit("` ~ input_dir ~ `", "`, test_name , `");
}
`);
    }

    const testScriptExe = buildPath(testOutDir, "run" ~ envData.exe);

    auto outfile = File(output_file, "w");
    enum keepFilesOpen = Config.retainStdout | Config.retainStderr;

    //
    // compile the test
    //
    {
        const compile = [envData.dmd, "-conf=", "-m"~envData.model] ~
            envData.picFlag ~ [
            "-od" ~ testOutDir,
            "-of" ~ testScriptExe,
            "-I=" ~ testScriptDir,
            "-I=" ~ testOutDir,
            "-I=" ~ buildPath(dmdTestDir, "tools", "dshell_prebuilt"),
            "-i",
            // Causing linker errors for some reason?
            "-i=-dshell_prebuilt", buildPath(envData.results_dir, "dshell_prebuilt" ~ envData.obj),
            testScriptPath,
        ];
        outfile.writeln("[COMPILE_TEST] ", escapeShellCommand(compile));
        outfile.flush();
        // Note that spawnprocess closes the file, so it will need to be re-opened
        // below when we run the test
        auto compileProc = std.process.spawnProcess(compile, stdin, outfile, outfile, null, keepFilesOpen);
        const exitCode = wait(compileProc);
        if (exitCode != 0)
        {
            printTestFailure(testLogName, outfile);
            return exitCode;
        }
    }

    //
    // run the test
    //
    {
        const runTest = [testScriptExe];
        outfile.writeln("\n[RUN_TEST] ", escapeShellCommand(runTest));
        outfile.flush();
        auto runTestProc = std.process.spawnProcess(runTest, stdin, outfile, outfile, null, keepFilesOpen);
        const exitCode = wait(runTestProc);

        if (exitCode == 125) // = DISABLED from tools/dshell_prebuilt.d
        {
            writefln(" !!! %s is disabled!", testLogName);
            return 0;
        }
        else if (exitCode != 0)
        {
            printTestFailure(testLogName, outfile);
            return exitCode;
        }
    }

    return 0;
}

/**
 * Prints the summary of a test failure to stdout and removes the logfile.
 *
 * Params:
 *   testLogName = name of the test
 *   outfile     = the logfile
 *   extra       = supplemental error message
 * Returns: the content of outfile
 **/
string printTestFailure(string testLogName, scope ref File outfile, string extra = null)
{
    const output_file_temp = outfile.name;
    outfile.close();

    writeln("==============================");
    writefln("Test '%s' failed. The logged output:", testLogName);
    const output = readText(output_file_temp);
    write(output);
    if (!output.endsWith("\n"))
          writeln();
    writeln("==============================");

    if (extra)
        writefln("Test '%s' failed: %s\n", testLogName, extra);

    tryRemove(output_file_temp);
    return output;
}

/**
 * Print symbols in C++ objects
 *
 * If linking failed, we print the symbols present in the C++ object file being
 * linked it. This is so that C++ `runnable` tests are easier to debug,
 * as the CI machines can have different environment than the users,
 * and it is generally painful to work with them when trying to support
 * newer (C++11, C++14, C++17, etc...) features.
 */
void printCppSources (in const(char)[][] compiled)
{
    version (Posix)
    {
        foreach (file; compiled)
        {
            if (!file.endsWith(".cpp.o"))
                continue;
            writeln("========== Symbols for C++ object file: ", file, " ==========");
            std.process.spawnProcess(["nm", file]).wait();
        }
    }
}
