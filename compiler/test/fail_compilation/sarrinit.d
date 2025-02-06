/*
TEST_OUTPUT:
---
fail_compilation/sarrinit.d(8): Error: cannot implicitly convert expression `null` of type `typeof(null)` to `int[0]`
---
*/
int[0] a = []; // ok
int[0] a1 = null; // fail
