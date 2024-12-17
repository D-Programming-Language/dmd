// REQUIRED_ARGS: -O -fPIC
// PERMUTE_ARGS:
// only testing on SYSV-ABI, but backend code is identical across platforms
// DISABLED: win32 win64 osx linux32 freebsd32 openbsd32
debug = PRINTF;
debug (PRINTF) import core.stdc.stdio;

// Run this after codegen changes:
// env DMD=generated/linux/release/64/dmd rdmd -fPIC -version=update test/runnable/test_cdstrpar.d
version (update)
{
    import std.algorithm : canFind, find, splitter, until;
    import std.array : appender, join;
    import std.conv : to;
    import std.exception : enforce;
    import std.file : readText;
    import std.format : formattedWrite;
    import std.meta : AliasSeq;
    import std.path : baseName, setExtension;
    import std.process : environment, execute, pipeProcess, wait;
    import std.range : dropOne;
    import std.regex : ctRegex, matchFirst, replaceFirstInto;
    import std.stdio : File, stdout, writeln;
    import std.string : strip;
    import std.traits : EnumMembers;
    import std.typecons : tuple;

    enum Arch
    {
        baseline, // doesn't affect argument passing
        // avx,
        // avx2,
    }

    enum sizes = [4, 8, 16, 32, 64];

    enum asmRE = ctRegex!`^\s+[\da-z]+:((\s[\da-z]{2})*)(.*)$`;

    void formatASM(Captures, Sink)(Captures cap, Sink sink)
    {
        formattedWrite(sink, "        /* %-30s */ %-(0x%s,%| %)\n", cap[3].strip, cap[1].splitter);
    }

    void main()
    {
        enum src = __FILE__;
        auto dmd = environment.get("DMD", "dmd");
        auto sink = appender!string();
        foreach (arch; [EnumMembers!Arch])
        {
            auto args = [dmd, "-c", "-O", "-fPIC", "-mcpu=" ~ arch.to!string, __FILE__];
            auto rc = execute(args);
            enforce(rc.status == 0, rc.output);
            formattedWrite(sink, "alias %sCases = AliasSeq!(\n", arch);
            // Just add empty Code!(newtype, count)(null) elements when adding a new type
            foreach (type; AliasSeq!(ubyte))
            {
                foreach (sz; sizes)
                {
                    args = ["objdump", "--disassemble", "--disassembler-options=intel-mnemonic",
                        "--section=.text.testee_" ~ type.stringof ~ "_" ~ sz.to!string,
                        __FILE__.baseName.setExtension(".o")];
                    auto p = pipeProcess(args);
                    formattedWrite(sink, "    Code!(%s, %s)([\n", type.stringof, sz);
                    foreach (line; p.stdout.byLine.find!(ln => ln.matchFirst(ctRegex!">:$"))
                            .dropOne.until!(ln => ln.canFind("...")))
                    {
                        replaceFirstInto!formatASM(sink, line, asmRE);
                    }
                    formattedWrite(sink, "    ]),\n");
                    enforce(wait(p.pid) == 0, p.stderr.byLine.join("\n"));
                }
            }
            formattedWrite(sink, ");\n\n");
        }
        {
            auto content = src.readText;
            auto f = File(src, "w");
            auto orng = f.lockingTextWriter;
            immutable string start = "// dfmt off";
            immutable string end = "// dfmt on";
            replaceFirstInto!((_, orng) => formattedWrite(orng, start ~ "\n%s" ~ end, sink.data))(orng,
                    content, ctRegex!(`^` ~ start ~ `[^$]*` ~ end ~ `$`, "m"));
        }
    }
}
else:

struct Struct(T, int N)
{
    T[N] buf;
}

private void callee(S)(S s)
{
}

private T getRValue(T)()
{
    return T.init;
}

template testee(T, int N)
{
    pragma(mangle, "testee_" ~ T.stringof ~ "_" ~ N.stringof) void testee()
    {
        callee(getRValue!(Struct!(T, N)));
    }
}

// holding the expected byte sequence
struct Code(T_, int N_)
{
    alias T = T_;
    alias N = N_;
    ubyte[] code;
}

alias AliasSeq(Args...) = Args;

