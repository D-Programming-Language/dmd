// https://issues.dlang.org/show_bug.cgi?id=22202

/*
TEST_OUTPUT:
---
fail_compilation/fail22202.d(23): Error: `pure` function `D main` cannot call impure copy constructor `fail22202.SystemCopy.this`
fail_compilation/fail22202.d(23): Error: `@safe` function `D main` cannot call `@system` copy constructor `fail22202.SystemCopy.this`
fail_compilation/fail22202.d(15):        `fail22202.SystemCopy.this` is declared here
fail_compilation/fail22202.d(23): Error: `@nogc` function `D main` cannot call non-@nogc copy constructor `fail22202.SystemCopy.this`
---
*/

struct SystemCopy
{
    this(ref inout SystemCopy other) inout {}
}

void fun(SystemCopy) @safe pure @nogc {}

void main() @safe pure @nogc
{
    SystemCopy s;
    fun(s);
}
