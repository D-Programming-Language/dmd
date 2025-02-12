/**
 * When compiling on Windows with the Microsoft toolchain, try to detect the Visual Studio setup.
 *
 * Copyright:   Copyright (C) 1999-2024 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 https://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/src/dmd/link.d, _vsoptions.d)
 * Documentation:  https://dlang.org/phobos/dmd_vsoptions.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/vsoptions.d
 */

module dmd.vsoptions;

version (Windows):
import core.stdc.ctype;
import core.stdc.stdlib;
import core.stdc.string;
import core.stdc.wchar_;
import core.sys.windows.winbase;
import core.sys.windows.windef;
import core.sys.windows.winreg;

import dmd.root.env;
import dmd.root.file;
import dmd.root.filename;
import dmd.common.outbuffer;
import dmd.root.rmem;
import dmd.root.string : toDString;

nothrow:

private immutable supportedPre2017Versions = ["14.0", "12.0", "11.0", "10.0", "9.0"];

extern(C++) struct VSOptions
{
  nothrow:

    // evaluated once at startup, reflecting the result of vcvarsall.bat
    //  from the current environment or the latest Visual Studio installation
    const(char)* WindowsSdkDir;
    const(char)* WindowsSdkVersion;
    const(char)* UCRTSdkDir;
    const(char)* UCRTVersion;
    const(char)* VSInstallDir;
    const(char)* VCInstallDir;
    const(char)* VCToolsInstallDir; // used by VS 2017+

    /**
     * fill member variables from environment or registry
     */
    void initialize()
    {
        detectWindowsSDK();
        detectUCRT();
        detectVSInstallDir();
        detectVCInstallDir();
        detectVCToolsInstallDir();
    }

    /**
     * set all members to null. Used if we detect a VS installation but end up
     * falling back on lld-link.exe
     */
    void uninitialize()
    {
        WindowsSdkDir = null;
        WindowsSdkVersion = null;
        UCRTSdkDir = null;
        UCRTVersion = null;
        VSInstallDir = null;
        VCInstallDir = null;
        VCToolsInstallDir = null;
    }

    /**
     * retrieve the name of the default C runtime library
     * Params:
     *   x64 = target architecture (x86 if false)
     * Returns:
     *   name of the default C runtime library
     */
    const(char)* defaultRuntimeLibrary(bool x64)
    {
        if (VCInstallDir is null)
        {
            detectVCInstallDir();
            detectVCToolsInstallDir();
        }
        if (getVCLibDir(x64))
            return "libcmt";
        else
            return "msvcrt120"; // mingw replacement
    }

    /**
     * retrieve options to be passed to the Microsoft linker
     * Params:
     *   x64 = target architecture (x86 if false)
     * Returns:
     *   allocated string of options to add to the linker command line
     */
    const(char)* linkOptions(bool x64)
    {
        OutBuffer cmdbuf;
        if (auto vclibdir = getVCLibDir(x64))
        {
            cmdbuf.writestring(" /LIBPATH:\"");
            cmdbuf.writestring(vclibdir);
            cmdbuf.writeByte('\"');

            if (FileName.exists(FileName.combine(vclibdir, "legacy_stdio_definitions.lib")))
            {
                // VS2015 or later use UCRT
                cmdbuf.writestring(" legacy_stdio_definitions.lib");
                if (auto p = getUCRTLibPath(x64))
                {
                    cmdbuf.writestring(" /LIBPATH:\"");
                    cmdbuf.writestring(p);
                    cmdbuf.writeByte('\"');
                }
            }
        }
        if (auto p = getSDKLibPath(x64))
        {
            cmdbuf.writestring(" /LIBPATH:\"");
            cmdbuf.writestring(p);
            cmdbuf.writeByte('\"');
        }
        if (auto p = getenv("DXSDK_DIR"w))
        {
            // support for old DX SDK installations
            cmdbuf.writestring(" /LIBPATH:\"");
            cmdbuf.writestring(p);
            cmdbuf.writestring(x64 ? `\Lib\x64"` : `\Lib\x86"`);
            mem.xfree(p);
        }
        return cmdbuf.extractChars();
    }

    /**
     * retrieve path to the Microsoft linker executable
     * also modifies PATH environment variable if necessary to find conditionally loaded DLLs
     * Params:
     *   x64 = target architecture (x86 if false)
     * Returns:
     *   absolute path to link.exe, just "link.exe" if not found
     */
    const(char)* linkerPath(bool x64)
    {
        const(char)* addpath;
        if (auto p = getVCBinDir(x64, addpath))
        {
            OutBuffer cmdbuf;
            cmdbuf.writestring(p);
            cmdbuf.writestring(r"\link.exe");
            if (addpath)
            {
                // debug info needs DLLs from $(VSInstallDir)\Common7\IDE for most linker versions
                //  so prepend it too the PATH environment variable
                char* path = getenv("PATH"w);
                const pathlen = strlen(path);
                const addpathlen = strlen(addpath);

                const length = addpathlen + 1 + pathlen;
                char* npath = cast(char*)mem.xmalloc(length);
                memcpy(npath, addpath, addpathlen);
                npath[addpathlen] = ';';
                memcpy(npath + addpathlen + 1, path, pathlen);
                if (putenvRestorable("PATH", npath[0 .. length]))
                    assert(0);
                mem.xfree(npath);
                mem.xfree(path);
            }
            return cmdbuf.extractChars();
        }

        // try lld-link.exe alongside dmd.exe
        char[MAX_PATH + 1] dmdpath = void;
        const len = GetModuleFileNameA(null, dmdpath.ptr, dmdpath.length);
        if (len <= MAX_PATH)
        {
            auto lldpath = FileName.replaceName(dmdpath[0 .. len], "lld-link.exe");
            if (FileName.exists(lldpath))
                return lldpath.ptr;
        }

        // search PATH to avoid createProcess preferring "link.exe" from the dmd folder
        if (auto p = FileName.searchPath(getenv("PATH"w), "link.exe"[], false))
            return p.ptr;
        return "link.exe";
    }

    /**
    * retrieve path to the Microsoft compiler executable
    * Params:
    *   x64 = target architecture (x86 if false)
    * Returns:
    *   absolute path to cl.exe, just "cl.exe" if not found
    */
    const(char)* compilerPath(bool x64)
    {
        const(char)* addpath;
        if (auto p = getVCBinDir(x64, addpath))
        {
            OutBuffer cmdbuf;
            cmdbuf.writestring(p);
            cmdbuf.writestring(r"\cl.exe");
            return cmdbuf.extractChars();
        }
        return "cl.exe";
    }

private:
    /**
     * detect WindowsSdkDir and WindowsSDKVersion from environment or registry
     */
    void detectWindowsSDK()
    {
        if (WindowsSdkDir is null)
            WindowsSdkDir = getenv("WindowsSdkDir"w);

        if (WindowsSdkDir is null)
        {
            WindowsSdkDir = GetRegistryString(r"Microsoft\Windows Kits\Installed Roots", "KitsRoot10"w);
            if (WindowsSdkDir && !findLatestSDKDir(FileName.combine(WindowsSdkDir, "Include"), r"um\windows.h"))
                WindowsSdkDir = null;
        }
        if (WindowsSdkDir is null)
        {
            WindowsSdkDir = GetRegistryString(r"Microsoft\Microsoft SDKs\Windows\v8.1", "InstallationFolder"w);
            if (WindowsSdkDir && !FileName.exists(FileName.combine(WindowsSdkDir, "Lib")))
                WindowsSdkDir = null;
        }
        if (WindowsSdkDir is null)
        {
            WindowsSdkDir = GetRegistryString(r"Microsoft\Microsoft SDKs\Windows\v8.0", "InstallationFolder"w);
            if (WindowsSdkDir && !FileName.exists(FileName.combine(WindowsSdkDir, "Lib")))
                WindowsSdkDir = null;
        }
        if (WindowsSdkDir is null)
        {
            WindowsSdkDir = GetRegistryString(r"Microsoft\Microsoft SDKs\Windows", "CurrentInstallationFolder"w);
            if (WindowsSdkDir && !FileName.exists(FileName.combine(WindowsSdkDir, "Lib")))
                WindowsSdkDir = null;
        }

        if (WindowsSdkVersion is null)
            WindowsSdkVersion = getenv("WindowsSdkVersion"w);

        if (WindowsSdkVersion is null && WindowsSdkDir !is null)
        {
            const(char)* rootsDir = FileName.combine(WindowsSdkDir, "Include");
            WindowsSdkVersion = findLatestSDKDir(rootsDir, r"um\windows.h");
        }
    }

    /**
     * detect UCRTSdkDir and UCRTVersion from environment or registry
     */
    void detectUCRT()
    {
        if (UCRTSdkDir is null)
            UCRTSdkDir = getenv("UniversalCRTSdkDir"w);

        if (UCRTSdkDir is null)
            UCRTSdkDir = GetRegistryString(r"Microsoft\Windows Kits\Installed Roots", "KitsRoot10"w);

        if (UCRTVersion is null)
            UCRTVersion = getenv("UCRTVersion"w);

        if (UCRTVersion is null && UCRTSdkDir !is null)
        {
            const(char)* rootsDir = FileName.combine(UCRTSdkDir, "Lib");
            UCRTVersion = findLatestSDKDir(rootsDir, r"ucrt\x86\libucrt.lib");
        }
    }

    /**
     * detect VSInstallDir from environment or registry
     */
    void detectVSInstallDir()
    {
        if (VSInstallDir is null)
            VSInstallDir = getenv("VSINSTALLDIR"w);

        if (VSInstallDir is null)
            VSInstallDir = detectVSInstallDirViaCOM();

        if (VSInstallDir is null)
            VSInstallDir = GetRegistryString(r"Microsoft\VisualStudio\SxS\VS7", "15.0"w); // VS2017

        if (VSInstallDir is null)
        {
            wchar[260] buffer = void;
            // VS Build Tools 2017 (default installation path)
            const numWritten = ExpandEnvironmentStringsW(r"%ProgramFiles(x86)%\Microsoft Visual Studio\2017\BuildTools"w.ptr, buffer.ptr, buffer.length);
            if (numWritten <= buffer.length && exists(buffer.ptr))
                VSInstallDir = toNarrowStringz(buffer[0 .. numWritten - 1]).ptr;
        }

        if (VSInstallDir is null)
            foreach (ver; supportedPre2017Versions)
            {
                VSInstallDir = GetRegistryString(FileName.combine(r"Microsoft\VisualStudio", ver), "InstallDir"w);
                if (VSInstallDir)
                    break;
            }
    }

    /**
     * detect VCInstallDir from environment or registry
     */
    void detectVCInstallDir()
    {
        if (VCInstallDir is null)
            VCInstallDir = getenv("VCINSTALLDIR"w);

        if (VCInstallDir is null)
            if (VSInstallDir && FileName.exists(FileName.combine(VSInstallDir, "VC")))
                VCInstallDir = FileName.combine(VSInstallDir, "VC");

        // detect from registry (build tools?)
        if (VCInstallDir is null)
            foreach (ver; supportedPre2017Versions)
            {
                auto regPath = FileName.buildPath(r"Microsoft\VisualStudio", ver, r"Setup\VC");
                VCInstallDir = GetRegistryString(regPath, "ProductDir"w);
                FileName.free(regPath.ptr);
                if (VCInstallDir)
                    break;
            }
    }

    /**
     * detect VCToolsInstallDir from environment or registry (only used by VC 2017)
     */
    void detectVCToolsInstallDir()
    {
        if (VCToolsInstallDir is null)
            VCToolsInstallDir = getenv("VCTOOLSINSTALLDIR"w);

        if (VCToolsInstallDir is null && VCInstallDir)
        {
            const(char)* defverFile = FileName.combine(VCInstallDir, r"Auxiliary\Build\Microsoft.VCToolsVersion.default.txt");
            if (!FileName.exists(defverFile)) // file renamed with VS2019 Preview 2
                defverFile = FileName.combine(VCInstallDir, r"Auxiliary\Build\Microsoft.VCToolsVersion.v142.default.txt");
            if (FileName.exists(defverFile))
            {
                // VS 2017
                OutBuffer buf;
                if (File.read(defverFile.toDString, buf)) // read file into buf
                    return; // failed to read the file

                auto ver = cast(char*)buf.extractSlice(true).ptr;
                // trim version number
                while (*ver && isspace(*ver))
                    ver++;
                auto p = ver;
                while (*p == '.' || (*p >= '0' && *p <= '9'))
                    p++;
                *p = 0;

                if (ver && *ver)
                    VCToolsInstallDir = FileName.buildPath(VCInstallDir.toDString, r"Tools\MSVC", ver.toDString).ptr;
            }
        }
    }

public:
    /**
     * get Visual C bin folder
     * Params:
     *   x64 = target architecture (x86 if false)
     *   addpath = [out] path that needs to be added to the PATH environment variable
     * Returns:
     *   folder containing the VC executables
     *
     * Selects the binary path according to the host and target OS, but verifies
     * that link.exe exists in that folder and falls back to 32-bit host/target if
     * missing
     * Note: differences for the linker binaries are small, they all
     * allow cross compilation
     */
    const(char)* getVCBinDir(bool x64, out const(char)* addpath) const
    {
        alias linkExists = returnDirIfContainsFile!"link.exe";

        const bool isHost64 = isWin64Host();
        if (VCToolsInstallDir !is null)
        {
            const vcToolsInstallDir = VCToolsInstallDir.toDString;
            if (isHost64)
            {
                if (x64)
                {
                    if (auto p = linkExists(vcToolsInstallDir, r"bin\HostX64\x64"))
                        return p;
                    // in case of missing linker, prefer other host binaries over other target architecture
                }
                else
                {
                    if (auto p = linkExists(vcToolsInstallDir, r"bin\HostX64\x86"))
                    {
                        addpath = FileName.combine(vcToolsInstallDir, r"bin\HostX64\x64").ptr;
                        return p;
                    }
                }
            }
            if (x64)
            {
                if (auto p = linkExists(vcToolsInstallDir, r"bin\HostX86\x64"))
                {
                    addpath = FileName.combine(vcToolsInstallDir, r"bin\HostX86\x86").ptr;
                    return p;
                }
            }
            if (auto p = linkExists(vcToolsInstallDir, r"bin\HostX86\x86"))
                return p;
        }
        if (VCInstallDir !is null)
        {
            const vcInstallDir = VCInstallDir.toDString;
            if (isHost64)
            {
                if (x64)
                {
                    if (auto p = linkExists(vcInstallDir, r"bin\amd64"))
                        return p;
                    // in case of missing linker, prefer other host binaries over other target architecture
                }
                else
                {
                    if (auto p = linkExists(vcInstallDir, r"bin\amd64_x86"))
                    {
                        addpath = FileName.combine(vcInstallDir, r"bin\amd64").ptr;
                        return p;
                    }
                }
            }

            if (VSInstallDir)
                addpath = FileName.combine(VSInstallDir.toDString, r"Common7\IDE").ptr;
            else
                addpath = FileName.combine(vcInstallDir, r"bin").ptr;

            if (x64)
                if (auto p = linkExists(vcInstallDir, r"x86_amd64"))
                    return p;

            if (auto p = linkExists(vcInstallDir, r"bin\HostX86\x86"))
                return p;
        }
        return null;
    }

    /**
    * get Visual C Library folder
    * Params:
    *   x64 = target architecture (x86 if false)
    * Returns:
    *   folder containing the VC runtime libraries
    */
    const(char)* getVCLibDir(bool x64) const
    {
        const(char)* proposed;

        if (VCToolsInstallDir !is null)
            proposed = FileName.combine(VCToolsInstallDir, x64 ? r"lib\x64" : r"lib\x86");
        else if (VCInstallDir !is null)
            proposed = FileName.combine(VCInstallDir, x64 ? r"lib\amd64" : "lib");

        // Due to the possibility of VS being installed with VC directory without the libraries
        // we must check that the expected directory does exist.
        // It is possible that this isn't the only location a file check is required.
        return FileName.exists(proposed) ? proposed : null;
    }

    const(char)* getVCIncludeDir() const
    {
        const(char)* proposed;

        if (VCToolsInstallDir !is null)
            proposed = FileName.combine(VCToolsInstallDir, "include");
        else if (VCInstallDir !is null)
            proposed = FileName.combine(VCInstallDir, "include");

        return FileName.exists(proposed) ? proposed : null;
    }

    /**
     * get the path to the universal CRT libraries
     * Params:
     *   x64 = target architecture (x86 if false)
     * Returns:
     *   folder containing the universal CRT libraries
     */
    const(char)* getUCRTLibPath(bool x64) const
    {
        if (UCRTSdkDir && UCRTVersion)
           return FileName.buildPath(UCRTSdkDir.toDString, "Lib", UCRTVersion.toDString, x64 ? r"ucrt\x64" : r"ucrt\x86").ptr;
        return null;
    }

    /**
     * get the path to the Windows SDK CRT libraries
     * Params:
     *   x64 = target architecture (x86 if false)
     * Returns:
     *   folder containing the Windows SDK libraries
     */
    const(char)* getSDKLibPath(bool x64) const
    {
        if (WindowsSdkDir)
        {
            alias kernel32Exists = returnDirIfContainsFile!"kernel32.lib";

            const arch = x64 ? "x64" : "x86";
            const sdk = FileName.combine(WindowsSdkDir.toDString, "lib");
            if (WindowsSdkVersion)
            {
                if (auto p = kernel32Exists(sdk, WindowsSdkVersion.toDString, "um", arch)) // SDK 10.0
                    return p;
            }
            if (auto p = kernel32Exists(sdk, r"win8\um", arch)) // SDK 8.0
                return p;
            if (auto p = kernel32Exists(sdk, r"winv6.3\um", arch)) // SDK 8.1
                return p;
            if (x64)
            {
                if (auto p = kernel32Exists(sdk, arch)) // SDK 7.1 or earlier
                    return p;
            }
            else
            {
                if (auto p = kernel32Exists(sdk)) // SDK 7.1 or earlier
                    return p;
            }
        }

        // try mingw fallback relative to phobos library folder that's part of LIB
        if (auto p = FileName.searchPath(getenv("LIB"w), r"mingw\kernel32.lib"[], false))
            return FileName.path(p).ptr;

        return null;
    }

    const(char)* getSDKIncludePath() const
    {
        if (WindowsSdkDir)
        {
            alias umExists = returnDirIfContainsFile!"um"; // subdir in this case

            const sdk = FileName.combine(WindowsSdkDir.toDString, "include");
            if (WindowsSdkVersion)
            {
                if (auto p = umExists(sdk, WindowsSdkVersion.toDString)) // SDK 10.0
                    return p;
            }
            // purely speculative
            if (auto p = umExists(sdk, "win8")) // SDK 8.0
                return p;
            if (auto p = umExists(sdk, "winv6.3")) // SDK 8.1
                return p;
            if (auto p = umExists(sdk)) // SDK 7.1 or earlier
                return p;
        }

        return null;
    }

private:
extern(D):

    // iterate through subdirectories named by SDK version in baseDir and return the
    //  one with the largest version that also contains the test file
    static const(char)* findLatestSDKDir(const(char)* baseDir, string testfile)
    {
        import dmd.common.smallbuffer : SmallBuffer, toWStringz;

        const(char)* pattern = FileName.combine(baseDir, "*");
        wchar[1024] support = void;
        auto buf = SmallBuffer!wchar(support.length, support);
        wchar* wpattern = toWStringz(pattern.toDString, buf).ptr;
        FileName.free(pattern);

        WIN32_FIND_DATAW fileinfo;
        HANDLE h = FindFirstFileW(wpattern, &fileinfo);
        if (h == INVALID_HANDLE_VALUE)
            return null;

        const dBaseDir = baseDir.toDString;

        char* res;
        do
        {
            if (fileinfo.cFileName[0] >= '1' && fileinfo.cFileName[0] <= '9')
            {
                char[] name = toNarrowStringz(fileinfo.cFileName.ptr.toDString);
                // FIXME: proper version strings comparison
                if ((!res || strcmp(res, name.ptr) < 0) &&
                    FileName.exists(FileName.buildPath(dBaseDir, name, testfile)))
                {
                    if (res)
                        mem.xfree(res);
                    res = name.ptr;
                }
                else
                    mem.xfree(name.ptr);
            }
        }
        while(FindNextFileW(h, &fileinfo));

        if (!FindClose(h))
            res = null;
        return res;
    }

    pragma(lib, "advapi32.lib");

    /**
     * read a string from the 32-bit registry
     * Params:
     *  softwareKeyPath = path below HKLM\SOFTWARE
     *  valueName       = name of the value to read
     * Returns:
     *  the registry value if it exists and has string type
     */
    const(char)* GetRegistryString(const(char)[] softwareKeyPath, wstring valueName) const
    {
        enum x64hive = false; // VS registry entries always in 32-bit hive

        version(Win64)
            enum prefix = x64hive ? r"SOFTWARE\" : r"SOFTWARE\WOW6432Node\";
        else
            enum prefix = r"SOFTWARE\";

        char[260] regPath = void;
        assert(prefix.length + softwareKeyPath.length < regPath.length);

        regPath[0 .. prefix.length] = prefix;
        regPath[prefix.length .. prefix.length + softwareKeyPath.length] = softwareKeyPath;
        regPath[prefix.length + softwareKeyPath.length] = 0;

        enum KEY_WOW64_64KEY = 0x000100; // not defined in core.sys.windows.winnt due to restrictive version
        enum KEY_WOW64_32KEY = 0x000200;
        HKEY key;
        LONG lRes = RegOpenKeyExA(HKEY_LOCAL_MACHINE, regPath.ptr, (x64hive ? KEY_WOW64_64KEY : KEY_WOW64_32KEY), KEY_READ, &key);
        if (FAILED(lRes))
            return null;
        scope(exit) RegCloseKey(key);

        wchar[260] buf = void;
        DWORD size = buf.sizeof;
        DWORD type;
        int hr = RegQueryValueExW(key, valueName.ptr, null, &type, cast(ubyte*) buf.ptr, &size);
        if (type != REG_SZ || size == 0)
            return null;

        wchar* wideValue = buf.ptr;
        scope(exit) wideValue != buf.ptr && mem.xfree(wideValue);
        if (hr == ERROR_MORE_DATA)
        {
            wideValue = cast(wchar*) mem.xmalloc_noscan(size);
            hr = RegQueryValueExW(key, valueName.ptr, null, &type, cast(ubyte*) wideValue, &size);
        }
        if (hr != 0)
            return null;

        auto wideLength = size / wchar.sizeof;
        if (wideValue[wideLength - 1] == 0) // may or may not be null-terminated
            --wideLength;
        return toNarrowStringz(wideValue[0 .. wideLength]).ptr;
    }

    /***
     * get architecture of host OS
     */
    static bool isWin64Host()
    {
        version (Win64)
        {
            return true;
        }
        else
        {
            // running as a 32-bit process on a 64-bit host?
            alias fnIsWow64Process = extern(Windows) BOOL function(HANDLE, PBOOL);
            __gshared fnIsWow64Process pIsWow64Process;

            if (!pIsWow64Process)
            {
                //IsWow64Process is not available on all supported versions of Windows.
                pIsWow64Process = cast(fnIsWow64Process) GetProcAddress(GetModuleHandleA("kernel32"), "IsWow64Process");
                if (!pIsWow64Process)
                    return false;
            }
            BOOL bIsWow64 = FALSE;
            if (!pIsWow64Process(GetCurrentProcess(), &bIsWow64))
                return false;

            return bIsWow64 != 0;
        }
    }
}

