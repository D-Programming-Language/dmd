/*
TEST_OUTPUT:
---
fail_compilation/diag10169.d(12): Error: `imports.a10169.B.x` is not visible from module `diag10169`
fail_compilation/diag10169.d(12): Error: no property `x` for type `B`, did you mean non-visible variable `x`?
---
*/
import imports.a10169;

void main()
{
    auto a = B.init.x;
}
