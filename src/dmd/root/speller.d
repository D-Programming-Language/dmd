/**
 * Compiler implementation of the D programming language
 * http://dlang.org
 *
 * Copyright: Copyright (C) 1999-2019 by The D Language Foundation, All Rights Reserved
 * Authors:   Walter Bright, http://www.digitalmars.com
 * License:   $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:    $(LINK2 https://github.com/dlang/dmd/blob/master/src/dmd/root/speller.d, root/_speller.d)
 * Documentation:  https://dlang.org/phobos/dmd_root_speller.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/root/speller.d
 */

module dmd.root.speller;

import core.stdc.stdlib;
import core.stdc.string;

alias dg_speller_t = void* delegate(const(char)[], ref int);

immutable string idchars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_";

/**************************************************
 * combine a new result from the spell checker to
 * find the one with the closest symbol with
 * respect to the cost defined by the search function
 * Input/Output:
 *      p       best found spelling (NULL if none found yet)
 *      cost    cost of p (int.max if none found yet)
 * Input:
 *      np      new found spelling (NULL if none found)
 *      ncost   cost of np if non-NULL
 * Returns:
 *      true    if the cost is less or equal 0
 *      false   otherwise
 */
private bool combineSpellerResult(ref void* p, ref int cost, void* np, int ncost)
{
    if (np && ncost < cost)
    {
        p = np;
        cost = ncost;
        if (cost <= 0)
            return true;
    }
    return false;
}

private void* spellerY(const(char)* seed, size_t seedlen, dg_speller_t dg, size_t index, ref int cost)
{
    if (!seedlen)
        return null;
    assert(seed[seedlen] == 0);
    char[30] tmp;
    char* buf;
    if (seedlen <= tmp.sizeof - 2)
        buf = tmp.ptr;
    else
    {
        buf = cast(char*)alloca(seedlen + 2); // leave space for extra char
        if (!buf)
            return null; // no matches
    }
    buf[0 .. index] = seed[0 .. index];
    cost = int.max;
    void* p = null;
    int ncost;
    /* Delete at seed[index] */
    if (index < seedlen)
    {
        buf[index .. seedlen] = seed[index + 1 .. seedlen + 1];
        assert(buf[seedlen - 1] == 0);
        void* np = dg(buf[0 .. seedlen - 1], ncost);
        if (combineSpellerResult(p, cost, np, ncost))
            return p;
    }
    /* Substitutions */
    if (index < seedlen)
    {
        buf[0 .. seedlen + 1] = seed[0 .. seedlen + 1];
        foreach (s; idchars)
        {
            buf[index] = s;
            //printf("sub buf = '%s'\n", buf);
            void* np = dg(buf[0 .. seedlen], ncost);
            if (combineSpellerResult(p, cost, np, ncost))
                return p;
        }
        assert(buf[seedlen] == 0);
    }
    /* Insertions */
    buf[index + 1 .. seedlen + 2] = seed[index .. seedlen + 1];
    foreach (s; idchars)
    {
        buf[index] = s;
        //printf("ins buf = '%s'\n", buf);
        void* np = dg(buf[0 .. seedlen + 1], ncost);
        if (combineSpellerResult(p, cost, np, ncost))
            return p;
    }
    assert(buf[seedlen + 1] == 0);
    return p; // return "best" result
}

