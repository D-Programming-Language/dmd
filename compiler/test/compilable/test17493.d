// https://issues.dlang.org/show_bug.cgi?id=17493

struct S {
    ~this() {}
}

class C {
    S s;

    this() nothrow {}
}
