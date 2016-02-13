/*
TEST_OUTPUT:
---
fail_compilation/fail10528.d(19): Error: undefined identifier 'a'
fail_compilation/fail10528.d(20): Error: undefined identifier 'a' in module 'a10528'
fail_compilation/fail10528.d(22): Error: undefined identifier 'b'
fail_compilation/fail10528.d(23): Error: undefined identifier 'b' in module 'a10528'
fail_compilation/fail10528.d(25): Error: variable a10528.S.c is not accessible from module fail10528
fail_compilation/fail10528.d(26): Error: variable a10528.S.c is not accessible from module fail10528
fail_compilation/fail10528.d(28): Error: variable a10528.C.d is not accessible from module fail10528
fail_compilation/fail10528.d(29): Error: variable a10528.C.d is not accessible from module fail10528
---
*/

import imports.a10528;

void main()
{
    auto a1 = a;
    auto a2 = imports.a10528.a;

    auto b1 = b;
    auto b2 = imports.a10528.b;

    auto c1 = S.c;
    with (S) auto c2 = c;

    auto d1 = C.d;
    with (C) auto d2 = d;
}
