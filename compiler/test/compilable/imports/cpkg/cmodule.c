// D module declaration

#if __IMPORTC__

__module imports.cpkg.cmodule;

// Only the first module statement is used,
// subsequent __module declarations are assumed to come from #included other files
__module some.header;

#endif

int sqr(int i) { return i * i; }
