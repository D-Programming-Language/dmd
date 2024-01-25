/* DISABLED: win32 win64
REQUIRED_ARGS: -extern-std=c++11
TEST_OUTPUT:
---
fail_compilation/cpp_abi_tag2.d(102): Error: constructor `this` is not callable using argument types `(string, wstring, dstring)`
fail_compilation/cpp_abi_tag2.d(102):        cannot pass argument `"b"w` of type `wstring` to parameter `string[] tags...`
/home/ryuukk/dev/dmd/compiler/test/../../druntime/import/core/attribute.d(239):        `core.attribute.gnuAbiTag.this(string[] tags...)` declared here
fail_compilation/cpp_abi_tag2.d(105): Error: constructor `this` is not callable using argument types `(string, int, double)`
fail_compilation/cpp_abi_tag2.d(105):        cannot pass argument `2` of type `int` to parameter `string[] tags...`
/home/ryuukk/dev/dmd/compiler/test/../../druntime/import/core/attribute.d(239):        `core.attribute.gnuAbiTag.this(string[] tags...)` declared here
---
*/

#line 100
import core.attribute;

@gnuAbiTag("a", "b"w, "c"d)
extern(C++) struct C {}

@gnuAbiTag("a", 2, 3.3)
extern(C++) struct E {}
