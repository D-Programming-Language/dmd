// COMPILE_SEPARATELY:
// EXTRA_SOURCES: imports/test23722b.d
// REQUIRED_ARGS: -betterC
// https://issues.dlang.org/show_bug.cgi?id=23722
// Lambdas are mangled incorrectly when using multiple compilation units, resulting in incorrect code
import imports.test23722b;

// do_y should call A.y (and print "y")
void do_y() {
    A.y();
}

extern (C) void main() {
    do_y(); // should print y
    do_x(); // should print x
}
