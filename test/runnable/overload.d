
template Seq(T...){ alias T Seq; }
template Id(alias A){ alias A Id; }

/**************************************/

// overloaded function/delegate expresison returns exact type
// "..."~"()" is workaround for bug1373
void test1()
{
    static class C1
    {
              void f1(){}
        const void f1(){}

              void f2(){}

              auto f3(){ return &f1; }
        const auto f3(){ return &f1; }
    }
    static class C2
    {
        const void f1(){}
              void f1(){}

              void f2(){}

        const auto f3(){ return &f1; }
              auto f3(){ return &f1; }
    }

    // FIX: the tolerance against C's member function declaration order
    foreach (C; Seq!(C1, C2))
    {
        C mc = new C;
        pragma(msg, typeof(mc), " ----");

        pragma(msg, ">>> ", typeof(mc.f1));
        static assert(typeof(mc.f1).stringof == "void()"~"()");

        auto mg = &mc.f1;
        pragma(msg, ">>> ", typeof(mg));
        static assert(typeof(mg).stringof == "void delegate()");

        pragma(msg, ">>> ", typeof(mc.f2));
        static assert(is(typeof(mc.f2)));
        static assert(typeof(mc.f2).stringof == "void()"~"()");

        pragma(msg, ">>> ", typeof(mc.f3));
        static assert(typeof(mc.f3).stringof == "void delegate()()"~"()");


        const(C) cc = new C;
        pragma(msg, typeof(cc), " ----");

        pragma(msg, ">>> ", typeof(cc.f1));
        static assert(typeof(cc.f1).stringof == "const void()"~"()");
        // FIX: const 'this' object selects const member function

        auto cg = &cc.f1;
        pragma(msg, ">>> ", typeof(cg));
        static assert(typeof(cg).stringof == "void delegate() const");
        // FIX: delegate has expect type

        //pragma(msg, ">>> ", typeof(cc.f2));
        static assert(!is(typeof(cc.f2)));
        // FIX: const 'this' object and non-const member function makes no type

        pragma(msg, ">>> ", typeof(cc.f3));
        static assert(typeof(cc.f3).stringof == "const void delegate() const()"~"()");
        // FIX: in C.f3, &f1 type is considered with 'this' type
    }
}

/**************************************/

void test2()
{
    static class C1
    {
        bool f() const{ return true; }
        void f(bool v){}

               const void g1(){}
        shared const void g1(){}

               const int g2(int m){ return 1; }
        shared const int g2(int m, int n){ return 2; }
    }
    static class C2
    {
        void f(bool v){}
        bool f() const{ return true; }

        shared const void g1(){}
               const void g1(){}

        shared const int g2(int m, int n){ return 2; }
               const int g2(int m)       { return 1; }
    }
    static bool g(bool v){ return v; }

    foreach (C; Seq!(C1, C2))
    {
        auto mc = new C();
        assert(g(mc.f));
        // mc.f -> select property call of bool f() const

        auto ic = new immutable(C)();
        static assert(is(typeof(ic.g1)));
        static assert(!__traits(compiles, typeof(ic.g1)));
        // conversion from immutable to const and shared const is ambiguous
        // -> is(typeof(...)) idiom returns true
        // -> but compile fails

        assert(ic.g2(0) == 1);
        assert(ic.g2(0,0) == 2);
        // but overload resolution by arguments still valid

        alias C.f foo;
        static assert(is(typeof(foo)));
        static assert(!__traits(compiles, typeof(foo)));
        // foo(C.f) has ambiguous type, not exact type
    }
}

/**************************************/

void test3()
{
    static class C
    {
        void f(){}
        void f(int n){}
    
        // dummy functions to get type of f
        void f1(){}
        void f2(int n){}
    }

    alias Seq!(__traits(getOverloads, C, "f")) Fs;
    alias Fs[0] F1;
    alias Fs[1] F2;
    static assert(is(typeof(F1) == typeof(C.f1)));
    static assert(is(typeof(F2) == typeof(C.f2)));

    static assert(is(typeof(Id!F1) == typeof(C.f1)));
    static assert(is(typeof(Id!F2) == typeof(C.f2)));
    // ovrload resolution keeps through template alias parameter.

    foreach (i, F; __traits(getOverloads, C, "f"))
    {
        static if (i==0) static assert(is(typeof(F) == typeof(C.f1)));
        static if (i==1) static assert(is(typeof(F) == typeof(C.f2)));

        static if (i==0) static assert(is(typeof(Id!F) == typeof(C.f1)));
        static if (i==1) static assert(is(typeof(Id!F) == typeof(C.f2)));
    }
}

/**************************************/

static int g(int n){ return 1; }
static int g(int n, int m){ return 2; }

void test4()
{
    static class C
    {
        int f(int n){ return 1; }
        int f(int n, int m){ return 2; }
    }
    auto c = new C();
    static assert(!__traits(compiles, (&c.f)()));
    assert((&c.f)(0) == 1);
    assert((&c.f)(0,1) == 2);

    static assert(!__traits(compiles, (&g)()));
    assert((&g)(0) == 1);
    assert((&g)(0,1) == 2);
}

struct Test5S
{
    void f(){}
    void f(int n){}
    void g()
    {
        // mtype.c L7107 TODO -> resloved
        //pragma(msg, typeof(Test5S.f));
        static assert(is(typeof(Test5S.f)));
        static assert(!__traits(compiles, typeof(Test5S.f)));
    }

