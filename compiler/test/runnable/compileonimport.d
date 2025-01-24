/*
REQUIRED_ARGS: -Irunnable/imports
*/
module compileonimport;
import compileonimportlib;

void main() {
    bool v = runMe();
    assert(v);
}
