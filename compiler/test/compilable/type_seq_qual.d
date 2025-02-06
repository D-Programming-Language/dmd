alias AliasSeq(Args...) = Args;

immutable(AliasSeq!(int, float)) c;
immutable AliasSeq!(int, float) d;
static assert(is(typeof(c) == typeof(d)));

alias TS = AliasSeq!(int, float);
static assert(is(typeof(c) == immutable TS));
static assert(is(immutable(TS)[0] == immutable int));

static assert(is(const(TS) == const TS));
static assert(is(const(AliasSeq!(int, float))[0] == const int)); // OK
static assert(is(const(TS)[0] == const int)); // fails

alias CT = const(TS);
static assert(is(CT[0] == const int));
