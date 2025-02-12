/*
REQUIRED_ARGS:
PERMUTE_ARGS:
TEST_OUTPUT:
---
fail_compilation/test14251.d(15): Error: cannot synchronize on const object c
fail_compilation/test14251.d(22): Error: synchronize not allowed in pure function test2
---
*/

class C { }

void test1(const C c)
{
    synchronized (c)
    {
    }
}

void test2(C c) pure
{
    synchronized (c)
    {
    }
}
