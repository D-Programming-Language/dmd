/*
TEST_OUTPUT:
---
fail_compilation/b20011.d(22): Error: cannot modify expression `S1(cast(ubyte)0u).member` because it is not an lvalue
fail_compilation/b20011.d(25): Error: cannot modify expression `S2(null).member` because it is not an lvalue
fail_compilation/b20011.d(26): Error: cannot modify expression `S2(null).member` because it is not an lvalue
fail_compilation/b20011.d(29): Error: cannot modify expression `U1(cast(ubyte)0u, ).m2` because it is not an lvalue
fail_compilation/b20011.d(35): Error: function `assignableByOut` is not callable using argument types `(ubyte)`
fail_compilation/b20011.d(35):        cannot pass rvalue argument `S1(cast(ubyte)0u).member` of type `ubyte` to parameter `out ubyte p`
fail_compilation/b20011.d(32):        `b20011.main.assignableByOut(out ubyte p)` declared here
---
*/
module b20011;

struct S1 { ubyte member;     }
struct S2 { ubyte[] member;   }
union U1  { ubyte m1; int m2; }

void main()
{
    enum S1 s1 = {};
    s1.member = 42;

    enum S2 s2 = {};
    s2.member = [];
    s2.member ~= [];

    enum U1 u1 = {m1 : 0};
    u1.m2 = 42;

    void assignableByRef(ref ubyte p){ p = 42; }
    void assignableByOut(out ubyte p){ p = 42; }
    void assignableByConstRef(ref const ubyte p){}
    assignableByRef(s1.member);
    assignableByOut(s1.member);
    assignableByConstRef(s1.member);
}
