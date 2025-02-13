
import std.algorithm.searching;
import std.range;
import std.traits;

/// Checks is a function is @ctonly
enum isCtOnly(alias f) = canFind(only(__traits(getFunctionAttributes, f)), "@ctonly");

/// Simplified @ctonly-aware version of `map`
auto simple_map(alias fun, Range)(Range r) {
    return SimpleMapResult!(fun, Range)(r);
}

private struct SimpleMapResult(alias fun, Range) {
    alias R = Unqual!Range;
    enum funIsCtOnly = isCtOnly!fun;
    R _input;
    this(R input) {
        _input = input;
    }
    void popFront() {
        _input.popFront();
    }
    @property bool empty() {
        return _input.empty;
    }
    static if (funIsCtOnly) {
        /// If `fun` is @ctonly, `front` must be @ctonly too
        @property auto ref front() @ctonly {
            return fun(_input.front);
        }
    } else {
        @property auto ref front() {
            return fun(_input.front);
        }
    }
}

int f(int x) @ctonly {
    return x + 1;
}

import std.algorithm.iteration;
import std.array;

void main() {
    enum f2 = f(2);
    // enum a = map!f([1, 2, 3]).array; // doesn't work
    enum a2 = simple_map!f([1, 2, 3]); // that works
    enum a2f = a2.front; // that works too, even though `a2.array` won't work, since `array` must be @ctonly-aware as well
}
