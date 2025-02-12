/*
EXTRA_FILES: imports/imp3254.d
TEST_OUTPUT:
---
fail_compilation/fail3254.d(13): Error: function `imports.imp3254.test3254(float)` is not accessible from function `D main`
---
*/
import imports.imp3254;

void main()
{
    test3254();     // OK, public
    test3254(0.0);
}
