/*
TEST_OUTPUT:
---
fail_compilation/test20274.d(28): Error: function expected before `()`, not `(*__withSym).opDispatch()` of type `void`
fail_compilation/test20274.d(35): Error: undefined identifier `foo`
---
*/

// https://issues.dlang.org/show_bug.cgi?id=20274

struct A {
	void opDispatch(string name, A...)(A a) {
	}
}

struct B {
	void opDispatch(string name, T)(T a) {
	}
}

void main()
{
	A a;
	a.foo(2); // ok

	with (a)
	{
		foo(2); // fails
	}

	B b;
	b.foo(3); // ok

	with(b) {
		foo(3); // fails
	}

}
