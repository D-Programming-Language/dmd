/**
TEST_OUTPUT:
---
fail_compilation/cmodule_malformed.c(15): Error: identifier expected following `module`
fail_compilation/cmodule_malformed.c(15): Error: no type for declarator before `"a"`
fail_compilation/cmodule_malformed.c(21): Error: no type-specifier for struct member
fail_compilation/cmodule_malformed.c(21): Error: identifier or `(` expected
fail_compilation/cmodule_malformed.c(21): Error: expected identifier for declarator
fail_compilation/cmodule_malformed.c(26): Error: found `__module` instead of statement
---
*/

#if __IMPORTC__

__module "a";

typedef struct S
{
    int x;

    __module b;
} S;

void main(void)
{
    __module c.d;
}

__module e;

#endif
