/*
TEST_OUTPUT:
---
fail_compilation/fail_contracts3.d(15): Error: function `fail_contracts3.D.foo` cannot have an in contract when overridden function `fail_contracts3.C.foo` does not have an in contract
fail_compilation/fail_contracts3.d(26): Error: function `fail_contracts3.F.foo` cannot have an in contract when overridden function `fail_contracts3.E.foo` does not have an in contract
fail_compilation/fail_contracts3.d(34): Error: function `fail_contracts3.G.foo` cannot have an in contract when overridden function `fail_contracts3.I.foo` does not have an in contract
---
*/

class C {
	void foo(){}
}

class D : C {
	override void foo()in{}do{}
}

/* https://issues.dlang.org/show_bug.cgi?id=21298
 */

class E {
	void foo();
}

class F : E {
	override void foo()in{}do{}
}

class I {
	void foo();
}

class G : I {
	override void foo()in{}do{}
}
