/*
TEST_OUTPUT:
---
fail_compilation/fail10481.d(10): Error: undefined identifier T1, did you mean alias T0?
---
*/

struct A {}

void get(T0 = T1.Req, Params...)(Params , T1) {}

void main()
{
    auto xxx = get!A;
}
