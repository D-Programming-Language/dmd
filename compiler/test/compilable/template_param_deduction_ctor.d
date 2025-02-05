// Template parameter deduction for constructors
// dlang.org/dips/40

//////////////////////////////////////////
// Basic succes case
struct Dip40(T)
{
	T x;
    this(T x) { this.x = x; }
}

static assert (Dip40(30).x == 30);
static assert ("a".Dip40.x == "a");

//////////////////////////////////////////
// Variadic template arguments
struct Tuple(T...)
{
	T fields;
    this(T t) { this.fields = t; }
}

static assert (Tuple(1, 2, 3).fields[0] == 1);
static assert(is(typeof(Tuple('a', "b")) == Tuple!(char, string)));

//////////////////////////////////////////
// Constructor is required for now
struct CtorLess(T)
{
	T x;
}
static assert(!is(typeof(CtorLess('a'))));

//////////////////////////////////////////
// Partial instantiation not supported
struct Pair(T, U)
{
	T x;
	U y;
	this(T x, U y) { this.x = x; this.y = y; }
}
static assert(!is(typeof(Pair!char('a', "b"))));

//////////////////////////////////////////
// Ambiguity errors are checked
struct Ambig(T)
{
	T x;
    this(int x, int y) { this.x = x; }
    this(T x) { this.x = x; }
}
static assert(!is(typeof(Ambig(0))));

//////////////////////////////////////////
