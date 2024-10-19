/*
TEST_OUTPUT:
---
fail_compilation/template_instance.d(15): Error: static assert:  `false` is false
fail_compilation/template_instance.d(17):        instantiated from here: `X!(E.a)`
---
*/

enum E
{
    a,b,c
}
template X(E e)
{
    static assert(false);
}
alias Y = X!(E.a);
