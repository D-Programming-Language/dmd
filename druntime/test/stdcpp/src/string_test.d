module test.stdcpp.string;

import core.stdcpp.string;

alias std_string = basic_string!char;
alias std_wstring = basic_string!wchar;

unittest
{
    std_string str = std_string("Hello");

    assert(str.size == 5);
    assert(str.length == 5);
    assert(str.empty == false);

    assert(sumOfElements_val(str) == 1500);
    assert(sumOfElements_ref(str) == 500);

    str = "Hello again with a long long string woo";
    assert(sumOfElements_val(str) == 10935);
    assert(sumOfElements_ref(str) == 3645);
    assert(str == std_string("Hello again with a long long string woo"));

    std_string str2 = std_string(Default);
    assert(str2.size == 0);
    assert(str2.length == 0);
    assert(str2.empty == true);
    assert(str2[] == []);

    str2 = std_string("World");
    assert(str2[] == "World");
    str = str2;
    assert(str[] == "World");
    str2 = "Direct";
    assert(str2[] == "Direct");
    assert(str2[2] == 'r');
    assert(str2[2 .. 5] == "rec");
    str2[] = "Plonk!";
    assert(str2[] == "Plonk!");
    str2[2] = 'a';
    str2[3 .. 5] = "ne";
    assert(str2[] == "Plane!");
    str2[] = 'a';
    str2[1 .. 5] = 'b';
    str2[] += 1;
    str2[1] += 1;
    str2[2 .. 4] += 2;
    assert(str2[] == "bdeecb");

    // test local instantiations...
    // there's no basic_string<char16_t> instantiation in C++
    std_wstring str3 = std_wstring("Hello"w);

    assert(str3.size == 5);
    assert(str3.length == 5);
    assert(str3.empty == false);

    std_string str4 = "12345";
    str4.reserve(40);
    auto p = str4.data();
    foreach (i; 0 .. 5)
        str4 ~= "00000";
    assert(str4.length == 30);
    assert(str4.data() == p);
    str4.shrink_to_fit();

    str4.clear();
    str4 ~= "world";
    str4.insert(0, "hello ");
    str4.insert(11, "!");
    assert(str4[] == "hello world!");
    str4.replace(6, 5, "me");
    assert(str4[] == "hello me!");
    str4.insert(0, 4, ' ');
    assert(str4[] == "    hello me!");
    str4.resize(4);
    str4.resize(7, '.');
    assert(str4[] == "    ...");
}


extern(C++):

// test the ABI for calls to C++
int sumOfElements_val(std_string);
int sumOfElements_ref(ref const(std_string));

// test the ABI for calls from C++
int fromC_val(std_string str)
{
    assert(str[0 .. 5] == "Hello");
    assert(str.front == 'H');
    assert(str.back == 'o');
    assert(str.at(2) == 'l');

//    str.fill(2);

    int r;
    foreach (e; str[])
        r += e;
    return r;
}

int fromC_ref(ref const(std_string) str)
{
    int r;
    foreach (e; str[])
        r += e;
    return r;
}
