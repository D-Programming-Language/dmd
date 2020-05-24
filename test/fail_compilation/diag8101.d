/*
TEST_OUTPUT:
---
fail_compilation/diag8101.d(57): Error: function `diag8101.f_0(int)` is not callable using argument types `()`
fail_compilation/diag8101.d(57):        missing argument for parameter #1: `int`
fail_compilation/diag8101.d(58): Error: none of the overloads of `f_1` are callable using argument types `()`, candidates are:
fail_compilation/diag8101.d(33):        `diag8101.f_1(int)`
fail_compilation/diag8101.d(34):        `diag8101.f_1(int, int)`
fail_compilation/diag8101.d(59): Error: none of the overloads of `f_2` are callable using argument types `()`, candidates are:
fail_compilation/diag8101.d(36):        `diag8101.f_2(int)`
fail_compilation/diag8101.d(37):        `diag8101.f_2(int, int)`
fail_compilation/diag8101.d(38):        `diag8101.f_2(int, int, int)`
fail_compilation/diag8101.d(39):        `diag8101.f_2(int, int, int, int)`
fail_compilation/diag8101.d(40):        `diag8101.f_2(int, int, int, int, int)`
fail_compilation/diag8101.d(59):        ... (1 more, -v to show) ...
fail_compilation/diag8101.d(61): Error: template `diag8101.t_0` cannot deduce function from argument types `!()()`, candidates are:
fail_compilation/diag8101.d(43):        `t_0(T1)()`
fail_compilation/diag8101.d(62): Error: template `diag8101.t_1` cannot deduce function from argument types `!()()`, candidates are:
fail_compilation/diag8101.d(45):        `t_1(T1)()`
fail_compilation/diag8101.d(46):        `t_1(T1, T2)()`
fail_compilation/diag8101.d(63): Error: template `diag8101.t_2` cannot deduce function from argument types `!()()`, candidates are:
fail_compilation/diag8101.d(48):        `t_2(T1)()`
fail_compilation/diag8101.d(49):        `t_2(T1, T2)()`
fail_compilation/diag8101.d(50):        `t_2(T1, T2, T3)()`
fail_compilation/diag8101.d(51):        `t_2(T1, T2, T3, T4)()`
fail_compilation/diag8101.d(52):        `t_2(T1, T2, T3, T4, T5)()`
fail_compilation/diag8101.d(63):        ... (1 more, -v to show) ...
---
*/

void f_0(int) @system;

void f_1(int) @system;
void f_1(int, int) @system;

void f_2(int) @system;
void f_2(int, int) @system;
void f_2(int, int, int) @system;
void f_2(int, int, int, int) @system;
void f_2(int, int, int, int, int) @system;
void f_2(int, int, int, int, int, int) @system;

void t_0(T1)();

void t_1(T1)();
void t_1(T1, T2)();

void t_2(T1)();
void t_2(T1, T2)();
void t_2(T1, T2, T3)();
void t_2(T1, T2, T3, T4)();
void t_2(T1, T2, T3, T4, T5)();
void t_2(T1, T2, T3, T4, T5, T6)();

void main()
{
    f_0();
    f_1();
    f_2();

    t_0();
    t_1();
    t_2();
}
