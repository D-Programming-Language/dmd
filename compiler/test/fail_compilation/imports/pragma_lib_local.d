module imports.pragma_lib_local;


pragma(lib, "extra-files/fake.a");

extern(C) int lib_get_int();
