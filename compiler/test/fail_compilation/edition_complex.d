/*
TEST_OUTPUT:
---
fail_compilation/edition_complex.d(3): Error: undefined identifier `ifloat`
fail_compilation/edition_complex.d(4): Error: undefined identifier `cfloat`
fail_compilation/edition_complex.d(5): Error: undefined identifier `idouble`
fail_compilation/edition_complex.d(6): Error: undefined identifier `cdouble`
fail_compilation/edition_complex.d(7): Error: undefined identifier `ireal`
fail_compilation/edition_complex.d(8): Error: undefined identifier `creal`
---
 */
@__edition_latest_do_not_use
module edition_complex;

#line 1
void main()
{
    ifloat fi;
    cfloat fc;
    idouble di;
    cdouble dc;
    ireal ri;
    creal rc;
}
