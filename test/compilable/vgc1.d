// REQUIRED_ARGS: -vgc -o-
// PERMUTE_ARGS:

/***************** NewExp *******************/

struct S1 { }
struct S2 { this(int) @system; }
struct S3 { this(int) @nogc @system; }

/*
TEST_OUTPUT:
---
compilable/vgc1.d(25): vgc: `new` causes a GC allocation
compilable/vgc1.d(27): vgc: `new` causes a GC allocation
compilable/vgc1.d(28): vgc: `new` causes a GC allocation
compilable/vgc1.d(30): vgc: `new` causes a GC allocation
compilable/vgc1.d(31): vgc: `new` causes a GC allocation
compilable/vgc1.d(32): vgc: `new` causes a GC allocation
compilable/vgc1.d(34): vgc: `new` causes a GC allocation
---
*/

void testNew()
{
    int* p1 = new int;

    int[] a1 = new int[3];
    int[][] a2 = new int[][](2, 3);

    S1* ps1 = new S1();
    S2* ps2 = new S2(1);
    S3* ps3 = new S3(1);

    Object o1 = new Object();
}

/*
TEST_OUTPUT:
---
compilable/vgc1.d(51): vgc: `new` causes a GC allocation
compilable/vgc1.d(53): vgc: `new` causes a GC allocation
compilable/vgc1.d(54): vgc: `new` causes a GC allocation
compilable/vgc1.d(56): vgc: `new` causes a GC allocation
compilable/vgc1.d(57): vgc: `new` causes a GC allocation
compilable/vgc1.d(58): vgc: `new` causes a GC allocation
---
*/

void testNewScope()
{
    scope int* p1 = new int;

    scope int[] a1 = new int[3];
    scope int[][] a2 = new int[][](2, 3);

    scope S1* ps1 = new S1();
    scope S2* ps2 = new S2(1);
    scope S3* ps3 = new S3(1);

    scope Object o1 = new Object();     // no error
    scope o2 = new Object();            // no error
    scope Object o3;
    o3 = o2;                            // no error
}

/***************** DeleteExp *******************/

/*
TEST_OUTPUT:
---
compilable/vgc1.d(81): Deprecation: The `delete` keyword has been deprecated.  Use `object.destroy()` (and `core.memory.GC.free()` if applicable) instead.
compilable/vgc1.d(81): vgc: `delete` requires the GC
compilable/vgc1.d(82): Deprecation: The `delete` keyword has been deprecated.  Use `object.destroy()` (and `core.memory.GC.free()` if applicable) instead.
compilable/vgc1.d(82): vgc: `delete` requires the GC
compilable/vgc1.d(83): Deprecation: The `delete` keyword has been deprecated.  Use `object.destroy()` (and `core.memory.GC.free()` if applicable) instead.
compilable/vgc1.d(83): vgc: `delete` requires the GC
---
*/
void testDelete(int* p, Object o, S1* s)
{
    delete p;
    delete o;
    delete s;
}
