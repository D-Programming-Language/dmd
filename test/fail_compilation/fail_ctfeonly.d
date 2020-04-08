/* TEST_OUTPUT:
---
fail_compilation/fail_ctfeonly.d(10): Error: function `fail_ctfeonly.ctfeOnly` may only be used for CTFE
fail_compilation/fail_ctfeonly.d(16): Error: function `fail_ctfeonly.ctfeOnly2` may only be used for CTFE
---
*/


pragma(ctfe)
string ctfeOnly(string x, string y)
{
    return (x ~ " " ~ y);
}

pragma(ctfe)
string ctfeOnly2(string x, string y)
{
    return (x ~ " " ~ y);
}


void main(string[] args)
{
    import core.stdc.stdio;
    printf("%s", ctfeOnly(args[0], args[1]).ptr);
    printf("%s", ctfeOnly2(args[0], args[1]).ptr);
}
