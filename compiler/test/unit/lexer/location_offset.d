module lexer.location_offset;

import dmd.lexer : Lexer;
import dmd.tokens : TOK;
import dmd.errorsink;

import support : afterEach;

@afterEach deinitializeFrontend()
{
    import dmd.frontend : deinitializeDMD;
    deinitializeDMD();
}

@("first token in the source code")
unittest
{
    enum code = "token";

    scope lexer = new Lexer("test.d", code.ptr, 0, code.length, 0, 0, new ErrorSinkStderr, null);

    lexer.nextToken;

    assert(lexer.token.loc.fileOffset == 0, code);
}

@("first token when begoffset is not 0")
unittest
{
    enum code = "ignored_token token";

    scope lexer = new Lexer("test.d", code.ptr, 13, code.length - 14, 0, 0, new ErrorSinkStderr, null);

    lexer.nextToken;

    assert(lexer.token.loc.fileOffset == 14, code);
}

@("last token in the source code")
unittest
{
    enum code = "token1 token2 3";

    scope lexer = new Lexer("test.d", code.ptr, 0, code.length, 0, 0, new ErrorSinkStderr, null);

    lexer.nextToken;
    lexer.nextToken;
    lexer.nextToken;

    assert(lexer.token.loc.fileOffset == 14, code);
}

@("end of code")
unittest
{
    enum code = "token";

    scope lexer = new Lexer("test.d", code.ptr, 0, code.length, 0, 0, new ErrorSinkStderr, null);

    lexer.nextToken;
    lexer.nextToken;

    assert(lexer.token.loc.fileOffset == 5, code);
}

@("block comment")
unittest
{
    enum code = "/* comment */";

    scope lexer = new Lexer("test.d", code.ptr, 0, code.length, 0, true, new ErrorSinkStderr, null);

    lexer.nextToken;

    assert(lexer.token.value == TOK.comment, code);
    assert(lexer.token.loc.fileOffset == 2, code);
}

@("line comment")
unittest
{
    enum code = "// comment";

    scope lexer = new Lexer("test.d", code.ptr, 0, code.length, 0, true, new ErrorSinkStderr, null);

    lexer.nextToken;

    assert(lexer.token.value == TOK.comment, code);
    assert(lexer.token.loc.fileOffset == 1, code);
}

@("nesting block comment")
unittest
{
    enum code = "/+ comment +/";

    scope lexer = new Lexer("test.d", code.ptr, 0, code.length, 0, true, new ErrorSinkStderr, null);

    lexer.nextToken;

    assert(lexer.token.value == TOK.comment, code);
    assert(lexer.token.loc.fileOffset == 1, code);
}

@("identifier after block comment")
unittest
{
    enum code = "/* comment */ token";

    scope lexer = new Lexer("test.d", code.ptr, 0, code.length, 0, 0, new ErrorSinkStderr, null);

    lexer.nextToken;

    assert(lexer.token.loc.fileOffset == 14, code);
}

@("identifier after line comment")
unittest
{
    enum code = "// comment\ntoken";

    scope lexer = new Lexer("test.d", code.ptr, 0, code.length, 0, 0, new ErrorSinkStderr, null);

    lexer.nextToken;

    assert(lexer.token.loc.fileOffset == 11, code);
}

@("identifier after nesting block comment")
unittest
{
    enum code = "/+ comment +/ token";

    scope lexer = new Lexer("test.d", code.ptr, 0, code.length, 0, 0, new ErrorSinkStderr, null);

    lexer.nextToken;

    assert(lexer.token.loc.fileOffset == 14, code);
}

@("token after Unix line ending")
unittest
{
    enum code = "line\ntoken";

    scope lexer = new Lexer("test.d", code.ptr, 0, code.length, 0, 0, new ErrorSinkStderr, null);

    lexer.nextToken;
    lexer.nextToken;

    assert(lexer.token.loc.fileOffset == 5, code);
}

@("token after Windows line ending")
unittest
{
    enum code = "line\r\ntoken";

    scope lexer = new Lexer("test.d", code.ptr, 0, code.length, 0, 0, new ErrorSinkStderr, null);

    lexer.nextToken;
    lexer.nextToken;

    assert(lexer.token.loc.fileOffset == 6, code);
}