private void* spellerX(const(char)* seed, size_t seedlen, dg_speller_t dg, int flag)
{
    if (!seedlen)
        return null;
    char[30] tmp;
    char* buf;
    if (seedlen <= tmp.sizeof - 2)
        buf = tmp.ptr;
    else
    {
        buf = cast(char*)alloca(seedlen + 2); // leave space for extra char
        if (!buf)
            return null; // no matches
    }
    int cost = int.max, ncost;
    void* p = null, np;
    /* Deletions */
    buf[0 .. seedlen] = seed[1 .. seedlen + 1];
    for (size_t i = 0; i < seedlen; i++)
    {
        //printf("del buf = '%s'\n", buf);
        if (flag)
            np = spellerY(buf, seedlen - 1, dg, i, ncost);
        else
            np = dg(buf[0 .. seedlen - 1], ncost);
        if (combineSpellerResult(p, cost, np, ncost))
            return p;
        buf[i] = seed[i];
    }
    /* Transpositions */
    if (!flag)
    {
        buf[0 .. seedlen + 1] = seed[0 .. seedlen + 1];
        for (size_t i = 0; i + 1 < seedlen; i++)
        {
            // swap [i] and [i + 1]
            buf[i] = seed[i + 1];
            buf[i + 1] = seed[i];
            //printf("tra buf = '%s'\n", buf);
            if (combineSpellerResult(p, cost, dg(buf[0 .. seedlen], ncost), ncost))
                return p;
            buf[i] = seed[i];
        }
    }
    /* Substitutions */
    buf[0 .. seedlen + 1] = seed[0 .. seedlen + 1];
    for (size_t i = 0; i < seedlen; i++)
    {
        foreach (s; idchars)
        {
            buf[i] = s;
            //printf("sub buf = '%s'\n", buf);
            if (flag)
                np = spellerY(buf, seedlen, dg, i + 1, ncost);
            else
                np = dg(buf[0 .. seedlen], ncost);
            if (combineSpellerResult(p, cost, np, ncost))
                return p;
        }
        buf[i] = seed[i];
    }
    /* Insertions */
    buf[1 .. seedlen + 2] = seed[0 .. seedlen + 1];
    for (size_t i = 0; i <= seedlen; i++) // yes, do seedlen+1 iterations
    {
        foreach (s; idchars)
        {
            buf[i] = s;
            //printf("ins buf = '%s'\n", buf);
            if (flag)
                np = spellerY(buf, seedlen + 1, dg, i + 1, ncost);
            else
                np = dg(buf[0 .. seedlen + 1], ncost);
            if (combineSpellerResult(p, cost, np, ncost))
                return p;
        }
        buf[i] = seed[i]; // going past end of seed[] is ok, as we hit the 0
    }
    return p; // return "best" result
}

/**************************************************
 * Looks for correct spelling.
 * Currently only looks a 'distance' of one from the seed[].
 * This does an exhaustive search, so can potentially be very slow.
 * Params:
 *      seed = wrongly spelled word
 *      dg = search delegate
 * Returns:
 *      null = no correct spellings found, otherwise
 *      the value returned by dg() for first possible correct spelling
 */
void* speller(const(char)* seed, scope dg_speller_t dg)
{
    size_t seedlen = strlen(seed);
    size_t maxdist = seedlen < 4 ? seedlen / 2 : 2;
    for (int distance = 0; distance < maxdist; distance++)
    {
        void* p = spellerX(seed, seedlen, dg, distance);
        if (p)
            return p;
        //      if (seedlen > 10)
        //          break;
    }
    return null; // didn't find it
}

unittest
{
    static string[][] cases =
    [
        ["hello", "hell", "y"],
        ["hello", "hel", "y"],
        ["hello", "ello", "y"],
        ["hello", "llo", "y"],
        ["hello", "hellox", "y"],
        ["hello", "helloxy", "y"],
        ["hello", "xhello", "y"],
        ["hello", "xyhello", "y"],
        ["hello", "ehllo", "y"],
        ["hello", "helol", "y"],
        ["hello", "abcd", "n"],
        ["hello", "helxxlo", "y"],
        ["hello", "ehlxxlo", "n"],
        ["hello", "heaao", "y"],
        ["_123456789_123456789_123456789_123456789", "_123456789_123456789_123456789_12345678", "y"],
        [null, null, null]
    ];
    //printf("unittest_speller()\n");

    string dgarg;

    void* speller_test(const(char)[] s, ref int cost)
    {
        assert(s[$-1] != '\0');
        //printf("speller_test(%s, %s)\n", dgarg, s);
        cost = 0;
        if (dgarg == s)
            return cast(void*)dgarg;
        return null;
    }

    dgarg = "hell";
    const(void)* p = speller(cast(const(char)*)"hello", &speller_test);
    assert(p !is null);
    for (int i = 0; cases[i][0]; i++)
    {
        //printf("case [%d]\n", i);
        dgarg = cases[i][1];
        void* p2 = speller(cases[i][0].ptr, &speller_test);
        if (p2)
            assert(cases[i][2][0] == 'y');
        else
            assert(cases[i][2][0] == 'n');
    }
    //printf("unittest_speller() success\n");
}
