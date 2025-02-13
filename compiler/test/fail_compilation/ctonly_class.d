/* TEST_OUTPUT:
---
fail_compilation/ctonly_class.d(24): Error: cannot call @ctonly function ctonly_class.C.f from non-@ctonly function D main
fail_compilation/ctonly_class.d(25): Error: cannot call @ctonly function ctonly_class.C.g from non-@ctonly function D main
fail_compilation/ctonly_class.d(27): Error: cannot call @ctonly function ctonly_class.CtOnly.this from non-@ctonly function D main
---
*/
class C {
    int v;
    this(int v_) { v = v_; }
    int f(int x) const @ctonly { return x + v; }
    static int g(int x) @ctonly { return x + 2; }
}

class CtOnly {
    int v;
    this(int v_) @ctonly { v = v_; }
    int f(int x) const { return x + v; }
    static int g(int x) { return x + 2; }
}

void main() {
    C i = new C(1);
    int a = i.f(3);
    int v = C.g(2);

    auto cl = new CtOnly(5);
}
