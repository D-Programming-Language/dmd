/* test bitfields
 * DISABLED: win32 win64 linux32 freebsd32 openbsd32 osx32
 * RUN_OUTPUT:
---
T0 = 1 1 | 1 1
T1 = 2 2 | 2 2
T2 = 4 4 | 4 4
T3 = 8 8 | 8 8
T4 = 16 8 | 16 8
T5 = 8 8 | 8 8
S1 = 8 8 | 8 8
S2 = 4 4 | 4 4
S3 = 4 4 | 4 4
S4 = 4 4 | 4 4
S5 = 4 4 | 4 4
S6 = 2 2 | 2 2
S7 = 8 8 | 8 8
S8 = 2 2 | 2 2
S8A = 2 2 | 2 2
S8B = 2 2 | 2 2
S8C = 4 4 | 4 4
S9  = 4 2 | 4 2
S10 = 1 1 | 0 1
S11 = 1 1 | 0 1
S12 = 4 4 | 4 4
S13 = 8 4 | 8 4
S14 = 8 4 | 8 4
S15 = 4 4 | 4 4
S16 = 4 1 | 4 1
S17 = 4 4 | 4 4
S18 = 9 1 | 9 1
A0  = 16 8 | 16 8
A1  = 12 4 | 12 4
A2  = 12 4 | 12 4
A3  = 16 4 | 16 4
A4  = 8 4 | 8 4
A5  = 2 1 | 2 1
A6  = 2 2 | 2 2
A7  = 16 8 | 16 8
A8  = 8 8 | 8 8
A9  = 16 8 | 16 8
A10 = 2 2 | 2 2
A11 = 12 4 | 12 4
S9 = x30200
S14 = x300000201
S15 = xe01
S18 = 8 should be 8
A0 = x1
---
 */

import core.stdc.stdio;

int is64bit() { return size_t.sizeof == 8; }  // otherwise assume 32 bit

/*************************************************************/

struct T0  { ubyte x:1; };                       // 1 1
struct T1  { short x:1; };                       // 2 2
struct T2  { int x:1; };                         // 4 4
struct T3  { ubyte a,b,c,d; long x:1; };         // 8 4 (32 bit) 8 8 (64 bit)
struct T4  { ubyte a,b,c,d,e,f,g,h; long x:1; }; // 12 4 (32 bit) 16 8 (64 bit)
struct T5  { ubyte a,b,c,d,e,f,g; long x:1; };   // 8 4 (32 bit) 8 8 (64 bit)
struct S1  { long f:1; };                        // 4 4 (32 bit) 8 8 (64 bit)
struct S2  { int x:1; int y:1; };                // 4 4
struct S3  { short c; int x:1; uint y:1; };      // 4 4
struct S4  { int x:1; short y:1; };              // 4 4
struct S5  { short x:1; int y:1; };              // 4 4
struct S6  { short x:1; short y:1; };            // 2 2
struct S7  { short x:1; int y:1; long z:1; };    // 4 4 (32 bit) 8 8 (64 bit)
struct S8  { ubyte a; ubyte b:1; short c:2; };   // 2 2
struct S8A { ubyte b:1; short c:2; };            // 2 2
struct S8B { ubyte a; short b:1; ubyte c:2; };   // 2 2
struct S8C { ubyte a; int b:1; };                // 4 4
struct S9  { ubyte a; ubyte b:2; short c:9; };   // 4 2 x30201
struct S10 { };                                  // differs from C
struct S11 { int :0; };                          // differs from CG
struct S12 { int :0; int x; };                   // 4 4
struct S13 { uint x:12; uint x1:1; uint x2:1; uint x3:1; uint x4:1; int w; }; // 8 4
struct S14 { ubyte a; ubyte b:4; int c:30; };    // 8 4
struct S15 { ubyte a; ubyte b:2; int c:9; };     // 4 4 xe01
struct S16 { int :32; };                         // 4 1
struct S17 { int a:32; };                        // 4 4
struct S18 { ubyte a; long :0; ubyte b; };       // 5 1 (32 bit) 9 1 (64 bit)
struct A0  { int a; long b:34, c:4; };           // 12 4 (32 bit) 16 8 (64 bit)
struct A1  { int a; uint b:11; int c; };         // 12 4
struct A2  { int a; uint b:11, c:5, d:16;        // 12 4
             int e; };
struct A3  { int a; uint b:11, c:5, :0, d:16;    // 16 4
             int e; };
struct A4  { int a:8; short b:7;                 // 8 4
             uint c:29; };
struct A5  { ubyte a:7, b:2; };                  // 2 1
struct A6  { ubyte a:7; short b:2; };            // 2 2
struct A7  { short a:8; long b:16; int c;        // 12 4 (32 bit) 16 8 (64 bit)
             ubyte d:7; };
struct A8  { short a:8; long b:16; int :0;       // 8 4 (32 bit) 8 8 (64 bit)
             ubyte c:7; };
struct A9  { ushort a:8; int b:16;               // 16 4 (32 bit) 16 8 (64 bit)
             uint c:29; long d:9;
             uint e:2, f:31; };
struct A10 { ushort a:8; ubyte b; };             // 2 2
struct A11 { ubyte a; int b:5, c:11, :0, d:8;    // 12 4
             struct { int ee:8; } };

