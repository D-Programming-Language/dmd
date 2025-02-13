
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

// can do this
enum v = new C(1).f(0);
// or this
static const c = new C(2);
enum v2 = c.f(2);

void main() {
    C i = new C(2);
    // or this
    enum v = C.g(2);
    // or this
    enum e = new CtOnly(5).f(5);
}
