/*
TEST_OUTPUT:
---
fail_compilation/fail7352.d(42): Error: template instance `Type!(1)` does not match template declaration `Type(T)`
fail_compilation/fail7352.d(42):        instantiated from here: `Type!(1)`
fail_compilation/fail7352.d(18):        Candidate match: Type(T)
fail_compilation/fail7352.d(43): Error: template instance `Type!(b)` does not match template declaration `Type(T)`
fail_compilation/fail7352.d(43):        instantiated from here: `Type!(b)`
fail_compilation/fail7352.d(18):        Candidate match: Type(T)
fail_compilation/fail7352.d(43):        `b` is not a type
fail_compilation/fail7352.d(44): Error: template instance `Type!(function () pure nothrow @nogc @safe => 1)` does not match template declaration `Type(T)`
fail_compilation/fail7352.d(44):        instantiated from here: `Type!(function () pure nothrow @nogc @safe => 1)`
fail_compilation/fail7352.d(18):        Candidate match: Type(T)
fail_compilation/fail7352.d(45): Error: template instance `Type!(fun)` does not match template declaration `Type(T)`
fail_compilation/fail7352.d(45):        instantiated from here: `Type!(fun)`
fail_compilation/fail7352.d(18):        Candidate match: Type(T)
fail_compilation/fail7352.d(45):        `fun` is not a type
fail_compilation/fail7352.d(47): Error: template instance `Immutable!int` does not match template declaration `Immutable(T : immutable(T))`
fail_compilation/fail7352.d(47):        instantiated from here: `Immutable!int`
fail_compilation/fail7352.d(22):        Candidate match: Immutable(T : immutable(T))
fail_compilation/fail7352.d(49): Error: template instance `Value!int` does not match template declaration `Value(string s)`
fail_compilation/fail7352.d(49):        instantiated from here: `Value!int`
fail_compilation/fail7352.d(27):        Candidate match: Value(string s)
fail_compilation/fail7352.d(50): Error: template instance `Value!(1)` does not match template declaration `Value(string s)`
fail_compilation/fail7352.d(50):        instantiated from here: `Value!(1)`
fail_compilation/fail7352.d(27):        Candidate match: Value(string s)
fail_compilation/fail7352.d(51): Error: template instance `Value!(fun)` does not match template declaration `Value(string s)`
fail_compilation/fail7352.d(51):        instantiated from here: `Value!(fun)`
fail_compilation/fail7352.d(27):        Candidate match: Value(string s)
fail_compilation/fail7352.d(51):        `fun` is not of a value of type `string`
---
*/

# line 100

template Type(T)
{
}

template Immutable(T : immutable(T))
{
    alias Immutable = T;
}

template Value(string s)
{
    auto x = s;
}

int fun(int i)
{
    return i;
}

void main()
{
    enum a = 1;
    int b;

    Type!a         testTypeValue;
    Type!b         testTypeVar;
    Type!(() => 1) testTypeFuncLiteral;
    Type!fun       testTypeFunc;

    Immutable!int  testImmutable;

    auto testValueType      = Value!int.x;
    auto testValueWrongType = Value!a.x;
    auto testValueFunc      = Value!fun.x;
}
