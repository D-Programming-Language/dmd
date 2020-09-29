/*
TEST_OUTPUT:
---
tuple(func)
---
*/
// https://issues.dlang.org/show_bug.cgi?id=21282

template I(T...) { alias I = T; }

template Bug(T...) {
        alias Bug = I!(T[0]);
        //alias Bug = mixin("I!(T[0])");
}
void func() {}
pragma(msg, Bug!func);
