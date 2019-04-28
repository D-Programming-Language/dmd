/*
TEST_OUTPUT:
---
fail_compilation/faildeleteaa.d(12): Error: `delete` is obsolete.  Use `object.destroy()` (and `core.memory.GC.free()` if applicable) instead.
fail_compilation/faildeleteaa.d(12): Error: cannot delete type `int`
---
*/

void main()
{
    int[int] aa = [1 : 2];
    delete aa[1];
}
