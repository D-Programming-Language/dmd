// https://issues.dlang.org/show_bug.cgi?id=19491

class Foo
{
    shared this() @system;
}

void test()
{
    scope foo = new shared Foo();
}
