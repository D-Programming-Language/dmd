/* TEST_OUTPUT:
---
fail_compilation/castref.d(10): Error: `cast(ref` needs to be followed with a type
---
*/

void test()
{
    int* p;
    char* q = cast(ref const)p;
}
