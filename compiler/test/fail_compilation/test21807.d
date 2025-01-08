/*
https://issues.dlang.org/show_bug.cgi?id=21807

REQUIRED_ARGS: -de
TEST_OUTPUT:
---
fail_compilation/test21807.d(11): Deprecation: slice of static array temporary returned by `getSArray()` assigned to longer lived variable `this.str`
fail_compilation/test21807.d(12): Deprecation: slice of static array temporary returned by `getSArray()` assigned to longer lived variable `this.ca`
---
*/
#line 1

char[12] getSArray() pure;

class Foo
{
	string str;
	char[] ca;

	this()
	{
		str = getSArray(); // Should probably be a type error
		ca = getSArray();
	}
}
