// REQUIRED_ARGS:
/*
TEST_OUTPUT:
---
fail_compilation/test15897.d(18): Error: no property `create` for type `imports.test15897.Cat`, did you mean non-visible function `create`?
---
*/
module test15897;
import imports.test15897;

class Animal
{
    private void create() {}
}

void foo(Cat cat)
{
    cat.create();
}
