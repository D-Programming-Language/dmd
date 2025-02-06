/* This .h file is to be #include'd by ImportC files first in order provide
 * adjustments to the source to account for various C compiler extensions
 * not supported by ImportC.
 *
 * Copyright: Copyright D Language Foundation 2022
 * License:   $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
 * Authors:   Walter Bright
 * Source: $(DRUNTIMESRC importc.h)
 */

/**********************
 * Silence noisy warnings for this file
 */
#ifdef __GNUC__
#pragma GCC system_header
#endif

/**********************
 * For special casing ImportC code.
 */
#define __IMPORTC__ 1

/********************
 * Some compilers define `__restrict` instead of `restrict` as C++ compilers don't
 * recognize `restrict` as a keyword.
 * ImportC assigns no semantics to `restrict`, so just ignore the keyword.
 */
#define __restrict
#define __restrict__

/**********************
 * Some old pre-Ansi headers use these
 */
#define __signed__ signed
#define __asm__ asm
#define __asm asm
#define __inline__ inline
#define __inline inline
#define __volatile__ volatile
#define __attribute __attribute__
#define __alignof _Alignof
#define __vector_size__ vector_size
#define __typeof typeof
#define __typeof__ typeof

/********************
 * Clang nullability extension used by macOS headers.
 */
#define _Nonnull
#define _Nullable
#define _Null_unspecified

/********************
 * This is a Microsoft C function calling convention not supported by ImportC,
 * so ignore it.
 */
#define __fastcall

#define __forceinline
#undef _Check_return_
//#define _Check_return_
#define __pragma(x)

#undef _GLIBCXX_USE_FLOAT128

/* Microsoft builtin types */
#define __int8 char
#define __int16 short
#define __int32 int
#define __int64 long long

/* Linux builtin types */
typedef unsigned short __uint16_t;
typedef unsigned int __uint32_t;
typedef unsigned long long __uint64_t;

/*********************
 * Obsolete detritus
 */
#define __cdecl
#define __pascal

/*********************
 * DMC-specific extensions, https://digitalmars.com/ctg/pointers16.html
 */
#ifdef __DMC__
#define __ss
#define __cs
#define __far
#define __near
#define __handle
#endif

/****************************
 * __extension__ is a GNU C extension. It suppresses warnings
 * when placed before an expression.
 */
#define __extension__  /* ignore it, as ImportC doesn't do warnings */

#define __builtin_isnan(x) isnan(x)
#define __builtin_isfinite(x) finite(x)
#define __builtin_alloca(x) alloca(x)

/********************************
 * __has_extension is a clang thing:
 *    https://clang.llvm.org/docs/LanguageExtensions.html
 * ImportC no has extensions.
 */
#undef __has_feature
#define __has_feature(x) 0

#undef __has_extension
#define __has_extension(x) 0

/*************************************
 * OS-specific macros
 */
#if __APPLE__
#define __builtin___memmove_chk(dest, src, len, x) memmove(dest,src,len)  // put it back to memmove()
#define __builtin___memcpy_chk(dest, src, len, x) memcpy(dest,src,len)
#define __builtin___memset_chk(dest, val, len, x) memset(dest,val,len)
#define __builtin___stpcpy_chk(dest, src, x) stpcpy(dest,src)
#define __builtin___stpncpy_chk(dest, src, len, x) stpncpy(dest,src,len)
#define __builtin___strcat_chk(dest, src, x) strcat(dest,src)
#define __builtin___strcpy_chk(dest, src, x) strcpy(dest,src)
#define __builtin___strncat_chk(dest, src, len, x) strncat(dest,src,len)
#define __builtin___strncpy_chk(dest, src, len, x) strncpy(dest,src,len)
#define __builtin___sprintf_chk(s, flag, os, fmt, ...) sprintf(s, fmt, __VA_ARGS__)
#define __builtin___snprintf_chk(s, c, flag, os, fmt, ...) snprintf(s, c, fmt, __VA_ARGS__)
#define __builtin___vsnprintf_chk(s, c, flag, os, fmt, ...) vsnprintf(s, c, fmt, __VA_ARGS__)
#define __builtin___strlcat_chk(dest, src, x, n) strlcat(dest,src,x)
#define __builtin___strlcpy_chk(dest, src, x, n) strlcpy(dest,src,x)
#define __builtin_object_size
#define __signed signed
#endif

#if __FreeBSD__
#define __volatile volatile
#define __sync_synchronize()
#define __sync_swap(A, B) 1
#endif

#if _MSC_VER
#define _CRT_INSECURE_DEPRECATE(x)
#define _CRT_NONSTDC_NO_DEPRECATE 1
#define _CRT_SECURE_NO_WARNINGS 1
#define __ptr32
#define __ptr64
#define __unaligned
#define _NO_CRT_STDIO_INLINE 1
#define _stdcall __stdcall

// This header disables the Windows API Annotations macros
// Need to include sal.h to get the pragma once to prevent macro redefinition.
#include "sal.h"
#include "no_sal2.h"
#endif

/****************************
 * Define it to do what other C compilers do.
 */
#define __builtin_offsetof(t,i) ((typeof(sizeof(0)))((char *)&((t *)0)->i - (char *)0))

#define __builtin_bit_cast(t,e) (*(t*)(void*)&(e))

/***************************
 * C11 6.10.8.3 Conditional feature macros
 */
#define __STDC_NO_VLA__ 1

#if linux  // Microsoft won't allow the following macro
// Ubuntu's assert.h uses this
#define __PRETTY_FUNCTION__ __func__

#ifndef __aarch64__
#define _Float16 float
#define _Float32 float
#define _Float32x double
#define _Float64 double
#define _Float64x long double
#define _Float128 long double
#define __float128 long double
#endif
#endif

#if __APPLE__
#undef __SIZEOF_INT128__
#endif

// so that `size_t`, `NULL` and friends are always defined.
#include <stddef.h>
