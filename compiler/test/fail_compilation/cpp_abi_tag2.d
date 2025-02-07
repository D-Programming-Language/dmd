/* DISABLED: win32 win64
REQUIRED_ARGS: -extern-std=c++11
TRANSFORM_OUTPUT: remove_lines("(Candidates|attribute)")
TEST_OUTPUT:
---
fail_compilation/cpp_abi_tag2.d(102): Error: none of the overloads of `this` are callable using argument types `(string, wstring, dstring)`
fail_compilation/cpp_abi_tag2.d(105): Error: none of the overloads of `this` are callable using argument types `(string, int, double)`
---
*/

#line 100
import core.attribute;

@gnuAbiTag("a", "b"w, "c"d)
extern(C++) struct C {}

@gnuAbiTag("a", 2, 3.3)
extern(C++) struct E {}
