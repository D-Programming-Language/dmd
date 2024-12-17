void main()
{
    int[int][] a = [[1 : 2]]; // ok
    int[int][] b = [[0 : 2]]; // expression ([[2]]) of type int[][]
    int[int][int] c = [1 : [0 : 2]]; // expression ([1:[2]]) of type int[][int]
    int[int][int] d = [1 : [3 : 2]]; // Error: not an associative array initializer

    assert(a[0][1] == 2);
    assert(b[0][0] == 2);
    assert(c[1][0] == 2);
    assert(d[1][3] == 2);

    static assert(!__traits(compiles, { int[][] x = [[0 : 2]]; })); // fails
    static assert(!__traits(compiles, { int[][int] x = [1 : [0 : 2]]; })); // fails
}
