// REQUIRED_ARGS: -o-
// PERMUTE_ARGS:

nothrow /*extern(Windows) */export int GetModuleHandleA(const char* lpModuleName) @system;

void main()
{
    /*extern(Windows) */int function(const char*) f;
    assert(f != &GetModuleHandleA);
}
