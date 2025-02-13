/* TEST_OUTPUT:
---
fail_compilation/withspoon.d(17): Error: matching `}` expected following compound with statement, not `End of File`
fail_compilation/withspoon.d(15):        unmatched `with (exp):`
fail_compilation/withspoon.d(17): Error: matching `}` expected following compound statement, not `End of File`
fail_compilation/withspoon.d(14):        unmatched `{`
---
*/


enum E { A, B }

void test2()
{
	with (E):
		return;
