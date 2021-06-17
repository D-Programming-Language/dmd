// check the expression parser

/********************************/
// https://issues.dlang.org/show_bug.cgi?id=21937
#line 100
void test21962() __attribute__((noinline))
{
}

/********************************/
// https://issues.dlang.org/show_bug.cgi?id=21962
#line 200
enum E21962 { };
enum { };

/********************************/
// https://issues.dlang.org/show_bug.cgi?id=22028
#line 250
struct S22028
{
    int init = 1;
    void vfield nocomma;
    struct { };
};

int test22028 = sizeof(struct S22028 ident);

/********************************/
// https://issues.dlang.org/show_bug.cgi?id=22029
#line 300
struct S22029
{
    int field;
    typedef int tfield;
    extern int efield;
    static int sfield;
    _Thread_local int lfield;
    auto int afield;
    register int rfield;
};

// https://issues.dlang.org/show_bug.cgi?id=22030
#line 400
int;
int *;
int &;
int , int;

struct S22030
{
  int;
  int *;
  int &;
  int, int;
  int _;
};

void test22030(struct S22030, struct S22030*, struct S22030[4]);
