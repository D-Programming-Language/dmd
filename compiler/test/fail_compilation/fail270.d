/*
TEST_OUTPUT:
---
fail_compilation/fail270.d(12): Error: slice `[1..0]` is out of range of `[0..0]`
fail_compilation/fail270.d(12): Error: mixin `fail270.Tuple!int.Tuple.Tuple!()` error instantiating
fail_compilation/fail270.d(14): Error: mixin `fail270.Tuple!int` error instantiating
---
*/

struct Tuple(TList...)
{
    mixin .Tuple!((TList[1 .. $])) tail;
}
mixin Tuple!(int);
