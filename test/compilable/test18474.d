shared struct A
{
    this(this) @system;
}

struct B
{
    A a;
}

void main()
{
    shared B b1;
    auto b2 = b1;
}
