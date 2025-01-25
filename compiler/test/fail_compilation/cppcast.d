/*
REQUIRED_ARGS: -de
TEST_OUTPUT:
---
fail_compilation/cppcast.d(14): Deprecation: dynamic cast is not implemented for `extern(C++)` classes
fail_compilation/cppcast.d(14):        use `*cast(cppcast.D*) &object` instead
---
*/
extern(C++) class C { void f() { } }
extern(C++) class D : C { }

void main() @safe
{
    assert(cast(D)(new C) is null); // would fail as RTTI not checked
    auto c = cast(C)(new D); // OK
}
