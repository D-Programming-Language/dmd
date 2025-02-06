/*
REQUIRED_ARGS: -de
TEST_OUTPUT:
---
fail_compilation/trusted_escape.d(13): Deprecation: returning `r` escapes a reference to parameter `r`
fail_compilation/trusted_escape.d(13):        perhaps annotate the parameter with `return`
fail_compilation/trusted_escape.d(15): Deprecation: returning `&r` escapes a reference to parameter `r`
fail_compilation/trusted_escape.d(15):        perhaps annotate the parameter with `return`
---
*/

// @trusted functions must have a safe interface
@trusted ref int a(ref int r) { return r; }
@system ref int a2(ref int r) { return r; } // OK
@trusted int* b(ref int r) { return &r; }