@("token after Mac line ending")
unittest
{
    enum code = "line\rtoken";

    scope lexer = new Lexer("test.d", code.ptr, 0, code.length, 0, 0, new ErrorSinkStderr, null);

    lexer.nextToken;
    lexer.nextToken;

    assert(lexer.token.loc.fileOffset == 5, code);
}

@("multibyte character token")
unittest
{
    enum code = "'🍺'";

    scope lexer = new Lexer("test.d", code.ptr, 0, code.length, 0, 0, new ErrorSinkStderr, null);

    lexer.nextToken;

    assert(lexer.token.loc.fileOffset == 0, code);
}

@("multibyte character string token")
unittest
{
    enum code = `"🍺🍺"`;

    scope lexer = new Lexer("test.d", code.ptr, 0, code.length, 0, 0, new ErrorSinkStderr, null);

    lexer.nextToken;

    assert(lexer.token.loc.fileOffset == 0, code);
}

@("token after multibyte character token")
unittest
{
    enum code = "'🍺' token";

    scope lexer = new Lexer("test.d", code.ptr, 0, code.length, 0, 0, new ErrorSinkStderr, null);

    lexer.nextToken;
    lexer.nextToken;

    assert(lexer.token.loc.fileOffset == 7, code);
}

@("token after multibyte character string token")
unittest
{
    enum code = `"🍺🍺" token`;

    scope lexer = new Lexer("test.d", code.ptr, 0, code.length, 0, 0, new ErrorSinkStderr, null);

    lexer.nextToken;
    lexer.nextToken;

    assert(lexer.token.loc.fileOffset == 11, code);
}

immutable struct Test
{
    /*
     * The description of the unit test.
     *
     * This will go into the UDA attached to the `unittest` block.
     */
    string description_;

    /*
     * The code to lex.
     *
     * Optional. If the code is not provided the description will be used.
     * Useful when the description and the code is exactly the same, i.e. for
     * keywords.
     */
    string code_ = null;

    string code()
    {
        return code_ ? code_ : description_;
    }

    string description()
    {
        return description_;
    }
}

