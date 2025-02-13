/*
REQUIRED_ARGS: -betterC
TEST_OUTPUT:
---
fail_compilation/test18312.d(14): Error: `"[" ~ s ~ "]"` is not allowed in -betterC mode because it requires the garbage collector.
---
*/

// https://issues.dlang.org/show_bug.cgi?id=18312

extern (C) void main()
{
    scope string s;
    s = "[" ~ s ~ "]";
}
