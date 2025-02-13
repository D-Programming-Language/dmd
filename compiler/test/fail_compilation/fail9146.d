// https://issues.dlang.org/show_bug.cgi?id=9146

/*
TEST_OUTPUT:
---
fail_compilation/fail9146.d(13): Error: undefined identifier `Y7`, did you mean variable `X7`?
fail_compilation/fail9146.d(16): Error: undefined identifier `Y11`, did you mean variable `X11`?
fail_compilation/fail9146.d(19): Error: undefined identifier `Y12`, did you mean variable `X12`?
---
*/

static if(is(typeof(X7))) {}
Y7 X7;

static if(is(typeof(X11.init))) {}
const { Y11 X11; }

static if(is(typeof(X12.init))) {}
enum X12 = Y12;