// dfmt off
alias baselineCases = AliasSeq!(
    Code!(ubyte, 4)([
        /* push   rbp                     */ 0x55,
        /* mov    rbp,rsp                 */ 0x48, 0x8b, 0xec,
        /* call   9 <testee_ubyte_4+0x9>  */ 0xe8, 0x00, 0x00, 0x00, 0x00,
        /* mov    edi,eax                 */ 0x89, 0xc7,
        /* call   11 <testee_ubyte_4+0x11> */ 0xe8, 0x00, 0x00, 0x00, 0x00,
        /* pop    rbp                     */ 0x5d,
        /* ret                            */ 0xc3,
    ]),
    Code!(ubyte, 8)([
        /* push   rbp                     */ 0x55,
        /* mov    rbp,rsp                 */ 0x48, 0x8b, 0xec,
        /* call   9 <testee_ubyte_8+0x9>  */ 0xe8, 0x00, 0x00, 0x00, 0x00,
        /* mov    rdi,rax                 */ 0x48, 0x89, 0xc7,
        /* call   11 <testee_ubyte_8+0x11> */ 0xe8, 0x00, 0x00, 0x00, 0x00,
        /* pop    rbp                     */ 0x5d,
        /* ret                            */ 0xc3,
    ]),
    Code!(ubyte, 16)([
        /* push   rbp                     */ 0x55,
        /* mov    rbp,rsp                 */ 0x48, 0x8b, 0xec,
        /* call   9 <testee_ubyte_16+0x9> */ 0xe8, 0x00, 0x00, 0x00, 0x00,
        /* mov    rdi,rax                 */ 0x48, 0x89, 0xc7,
        /* mov    rsi,rdx                 */ 0x48, 0x89, 0xd6,
        /* call   14 <testee_ubyte_16+0x14> */ 0xe8, 0x00, 0x00, 0x00, 0x00,
        /* pop    rbp                     */ 0x5d,
        /* ret                            */ 0xc3,
    ]),
    Code!(ubyte, 32)([
        /* push   rbp                     */ 0x55,
        /* mov    rbp,rsp                 */ 0x48, 0x8b, 0xec,
        /* sub    rsp,0x20                */ 0x48, 0x83, 0xec, 0x20,
        /* lea    rdi,[rbp-0x20]          */ 0x48, 0x8d, 0x7d, 0xe0,
        /* call   11 <testee_ubyte_32+0x11> */ 0xe8, 0x00, 0x00, 0x00, 0x00,
        /* mov    rsi,rax                 */ 0x48, 0x89, 0xc6,
        /* push   QWORD PTR [rsi+0x18]    */ 0xff, 0x76, 0x18,
        /* push   QWORD PTR [rsi+0x10]    */ 0xff, 0x76, 0x10,
        /* push   QWORD PTR [rsi+0x8]     */ 0xff, 0x76, 0x08,
        /* push   QWORD PTR [rsi]         */ 0xff, 0x36,
        /* call   24 <testee_ubyte_32+0x24> */ 0xe8, 0x00, 0x00, 0x00, 0x00,
        /* add    rsp,0x20                */ 0x48, 0x83, 0xc4, 0x20,
        /* mov    rsp,rbp                 */ 0x48, 0x8b, 0xe5,
        /* pop    rbp                     */ 0x5d,
        /* ret                            */ 0xc3,
        /* add    BYTE PTR [rax],al       */ 0x00, 0x00,
    ]),
    Code!(ubyte, 64)([
        /* push   rbp                     */ 0x55,
        /* mov    rbp,rsp                 */ 0x48, 0x8b, 0xec,
        /* sub    rsp,0x40                */ 0x48, 0x83, 0xec, 0x40,
        /* lea    rdi,[rbp-0x40]          */ 0x48, 0x8d, 0x7d, 0xc0,
        /* call   11 <testee_ubyte_64+0x11> */ 0xe8, 0x00, 0x00, 0x00, 0x00,
        /* mov    rsi,rax                 */ 0x48, 0x89, 0xc6,
        /* mov    ecx,0x8                 */ 0xb9, 0x08, 0x00, 0x00, 0x00,
        /* add    rsi,0x38                */ 0x48, 0x83, 0xc6, 0x38,
        /* push   QWORD PTR [rsi]         */ 0xff, 0x36,
        /* sub    rsi,0x8                 */ 0x48, 0x83, 0xee, 0x08,
        /* dec    ecx                     */ 0xff, 0xc9,
        /* jne    1d <testee_ubyte_64+0x1d> */ 0x75, 0xf6,
        /* call   2c <testee_ubyte_64+0x2c> */ 0xe8, 0x00, 0x00, 0x00, 0x00,
        /* add    rsp,0x40                */ 0x48, 0x83, 0xc4, 0x40,
        /* mov    rsp,rbp                 */ 0x48, 0x8b, 0xe5,
        /* pop    rbp                     */ 0x5d,
        /* ret                            */ 0xc3,
        /* add    BYTE PTR [rax],al       */ 0x00, 0x00,
    ]),
);

// dfmt on

bool matches(const(ubyte)[] code, const(ubyte)[] exp)
{
    assert(code.length == exp.length);
    for (size_t i = 0; i < code.length; i++)
    {
        if (code[i] == exp[i])
            continue;
        // wildcard match for relative call displacement
        if (i && exp.length - (i - 1) >= 5 && exp[i - 1 .. i + 4] == [0xe8, 0x00, 0x00, 0x00, 0x00])
        {
            i += 3;
            continue;
        }
        return false;
    }
    return true;
}

alias testCases = AliasSeq!(baselineCases);

void main()
{
    foreach (tc; testCases)
    (){ // workaround Issue 7157
        auto code = (cast(ubyte*)&testee!(tc.T, tc.N))[0 .. tc.code.length];
        bool failure;
        if (!code.matches(tc.code))
        {
            fprintf(stderr, "Expected code sequence for testee!(%s, %u) not found.",
                    tc.T.stringof.ptr, tc.N);
            fprintf(stderr, "\n  Expected:");
            foreach (i, d; tc.code)
            {
                if (tc.code[i] != code[i])
                    fprintf(stderr, " \033[32m0x%02x\033[0m", d);
                else
                    fprintf(stderr, " 0x%02x", d);
            }
            fprintf(stderr, "\n    Actual:");
            foreach (i, d; code)
            {
                if (tc.code[i] != code[i])
                    fprintf(stderr, " \033[31m0x%02x\033[0m", d);
                else
                    fprintf(stderr, " 0x%02x", d);
            }
            fprintf(stderr, "\n");
            failure = true;
        }
        assert(!failure);
    }();
}
