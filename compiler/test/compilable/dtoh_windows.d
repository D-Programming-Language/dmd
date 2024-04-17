/++
REQUIRED_ARGS: -HC -o-
TEST_OUTPUT:
---
// Automatically generated by Digital Mars D Compiler

#pragma once

#include <assert.h>
#include <math.h>
#include <stddef.h>
#include <stdint.h>

#ifdef CUSTOM_D_ARRAY_TYPE
#define _d_dynamicArray CUSTOM_D_ARRAY_TYPE
#else
/// Represents a D [] array
template<typename T>
struct _d_dynamicArray final
{
    size_t length;
    T *ptr;

    _d_dynamicArray() : length(0), ptr(NULL) { }

    _d_dynamicArray(size_t length_in, T *ptr_in)
        : length(length_in), ptr(ptr_in) { }

    T& operator[](const size_t idx) {
        assert(idx < length);
        return ptr[idx];
    }

    const T& operator[](const size_t idx) const {
        assert(idx < length);
        return ptr[idx];
    }
};
#endif

#ifndef _WIN32
#define EXTERN_SYSTEM_AFTER __stdcall
#define EXTERN_SYSTEM_BEFORE
#else
#define EXTERN_SYSTEM_AFTER
#define EXTERN_SYSTEM_BEFORE extern "C"
#endif

EXTERN_SYSTEM_BEFORE int32_t EXTERN_SYSTEM_AFTER exSystem(int32_t x);

int32_t __stdcall exWindows(int32_t y);
---
++/

extern(System) int exSystem(int x)
{
    return x;
}

extern(Windows) int exWindows(int y)
{
    return y;
}
