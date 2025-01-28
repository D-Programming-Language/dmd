/*
TEST_OUTPUT:
---
fail_compilation/issue16020.d(1): Error: user-defined attributes not allowed for `alias` declarations
fail_compilation/issue16020.d(2): Error: semicolon expected to close `alias` declaration, not `(`
fail_compilation/issue16020.d(2): Error: unexpected identifier `t` in declarator
fail_compilation/issue16020.d(2): Error: no identifier for declarator `T`
fail_compilation/issue16020.d(3): Deprecation: storage class `final` has no effect in type aliases
---
*/
module issue16020;

struct UDA{}
#line 1
alias Fun = @UDA void();
alias FunTemplate = void(T)(T t);
alias F2 = final int();
