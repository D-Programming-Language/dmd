// REQUIRED_ARGS: -preview=dip1000 -preview=in

void main ()
{
    testWithAllAttributes();
    testForeach();
    testSideEffect();
    testSideEffect2();
}

private immutable int CTFETestSideEffect = testSideEffect2();

void testWithAllAttributes() @safe pure nothrow @nogc
{
    // Used to test dtors
    bool isTestOver = false;

    // rvalues
    testin1(42);
    testin2((ulong[64]).init);
    testin3(ValueT(42));
    testin3(RefT(42));
    testin4((ValueT[64]).init);
    testin4([RefT(42), RefT(84), RefT(126), RefT(4)]);
    testin5(NonCopyable(true));
    testin6(WithPostblit(true));
    testin7(WithCopyCtor(true));
    isTestOver = false;
    testin8(WithDtor(&isTestOver), &isTestOver);
    isTestOver = false;

    // lvalues
    uint       a1;
    ulong[64]  a2;
    ValueT     a3;
    ValueT[64] a4;
    RefT       a5;
    RefT[4]    a6;
    NonCopyable  a7 = NonCopyable(true);
    WithPostblit a8;
    WithCopyCtor a9;
    WithDtor     a10 = WithDtor(&isTestOver);

    testin1(a1);
    testin2(a2);
    testin3(a3);
    testin3(a5);
    testin4(a4);
    testin4(a6);
    testin5(a7);
    testin6(a8);
    testin7(a9);
    isTestOver = false;
    testin8(a10, null);

    // Arguments are all values, no `ref` needed
    testin9(int.init);
    testin9(char.init, ubyte.init, short.init, int.init, size_t.init);
    // Arguments are all refs
    testin9(a2, a4, a5, a6, a7, a8, a9, a10);
    testin9(NonCopyable(true), WithPostblit(true), WithCopyCtor(true));
    // Mixed values and ref
    testin9(char.init, ubyte.init, a2, a4, a5, a6, a7, a8, a9, a10, size_t.init);

    // With dtor
    isTestOver = false;
    testin10(&isTestOver, NonCopyable(true), WithPostblit(true),
             WithCopyCtor(true), WithDtor(&isTestOver));
    isTestOver = true;
}

void testForeach() @safe pure
{
    int testCallNC (in NonCopyable k, in NonCopyable v)
    {
        assert(k == v);
        return k.value - v.value;
    }

    NonCopyable[NonCopyable] nc;
    nc[NonCopyable(0)] = NonCopyable(0);
    nc[NonCopyable(42)] = NonCopyable(42);
    nc[NonCopyable(int.min)] = NonCopyable(int.min);
    nc[NonCopyable(int.max)] = NonCopyable(int.max);
    foreach (ref k, const ref v; nc)
    {
        assert(k.value == v.value);
        assert(testCallNC(k, v) == 0);
    }
    assert(nc == nc);
    assert(nc.length == 4);

    RefT[RefT] rt;
    rt[RefT(42)] = RefT(42);
    rt[RefT(4)] = RefT(4);
    rt[RefT(242)] = RefT(242);
    rt[RefT(24)] = RefT(24);
    foreach (k, v; rt)
        assert(k.value == v.value);
    assert(rt == rt);

    static struct Msg
    {
        ubyte[3] value;
        const(char)[] msg;
    }

    static void testMsg (in Msg k_func, in Msg v_func)
    {
        assert(k_func.value == v_func.value);
        assert(k_func.msg == v_func.msg);
        assert(k_func == v_func);
    }

    Msg[Msg] msg;
    msg[Msg([1, 2, 3], "123")] = Msg([1, 2, 3], "123");
    msg[Msg([42, 4, 2], "4242")] = Msg([42, 4, 2], "4242");
    msg[Msg([242, 4, 0], "2424")] = Msg([242, 4, 0], "2424");
    foreach (ref k_loop, ref v_loop; msg)
        testMsg(k_loop, v_loop);
}

struct ValueT { int value; }
struct RefT   { ulong[64] value; }

struct NonCopyable
{
    @safe pure nothrow @nogc:

    int value;
    this(int b) { this.value = b; }

    @disable this(this);
    @disable this(ref NonCopyable);
}

struct NonUsable
{
    this(string msg) { throw new Exception(msg); }

    @safe pure nothrow @nogc:

    this(int b) { assert(0); }
    this(this)  { assert(0); }
    this(ref NonUsable) { assert(0); }
    ~this() { assert(0); }
}

struct WithPostblit
{
    int value;
    this(this) @safe pure nothrow @nogc { assert(0); }
}

struct WithCopyCtor
{
    @safe pure nothrow @nogc:

    int value;
    this(int b) { this.value = b; }
    this(ref WithCopyCtor) { assert(0); }
}

struct WithDtor
{
    bool* value;
    ~this() scope @safe pure nothrow @nogc {  assert(*value); }
}

void testSideEffect()
{
    static struct Struct
    {
        int value;
        // Need a dtor, but the throw is just to avoid `nothrow` inference
        ~this() { if (value == -1) throw new Exception(""); }
    }

    static void foo (Struct a, in Struct b)
    {
        assert(a.value == 0);
        assert(b.value == 1);
    }

    static Struct sideEffect ()
    {
        static int count;
        return Struct(count++);
    }

    foo(sideEffect(), sideEffect());
}

int testSideEffect2()
{
    static void foo (in NonUsable a, in NonUsable b)
    {
        assert(0);
    }

    // Make sure things are not destructed if they are not constructed
    // https://github.com/dlang/dmd/pull/14999#issuecomment-1473993053
    try
        foo(NonUsable("Something bad happened"), NonUsable(42));
    catch (Exception exc)
        assert(exc.msg == "Something bad happened");

    return 0;
}

@safe pure nothrow @nogc:

// By value
void testin1(in uint p) { }
// By ref because of size
void testin2(in ulong[64] p) { }
// By value or ref depending on size (or structs always passed by reference)
void testin3(in ValueT p) { }
void testin3(in RefT p) { }
// By ref because of size (or arrays always passed by reference)
void testin4(in ValueT[64] p) { }
void testin4(in RefT[4] p) { }

// By ref because of non-copyability
void testin5(in NonCopyable noncopy) { }
//  By ref because of postblit
void testin6(in WithPostblit withpostblit) { }
//  By ref because of copy ctor
void testin7(in WithCopyCtor withcopy) { }
//  By ref because of dtor
void testin8(in WithDtor withdtor, scope bool* isTestOver)
{
    if (isTestOver)
        *isTestOver = true;
}

// Allow to test various tuples (e.g. `(int, int)` and `(int, WithDtor)`)
// `ref` is only applied to the members which need it
void testin9(T...)(in T args) {}
void testin10(T...)(scope bool* isTestOver, in T args)
{
    if (isTestOver)
        *isTestOver = true;
}
