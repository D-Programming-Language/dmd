/*
RUN_OUTPUT:
---
Large struct: success
Large struct with opAssign: success
Large array: success
Large array with opAssign: success
---
*/
extern (C) int printf(const char* fmt, ...);

enum SIZE = 10_000_000; // 10 MB should exhaust the stack on most if not all test systems.

// The crucial part of the test cases is testing `destroy`. At the same time, we test
// `core.internal.lifetime.emplaceInitializer` (which is currently called by `destroy`).


import core.internal.lifetime;

void test_largestruct()
{
    static struct LargeStruct
    {
        int[SIZE/2] a1;
        int b = 42;
        int[SIZE/2] a2;
    }
    static LargeStruct s = void;
    emplaceInitializer(s);
    assert(s.b == 42);
    s.b = 101;
    destroy(s);
    assert(s.b == 42);
}

void test_largestruct_w_opassign()
{
    static struct LargeStructOpAssign
    {
        int[SIZE/2] a1;
        int b = 420;         // non-zero init
        int[SIZE/2] a2;

        void opAssign(typeof(this)) {} // hasElaborateAssign == true
    }
    static LargeStructOpAssign s = void;
    emplaceInitializer(s);
    assert(s.b == 420);
    s.b = 101;
    destroy(s);
    assert(s.b == 420);
}

void test_largearray() {
    static struct NonZero
    {
        int i = 123;
    }
    static NonZero[SIZE] s = void;
    emplaceInitializer(s);
    assert(s[SIZE/2] == NonZero.init);
    s[10] = NonZero(101);
    destroy(s);
    assert(s[10] == NonZero.init);
}

void test_largearray_w_opassign() {
    static struct NonZeroWithOpAssign
    {
        int i = 123;
        void opAssign(typeof(this)) {} // hasElaborateAssign == true
    }
    static NonZeroWithOpAssign[SIZE] s = void;
    emplaceInitializer(s);
    assert(s[SIZE/2] == NonZeroWithOpAssign.init);
    s[10] = NonZeroWithOpAssign(101);
    destroy(s);
    assert(s[10] == NonZeroWithOpAssign.init);
}

int main()
{
    test_largestruct();
    printf("Large struct: success\n");
    test_largestruct_w_opassign();
    printf("Large struct with opAssign: success\n");
    test_largearray();
    printf("Large array: success\n");
    test_largearray_w_opassign();
    printf("Large array with opAssign: success\n");
    return 0;
}
