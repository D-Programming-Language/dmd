// REQUIRED_ARGS: -revert=aliasaggquals
alias t(alias a) = a;

static assert(is(t!(const Object) == Object));
static assert(is(t!(shared(Object)) == Object));
static assert(is(t!(immutable S) == S));

struct S{}
