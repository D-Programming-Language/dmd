/**
 * Contains a memset implementation used by compiler-generated code.
 *
 * Copyright: Copyright Digital Mars 2004 - 2010.
 * License:   $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
 * Authors:   Walter Bright
 * Source: $(DRUNTIMESRC rt/_memset.d)
 */

/*          Copyright Digital Mars 2004 - 2010.
 * Distributed under the Boost Software License, Version 1.0.
 *    (See accompanying file LICENSE or copy at
 *          http://www.boost.org/LICENSE_1_0.txt)
 */
module rt.memset;

extern (C)
{
    // Functions from the C library.
    void *memcpy(void *, void *, size_t);
}

extern (C):

short *_memset16(short *p, short value, size_t count)
{
    short *pstart = p;
    short *ptop;

    for (ptop = &p[count]; p < ptop; p++)
        *p = value;
    return pstart;
}

int *_memset32(int *p, int value, size_t count)
{
version (D_InlineAsm_X86)
{
    asm
    {
        mov     EDI,p           ;
        mov     EAX,value       ;
        mov     ECX,count       ;
        mov     EDX,EDI         ;
        rep                     ;
        stosd                   ;
        mov     EAX,EDX         ;
    }
}
else
{
    int *pstart = p;
    int *ptop;

    for (ptop = &p[count]; p < ptop; p++)
        *p = value;
    return pstart;
}
}

long *_memset64(long *p, long value, size_t count)
{
    long *pstart = p;
    long *ptop;

    for (ptop = &p[count]; p < ptop; p++)
        *p = value;
    return pstart;
}

void[] *_memset128ii(void[] *p, void[] value, size_t count)
{
    void[] *pstart = p;
    void[] *ptop;

    for (ptop = &p[count]; p < ptop; p++)
        *p = value;
    return pstart;
}

real *_memset80(real *p, real value, size_t count)
{
    real *pstart = p;
    real *ptop;

    for (ptop = &p[count]; p < ptop; p++)
        *p = value;
    return pstart;
}

void *_memsetn(void *p, void *value, int count, size_t sizelem)
{   void *pstart = p;
    int i;

    for (i = 0; i < count; i++)
    {
        memcpy(p, value, sizelem);
        p = cast(void *)(cast(char *)p + sizelem);
    }
    return pstart;
}

float *_memsetFloat(float *p, float value, size_t count)
{
    float *pstart = p;
    float *ptop;

    for (ptop = &p[count]; p < ptop; p++)
        *p = value;
    return pstart;
}

double *_memsetDouble(double *p, double value, size_t count)
{
    double *pstart = p;
    double *ptop;

    for (ptop = &p[count]; p < ptop; p++)
        *p = value;
    return pstart;
}

version (D_SIMD)
{
    import core.simd;

    void16* _memsetSIMD(void16 *p, void16 value, size_t count)
    {
        foreach (i; 0..count)
            p[i] = value;
        return p;
    }
}
