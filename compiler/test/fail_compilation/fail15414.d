// https://issues.dlang.org/show_bug.cgi?id=15414

/*
TEST_OUTPUT:
---
fail_compilation/fail15414.d(18): Error: `__traits(getAttributes)` may only be used for individual functions, not the overload set `fun`
fail_compilation/fail15414.d(18):        the result of `__traits(getOverloads)` may be used to select the desired function to extract attributes from
---
*/

@("gigi")
void fun() {}
@("mimi")
void fun(int) {}

void main()
{
    auto t =  __traits(getAttributes, fun);
}
