/* TEST_OUTPUT:
---
fail_compilation/test23715.i(13): Error: `_Thread_local` in block scope must be accompanied with `static` or `extern`
    _Thread_local int tli;
    ^
---
*/

// https://issues.dlang.org/show_bug.cgi?id=23715

void test2()
{
    _Thread_local int tli;
}
