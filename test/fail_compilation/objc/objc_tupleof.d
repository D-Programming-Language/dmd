// PLATFORM: osx
/*
TEST_OUTPUT:
---
fail_compilation/objc/objc_tupleof.d(17): Error: .tupleof (obj) is not available for Objective-C classes (ObjcTupleof)
fail_compilation/objc/objc_tupleof.d(18): Error: .tupleof (ObjcTupleof) is not available for Objective-C classes (ObjcTupleof)
---
*/

extern (Objective-C) class ObjcTupleof
{
}

void main ()
{
    ObjcTupleof obj;
    auto o = obj.tupleof;
    o = ObjcTupleof.tupleof;
}