int main()
{
    printf("T0 = %d %d | 1 1\n", cast(int)T0.sizeof, cast(int)T0.alignof);
    printf("T1 = %d %d | 2 2\n", cast(int)T1.sizeof, cast(int)T1.alignof);
    printf("T2 = %d %d | 4 4\n", cast(int)T2.sizeof, cast(int)T2.alignof);
    printf("T3 = %d %d | 8 8\n", cast(int)T3.sizeof, cast(int)T3.alignof);
    printf("T4 = %d %d | 16 8\n", cast(int)T4.sizeof, cast(int)T4.alignof);
    printf("T5 = %d %d | 8 8\n", cast(int)T5.sizeof, cast(int)T5.alignof);
    printf("S1 = %d %d | 8 8\n", cast(int)S1.sizeof, cast(int)S1.alignof);
    printf("S2 = %d %d | 4 4\n", cast(int)S2.sizeof, cast(int)S2.alignof);
    printf("S3 = %d %d | 4 4\n", cast(int)S3.sizeof, cast(int)S3.alignof);
    printf("S4 = %d %d | 4 4\n", cast(int)S4.sizeof, cast(int)S4.alignof);
    printf("S5 = %d %d | 4 4\n", cast(int)S5.sizeof, cast(int)S5.alignof);
    printf("S6 = %d %d | 2 2\n", cast(int)S6.sizeof, cast(int)S6.alignof);
    printf("S7 = %d %d | 8 8\n", cast(int)S7.sizeof, cast(int)S7.alignof);
    printf("S8 = %d %d | 2 2\n", cast(int)S8.sizeof, cast(int)S8.alignof);
    printf("S8A = %d %d | 2 2\n", cast(int)S8A.sizeof, cast(int)S8A.alignof);
    printf("S8B = %d %d | 2 2\n", cast(int)S8B.sizeof, cast(int)S8B.alignof);
    printf("S8C = %d %d | 4 4\n", cast(int)S8C.sizeof, cast(int)S8C.alignof);
    printf("S9  = %d %d | 4 2\n", cast(int)S9.sizeof,  cast(int)S9.alignof);
    printf("S10 = %d %d | 0 1\n", cast(int)S10.sizeof, cast(int)S10.alignof);
    printf("S11 = %d %d | 0 1\n", cast(int)S11.sizeof, cast(int)S11.alignof);
    printf("S12 = %d %d | 4 4\n", cast(int)S12.sizeof, cast(int)S12.alignof);
    printf("S13 = %d %d | 8 4\n", cast(int)S13.sizeof, cast(int)S13.alignof);
    printf("S14 = %d %d | 8 4\n", cast(int)S14.sizeof, cast(int)S14.alignof);
    printf("S15 = %d %d | 4 4\n", cast(int)S15.sizeof, cast(int)S15.alignof);
    printf("S16 = %d %d | 4 1\n", cast(int)S16.sizeof, cast(int)S16.alignof);
    printf("S17 = %d %d | 4 4\n", cast(int)S17.sizeof, cast(int)S17.alignof);
    printf("S18 = %d %d | 9 1\n", cast(int)S18.sizeof, cast(int)S18.alignof);
    printf("A0  = %d %d | 16 8\n", cast(int)A0.sizeof, cast(int)A0.alignof);
    printf("A1  = %d %d | 12 4\n", cast(int)A1.sizeof, cast(int)A1.alignof);
    printf("A2  = %d %d | 12 4\n", cast(int)A2.sizeof, cast(int)A2.alignof);
    printf("A3  = %d %d | 16 4\n", cast(int)A3.sizeof, cast(int)A3.alignof);
    printf("A4  = %d %d | 8 4\n", cast(int)A4.sizeof, cast(int)A4.alignof);
    printf("A5  = %d %d | 2 1\n", cast(int)A5.sizeof, cast(int)A5.alignof);
    printf("A6  = %d %d | 2 2\n", cast(int)A6.sizeof, cast(int)A6.alignof);
    printf("A7  = %d %d | 16 8\n", cast(int)A7.sizeof, cast(int)A7.alignof);
    printf("A8  = %d %d | 8 8\n", cast(int)A8.sizeof, cast(int)A8.alignof);
    printf("A9  = %d %d | 16 8\n", cast(int)A9.sizeof, cast(int)A9.alignof);
    printf("A10 = %d %d | 2 2\n", cast(int)A10.sizeof, cast(int)A10.alignof);
    printf("A11 = %d %d | 12 4\n", cast(int)A11.sizeof, cast(int)A11.alignof);

    {
        S9 s;
        *cast(uint *)&s = 0;
        s.b = 2; s.c = 3;
        uint x = *cast(uint *)&s;
        printf("S9 = x%x\n", x);
    }
    {
        S14 s = { 1, 2, 3 };
        *cast(long *)&s = 0;
        s.a = 1;
        s.b = 2;
        s.c = 3;
        ulong v = *cast(ulong *)&s;
        printf("S14 = x%llx\n", v);
    }
    {
        S15 s = { 1,2,3 };
        *cast(uint *)&s = 0;
        s.a = 1; s.b = 2; s.c = 3;
        uint x = *cast(uint *)&s;
        printf("S15 = x%x\n", x);
    }
    {
        S18 s;
        printf("S18 = %d should be %d\n", cast(int)(&s.b - &s.a), is64bit() ? 8 : 4);
    }
    {
        A0 s;
        *cast(long *)&s = 0;
        s.a = 1; s.b = 15;
        long x = *cast(long *)&s;
        printf("A0 = x%llx\n", x);
    }

    return 0;
}
