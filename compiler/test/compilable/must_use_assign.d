import core.attribute;

@mustuse struct S {}

void test()
{
    S a, b;
    a = b;
}

@mustuse struct Inner
{
    this(int n) {}
}

struct Outer
{
    Inner inner;
    this(int n)
    {
        this.inner = n;
    }
}
