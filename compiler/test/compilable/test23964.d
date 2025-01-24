// https://issues.dlang.org/show_bug.cgi?id=23964

// REQUIRED_ARGS: -de

ulong foo()
{
    return 1;
}

void compileCheck(const(ClusterInfoJohan) src, ClusterInfoJohan tgt)
{
    tgt = src;
}

struct ClusterInfoJohan
{
    UUID guid;

    ulong oiuoi = 512;

    ulong asdasdasd =
    {
        foo();
        return 1;
    }();
}

struct UUID
{
    @safe @nogc opAssign(UUID) { }
}
