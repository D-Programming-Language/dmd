/*
TEST_OUTPUT:
---
fail_compilation/sarrrtinit.d(11): Deprecation: cannot implicitly convert expression `null` of type `typeof(null)` to `int[0]`
fail_compilation/sarrrtinit.d(13): Error: mismatched array lengths, 1 and 0
---
*/
void f()
{
	int[0] a = []; // ok
	int[0] a1 = null; // fail
	int[0] a2 = (int[]).init; // ok
	int[1] a3 = (int[]).init; // fail
}
