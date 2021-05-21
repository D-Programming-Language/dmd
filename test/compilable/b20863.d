alias t(alias a) = a;

static assert(is(t!(const Object) == const Object));
static assert(is(t!(shared(Object)) == shared Object));
static assert(is(t!(immutable S) == immutable(S)));

struct S{}
