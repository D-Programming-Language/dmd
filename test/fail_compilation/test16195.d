/*
 * TEST_OUTPUT:
---
fail_compilation/test16195.d(14): Error: `delete` is obsolete.  Use `object.destroy()` (and `core.memory.GC.free()` if applicable) instead.
fail_compilation/test16195.d(14): Error: `delete p` is not `@safe` but is used in `@safe` function `test`
---
 */


// https://issues.dlang.org/show_bug.cgi?id=16195

@safe pure nothrow @nogc void test(int* p)
{
    delete p;
}
