/*
TEST_OUTPUT:
---
fail_compilation/nestedtempl3.d(25): Error: cannot access frame pointer of `nestedtempl3.test.S!(i).S`
    auto s = S();
              ^
---
*/

void test()
{
    int i;

    auto f0()
    {
        int j = 10;
        struct S(alias a)
        {
            auto get() { return j; }
        }
        return S!i();
    }

    alias S = typeof(f0());
    auto s = S();
}
