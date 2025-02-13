// https://issues.dlang.org/show_bug.cgi?id=22740


const float ff = 0.2f;
static float gf = 0.2f;
enum float hf = 0.2f;

const double fd = 0.2;
static double gd = 0.2;
enum double hd = 0.2;

const real fr = 0.2L;
static real gr = 0.2L;
enum real hr = 0.2L;

void main()
{
    assert(ff == gf);
    assert(hf == gf);

    assert(fd == gd);
    assert(hd == gd);

    assert(fr == gr);
    assert(hr == gr);

    assert(gf != gd);
    assert(gf != gr);
    assert(gd != gr);
}