    void h(){}
    void h(int n){}
}
class Test5C
{
    void f(){}
    void f(int n){}
    void g()
    {
        // mtype.c L7646 TODO -> resolved
        //pragma(msg, typeof(Test5C.f));
        static assert(is(typeof(Test5C.f)));
        static assert(!__traits(compiles, typeof(Test5C.f)));
    }

    class N
    {
        void x(){
            // mtype.c L7660 TODO -> resolved
            //pragma(msg, typeof(Test5C.f));
            static assert(is(typeof(Test5C.f)));
            static assert(!__traits(compiles, typeof(Test5C.f)));
        }
    }

}
void test5()
{
    Test5S s;
    s.g();
    // mtype.c L7145 TODO -> resolved
    //pragma(msg, typeof(s.h));
    static assert(is(typeof(s.h)));
    static assert(!__traits(compiles, typeof(s.h)));

    Test5C c = new Test5C();
    c.g();
    // mtype.c L7694 TODO -> resolved
    //pragma(msg, typeof(c.h));
    static assert(is(typeof(c.f)));
    static assert(!__traits(compiles, typeof(c.f)));
}

/**************************************/

void test6()
{
    static class C
    {
        void f(){}
        void f(int n){}

        void f1(){}
        void f2(int n){}
    }
    alias C.f Fun;
    alias Seq!(__traits(getOverloads, C, "f")) FunSeq;

    /*
        When template instantiates, overloaded symbol passed by FuncDeclaratioin.
        By the side, non overloaded symbol is passed by VarExp(var=fd, hasOverloads=0),
        and its type is same as fd->type.
    */

    static assert(is(typeof(C.f)));
    static assert(!__traits(compiles, typeof(C.f)));
    // direct

    static assert(is(typeof(Id!(C.f))));
    static assert(!__traits(compiles, typeof(Id!(C.f))));
    // direct -> through template alias parameter

    static assert(is(typeof(Fun)));
    static assert(!__traits(compiles, typeof(Fun)));
    // indirect(through alias)

    static assert(is(typeof(Id!(Fun))));
    static assert(!__traits(compiles, typeof(Id!(Fun))));
    // indirect -> through template alias parameter

    static assert(is(typeof(FunSeq[0]) == typeof(C.f1)));
    static assert(is(typeof(FunSeq[1]) == typeof(C.f2)));
    // direct(tuple element)

    static assert(is(typeof(Id!(FunSeq[0])) == typeof(C.f1)));
    static assert(is(typeof(Id!(FunSeq[1])) == typeof(C.f2)));
    // direct(tuple element) -> through template alias parameter
}

/**************************************/

void test7()
{
    static class C
    {
        static int f()     { return 1; }
        static int f(int n){ return 2; }

        int f1()     { return 1; }
        int f2(int n){ return 2; }
    }
    alias C.f Fun;
    alias Seq!(__traits(getOverloads, C, "f")) FunSeq;

    assert(C.f( ) == 1);
    assert(C.f(0) == 2);

    assert(Id!(C.f)( ) == 1);
    assert(Id!(C.f)(0) == 2);

    assert(FunSeq[0]( ) == 1);
    assert(FunSeq[1](0) == 2);
    static assert(!__traits(compiles, FunSeq[0](0) == 1));
    static assert(!__traits(compiles, FunSeq[1]( ) == 2));

    assert(Id!(FunSeq[0])( ) == 1);
    assert(Id!(FunSeq[1])(0) == 2);
    static assert(!__traits(compiles, Id!(FunSeq[0])(0) == 1));
    static assert(!__traits(compiles, Id!(FunSeq[1])( ) == 2));
}

/**************************************/

class A8
{
	static int f(){ return 1; }
}
int g8(int n){ return 2; }
alias A8.f fun8;
alias g8 fun8;
void test8()
{
	assert(fun8( ) == 1);
	assert(fun8(0) == 2);
}

/**************************************/

class A9
{
	static int f(){ return 1; }
}
class B9
{
	static int g(int n){ return 2; }
	alias A9.f fun;
	alias g fun;
}

void test9()
{
	assert(B9.fun( ) == 1);
	assert(B9.fun(0) == 2);
}

/**************************************/

class A10
{
	static int f(){ return 1; }
	static int f(int n){ return 2; }
	alias Seq!(__traits(getOverloads, A10, "f")) F;
	alias F[0] f0;
	alias F[1] f1;
}
class B10
{
	static int g(string s){ return 3; }
}

// int(), int(int), int(string)
alias A10.f fun10_1;
alias B10.g fun10_1;

// int(), int(string)
alias A10.F[0] fun10_2;
alias B10.g fun10_2;

// int(), int(int), int(string)
alias fun10_1 fun10_3;
alias fun10_2 fun10_3;

void test10()
{
	assert(fun10_1() == 1);
	assert(fun10_1(0) == 2);
	assert(fun10_1("s") == 3);

	assert(fun10_2() == 1);
	static assert(!__traits(compiles, fun10_2(0)));
	assert(fun10_2("s") == 3);

	assert(A10.f0() == 1);
	static assert(!__traits(compiles, A10.f0(0)));

	static assert(!__traits(compiles, A10.f1()));
	assert(A10.f1(0) == 2);

	assert(fun10_3() == 1);
	assert(fun10_3(0) == 2);
	assert(fun10_3("s") == 3);
}

/**************************************/

void main()
{
    test1();
    test2();
    test3();
    test4();
    test5();
    test6();
    test7();
	test8();
	test9();
	test10();
}
