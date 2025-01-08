/* REQUIRED_ARGS: -preview=dip1000
TEST_OUTPUT:
---
fail_compilation/fail20183.d(1016): Error: address of variable `__rvalue2` assigned to `p` with longer lifetime
fail_compilation/fail20183.d(1017): Error: address of expression temporary returned by `s()` assigned to `q` with longer lifetime
fail_compilation/fail20183.d(1018): Error: address of struct literal `S(0)` assigned to `r` with longer lifetime
---
 */

#line 1000

// https://issues.dlang.org/show_bug.cgi?id=20183
@safe:

int* addr(return ref int b) { return &b; }

struct S
{
    int i;
    S* addrOf() return => &this;
}

S s() { return S(); }

void test()
{
    scope int* p = addr(S().i);  // struct literal
    scope int* q = addr(s().i);  // struct temporary
    scope S* r = S().addrOf();   // struct literal
}

/*
TEST_OUTPUT:
---
fail_compilation/fail20183.d(1107): Error: address of expression temporary returned by `s()` assigned to `this.ptr` with longer lifetime
---
 */
#line 1100

class Foo
{
    int* ptr;

    this() @safe
    {
        ptr = addr(s().i);  // struct literal
    }
}
