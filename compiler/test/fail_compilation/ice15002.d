/*
TEST_OUTPUT:
---
fail_compilation/ice15002.d(14): Error: array index 5 is out of bounds `x[0 .. 3]`
int* p = &x[5][0];
          ^
fail_compilation/ice15002.d(14): Error: array index 5 is out of bounds `x[0 .. 3]`
int* p = &x[5][0];
          ^
---
*/

int[][3] x = [];
int* p = &x[5][0];
