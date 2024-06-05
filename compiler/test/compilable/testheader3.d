/*
EXTRA_SOURCES: extra-files/header3.d
REQUIRED_ARGS: -o- -unittest -H -Hf${RESULTS_DIR}/compilable/testheader3.di
PERMUTE_ARGS: -d -dw
OUTPUT_FILES: ${RESULTS_DIR}/compilable/testheader3.di

TEST_OUTPUT:
---
=== ${RESULTS_DIR}/compilable/testheader3.di
// D import file generated from 'compilable/extra-files/header3.d'
void elseifchain() pure nothrow @nogc @safe
{
	bool a = false;
	bool b = false;
	bool c = false;
	if (a)
	{
	}
	else if (b)
	{
	}
	else if (c)
	{
	}
}
---
*/

void main() {}
