/*
TEST_OUTPUT:
---
fail_compilation/ice15235.d(32): Error: 0 operands found for mov instead of the expected 2
fail_compilation/ice15235.d(33): Error: 0 operands found for mov instead of the expected 2
fail_compilation/ice15235.d(34): Error: bad operand
fail_compilation/ice15235.d(35): Error: bad operand
fail_compilation/ice15235.d(36): Error: bad integral operand
fail_compilation/ice15235.d(37): Error: bad integral operand
fail_compilation/ice15235.d(40): Error: bad type/size of operands 'mov'
fail_compilation/ice15235.d(41): Error: bad type/size of operands 'mov'
fail_compilation/ice15235.d(42): Error: bad operand
fail_compilation/ice15235.d(43): Error: bad operand
fail_compilation/ice15235.d(44): Error: bad operand
fail_compilation/ice15235.d(45): Error: bad operand
fail_compilation/ice15235.d(46): Error: bad integral operand
fail_compilation/ice15235.d(47): Error: bad integral operand
fail_compilation/ice15235.d(48): Error: bad integral operand
fail_compilation/ice15235.d(49): Error: bad integral operand
---
*/








void main() {static assert(__LINE__ == 30);
	asm {
		mov [+], EAX; // syntax error
		mov [-], EAX; // syntax error
		mov [*], EAX; // [s]segfault[/s] syntax error
		mov [****], EAX; // [s]segfault[/s] syntax error
		mov [/], EAX; // syntax error
		mov [%], EAX; // syntax error
	};
	asm {
		mov [EBX+], EAX; // syntax error
		mov [EBX-], EAX; // segfault
		mov [EBX+*], EAX; // segfault
		mov [EBX*], EAX; // segfault
		mov [EBX*EBX*], EAX; // segfault
		mov [*EBX], EAX; // segfault
		mov [/EBX], EAX; // syntax error
		mov [EBX/], EAX; // syntax error
		mov [%EBX], EAX; // syntax error
		mov [EBX%], EAX; // syntax error
	};
};
