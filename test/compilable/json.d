// PERMUTE_ARGS:
// REQUIRED_ARGS: -o- -X -Xftest_results/compilable/json.out
// POST_SCRIPT: compilable/extra-files/json-postscript.sh

module json;

import std.stdio : writefln;


static this() {}

static ~this() {}


alias int myInt;
myInt x; // bug 3404

struct Foo(T) { T t; }
class  Bar(int T) { int t = T; }
interface Baz(T...) { T[0] t() const; } // bug 3466

template P(alias T) {}

class Bar2 : Bar!1, Baz!(void, 2, null) {
    this() {}
    ~this() {} // bug 4178

    static foo() {}
    protected abstract Foo!int baz();
}

struct Foo2 {
	Bar2 bar2;
	union U {
		struct {
			short s;
			int i;
		}
		Object o;
	}
}

/++
 + Documentation test
 +/
@trusted myInt bar(uint blah, ref Object foo = new Object()) // bug 4477
{
	return -1;
}

@property int outer() nothrow
in {
	assert(true);
}
out(result) {
	assert(result == 18);
}
body {
	int x = 8;
	int inner(void* v) nothrow
	{
		int y = 2;
		assert(true);
		return x + y;
	}
	int z = inner(null);
	return x + z;
}

