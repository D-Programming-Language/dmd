/*
ARG_SETS: -revert=?
ARG_SETS: -revert=h
TEST_OUTPUT:
----
Revertable language changes listed by -revert=name:
  =all              Enables all available revertable language changes
  =dip25            revert DIP25 changes [DEPRECATED] (https://github.com/dlang/DIPs/blob/master/DIPs/archive/DIP25.md)
  =dip1000          revert DIP1000 changes (Scoped Pointers) (https://github.com/dlang/DIPs/blob/master/DIPs/other/DIP1000.md)
  =intpromote       revert integral promotions for unary + - ~ operators
  =dtorfields       don't destruct fields of partially constructed objects
  =fieldwise        don't use fieldwise comparisons for struct equality (https://dlang.org/changelog/2.085.0.html#no-cmpsb)
  =rvaluerefparam   revert rvalue arguments to ref parameters (https://gist.github.com/andralex/e5405a5d773f07f73196c05f8339435a)
----
*/
