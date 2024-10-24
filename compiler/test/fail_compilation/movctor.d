/* TEST_OUTPUT:
---
fail_compilation/movctor.d(9): Error: first parameter to move constructor should be type struct `movctor.S`
---
*/

struct S
{
    =this(ref S s);
}
