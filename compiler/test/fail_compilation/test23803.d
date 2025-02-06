// https://issues.dlang.org/show_bug.cgi?id=23803

/*
REQUIRED_ARGS: -betterC
TEST_OUTPUT:
---
fail_compilation/test23803.d(14): Error: `a ~ b` is not allowed in -betterC mode because it requires the garbage collector.
---
*/

string foo()
{
    string a, b;
    return a ~ b;
}

extern(C) void main()
{
    foo();
}
