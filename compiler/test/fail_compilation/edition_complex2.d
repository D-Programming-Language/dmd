/*
TEST_OUTPUT:
---
fail_compilation/edition_complex2.d(3): Error: semicolon expected following auto declaration, not `i`
fail_compilation/edition_complex2.d(4): Error: semicolon expected following auto declaration, not `i`
---
 */
@__edition_latest_do_not_use
module edition_complex2;

#line 1
void main()
{
    auto cv = 1.0+0.0i;
    auto iv = 1.0i;
}