private:

inout(wchar)[] toDString(inout(wchar)* s)
{
    return s ? s[0 .. wcslen(s)] : null;
}

extern(C) wchar* _wgetenv(const(wchar)* name);

char* getenv(wstring name)
{
    if (auto wide = _wgetenv(name.ptr))
        return toNarrowStringz(wide.toDString).ptr;
    return null;
}

const(char)* returnDirIfContainsFile(string fileName)(scope const(char)[][] dirs...)
{
    auto dirPath = FileName.buildPath(dirs);

    auto filePath = FileName.combine(dirPath, fileName);
    scope(exit) FileName.free(filePath.ptr);

    if (FileName.exists(filePath))
        return dirPath.ptr;

    FileName.free(dirPath.ptr);
    return null;
}

extern (C) int _waccess(const(wchar)* _FileName, int _AccessMode);

bool exists(const(wchar)* path)
{
    return _waccess(path, 0) == 0;
}

///////////////////////////////////////////////////////////////////////
// COM interfaces to find VS2017+ installations
import core.sys.windows.com;
import core.sys.windows.wtypes : BSTR;
import core.sys.windows.oleauto : SysFreeString, SysStringLen;

pragma(lib, "ole32.lib");
pragma(lib, "oleaut32.lib");

interface ISetupInstance : IUnknown
{
    // static const GUID iid = uuid("B41463C3-8866-43B5-BC33-2B0676F7F42E");
    static const GUID iid = { 0xB41463C3, 0x8866, 0x43B5, [ 0xBC, 0x33, 0x2B, 0x06, 0x76, 0xF7, 0xF4, 0x2E ] };

