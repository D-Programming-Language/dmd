/*
ARG_SETS: -preview=?
ARG_SETS: -preview=h
TEST_OUTPUT:
----
Upcoming language changes listed by -preview=name:
  =all              Enables all available upcoming language changes
  =dip25            implement Sealed References DIP [DEPRECATED] (https://github.com/dlang/DIPs/blob/master/DIPs/archive/DIP25.md)
  =dip1000          implement Scoped Pointers DIP (https://github.com/dlang/DIPs/blob/master/DIPs/other/DIP1000.md)
  =dip1008          implement @nogc Throwable DIP (https://github.com/dlang/DIPs/blob/master/DIPs/other/DIP1008.md)
  =dip1021          implement Mutable Function Arguments DIP (https://github.com/dlang/DIPs/blob/master/DIPs/accepted/DIP1021.md)
  =bitfields        add C-like bitfields (https://github.com/dlang/dlang.org/pull/3190)
  =fixAliasThis     when a symbol is resolved, check alias this scope before going to upper scopes (https://github.com/dlang/dmd/pull/8885)
  =safer            more safety checks by default (https://github.com/WalterBright/documents/blob/38f0a846726b571f8108f6e63e5e217b91421c86/safer.md)
  =nosharedaccess   disable access to shared memory objects (https://dlang.org/spec/const3.html#shared)
  =in               `in` on parameters means `scope const [ref]` and accepts rvalues (https://dlang.org/spec/function.html#in-params)
  =inclusiveincontracts 'in' contracts of overridden methods must be a superset of parent contract (https://dlang.org/changelog/2.095.0.html#inclusive-incontracts)
  =fixImmutableConv disallow `void[]` data from holding immutable data (https://dlang.org/changelog/2.101.0.html#dmd.fix-immutable-conv, https://issues.dlang.org/show_bug.cgi?id=17148)
  =systemVariables  disable access to variables marked '@system' from @safe code (https://dlang.org/spec/attribute.html#system-variables)
----
*/
