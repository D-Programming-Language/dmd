alias fp = (x = 0) => x;
static assert(is(typeof(fp!int) : int function(int = 0)));
static assert(fp() == 0);

int main() {}
