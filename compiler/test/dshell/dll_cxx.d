import dshell;

import std.stdio;

int main()
{
    // Only run this test, if CC has been set.
    if (Vars.CC.empty)
        return DISABLED;

    version (Windows)
        if (environment.get("C_RUNTIME", "") == "mingw")
            return DISABLED;

    version (FreeBSD)
        if (Vars.MODEL == "32")
            return DISABLED;

    Vars.set(`SRC`, `$EXTRA_FILES${SEP}dll_cxx`);
    Vars.set(`EXE_NAME`, `$OUTPUT_BASE${SEP}testdll$EXE`);
    Vars.set(`DLL`, `$OUTPUT_BASE${SEP}mydll$SOEXT`);

    string[] dllCmd = [Vars.CC];
    string mainExtra;
    version (Windows)
    {
        Vars.set(`DLL_LIB`, `$OUTPUT_BASE${SEP}mydll.lib`);
        if (Vars.MODEL == "32omf")
        {
            // CC should be dmc for win32omf.
            dllCmd ~= [`-mn`, `-L/implib:` ~ Vars.DLL_LIB, `-WD`, `-o` ~ Vars.DLL, `kernel32.lib`, `user32.lib`];
            mainExtra = `$DLL_LIB`;
        }
        else
        {
            // CC should be cl for win32mscoff.
            dllCmd ~= [`/LD`, `/nologo`, `/Fe` ~ Vars.DLL];
            mainExtra = `$DLL_LIB`;
        }
    }
    else version(OSX)
    {
        dllCmd ~= [`-dynamiclib`, `-fPIC`, `-o`, Vars.DLL, `-lstdc++`];
        mainExtra = `-fPIC -L-L$OUTPUT_BASE -L$DLL -L-lstdc++ -L--no-demangle`;
    }
    else
    {
        dllCmd ~= [ `-m` ~ Vars.MODEL, `-shared`, `-fPIC`, `-o`, Vars.DLL ];
        mainExtra = `-fPIC -L-L$OUTPUT_BASE -L$DLL -L-lstdc++ -L--no-demangle`;
    }

    dllCmd ~= Vars.SRC ~ Vars.SEP ~ `mydll.cpp`;
    // The arguments have to be passed as an array, because run would replace '/' with '\\' otherwise.
    run(dllCmd);

    run(`$DMD -m$MODEL -I$SRC -checkaction=D -g -od=$OUTPUT_BASE -of=$EXE_NAME $SRC/testdll.d $SRC/cppnew.d ` ~ mainExtra);

    run(`$EXE_NAME`, stdout, stderr, [`LD_LIBRARY_PATH`: Vars.OUTPUT_BASE]);

    return 0;
}
