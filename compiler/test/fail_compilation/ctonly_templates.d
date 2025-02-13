/* TEST_OUTPUT:
---
fail_compilation/ctonly_templates.d(21): Error: cannot call @ctonly function std.array.array!(MapResult!(f, int[])).array from non-@ctonly function D main
fail_compilation/ctonly_templates.d(21):        std.array.array!(MapResult!(f, int[])).array was inferred to be @ctonly because it calls std.algorithm.iteration.MapResult!(f, int[]).MapResult.front
---
*/
import std.algorithm.iteration;
import std.array;

int f(int x) @ctonly
{
    return x + 1;
}

enum a = map!f([1, 2, 3]);

import std.stdio;

void main() {
    // That fails, because `f` is called internally.
    writeln(a.array);
}
