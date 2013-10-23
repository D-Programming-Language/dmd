// PERMUTE_ARGS: -O -inline
// REQUIRED_ARGS: -fPIC

extern (C) int printf(const char*, ...);

/***************************************************/

align(16) struct S41
{
    int[4] a;
}

shared int x41;
shared S41 s41;

void test11310()
{
    printf("&x = %p\n", &x41);
    printf("&s = %p\n", &s41);
    assert((cast(int)&s41 & 0xF) == 0);
}

/***************************************************/

int main()
{
    test11310();

    writefln("Success");
    return 0;
}

