
extern (Objective-C)
class NSObject {
	void* isa; // pointer to class object

	static NSObject alloc();
	static NSObject alloc(void* zone);
	NSObject init();
}

import std.c.stdio;

class TestObject : NSObject {
	int val;
    
    
//
////	static void load() { printf("hello load".ptr); }
//	static void initialize() { printf("hello initialize\n"); }
////	static TestObject alloc() { printf("hello alloc"); return null; }
//	TestObject init() { printf("init\n"); return null; }
//	TestObject init2() { printf("init2\n"); return init(); }
}

void main() {
	NSObject obj2 = new TestObject;
	assert(obj2 !is null);
}