enum Test[string] tests = [
    "leftParenthesis" : Test("left parenthesis", "("),
    "rightParenthesis" : Test("right parenthesis", ")"),
    "leftBracket" : Test("left square bracket", "["),
    "rightBracket" : Test("right square bracket", "]"),
    "leftCurly" : Test("left curly brace", "{"),
    "rightCurly" : Test("right curly brace", "}"),
    "colon" : Test("colon", ":"),
    "semicolon" : Test("semicolon", ";"),
    "dotDotDot" : Test("triple dot", "..."),
    "endOfFile" : Test("end of file", "\u001A"),
    "cast_" : Test("cast"),
    "null_" : Test("null"),
    "assert_" : Test("assert"),
    "true_" : Test("true"),
    "false_" : Test("false"),
    "throw_" : Test("throw"),
    "new_" : Test("new"),
    "delete_" : Test("delete"),
    "slice" : Test("slice", ".."),
    "version_" : Test("version"),
    "module_" : Test("module"),
    "dollar" : Test("dollar", "$"),
    "template_" : Test("template"),
    "typeof_" : Test("typeof"),
    "pragma_" : Test("pragma"),
    "typeid_" : Test("typeid"),

    "lessThan" : Test("less than", "<"),
    "greaterThan" : Test("greater then", ">"),
    "lessOrEqual" : Test("less then or equal", "<="),
    "greaterOrEqual" : Test("greater then or equal", ">="),
    "equal" : Test("equal", "=="),
    "notEqual" : Test("not equal", "!="),
    "is_" : Test("is"),
    "leftShift" : Test("left shift", "<<"),
    "rightShift" : Test("right shift", ">>"),
    "leftShiftAssign" : Test("left shift assign", "<<="),
    "rightShiftAssign" : Test("right shift assign", ">>="),
    "unsignedRightShift" : Test("unsigned right shift", ">>>"),
    "unsignedRightShiftAssign" : Test("unsigned right shift assign", ">>>="),
    "concatenateAssign" : Test("concatenate assign", "~="),
    "add" : Test("plus", "+"),
    "min" : Test("minus", "-"),
    "addAssign" : Test("plus assign", "+="),
    "minAssign" : Test("minus assign", "-="),
    "mul" : Test("multiply", "*"),
    "div" : Test("divide", "/"),
    "mod" : Test("modulo", "%"),
    "mulAssign" : Test("multiply assign", "*="),
    "divAssign" : Test("divide assign", "/="),
    "modAssign" : Test("modulo assign", "%="),
    "and" : Test("and", "&"),
    "or" : Test("or", "|"),
    "xor" : Test("xor", "^"),
    "andAssign" : Test("and assign", "&="),
    "orAssign" : Test("or assign", "|="),
    "xorAssign" : Test("xor assign", "^="),
    "assign" : Test("assign", "="),
    "not" : Test("not", "!"),
    "tilde" : Test("tilde", "~"),
    "plusPlus" : Test("plus plus", "++"),
    "minusMinus" : Test("minus minus", "--"),
    "dot" : Test("dot", "."),
    "comma" : Test("comma", ","),
    "question" : Test("question mark", "?"),
    "andAnd" : Test("and and", "&&"),
    "orOr" : Test("or or", "||"),

    "int32Literal" : Test("32 bit integer literal", "0"),
    "uns32Literal" : Test("32 bit unsigned integer literal", "0U"),
    "int64Literal" : Test("64 bit integer literal", "0L"),
    "uns64Literal" : Test("64 bit unsigned integer literal", "0UL"),
    "float32Literal" : Test("32 bit floating point literal", "0.0f"),
    "float64Literal" : Test("64 bit floating point literal", "0.0"),
    "float80Literal" : Test("80 bit floating point literal", "0.0L"),
    "imaginary32Literal" : Test("32 bit imaginary floating point literal", "0.0fi"),
    "imaginary64Literal" : Test("64 bit imaginary floating point literal", "0.0i"),
    "imaginary80Literal" : Test("80 bit imaginary floating point literal", "0.0Li"),

    "charLiteral" : Test("character literal", "'a'"),
    "wcharLiteral" : Test("wide character literal", "'ö'"),
    "dcharLiteral" : Test("double wide character literal", "'🍺'"),

    "identifier" : Test("identifier", "foo"),
    "string_" : Test("string literal", `"foo"`),
    "hexadecimalString" : Test("hexadecimal string literal", `x"61"`),
    "this_" : Test("this"),
    "super_" : Test("super"),

    "void_" : Test("void"),
    "int8" : Test("byte"),
    "uns8" : Test("ubyte"),
    "int16" : Test("short"),
    "uns16" : Test("ushort"),
    "int32" : Test("int"),
    "uns32" : Test("uint"),
    "int64" : Test("long"),
    "uns64" : Test("ulong"),
    "float32" : Test("float"),
    "float64" : Test("double"),
    "float80" : Test("real"),
    "imaginary32" : Test("ifloat"),
    "imaginary64" : Test("idouble"),
    "imaginary80" : Test("ireal"),
    "complex32" : Test("cfloat"),
    "complex64" : Test("cdouble"),
    "complex80" : Test("creal"),
    "char_" : Test("char"),
    "wchar_" : Test("wchar"),
    "dchar_" : Test("dchar"),
    "bool_" : Test("bool"),

    "struct_" : Test("struct"),
    "class_" : Test("class"),
    "interface_" : Test("interface"),
    "union_" : Test("union"),
    "enum_" : Test("enum"),
    "import_" : Test("import"),
    "alias_" : Test("alias"),
    "override_" : Test("override"),
    "delegate_" : Test("delegate"),
    "function_" : Test("function"),
    "mixin_" : Test("mixin"),
    "align_" : Test("align"),
    "extern_" : Test("extern"),
    "private_" : Test("private"),
    "protected_" : Test("protected"),
    "public_" : Test("public"),
    "export_" : Test("export"),
    "static_" : Test("static"),
    "final_" : Test("final"),
    "const_" : Test("const"),
    "abstract_" : Test("abstract"),
    "debug_" : Test("debug"),
    "deprecated_" : Test("deprecated"),
    "in_" : Test("in"),
    "out_" : Test("out"),
    "inout_" : Test("inout"),
    "lazy_" : Test("lazy"),
    "auto_" : Test("auto"),
    "package_" : Test("package"),
    "immutable_" : Test("immutable"),
    "rvalue" : Test("__rvalue"),

    "if_" : Test("if"),
    "else_" : Test("else"),
    "while_" : Test("while"),
    "for_" : Test("for"),
    "do_" : Test("do"),
    "switch_" : Test("switch"),
    "case_" : Test("case"),
    "default_" : Test("default"),
    "break_" : Test("break"),
    "continue_" : Test("continue"),
    "with_" : Test("with"),
    "synchronized_" : Test("synchronized"),
    "return_" : Test("return"),
    "goto_" : Test("goto"),
    "try_" : Test("try"),
    "catch_" : Test("catch"),
    "finally_" : Test("finally"),
    "asm_" : Test("asm"),
    "foreach_" : Test("foreach"),
    "foreach_reverse_" : Test("foreach_reverse"),
    "scope_" : Test("scope"),

    "invariant_" : Test("invariant"),

    "unittest_" : Test("unittest"),

    "argumentTypes" : Test("__argTypes"),
    "ref_" : Test("ref"),
    "macro_" : Test("macro"),

    "parameters" : Test("__parameters"),
    "traits" : Test("__traits"),
    "overloadSet" : Test("__overloadset"),
    "pure_" : Test("pure"),
    "nothrow_" : Test("nothrow"),
    "gshared" : Test("__gshared"),

    "line" : Test("__LINE__"),
    "file" : Test("__FILE__"),
    "fileFullPath" : Test("__FILE_FULL_PATH__"),
    "moduleString" : Test("__MODULE__"),
    "functionString" : Test("__FUNCTION__"),
    "prettyFunction" : Test("__PRETTY_FUNCTION__"),

    "shared_" : Test("shared"),
    "at" : Test("at sign", "@"),
    "pow" : Test("power", "^^"),
    "powAssign" : Test("power assign", "^^="),
    "goesTo" : Test("fat arrow", "=>"),
    "vector" : Test("__vector"),
    "pound" : Test("pound", "#"),

    "arrow" : Test("arrow", "->"),
    "colonColon" : Test("colonColon", "::"),
];

