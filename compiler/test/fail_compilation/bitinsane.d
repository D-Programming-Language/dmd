/* REQUIRED_ARGS: -preview=bitfields
 * TEST_OUTPUT:
---
fail_compilation/bitinsane.d(124): Error: Unpredictable bit field layout detected starting at bit field `i`
fail_compilation/bitinsane.d(125):        Bit offset for `j` expected 5, actual 0
fail_compilation/bitinsane.d(125):        To disable this check specify an extern that is not D i.e. `extern(C)`
fail_compilation/bitinsane.d(132): Error: Unpredictable bit field layout detected starting at bit field `x`
fail_compilation/bitinsane.d(133):        Bit offset for `y` expected 5, actual 0
fail_compilation/bitinsane.d(133):        To disable this check specify an extern that is not D i.e. `extern(C)`
---
 */

#line 100

struct Stuff_System {
extern(System):
    int before1;
    ubyte k1:4;
    ubyte k2:4;
    ubyte i:5;
    ubyte j:4;
    int after1;

    struct {
        int before2;
        ubyte w1:4;
        ubyte w2:4;
        ubyte x:5;
        ubyte y:4;
        int after2;
    }
}

struct Stuff_D {
    int before1;
    ubyte k1:4;
    ubyte k2:4;
    ubyte i:5;
    ubyte j:4;
    int after1;

    struct {
        int before2;
        ubyte w1:4;
        ubyte w2:4;
        ubyte x:5;
        ubyte y:4;
        int after2;
    }
}
