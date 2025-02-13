import std.algorithm.iteration;
import std.array;

int f(int x) @ctonly
{
    return x + 1;
}

enum a = map!f([1, 2, 3]).array;

import std.stdio;

void main() {
    writeln(a);
}