// Ignore tokens not produced by the lexer or tested above
enum ignoreTokens
{
    reserved,
    negate,
    array,
    call,
    address,
    star,
    type,
    dotVariable,
    dotIdentifier,
    dotTemplateInstance,
    dotType,
    symbolOffset,
    variable,
    arrayLength,
    dotTemplateDeclaration,
    declaration,
    dSymbol,
    uadd,
    remove,
    newAnonymousClass,
    comment,
    arrayLiteral,
    assocArrayLiteral,
    structLiteral,
    compoundLiteral,
    classReference,
    thrownException,
    delegatePointer,
    delegateFunctionPointer,
    identity,
    notIdentity,
    index,
    concatenate,
    concatenateElemAssign,
    concatenateDcharAssign,
    construct,
    blit,
    arrow,
    prePlusPlus,
    preMinusMinus,
    int128Literal,
    uns128Literal,
    halt,
    tuple,
    error,
    int128,
    uns128,
    onScopeExit,
    onScopeFailure,
    onScopeSuccess,
    interval,
    voidExpression,
    cantExpression,
    showCtfeContext,
    objcClassReference,
    vectorArray,
    interpolated,

    wchar_tLiteral,
    endOfLine,
    whitespace,
    inline,
    register,
    restrict,
    signed,
    sizeof_,
    typedef_,
    unsigned,
    volatile,
    _Alignas,
    _Alignof,
    _Atomic,
    _Bool,
    _Complex,
    _Generic,
    _Imaginary,
    _Noreturn,
    _Static_assert,
    _Thread_local,

    _assert,
    _import,
    _module,
    __cdecl,
    __declspec,
    __stdcall,
    __thread,
    __pragma,
    __int128,
    __attribute__,

    max_,
};

static foreach (tok; __traits(allMembers, TOK))
{
    static if (!__traits(hasMember, ignoreTokens, tok))
    {
        @(tests[tok].description)
        unittest
        {
            const newCode = "first_token " ~ tests[tok].code ~ '\0';

            scope lexer = new Lexer("test.d", newCode.ptr, 0, newCode.length, 0, 0, new ErrorSinkStderr, null);

            lexer.nextToken;
            lexer.nextToken;

            assert(lexer.token.value == __traits(getMember, TOK, tok), newCode);
            assert(lexer.token.loc.fileOffset == 12, newCode);
        }
    }
}
