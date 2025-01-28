// REQUIRED_ARGS: -unittest -main

// `a` takes its parameter by value;     the parameter returns by reference.
// `b` takes its parameter by reference; the parameter returns by value.
// The parameter storage class has priority over the value category of the parameter’s return type.
void a( ref (int function()) ) { }
void b((ref  int function()) ) { }

// `c` is `a` without clarifying parentheses.
void c( ref  int function()  ) { }

static assert(!is( typeof(&a) == typeof(&b) ));
static assert( is( typeof(&a) == typeof(&c) ));

// `x` returns by reference; the return type is a function that returns an `int` by value.
// `y` returns by vale;      the return type is a function that returns an `int` by reference.
// The value category of the declared function has priority over the value category of the return type.
 ref (int function()) x() { static typeof(return) fp = null; return fp; }
(ref  int function()) y() => null;

// `z` is `x` without clarifying parentheses.
 ref  int function()  z() => x();

static assert(!is( typeof(&x) == typeof(&y) ));
static assert( is( typeof(&x) == typeof(&z) ));

@safe unittest
{
    static int i = 0;
    // Congruence between function declaration and function type.
     ref int funcName() @safe  => i;
    (ref int delegate() @safe) fptr = &funcName;
}

// Combination of ref return and binding parameters by reference
// as well as returning by reference and by reference returning function type.
ref (ref int function() @safe) hof(ref (ref int function() @safe)[] fptrs) @safe
{
    static assert(__traits(isRef, fptrs));
    fptrs[0]() = 1;
    (ref int function() @safe)* result = &fptrs[0];
    fptrs = [];
    return *result;
}

@safe unittest
{
    static int i = 0;
    static ref int f() => i;
    static assert(is(typeof(&f) == ref int function() nothrow @nogc @safe));

    (ref int function() @safe)[] fps = [ &f, &f ];
    auto fpp = &(hof(fps));
    assert(fps.length == 0);
    assert(*fpp == &f);
    assert(i == 1);
    static assert(is(typeof(fpp) == (ref int function() @safe)*));
    int* p = &((*fpp)());
    *p = 2;
    assert(i == 2);
    (*fpp)()++;
    assert(i == 3);
}

struct S
{
    int i;
    ref int get() @safe return => i;
}

@safe unittest
{
    S s;
    (ref int delegate() return @safe) dg = &s.get;
    dg() = 1;
    assert(s.i == 1);
}

static assert(is(typeof(&S().get) == ref int delegate() @safe return));

@safe unittest
{
    static int x = 1;
    assert(x == 1);
    auto f = function ref int() => x;
    static assert( is( typeof(f) : ref const     int function() @safe ));
    static assert(!is( typeof(f) : ref immutable int function() @safe ));
    f() = 2;
    assert(x == 2);
    takesFP(f);
    assert(x == 3);

    auto g = cast(ref int function()) f;
}

ref (ref int function() @safe) returnsFP() @safe { static (ref int function() @safe) fp = null; return fp; }
void takesFP((ref int function() @safe) fp) @safe { fp() = 3; }

void takesFPFP(typeof(&returnsFP) function( typeof(&returnsFP) )) { }

// pretty print and actual D syntax coincide even in convoluted cases
static assert(   typeof(&takesFPFP).stringof == "void function((ref (ref int function() @safe) function() @safe) function((ref (ref int function() @safe) function() @safe)))");
static assert(is(typeof(&takesFPFP)          ==  void function((ref (ref int function() @safe) function() @safe) function((ref (ref int function() @safe) function() @safe))) ));
static assert((ref int function()).stringof == "(ref int function())");

// as an artifact of the type grammar, these should hold:
static assert(is( (int) == int ));
static assert(is( (const int) == const(int) ));
static assert(is( (const shared int) == shared(const(int)) ));
static assert(is( (const shared int) == shared(const int ) ));
