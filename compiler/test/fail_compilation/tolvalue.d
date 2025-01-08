/**
TEST_OUTPUT:
---
fail_compilation/tolvalue.d(25): Error: cannot take address of template `templateFunc(T)()`, perhaps instantiate it first
fail_compilation/tolvalue.d(26): Error: cannot take address of type `int`
fail_compilation/tolvalue.d(27): Error: cannot take address of constant `3`
fail_compilation/tolvalue.d(28): Error: cannot take address of operator `$`
fail_compilation/tolvalue.d(29): Error: cannot take address of compiler-generated variable `__ctfe`
fail_compilation/tolvalue.d(30): Error: cannot take address of manifest constant `f`
fail_compilation/tolvalue.d(35): Error: cannot modify constant `3`
fail_compilation/tolvalue.d(36): Error: cannot modify compiler-generated variable `__ctfe`
fail_compilation/tolvalue.d(37): Error: cannot modify manifest constant `f`
---
*/

// https://issues.dlang.org/show_bug.cgi?id=24238

void templateFunc(T)() {}
alias intAlias = int;
enum E { f }

void addr()
{
    int[] a;
    auto x0 = &templateFunc;
    auto x1 = &intAlias;
    auto x2 = &3;
    auto x3 = a[&$];
    auto x4 = &__ctfe;
    auto x6 = &E.f;
}

void inc(int lz)
{
    3++;
    __ctfe++;
    E.f++;
}