    int GetInstanceId(BSTR* pbstrInstanceId);
    int GetInstallDate(LPFILETIME pInstallDate);
    int GetInstallationName(BSTR* pbstrInstallationName);
    int GetInstallationPath(BSTR* pbstrInstallationPath);
    int GetInstallationVersion(BSTR* pbstrInstallationVersion);
    int GetDisplayName(LCID lcid, BSTR* pbstrDisplayName);
    int GetDescription(LCID lcid, BSTR* pbstrDescription);
    int ResolvePath(LPCOLESTR pwszRelativePath, BSTR* pbstrAbsolutePath);
}

interface IEnumSetupInstances : IUnknown
{
    // static const GUID iid = uuid("6380BCFF-41D3-4B2E-8B2E-BF8A6810C848");

    int Next(ULONG celt, ISetupInstance* rgelt, ULONG* pceltFetched);
    int Skip(ULONG celt);
    int Reset();
    int Clone(IEnumSetupInstances* ppenum);
}

interface ISetupConfiguration : IUnknown
{
    // static const GUID iid = uuid("42843719-DB4C-46C2-8E7C-64F1816EFD5B");
    static const GUID iid = { 0x42843719, 0xDB4C, 0x46C2, [ 0x8E, 0x7C, 0x64, 0xF1, 0x81, 0x6E, 0xFD, 0x5B ] };

