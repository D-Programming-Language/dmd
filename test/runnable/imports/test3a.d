module imports.test3a;

import imports.test3b;

extern(C) int printf(const char*, ...) @system;

class Afoo
{
    static this()
    {
	printf("Afoo()\n");
    }
}
