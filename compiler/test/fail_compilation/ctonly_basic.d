/* TEST_OUTPUT:
---
fail_compilation/ctonly_basic.d(23): Error: cannot call @ctonly function ctonly_basic.f from non-@ctonly function D main
fail_compilation/ctonly_basic.d(23): Error: cannot call @ctonly function ctonly_basic.g!2.g from non-@ctonly function D main
fail_compilation/ctonly_basic.d(23): Error: cannot take address of @ctonly function `f`
fail_compilation/ctonly_basic.d(23): Error: cannot take address of @ctonly function `g`
---
*/

int f(int x, int y) @ctonly {
    return x + y;
}

int g(int x)(int y) @ctonly {
    return x + y;
}

alias gf = g!2;

import std.stdio;

void main() {
    writeln(f(2, 4), gf(0), &f, &gf);
}