    int EnumInstances(IEnumSetupInstances* ppEnumInstances) ;
    int GetInstanceForCurrentProcess(ISetupInstance* ppInstance);
    int GetInstanceForPath(LPCWSTR wzPath, ISetupInstance* ppInstance);
}

const GUID iid_SetupConfiguration = { 0x177F0C4A, 0x1CD3, 0x4DE7, [ 0xA3, 0x2C, 0x71, 0xDB, 0xBB, 0x9F, 0xA3, 0x6D ] };

const(char)* detectVSInstallDirViaCOM()
{
    CoInitialize(null);
    scope(exit) CoUninitialize();

    ISetupConfiguration setup;
    IEnumSetupInstances instances;
    ISetupInstance instance;
    DWORD fetched;

    HRESULT hr = CoCreateInstance(&iid_SetupConfiguration, null, CLSCTX_ALL, &ISetupConfiguration.iid, cast(void**) &setup);
    if (hr != S_OK || !setup)
        return null;
    scope(exit) setup.Release();

    if (setup.EnumInstances(&instances) != S_OK)
        return null;
    scope(exit) instances.Release();

    static struct WrappedBString
    {
        BSTR ptr;
        this(this) @disable;
        ~this() { SysFreeString(ptr); }
        bool opCast(T : bool)() const { return ptr !is null; }
        size_t length() { return SysStringLen(ptr); }
        void moveTo(ref WrappedBString other)
        {
            SysFreeString(other.ptr);
            other.ptr = ptr;
            ptr = null;
        }
    }

    WrappedBString versionString, installDir;

    while (instances.Next(1, &instance, &fetched) == S_OK && fetched)
    {
        WrappedBString thisVersionString, thisInstallDir;
        if (instance.GetInstallationVersion(&thisVersionString.ptr) != S_OK ||
            instance.GetInstallationPath(&thisInstallDir.ptr) != S_OK)
            continue;

        // FIXME: proper version strings comparison
        //        existing versions are 15.0 to 16.5 (May 2020), problems expected in distant future
        if (versionString && wcscmp(thisVersionString.ptr, versionString.ptr) <= 0)
            continue; // not a newer version, skip

        const installDirLength = thisInstallDir.length;
        const vcInstallDirLength = installDirLength + 4;
        auto vcInstallDir = (cast(wchar*) mem.xmalloc_noscan(vcInstallDirLength * wchar.sizeof))[0 .. vcInstallDirLength];
        scope(exit) mem.xfree(vcInstallDir.ptr);
        vcInstallDir[0 .. installDirLength] = thisInstallDir.ptr[0 .. installDirLength];
        vcInstallDir[installDirLength .. $] = "\\VC\0"w;
        if (!exists(vcInstallDir.ptr))
            continue; // Visual C++ not included, skip

        thisVersionString.moveTo(versionString);
        thisInstallDir.moveTo(installDir);
    }

    return !installDir ? null : toNarrowStringz(installDir.ptr[0 .. installDir.length]).ptr;
}
