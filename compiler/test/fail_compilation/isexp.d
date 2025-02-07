/* TEST_OUTPUT:
---
fail_compilation/isexp.d(9): Error: cannot infer parameters for `is` TypeSpecialization when it is an alias template instance
fail_compilation/isexp.d(10): Error: cannot infer parameters for `is` TypeSpecialization when it is an alias template instance
---
*/
alias A(T) = int;
enum ati1 = is(int == A!int);
enum ati2 = is(int == A!T, T); // can't infer
enum ati3 = is(A!int == A!T, T); // can't infer

// note: LHS is expanded
enum et(alias a) = is(A!int == a!T, T); // allowed as `a` might not be a non-alias template
enum e1 = et!A;

enum et2(alias a) = is(A!int == a, T); // allowed as `a` might not be a non-alias template instance
enum e2 = et2!(A!int);
