/**
 * Compiler implementation of the
 * $(LINK2 http://www.dlang.org, D programming language).
 *
 * Copyright:   Copyright (C) 1999-2018 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 http://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/src/dmd/doc.d, _doc.d)
 * Documentation:  https://dlang.org/phobos/dmd_doc.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/doc.d
 */

module dmd.doc;

import core.stdc.ctype;
import core.stdc.stdlib;
import core.stdc.stdio;
import core.stdc.string;
import core.stdc.time;
import dmd.aggregate;
import dmd.arraytypes;
import dmd.attrib;
import dmd.dclass;
import dmd.declaration;
import dmd.denum;
import dmd.dmacro;
import dmd.dmodule;
import dmd.dscope;
import dmd.dstruct;
import dmd.dsymbol;
import dmd.dsymbolsem;
import dmd.dtemplate;
import dmd.errors;
import dmd.func;
import dmd.globals;
import dmd.hdrgen;
import dmd.id;
import dmd.identifier;
import dmd.lexer;
import dmd.mtype;
import dmd.root.array;
import dmd.root.file;
import dmd.root.filename;
import dmd.root.outbuffer;
import dmd.root.port;
import dmd.root.rmem;
import dmd.tokens;
import dmd.utf;
import dmd.utils;
import dmd.visitor;

struct Escape
{
    const(char)*[256] strings;

    /***************************************
     * Find character string to replace c with.
     */
    extern (C++) const(char)* escapeChar(uint c)
    {
        version (all)
        {
            assert(c < 256);
            //printf("escapeChar('%c') => %p, %p\n", c, strings, strings[c]);
            return strings[c];
        }
        else
        {
            const(char)* s;
            switch (c)
            {
            case '<':
                s = "&lt;";
                break;
            case '>':
                s = "&gt;";
                break;
            case '&':
                s = "&amp;";
                break;
            default:
                s = null;
                break;
            }
            return s;
        }
    }
}

/***********************************************************
 */
extern (C++) class Section
{
    const(char)* name;
    size_t namelen;
    const(char)* _body;
    size_t bodylen;
    int nooutput;

    void write(Loc loc, DocComment* dc, Scope* sc, Dsymbols* a, OutBuffer* buf)
    {
        assert(a.dim);
        if (namelen)
        {
            static __gshared const(char)** table =
            [
                "AUTHORS",
                "BUGS",
                "COPYRIGHT",
                "DATE",
                "DEPRECATED",
                "EXAMPLES",
                "HISTORY",
                "LICENSE",
                "RETURNS",
                "SEE_ALSO",
                "STANDARDS",
                "THROWS",
                "VERSION",
                null
            ];
            for (size_t i = 0; table[i]; i++)
            {
                if (icmp(table[i], name, namelen) == 0)
                {
                    buf.printf("$(DDOC_%s ", table[i]);
                    goto L1;
                }
            }
            buf.writestring("$(DDOC_SECTION ");
            // Replace _ characters with spaces
            buf.writestring("$(DDOC_SECTION_H ");
            size_t o = buf.offset;
            for (size_t u = 0; u < namelen; u++)
            {
                char c = name[u];
                buf.writeByte((c == '_') ? ' ' : c);
            }
            escapeStrayParenthesis(loc, buf, o);
            buf.writestring(")");
        }
        else
        {
            buf.writestring("$(DDOC_DESCRIPTION ");
        }
    L1:
        size_t o = buf.offset;
        buf.write(_body, bodylen);
        escapeStrayParenthesis(loc, buf, o);
        highlightText(sc, a, buf, o);
        buf.writestring(")");
    }
}

/***********************************************************
 */
extern (C++) final class ParamSection : Section
{
    override void write(Loc loc, DocComment* dc, Scope* sc, Dsymbols* a, OutBuffer* buf)
    {
        assert(a.dim);
        Dsymbol s = (*a)[0]; // test
        const(char)* p = _body;
        size_t len = bodylen;
        const(char)* pend = p + len;
        const(char)* tempstart = null;
        size_t templen = 0;
        const(char)* namestart = null;
        size_t namelen = 0; // !=0 if line continuation
        const(char)* textstart = null;
        size_t textlen = 0;
        size_t paramcount = 0;
        buf.writestring("$(DDOC_PARAMS ");
        while (p < pend)
        {
            // Skip to start of macro
            while (1)
            {
                switch (*p)
                {
                case ' ':
                case '\t':
                    p++;
                    continue;
                case '\n':
                    p++;
                    goto Lcont;
                default:
                    if (isIdStart(p) || isCVariadicArg(p, pend - p))
                        break;
                    if (namelen)
                        goto Ltext;
                    // continuation of prev macro
                    goto Lskipline;
                }
                break;
            }
            tempstart = p;
            while (isIdTail(p))
                p += utfStride(p);
            if (isCVariadicArg(p, pend - p))
                p += 3;
            templen = p - tempstart;
            while (*p == ' ' || *p == '\t')
                p++;
            if (*p != '=')
            {
                if (namelen)
                    goto Ltext;
                // continuation of prev macro
                goto Lskipline;
            }
            p++;
            if (namelen)
            {
                // Output existing param
            L1:
                //printf("param '%.*s' = '%.*s'\n", namelen, namestart, textlen, textstart);
                ++paramcount;
                HdrGenState hgs;
                buf.writestring("$(DDOC_PARAM_ROW ");
                {
                    buf.writestring("$(DDOC_PARAM_ID ");
                    {
                        size_t o = buf.offset;
                        Parameter fparam = isFunctionParameter(a, namestart, namelen);
                        if (!fparam)
                        {
                            // Comments on a template might refer to function parameters within.
                            // Search the parameters of nested eponymous functions (with the same name.)
                            fparam = isEponymousFunctionParameter(a, namestart, namelen);
                        }
                        bool isCVariadic = isCVariadicParameter(a, namestart, namelen);
                        if (isCVariadic)
                        {
                            buf.writestring("...");
                        }
                        else if (fparam && fparam.type && fparam.ident)
                        {
                            .toCBuffer(fparam.type, buf, fparam.ident, &hgs);
                        }
                        else
                        {
                            if (isTemplateParameter(a, namestart, namelen))
                            {
                                // 10236: Don't count template parameters for params check
                                --paramcount;
                            }
                            else if (!fparam)
                            {
                                warning(s.loc, "Ddoc: function declaration has no parameter '%.*s'", namelen, namestart);
                            }
                            buf.write(namestart, namelen);
                        }
                        escapeStrayParenthesis(loc, buf, o);
                        highlightCode(sc, a, buf, o);
                    }
                    buf.writestring(")");
                    buf.writestring("$(DDOC_PARAM_DESC ");
                    {
                        size_t o = buf.offset;
                        buf.write(textstart, textlen);
                        escapeStrayParenthesis(loc, buf, o);
                        highlightText(sc, a, buf, o);
                    }
                    buf.writestring(")");
                }
                buf.writestring(")");
                namelen = 0;
                if (p >= pend)
                    break;
            }
            namestart = tempstart;
            namelen = templen;
            while (*p == ' ' || *p == '\t')
                p++;
            textstart = p;
        Ltext:
            while (*p != '\n')
                p++;
            textlen = p - textstart;
            p++;
        Lcont:
            continue;
        Lskipline:
            // Ignore this line
            while (*p++ != '\n')
            {
            }
        }
        if (namelen)
            goto L1;
        // write out last one
        buf.writestring(")");
        TypeFunction tf = a.dim == 1 ? isTypeFunction(s) : null;
        if (tf)
        {
            size_t pcount = (tf.parameters ? tf.parameters.dim : 0) + cast(int)(tf.varargs == 1);
            if (pcount != paramcount)
            {
                warning(s.loc, "Ddoc: parameter count mismatch");
            }
        }
    }
}

/***********************************************************
 */
extern (C++) final class MacroSection : Section
{
    override void write(Loc loc, DocComment* dc, Scope* sc, Dsymbols* a, OutBuffer* buf)
    {
        //printf("MacroSection::write()\n");
        DocComment.parseMacros(dc.pescapetable, dc.pmacrotable, _body, bodylen);
    }
}

alias Sections = Array!(Section);

// Workaround for missing Parameter instance for variadic params. (it's unnecessary to instantiate one).
extern (C++) bool isCVariadicParameter(Dsymbols* a, const(char)* p, size_t len)
{
    for (size_t i = 0; i < a.dim; i++)
    {
        TypeFunction tf = isTypeFunction((*a)[i]);
        if (tf && tf.varargs == 1 && cmp("...", p, len) == 0)
            return true;
    }
    return false;
}

private Dsymbol getEponymousMember(TemplateDeclaration td)
{
    if (!td.onemember)
        return null;
    if (AggregateDeclaration ad = td.onemember.isAggregateDeclaration())
        return ad;
    if (FuncDeclaration fd = td.onemember.isFuncDeclaration())
        return fd;
    if (auto em = td.onemember.isEnumMember())
        return null;    // Keep backward compatibility. See compilable/ddoc9.d
    if (VarDeclaration vd = td.onemember.isVarDeclaration())
        return td.constraint ? null : vd;
    return null;
}

private TemplateDeclaration getEponymousParent(Dsymbol s)
{
    if (!s.parent)
        return null;
    TemplateDeclaration td = s.parent.isTemplateDeclaration();
    return (td && getEponymousMember(td)) ? td : null;
}

extern (C++) __gshared const(char)* ddoc_default = import("default_ddoc_theme.ddoc");
extern (C++) __gshared const(char)* ddoc_decl_s = "$(DDOC_DECL ";
extern (C++) __gshared const(char)* ddoc_decl_e = ")\n";
extern (C++) __gshared const(char)* ddoc_decl_dd_s = "$(DDOC_DECL_DD ";
extern (C++) __gshared const(char)* ddoc_decl_dd_e = ")\n";

/****************************************************
 */
extern (C++) void gendocfile(Module m)
{
    static __gshared OutBuffer mbuf;
    static __gshared int mbuf_done;
    OutBuffer buf;
    //printf("Module::gendocfile()\n");
    if (!mbuf_done) // if not already read the ddoc files
    {
        mbuf_done = 1;
        // Use our internal default
        mbuf.write(ddoc_default, strlen(ddoc_default));
        // Override with DDOCFILE specified in the sc.ini file
        char* p = getenv("DDOCFILE");
        if (p)
            global.params.ddocfiles.shift(p);
        // Override with the ddoc macro files from the command line
        for (size_t i = 0; i < global.params.ddocfiles.dim; i++)
        {
            auto f = FileName(global.params.ddocfiles[i]);
            auto file = File(&f);
            readFile(m.loc, &file);
            // BUG: convert file contents to UTF-8 before use
            //printf("file: '%.*s'\n", file.len, file.buffer);
            mbuf.write(file.buffer, file.len);
        }
    }
    DocComment.parseMacros(&m.escapetable, &m.macrotable, mbuf.peekSlice().ptr, mbuf.peekSlice().length);
    Scope* sc = Scope.createGlobal(m); // create root scope
    DocComment* dc = DocComment.parse(m, m.comment);
    dc.pmacrotable = &m.macrotable;
    dc.pescapetable = &m.escapetable;
    sc.lastdc = dc;
    // Generate predefined macros
    // Set the title to be the name of the module
    {
        const(char)* p = m.toPrettyChars();
        Macro.define(&m.macrotable, "TITLE", p[0 .. strlen(p)]);
    }
    // Set time macros
    {
        time_t t;
        time(&t);
        char* p = ctime(&t);
        p = mem.xstrdup(p);
        Macro.define(&m.macrotable, "DATETIME", p[0 .. strlen(p)]);
        Macro.define(&m.macrotable, "YEAR", p[20 .. 20 + 4]);
    }
    const srcfilename = m.srcfile.toChars();
    Macro.define(&m.macrotable, "SRCFILENAME", srcfilename[0 .. strlen(srcfilename)]);
    const docfilename = m.docfile.toChars();
    Macro.define(&m.macrotable, "DOCFILENAME", docfilename[0 .. strlen(docfilename)]);
    if (dc.copyright)
    {
        dc.copyright.nooutput = 1;
        Macro.define(&m.macrotable, "COPYRIGHT", dc.copyright._body[0 .. dc.copyright.bodylen]);
    }
    if (m.isDocFile)
    {
        Loc loc = m.md ? m.md.loc : m.loc;
        size_t commentlen = strlen(cast(char*)m.comment);
        Dsymbols a;
        // https://issues.dlang.org/show_bug.cgi?id=9764
        // Don't push m in a, to prevent emphasize ddoc file name.
        if (dc.macros)
        {
            commentlen = dc.macros.name - m.comment;
            dc.macros.write(loc, dc, sc, &a, &buf);
        }
        buf.write(m.comment, commentlen);
        highlightText(sc, &a, &buf, 0);
    }
    else
    {
        Dsymbols a;
        a.push(m);
        dc.writeSections(sc, &a, &buf);
        emitMemberComments(m, &buf, sc);
    }
    //printf("BODY= '%.*s'\n", buf.offset, buf.data);
    Macro.define(&m.macrotable, "BODY", buf.peekSlice());
    OutBuffer buf2;
    buf2.writestring("$(DDOC)");
    size_t end = buf2.offset;
    m.macrotable.expand(&buf2, 0, &end, null);
    version (all)
    {
        /* Remove all the escape sequences from buf2,
         * and make CR-LF the newline.
         */
        {
            const slice = buf2.peekSlice();
            buf.setsize(0);
            buf.reserve(slice.length);
            auto p = slice.ptr;
            for (size_t j = 0; j < slice.length; j++)
            {
                char c = p[j];
                if (c == 0xFF && j + 1 < slice.length)
                {
                    j++;
                    continue;
                }
                if (c == '\n')
                    buf.writeByte('\r');
                else if (c == '\r')
                {
                    buf.writestring("\r\n");
                    if (j + 1 < slice.length && p[j + 1] == '\n')
                    {
                        j++;
                    }
                    continue;
                }
                buf.writeByte(c);
            }
        }
        // Transfer image to file
        assert(m.docfile);
        m.docfile.setbuffer(cast(void*)buf.peekSlice().ptr, buf.peekSlice().length);
        m.docfile._ref = 1;
        ensurePathToNameExists(Loc.initial, m.docfile.toChars());
        writeFile(m.loc, m.docfile);
    }
    else
    {
        /* Remove all the escape sequences from buf2
         */
        {
            size_t i = 0;
            char* p = buf2.data;
            for (size_t j = 0; j < buf2.offset; j++)
            {
                if (p[j] == 0xFF && j + 1 < buf2.offset)
                {
                    j++;
                    continue;
                }
                p[i] = p[j];
                i++;
            }
            buf2.setsize(i);
        }
        // Transfer image to file
        m.docfile.setbuffer(buf2.data, buf2.offset);
        m.docfile._ref = 1;
        ensurePathToNameExists(Loc.initial, m.docfile.toChars());
        writeFile(m.loc, m.docfile);
    }
}

/****************************************************
 * Having unmatched parentheses can hose the output of Ddoc,
 * as the macros depend on properly nested parentheses.
 * This function replaces all ( with $(LPAREN) and ) with $(RPAREN)
 * to preserve text literally. This also means macros in the
 * text won't be expanded.
 */
extern (C++) void escapeDdocString(OutBuffer* buf, size_t start)
{
    for (size_t u = start; u < buf.offset; u++)
    {
        char c = buf.data[u];
        switch (c)
        {
        case '$':
            buf.remove(u, 1);
            buf.insert(u, "$(DOLLAR)");
            u += 8;
            break;
        case '(':
            buf.remove(u, 1); //remove the (
            buf.insert(u, "$(LPAREN)"); //insert this instead
            u += 8; //skip over newly inserted macro
            break;
        case ')':
            buf.remove(u, 1); //remove the )
            buf.insert(u, "$(RPAREN)"); //insert this instead
            u += 8; //skip over newly inserted macro
            break;
        default:
            break;
        }
    }
}

/****************************************************
 * Having unmatched parentheses can hose the output of Ddoc,
 * as the macros depend on properly nested parentheses.
 *
 * Fix by replacing unmatched ( with $(LPAREN) and unmatched ) with $(RPAREN).
 */
extern (C++) void escapeStrayParenthesis(Loc loc, OutBuffer* buf, size_t start)
{
    uint par_open = 0;
    bool inCode = 0;
    for (size_t u = start; u < buf.offset; u++)
    {
        char c = buf.data[u];
        switch (c)
        {
        case '(':
            if (!inCode)
                par_open++;
            break;
        case ')':
            if (!inCode)
            {
                if (par_open == 0)
                {
                    //stray ')'
                    warning(loc, "Ddoc: Stray ')'. This may cause incorrect Ddoc output. Use $(RPAREN) instead for unpaired right parentheses.");
                    buf.remove(u, 1); //remove the )
                    buf.insert(u, "$(RPAREN)"); //insert this instead
                    u += 8; //skip over newly inserted macro
                }
                else
                    par_open--;
            }
            break;
            version (none)
            {
                // For this to work, loc must be set to the beginning of the passed
                // text which is currently not possible
                // (loc is set to the Loc of the Dsymbol)
            case '\n':
                loc.linnum++;
                break;
            }
        case '-':
            // Issue 15465: don't try to escape unbalanced parens inside code
            // blocks.
            int numdash = 0;
            while (u < buf.offset && buf.data[u] == '-')
            {
                numdash++;
                u++;
            }
            if (numdash >= 3)
                inCode = !inCode;
            break;
        default:
            break;
        }
    }
    if (par_open) // if any unmatched lparens
    {
        par_open = 0;
        for (size_t u = buf.offset; u > start;)
        {
            u--;
            char c = buf.data[u];
            switch (c)
            {
            case ')':
                par_open++;
                break;
            case '(':
                if (par_open == 0)
                {
                    //stray '('
                    warning(loc, "Ddoc: Stray '('. This may cause incorrect Ddoc output. Use $(LPAREN) instead for unpaired left parentheses.");
                    buf.remove(u, 1); //remove the (
                    buf.insert(u, "$(LPAREN)"); //insert this instead
                }
                else
                    par_open--;
                break;
            default:
                break;
            }
        }
    }
}

// Basically, this is to skip over things like private{} blocks in a struct or
// class definition that don't add any components to the qualified name.
private Scope* skipNonQualScopes(Scope* sc)
{
    while (sc && !sc.scopesym)
        sc = sc.enclosing;
    return sc;
}

private bool emitAnchorName(OutBuffer* buf, Dsymbol s, Scope* sc, bool includeParent)
{
    if (!s || s.isPackage() || s.isModule())
        return false;
    // Add parent names first
    bool dot = false;
    auto eponymousParent = getEponymousParent(s);
    if (includeParent && s.parent || eponymousParent)
        dot = emitAnchorName(buf, s.parent, sc, includeParent);
    else if (includeParent && sc)
        dot = emitAnchorName(buf, sc.scopesym, skipNonQualScopes(sc.enclosing), includeParent);
    // Eponymous template members can share the parent anchor name
    if (eponymousParent)
        return dot;
    if (dot)
        buf.writeByte('.');
    // Use "this" not "__ctor"
    TemplateDeclaration td;
    if (s.isCtorDeclaration() || ((td = s.isTemplateDeclaration()) !is null && td.onemember && td.onemember.isCtorDeclaration()))
    {
        buf.writestring("this");
    }
    else
    {
        /* We just want the identifier, not overloads like TemplateDeclaration::toChars.
         * We don't want the template parameter list and constraints. */
        buf.writestring(s.Dsymbol.toChars());
    }
    return true;
}

private void emitAnchor(OutBuffer* buf, Dsymbol s, Scope* sc, bool forHeader = false)
{
    Identifier ident;
    {
        OutBuffer anc;
        emitAnchorName(&anc, s, skipNonQualScopes(sc), true);
        ident = Identifier.idPool(anc.peekSlice());
    }

    auto pcount = cast(void*)ident in sc.anchorCounts;
    typeof(*pcount) count;
    if (!forHeader)
    {
        if (pcount)
        {
            // Existing anchor,
            // don't write an anchor for matching consecutive ditto symbols
            TemplateDeclaration td = getEponymousParent(s);
            if (sc.prevAnchor == ident && sc.lastdc && (isDitto(s.comment) || (td && isDitto(td.comment))))
                return;

            count = ++*pcount;
        }
        else
        {
            sc.anchorCounts[cast(void*)ident] = 1;
            count = 1;
        }
    }

    // cache anchor name
    sc.prevAnchor = ident;
    auto macroName = forHeader ? "DDOC_HEADER_ANCHOR" : "DDOC_ANCHOR";
    auto symbolName = ident.toString();
    buf.printf("$(%.*s %.*s", cast(int) macroName.length, macroName.ptr,
        cast(int) symbolName.length, symbolName.ptr);
    // only append count once there's a duplicate
    if (count > 1)
        buf.printf(".%u", count);

    if (forHeader)
    {
        Identifier shortIdent;
        {
            OutBuffer anc;
            emitAnchorName(&anc, s, skipNonQualScopes(sc), false);
            shortIdent = Identifier.idPool(anc.peekSlice());
        }

        auto shortName = shortIdent.toString();
        buf.printf(", %.*s", cast(int) shortName.length, shortName.ptr);
    }

    buf.writeByte(')');
}

/******************************* emitComment **********************************/

/** Get leading indentation from 'src' which represents lines of code. */
private size_t getCodeIndent(const(char)* src)
{
    while (src && (*src == '\r' || *src == '\n'))
        ++src; // skip until we find the first non-empty line
    size_t codeIndent = 0;
    while (src && (*src == ' ' || *src == '\t'))
    {
        codeIndent++;
        src++;
    }
    return codeIndent;
}

/** Recursively expand template mixin member docs into the scope. */
private void expandTemplateMixinComments(TemplateMixin tm, OutBuffer* buf, Scope* sc)
{
    if (!tm.semanticRun)
        tm.dsymbolSemantic(sc);
    TemplateDeclaration td = (tm && tm.tempdecl) ? tm.tempdecl.isTemplateDeclaration() : null;
    if (td && td.members)
    {
        for (size_t i = 0; i < td.members.dim; i++)
        {
            Dsymbol sm = (*td.members)[i];
            TemplateMixin tmc = sm.isTemplateMixin();
            if (tmc && tmc.comment)
                expandTemplateMixinComments(tmc, buf, sc);
            else
                emitComment(sm, buf, sc);
        }
    }
}

private void emitMemberComments(ScopeDsymbol sds, OutBuffer* buf, Scope* sc)
{
    if (!sds.members)
        return;
    //printf("ScopeDsymbol::emitMemberComments() %s\n", toChars());
    const(char)* m = "$(DDOC_MEMBERS ";
    if (sds.isTemplateDeclaration())
        m = "$(DDOC_TEMPLATE_MEMBERS ";
    else if (sds.isClassDeclaration())
        m = "$(DDOC_CLASS_MEMBERS ";
    else if (sds.isStructDeclaration())
        m = "$(DDOC_STRUCT_MEMBERS ";
    else if (sds.isEnumDeclaration())
        m = "$(DDOC_ENUM_MEMBERS ";
    else if (sds.isModule())
        m = "$(DDOC_MODULE_MEMBERS ";
    size_t offset1 = buf.offset; // save starting offset
    buf.writestring(m);
    size_t offset2 = buf.offset; // to see if we write anything
    sc = sc.push(sds);
    for (size_t i = 0; i < sds.members.dim; i++)
    {
        Dsymbol s = (*sds.members)[i];
        //printf("\ts = '%s'\n", s.toChars());
        // only expand if parent is a non-template (semantic won't work)
        if (s.comment && s.isTemplateMixin() && s.parent && !s.parent.isTemplateDeclaration())
            expandTemplateMixinComments(cast(TemplateMixin)s, buf, sc);
        emitComment(s, buf, sc);
    }
    emitComment(null, buf, sc);
    sc.pop();
    if (buf.offset == offset2)
    {
        /* Didn't write out any members, so back out last write
         */
        buf.offset = offset1;
    }
    else
        buf.writestring(")");
}

extern (C++) void emitProtection(OutBuffer* buf, Prot prot)
{
    if (prot.kind != Prot.Kind.undefined && prot.kind != Prot.Kind.public_)
    {
        protectionToBuffer(buf, prot);
        buf.writeByte(' ');
    }
}

private void emitComment(Dsymbol s, OutBuffer* buf, Scope* sc)
{
    extern (C++) final class EmitComment : Visitor
    {
        alias visit = Visitor.visit;
    public:
        OutBuffer* buf;
        Scope* sc;

        extern (D) this(OutBuffer* buf, Scope* sc)
        {
            this.buf = buf;
            this.sc = sc;
        }

        override void visit(Dsymbol)
        {
        }

        override void visit(InvariantDeclaration)
        {
        }

        override void visit(UnitTestDeclaration)
        {
        }

        override void visit(PostBlitDeclaration)
        {
        }

        override void visit(DtorDeclaration)
        {
        }

        override void visit(StaticCtorDeclaration)
        {
        }

        override void visit(StaticDtorDeclaration)
        {
        }

        override void visit(TypeInfoDeclaration)
        {
        }

        void emit(Scope* sc, Dsymbol s, const(char)* com)
        {
            if (s && sc.lastdc && isDitto(com))
            {
                sc.lastdc.a.push(s);
                return;
            }
            // Put previous doc comment if exists
            if (DocComment* dc = sc.lastdc)
            {
                assert(dc.a.dim > 0, "Expects at least one declaration for a" ~
                    "documentation comment");

                auto symbol = dc.a[0];

                buf.writestring("$(DDOC_MEMBER");
                buf.writestring("$(DDOC_MEMBER_HEADER");
                emitAnchor(buf, symbol, sc, true);
                buf.writeByte(')');

                // Put the declaration signatures as the document 'title'
                buf.writestring(ddoc_decl_s);
                for (size_t i = 0; i < dc.a.dim; i++)
                {
                    Dsymbol sx = dc.a[i];
                    // the added linebreaks in here make looking at multiple
                    // signatures more appealing
                    if (i == 0)
                    {
                        size_t o = buf.offset;
                        toDocBuffer(sx, buf, sc);
                        highlightCode(sc, sx, buf, o);
                        buf.writestring("$(DDOC_OVERLOAD_SEPARATOR)");
                        continue;
                    }
                    buf.writestring("$(DDOC_DITTO ");
                    {
                        size_t o = buf.offset;
                        toDocBuffer(sx, buf, sc);
                        highlightCode(sc, sx, buf, o);
                    }
                    buf.writestring("$(DDOC_OVERLOAD_SEPARATOR)");
                    buf.writeByte(')');
                }
                buf.writestring(ddoc_decl_e);
                // Put the ddoc comment as the document 'description'
                buf.writestring(ddoc_decl_dd_s);
                {
                    dc.writeSections(sc, &dc.a, buf);
                    if (ScopeDsymbol sds = dc.a[0].isScopeDsymbol())
                        emitMemberComments(sds, buf, sc);
                }
                buf.writestring(ddoc_decl_dd_e);
                buf.writeByte(')');
                //printf("buf.2 = [[%.*s]]\n", buf.offset - o0, buf.data + o0);
            }
            if (s)
            {
                DocComment* dc = DocComment.parse(s, com);
                dc.pmacrotable = &sc._module.macrotable;
                sc.lastdc = dc;
            }
        }

        override void visit(Declaration d)
        {
            //printf("Declaration::emitComment(%p '%s'), comment = '%s'\n", d, d.toChars(), d.comment);
            //printf("type = %p\n", d.type);
            const(char)* com = d.comment;
            if (TemplateDeclaration td = getEponymousParent(d))
            {
                if (isDitto(td.comment))
                    com = td.comment;
                else
                    com = Lexer.combineComments(td.comment, com, true);
            }
            else
            {
                if (!d.ident)
                    return;
                if (!d.type)
                {
                    if (!d.isCtorDeclaration() &&
                        !d.isAliasDeclaration() &&
                        !d.isVarDeclaration())
                    {
                        return;
                    }
                }
                if (d.protection.kind == Prot.Kind.private_ || sc.protection.kind == Prot.Kind.private_)
                    return;
            }
            if (!com)
                return;
            emit(sc, d, com);
        }

        override void visit(AggregateDeclaration ad)
        {
            //printf("AggregateDeclaration::emitComment() '%s'\n", ad.toChars());
            const(char)* com = ad.comment;
            if (TemplateDeclaration td = getEponymousParent(ad))
            {
                if (isDitto(td.comment))
                    com = td.comment;
                else
                    com = Lexer.combineComments(td.comment, com, true);
            }
            else
            {
                if (ad.prot().kind == Prot.Kind.private_ || sc.protection.kind == Prot.Kind.private_)
                    return;
                if (!ad.comment)
                    return;
            }
            if (!com)
                return;
            emit(sc, ad, com);
        }

        override void visit(TemplateDeclaration td)
        {
            //printf("TemplateDeclaration::emitComment() '%s', kind = %s\n", td.toChars(), td.kind());
            if (td.prot().kind == Prot.Kind.private_ || sc.protection.kind == Prot.Kind.private_)
                return;
            if (!td.comment)
                return;
            if (Dsymbol ss = getEponymousMember(td))
            {
                ss.accept(this);
                return;
            }
            emit(sc, td, td.comment);
        }

        override void visit(EnumDeclaration ed)
        {
            if (ed.prot().kind == Prot.Kind.private_ || sc.protection.kind == Prot.Kind.private_)
                return;
            if (ed.isAnonymous() && ed.members)
            {
                for (size_t i = 0; i < ed.members.dim; i++)
                {
                    Dsymbol s = (*ed.members)[i];
                    emitComment(s, buf, sc);
                }
                return;
            }
            if (!ed.comment)
                return;
            if (ed.isAnonymous())
                return;
            emit(sc, ed, ed.comment);
        }

        override void visit(EnumMember em)
        {
            //printf("EnumMember::emitComment(%p '%s'), comment = '%s'\n", em, em.toChars(), em.comment);
            if (em.prot().kind == Prot.Kind.private_ || sc.protection.kind == Prot.Kind.private_)
                return;
            if (!em.comment)
                return;
            emit(sc, em, em.comment);
        }

        override void visit(AttribDeclaration ad)
        {
            //printf("AttribDeclaration::emitComment(sc = %p)\n", sc);
            /* A general problem with this,
             * illustrated by https://issues.dlang.org/show_bug.cgi?id=2516
             * is that attributes are not transmitted through to the underlying
             * member declarations for template bodies, because semantic analysis
             * is not done for template declaration bodies
             * (only template instantiations).
             * Hence, Ddoc omits attributes from template members.
             */
            Dsymbols* d = ad.include(null);
            if (d)
            {
                for (size_t i = 0; i < d.dim; i++)
                {
                    Dsymbol s = (*d)[i];
                    //printf("AttribDeclaration::emitComment %s\n", s.toChars());
                    emitComment(s, buf, sc);
                }
            }
        }

        override void visit(ProtDeclaration pd)
        {
            if (pd.decl)
            {
                Scope* scx = sc;
                sc = sc.copy();
                sc.protection = pd.protection;
                visit(cast(AttribDeclaration)pd);
                scx.lastdc = sc.lastdc;
                sc = sc.pop();
            }
        }

        override void visit(ConditionalDeclaration cd)
        {
            //printf("ConditionalDeclaration::emitComment(sc = %p)\n", sc);
            if (cd.condition.inc)
            {
                visit(cast(AttribDeclaration)cd);
                return;
            }
            /* If generating doc comment, be careful because if we're inside
             * a template, then include(null) will fail.
             */
            Dsymbols* d = cd.decl ? cd.decl : cd.elsedecl;
            for (size_t i = 0; i < d.dim; i++)
            {
                Dsymbol s = (*d)[i];
                emitComment(s, buf, sc);
            }
        }
    }

    scope EmitComment v = new EmitComment(buf, sc);
    if (!s)
        v.emit(sc, null, null);
    else
        s.accept(v);
}

private void toDocBuffer(Dsymbol s, OutBuffer* buf, Scope* sc)
{
    extern (C++) final class ToDocBuffer : Visitor
    {
        alias visit = Visitor.visit;
    public:
        OutBuffer* buf;
        Scope* sc;

        extern (D) this(OutBuffer* buf, Scope* sc)
        {
            this.buf = buf;
            this.sc = sc;
        }

        override void visit(Dsymbol s)
        {
            //printf("Dsymbol::toDocbuffer() %s\n", s.toChars());
            HdrGenState hgs;
            hgs.ddoc = true;
            .toCBuffer(s, buf, &hgs);
        }

        void prefix(Dsymbol s)
        {
            if (s.isDeprecated())
                buf.writestring("deprecated ");
            if (Declaration d = s.isDeclaration())
            {
                emitProtection(buf, d.protection);
                if (d.isStatic())
                    buf.writestring("static ");
                else if (d.isFinal())
                    buf.writestring("final ");
                else if (d.isAbstract())
                    buf.writestring("abstract ");

                if (d.isFuncDeclaration())      // functionToBufferFull handles this
                    return;

                if (d.isImmutable())
                    buf.writestring("immutable ");
                if (d.storage_class & STC.shared_)
                    buf.writestring("shared ");
                if (d.isWild())
                    buf.writestring("inout ");
                if (d.isConst())
                    buf.writestring("const ");

                if (d.isSynchronized())
                    buf.writestring("synchronized ");

                if (d.storage_class & STC.manifest)
                    buf.writestring("enum ");

                // Add "auto" for the untyped variable in template members
                if (!d.type && d.isVarDeclaration() &&
                    !d.isImmutable() && !(d.storage_class & STC.shared_) && !d.isWild() && !d.isConst() &&
                    !d.isSynchronized())
                {
                    buf.writestring("auto ");
                }
            }
        }

        override void visit(Declaration d)
        {
            if (!d.ident)
                return;
            TemplateDeclaration td = getEponymousParent(d);
            //printf("Declaration::toDocbuffer() %s, originalType = %s, td = %s\n", d.toChars(), d.originalType ? d.originalType.toChars() : "--", td ? td.toChars() : "--");
            HdrGenState hgs;
            hgs.ddoc = true;
            if (d.isDeprecated())
                buf.writestring("$(DEPRECATED ");
            prefix(d);
            if (d.type)
            {
                Type origType = d.originalType ? d.originalType : d.type;
                if (origType.ty == Tfunction)
                {
                    functionToBufferFull(cast(TypeFunction)origType, buf, d.ident, &hgs, td);
                }
                else
                    .toCBuffer(origType, buf, d.ident, &hgs);
            }
            else
                buf.writestring(d.ident.toChars());
            if (d.isVarDeclaration() && td)
            {
                buf.writeByte('(');
                if (td.origParameters && td.origParameters.dim)
                {
                    for (size_t i = 0; i < td.origParameters.dim; i++)
                    {
                        if (i)
                            buf.writestring(", ");
                        toCBuffer((*td.origParameters)[i], buf, &hgs);
                    }
                }
                buf.writeByte(')');
            }
            // emit constraints if declaration is a templated declaration
            if (td && td.constraint)
            {
                bool noFuncDecl = td.isFuncDeclaration() is null;
                if (noFuncDecl)
                {
                    buf.writestring("$(DDOC_CONSTRAINT ");
                }

                .toCBuffer(td.constraint, buf, &hgs);

                if (noFuncDecl)
                {
                    buf.writestring(")");
                }
            }
            if (d.isDeprecated())
                buf.writestring(")");
            buf.writestring(";\n");
        }

        override void visit(AliasDeclaration ad)
        {
            //printf("AliasDeclaration::toDocbuffer() %s\n", ad.toChars());
            if (!ad.ident)
                return;
            if (ad.isDeprecated())
                buf.writestring("deprecated ");
            emitProtection(buf, ad.protection);
            buf.printf("alias %s = ", ad.toChars());
            if (Dsymbol s = ad.aliassym) // ident alias
            {
                prettyPrintDsymbol(s, ad.parent);
            }
            else if (Type type = ad.getType()) // type alias
            {
                if (type.ty == Tclass || type.ty == Tstruct || type.ty == Tenum)
                {
                    if (Dsymbol s = type.toDsymbol(null)) // elaborate type
                        prettyPrintDsymbol(s, ad.parent);
                    else
                        buf.writestring(type.toChars());
                }
                else
                {
                    // simple type
                    buf.writestring(type.toChars());
                }
            }
            buf.writestring(";\n");
        }

        void parentToBuffer(Dsymbol s)
        {
            if (s && !s.isPackage() && !s.isModule())
            {
                parentToBuffer(s.parent);
                buf.writestring(s.toChars());
                buf.writestring(".");
            }
        }

        static bool inSameModule(Dsymbol s, Dsymbol p)
        {
            for (; s; s = s.parent)
            {
                if (s.isModule())
                    break;
            }
            for (; p; p = p.parent)
            {
                if (p.isModule())
                    break;
            }
            return s == p;
        }

        void prettyPrintDsymbol(Dsymbol s, Dsymbol parent)
        {
            if (s.parent && (s.parent == parent)) // in current scope -> naked name
            {
                buf.writestring(s.toChars());
            }
            else if (!inSameModule(s, parent)) // in another module -> full name
            {
                buf.writestring(s.toPrettyChars());
            }
            else // nested in a type in this module -> full name w/o module name
            {
                // if alias is nested in a user-type use module-scope lookup
                if (!parent.isModule() && !parent.isPackage())
                    buf.writestring(".");
                parentToBuffer(s.parent);
                buf.writestring(s.toChars());
            }
        }

        override void visit(AggregateDeclaration ad)
        {
            if (!ad.ident)
                return;
            version (none)
            {
                emitProtection(buf, ad.protection);
            }
            buf.printf("%s %s", ad.kind(), ad.toChars());
            buf.writestring(";\n");
        }

        override void visit(StructDeclaration sd)
        {
            //printf("StructDeclaration::toDocbuffer() %s\n", sd.toChars());
            if (!sd.ident)
                return;
            version (none)
            {
                emitProtection(buf, sd.protection);
            }
            if (TemplateDeclaration td = getEponymousParent(sd))
            {
                toDocBuffer(td, buf, sc);
            }
            else
            {
                buf.printf("%s %s", sd.kind(), sd.toChars());
            }
            buf.writestring(";\n");
        }

        override void visit(ClassDeclaration cd)
        {
            //printf("ClassDeclaration::toDocbuffer() %s\n", cd.toChars());
            if (!cd.ident)
                return;
            version (none)
            {
                emitProtection(buf, cd.protection);
            }
            if (TemplateDeclaration td = getEponymousParent(cd))
            {
                toDocBuffer(td, buf, sc);
            }
            else
            {
                if (!cd.isInterfaceDeclaration() && cd.isAbstract())
                    buf.writestring("abstract ");
                buf.printf("%s %s", cd.kind(), cd.toChars());
            }
            int any = 0;
            for (size_t i = 0; i < cd.baseclasses.dim; i++)
            {
                BaseClass* bc = (*cd.baseclasses)[i];
                if (bc.sym && bc.sym.ident == Id.Object)
                    continue;
                if (any)
                    buf.writestring(", ");
                else
                {
                    buf.writestring(": ");
                    any = 1;
                }
                emitProtection(buf, Prot(Prot.Kind.public_));
                if (bc.sym)
                {
                    buf.printf("$(DDOC_PSUPER_SYMBOL %s)", bc.sym.toPrettyChars());
                }
                else
                {
                    HdrGenState hgs;
                    .toCBuffer(bc.type, buf, null, &hgs);
                }
            }
            buf.writestring(";\n");
        }

        override void visit(EnumDeclaration ed)
        {
            if (!ed.ident)
                return;
            buf.printf("%s %s", ed.kind(), ed.toChars());
            if (ed.memtype)
            {
                buf.writestring(": $(DDOC_ENUM_BASETYPE ");
                HdrGenState hgs;
                .toCBuffer(ed.memtype, buf, null, &hgs);
                buf.writestring(")");
            }
            buf.writestring(";\n");
        }

        override void visit(EnumMember em)
        {
            if (!em.ident)
                return;
            buf.writestring(em.toChars());
        }
    }

    scope ToDocBuffer v = new ToDocBuffer(buf, sc);
    s.accept(v);
}

/***********************************************************
 */
struct DocComment
{
    Sections sections;      // Section*[]
    Section summary;
    Section copyright;
    Section macros;
    Macro** pmacrotable;
    Escape** pescapetable;
    Dsymbols a;

    extern (C++) static DocComment* parse(Dsymbol s, const(char)* comment)
    {
        //printf("parse(%s): '%s'\n", s.toChars(), comment);
        auto dc = new DocComment();
        dc.a.push(s);
        if (!comment)
            return dc;
        dc.parseSections(comment);
        for (size_t i = 0; i < dc.sections.dim; i++)
        {
            Section sec = dc.sections[i];
            if (icmp("copyright", sec.name, sec.namelen) == 0)
            {
                dc.copyright = sec;
            }
            if (icmp("macros", sec.name, sec.namelen) == 0)
            {
                dc.macros = sec;
            }
        }
        return dc;
    }

    /************************************************
     * Parse macros out of Macros: section.
     * Macros are of the form:
     *      name1 = value1
     *
     *      name2 = value2
     */
    extern (C++) static void parseMacros(Escape** pescapetable, Macro** pmacrotable, const(char)* m, size_t mlen)
    {
        const(char)* p = m;
        size_t len = mlen;
        const(char)* pend = p + len;
        const(char)* tempstart = null;
        size_t templen = 0;
        const(char)* namestart = null;
        size_t namelen = 0; // !=0 if line continuation
        const(char)* textstart = null;
        size_t textlen = 0;
        while (p < pend)
        {
            // Skip to start of macro
            while (1)
            {
                if (p >= pend)
                    goto Ldone;
                switch (*p)
                {
                case ' ':
                case '\t':
                    p++;
                    continue;
                case '\r':
                case '\n':
                    p++;
                    goto Lcont;
                default:
                    if (isIdStart(p))
                        break;
                    if (namelen)
                        goto Ltext; // continuation of prev macro
                    goto Lskipline;
                }
                break;
            }
            tempstart = p;
            while (1)
            {
                if (p >= pend)
                    goto Ldone;
                if (!isIdTail(p))
                    break;
                p += utfStride(p);
            }
            templen = p - tempstart;
            while (1)
            {
                if (p >= pend)
                    goto Ldone;
                if (!(*p == ' ' || *p == '\t'))
                    break;
                p++;
            }
            if (*p != '=')
            {
                if (namelen)
                    goto Ltext; // continuation of prev macro
                goto Lskipline;
            }
            p++;
            if (p >= pend)
                goto Ldone;
            if (namelen)
            {
                // Output existing macro
            L1:
                //printf("macro '%.*s' = '%.*s'\n", namelen, namestart, textlen, textstart);
                if (icmp("ESCAPES", namestart, namelen) == 0)
                    parseEscapes(pescapetable, textstart, textlen);
                else
                    Macro.define(pmacrotable, namestart[0 ..namelen], textstart[0 .. textlen]);
                namelen = 0;
                if (p >= pend)
                    break;
            }
            namestart = tempstart;
            namelen = templen;
            while (p < pend && (*p == ' ' || *p == '\t'))
                p++;
            textstart = p;
        Ltext:
            while (p < pend && *p != '\r' && *p != '\n')
                p++;
            textlen = p - textstart;
            p++;
            //printf("p = %p, pend = %p\n", p, pend);
        Lcont:
            continue;
        Lskipline:
            // Ignore this line
            while (p < pend && *p != '\r' && *p != '\n')
                p++;
        }
    Ldone:
        if (namelen)
            goto L1; // write out last one
    }

    /**************************************
     * Parse escapes of the form:
     *      /c/string/
     * where c is a single character.
     * Multiple escapes can be separated
     * by whitespace and/or commas.
     */
    extern (C++) static void parseEscapes(Escape** pescapetable, const(char)* textstart, size_t textlen)
    {
        Escape* escapetable = *pescapetable;
        if (!escapetable)
        {
            escapetable = new Escape();
            memset(escapetable, 0, Escape.sizeof);
            *pescapetable = escapetable;
        }
        //printf("parseEscapes('%.*s') pescapetable = %p\n", textlen, textstart, pescapetable);
        const(char)* p = textstart;
        const(char)* pend = p + textlen;
        while (1)
        {
            while (1)
            {
                if (p + 4 >= pend)
                    return;
                if (!(*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n' || *p == ','))
                    break;
                p++;
            }
            if (p[0] != '/' || p[2] != '/')
                return;
            char c = p[1];
            p += 3;
            const(char)* start = p;
            while (1)
            {
                if (p >= pend)
                    return;
                if (*p == '/')
                    break;
                p++;
            }
            size_t len = p - start;
            char* s = cast(char*)memcpy(mem.xmalloc(len + 1), start, len);
            s[len] = 0;
            escapetable.strings[c] = s;
            //printf("\t%c = '%s'\n", c, s);
            p++;
        }
    }

    /*****************************************
     * Parse next paragraph out of *pcomment.
     * Update *pcomment to point past paragraph.
     * Returns NULL if no more paragraphs.
     * If paragraph ends in 'identifier:',
     * then (*pcomment)[0 .. idlen] is the identifier.
     */
    extern (C++) void parseSections(const(char)* comment)
    {
        const(char)* p;
        const(char)* pstart;
        const(char)* pend;
        const(char)* idstart = null; // dead-store to prevent spurious warning
        size_t idlen;
        const(char)* name = null;
        size_t namelen = 0;
        //printf("parseSections('%s')\n", comment);
        p = comment;
        while (*p)
        {
            const(char)* pstart0 = p;
            p = skipwhitespace(p);
            pstart = p;
            pend = p;
            /* Find end of section, which is ended by one of:
             *      'identifier:' (but not inside a code section)
             *      '\0'
             */
            idlen = 0;
            int inCode = 0;
            while (1)
            {
                // Check for start/end of a code section
                if (*p == '-')
                {
                    if (!inCode)
                    {
                        // restore leading indentation
                        while (pstart0 < pstart && isIndentWS(pstart - 1))
                            --pstart;
                    }
                    int numdash = 0;
                    while (*p == '-')
                    {
                        ++numdash;
                        p++;
                    }
                    // BUG: handle UTF PS and LS too
                    if ((!*p || *p == '\r' || *p == '\n') && numdash >= 3)
                        inCode ^= 1;
                    pend = p;
                }
                if (!inCode && isIdStart(p))
                {
                    const(char)* q = p + utfStride(p);
                    while (isIdTail(q))
                        q += utfStride(q);

                    // Detected tag ends it
                    if (*q == ':' && isupper(*p)
                            && (isspace(q[1]) || q[1] == 0))
                    {
                        idlen = q - p;
                        idstart = p;
                        for (pend = p; pend > pstart; pend--)
                        {
                            if (pend[-1] == '\n')
                                break;
                        }
                        p = q + 1;
                        break;
                    }
                }
                while (1)
                {
                    if (!*p)
                        goto L1;
                    if (*p == '\n')
                    {
                        p++;
                        if (*p == '\n' && !summary && !namelen && !inCode)
                        {
                            pend = p;
                            p++;
                            goto L1;
                        }
                        break;
                    }
                    p++;
                    pend = p;
                }
                p = skipwhitespace(p);
            }
        L1:
            if (namelen || pstart < pend)
            {
                Section s;
                if (icmp("Params", name, namelen) == 0)
                    s = new ParamSection();
                else if (icmp("Macros", name, namelen) == 0)
                    s = new MacroSection();
                else
                    s = new Section();
                s.name = name;
                s.namelen = namelen;
                s._body = pstart;
                s.bodylen = pend - pstart;
                s.nooutput = 0;
                //printf("Section: '%.*s' = '%.*s'\n", s.namelen, s.name, s.bodylen, s.body);
                sections.push(s);
                if (!summary && !namelen)
                    summary = s;
            }
            if (idlen)
            {
                name = idstart;
                namelen = idlen;
            }
            else
            {
                name = null;
                namelen = 0;
                if (!*p)
                    break;
            }
        }
    }

    extern (C++) void writeSections(Scope* sc, Dsymbols* a, OutBuffer* buf)
    {
        assert(a.dim);
        //printf("DocComment::writeSections()\n");
        Loc loc = (*a)[0].loc;
        if (Module m = (*a)[0].isModule())
        {
            if (m.md)
                loc = m.md.loc;
        }
        size_t offset1 = buf.offset;
        buf.writestring("$(DDOC_SECTIONS ");
        size_t offset2 = buf.offset;
        for (size_t i = 0; i < sections.dim; i++)
        {
            Section sec = sections[i];
            if (sec.nooutput)
                continue;
            //printf("Section: '%.*s' = '%.*s'\n", sec.namelen, sec.name, sec.bodylen, sec.body);
            if (!sec.namelen && i == 0)
            {
                buf.writestring("$(DDOC_SUMMARY ");
                size_t o = buf.offset;
                buf.write(sec._body, sec.bodylen);
                escapeStrayParenthesis(loc, buf, o);
                highlightText(sc, a, buf, o);
                buf.writestring(")");
            }
            else
                sec.write(loc, &this, sc, a, buf);
        }
        for (size_t i = 0; i < a.dim; i++)
        {
            Dsymbol s = (*a)[i];
            if (Dsymbol td = getEponymousParent(s))
                s = td;
            for (UnitTestDeclaration utd = s.ddocUnittest; utd; utd = utd.ddocUnittest)
            {
                if (utd.protection.kind == Prot.Kind.private_ || !utd.comment || !utd.fbody)
                    continue;
                // Strip whitespaces to avoid showing empty summary
                const(char)* c = utd.comment;
                while (*c == ' ' || *c == '\t' || *c == '\n' || *c == '\r')
                    ++c;
                buf.writestring("$(DDOC_EXAMPLES ");
                size_t o = buf.offset;
                buf.writestring(cast(char*)c);
                if (utd.codedoc)
                {
                    auto codedoc = utd.codedoc.stripLeadingNewlines;
                    size_t n = getCodeIndent(codedoc);
                    while (n--)
                        buf.writeByte(' ');
                    buf.writestring("----\n");
                    buf.writestring(codedoc);
                    buf.writestring("----\n");
                    highlightText(sc, a, buf, o);
                }
                buf.writestring(")");
            }
        }
        if (buf.offset == offset2)
        {
            /* Didn't write out any sections, so back out last write
             */
            buf.offset = offset1;
            buf.writestring("\n");
        }
        else
            buf.writestring(")");
    }
}

/******************************************
 * Compare 0-terminated string with length terminated string.
 * Return < 0, ==0, > 0
 */
extern (C++) int cmp(const(char)* stringz, const(void)* s, size_t slen)
{
    size_t len1 = strlen(stringz);
    if (len1 != slen)
        return cast(int)(len1 - slen);
    return memcmp(stringz, s, slen);
}

extern (C++) int icmp(const(char)* stringz, const(void)* s, size_t slen)
{
    size_t len1 = strlen(stringz);
    if (len1 != slen)
        return cast(int)(len1 - slen);
    return Port.memicmp(stringz, cast(char*)s, slen);
}

/*****************************************
 * Return true if comment consists entirely of "ditto".
 */
extern (C++) bool isDitto(const(char)* comment)
{
    if (comment)
    {
        const(char)* p = skipwhitespace(comment);
        if (Port.memicmp(p, "ditto", 5) == 0 && *skipwhitespace(p + 5) == 0)
            return true;
    }
    return false;
}

/*****************************************
 * Return true if the given character is white space.
 */
private bool isWhitespace(const(char) c)
{
// TODO: unicode whitespace: Zs.
    return c == ' ' || c == '\t' || c == '\r' || c == '\n';
}

/*****************************************
 * Return true if the given character is punctuation.
 */
private bool isPunctuation(const(char) c)
{
// TODO: unicode punctuation: Pc, Pd, Pe, Pf, Pi, Po, or Ps.
// However, unicode punctuation should not be included for Markdown backslash
// escapes, so when it's implemented be sure to make the unicode punctuation
// check optional via a parameter
    return c == '!' || c == '"' || c == '#' || c == '$' || c == '%' || c == '&'
        || c == '\'' || c == '(' || c == ')' || c == '*' || c == '+' || c == ','
        || c == '-' || c == '.' || c == '/' || c == ':' || c == ';' || c == '<'
        || c == '=' || c == '>' || c == '?' || c == '@' || c == '[' || c == '\\'
        || c == ']' || c == '^' || c == '_' || c == '`' || c == '{' || c == '|'
        || c == '}' || c == '~';
}

/**********************************************
 * Skip white space.
 */
extern (C++) const(char)* skipwhitespace(const(char)* p)
{
    for (; 1; p++)
    {
        switch (*p)
        {
        case ' ':
        case '\t':
        case '\n':
            continue;
        default:
            break;
        }
        break;
    }
    return p;
}

/************************************************
 * Scan past the given characters.
 * Params:
 *  buf =           an OutputBuffer containing the DDoc
 *  i =             the index within `buf` to start scanning from
 *  chars =         the characters to skip
 * Returns: the index after skipping characters.
 */
private size_t skipChars(OutBuffer* buf, size_t i, string chars)
{
    const slice = buf.peekSlice();
    for (; i < slice.length; i++)
    {
        bool contains = false;
        foreach (char c; chars)
        {
            if (slice[i] == c)
            {
                contains = true;
                break;
            }
        }
        if (!contains)
            break;
    }
    return i;
}

/************************************************
 * Get the indent from one index to another, counting tab stops as four spaces wide
 * per the Markdown spec.
 * Params:
 *  buf =           an OutputBuffer containing the DDoc
 *  from =          the index within `buf` to start counting from, inclusive
 *  to =            the index within `buf` to stop counting at, exclusive
 * Returns: the indent
 */
private int getMarkdownIndent(OutBuffer* buf, size_t from, size_t to)
{
    const slice = buf.peekSlice();
    if (to > slice.length)
        to = slice.length;
    int indent = 0;
    foreach (char c; slice[from..to])
    {
        switch (c)
        {
        case '\t':
            indent += (4 - (indent % 4));
            break;
        default:
            ++indent;
            break;
        }
    }
    return indent;
}

/************************************************
 * Scan forward to one of:
 *      start of identifier
 *      beginning of next line
 *      end of buf
 */
extern (C++) size_t skiptoident(OutBuffer* buf, size_t i)
{
    const slice = buf.peekSlice();
    while (i < slice.length)
    {
        dchar c;
        size_t oi = i;
        if (utf_decodeChar(slice.ptr, slice.length, i, c))
        {
            /* Ignore UTF errors, but still consume input
             */
            break;
        }
        if (c >= 0x80)
        {
            if (!isUniAlpha(c))
                continue;
        }
        else if (!(isalpha(c) || c == '_' || c == '\n'))
            continue;
        i = oi;
        break;
    }
    return i;
}

/************************************************
 * Scan forward past end of identifier.
 */
extern (C++) size_t skippastident(OutBuffer* buf, size_t i)
{
    const slice = buf.peekSlice();
    while (i < slice.length)
    {
        dchar c;
        size_t oi = i;
        if (utf_decodeChar(slice.ptr, slice.length, i, c))
        {
            /* Ignore UTF errors, but still consume input
             */
            break;
        }
        if (c >= 0x80)
        {
            if (isUniAlpha(c))
                continue;
        }
        else if (isalnum(c) || c == '_')
            continue;
        i = oi;
        break;
    }
    return i;
}

/************************************************
 * Scan forward past URL starting at i.
 * We don't want to highlight parts of a URL.
 * Returns:
 *      i if not a URL
 *      index just past it if it is a URL
 */
extern (C++) size_t skippastURL(OutBuffer* buf, size_t i)
{
    const slice = buf.peekSlice()[i .. $];
    size_t j;
    bool sawdot = false;
    if (slice.length > 7 && Port.memicmp(slice.ptr, "http://", 7) == 0)
    {
        j = 7;
    }
    else if (slice.length > 8 && Port.memicmp(slice.ptr, "https://", 8) == 0)
    {
        j = 8;
    }
    else
        goto Lno;
    for (; j < slice.length; j++)
    {
        const c = slice[j];
        if (isalnum(c))
            continue;
        if (c == '-' || c == '_' || c == '?' || c == '=' || c == '%' ||
            c == '&' || c == '/' || c == '+' || c == '#' || c == '~')
            continue;
        if (c == '.')
        {
            sawdot = true;
            continue;
        }
        break;
    }
    if (sawdot)
        return i + j;
Lno:
    return i;
}

/****************************************************
 * Remove a previously-inserted blank line macro.
 *  buf =           an OutputBuffer containing the DDoc
 *  iAt =           the index within `buf` to remove the blank line from.
 *  i =             the index within `buf` of the current index. Its value changes when function returns.
 */
private void removeBlankLineMacro(OutBuffer *buf, ref size_t iAt, ref size_t i)
{
    if (!iAt)
        return;

    buf.remove(iAt, 17); // length of "$(DDOC_BLANKLINE)"
    if (i > iAt)
        i -= 17;
    iAt = 0;
}

/****************************************************
 * Replace a Markdown thematic break (HR).
 * Params:
 *  buf =           an OutputBuffer containing the DDoc
 *  i =             the index within `buf` to replace the Markdown thematic break at. Its value changes if the function succeeds.
 *  iLineStart =    the index within `buf` that the thematic break's line starts at
 * Returns: whether a thematic break was replaced
 */
private bool replaceMarkdownThematicBreak(OutBuffer *buf, ref size_t i, size_t iLineStart)
{
    const slice = buf.peekSlice();
    char c = buf.data[i];
    size_t j = i + 1;
    int repeat = 1;
    for (; j < slice.length; j++)
    {
        if (buf.data[j] == c)
            ++repeat;
        else if (buf.data[j] != ' ' && buf.data[j] != '\t')
            break;
    }
    if (repeat >= 3)
    {
        if (j >= buf.offset || buf.data[j] == '\n' || buf.data[j] == '\r')
        {
            buf.remove(iLineStart, j - iLineStart);
            i = buf.insert(iLineStart, "$(HR)") - 1;
            return true;
        }
    }
    return false;
}

/****************************************************
 * End a Markdown heading, if inside one.
 * Params:
 *  buf =           an OutputBuffer containing the DDoc
 *  i =             the index within `buf` to end the Markdown heading at. Its value changes if the function succeeds.
 *  headingLevel =  the level (1-6) of heading to end. Is set to `0` when this function ends.
 *  iHeadingStart = the index within `buf` that the Markdown heading starts at
 * Returns: whether a heading was replaced
 */
private bool endMarkdownHeading(OutBuffer *buf, ref size_t i, ref int headingLevel, size_t iHeadingStart)
{
    static char[5] heading = "$(H0 ";
    heading[3] = cast(char) ('0' + headingLevel);
    buf.insert(iHeadingStart, heading);
    i += 5;
    size_t iBeforeNewline = i;
    while (buf.data[iBeforeNewline-1] == '\r' || buf.data[iBeforeNewline-1] == '\n')
        --iBeforeNewline;
    buf.insert(iBeforeNewline, ")");
    headingLevel = 0;
    return true;
}

/****************************************************
 * End all nested Markdown quotes, if inside one.
 * Params:
 *  buf =               an OutputBuffer containing the DDoc
 *  i =                 the index within `buf` to end the Markdown heading at. Its value changes if nested quotes were ended.
 *  quoteLevel =        the current quote level. Is set to 0 when this function ends.
 *  quoteMacroLevel =   the macro level that the quote was started at, set to 0 when this function ends.
 * Returns: the amount that `i` was moved
 */
private size_t endAllMarkdownQuotes(OutBuffer *buf, ref size_t i, ref int quoteLevel, out int quoteMacroLevel)
{
    size_t length = quoteLevel;
    for (; quoteLevel > 0; --quoteLevel)
        i = buf.insert(i, ")");
    quoteMacroLevel = 0;
    return length;
}

/****************************************************
 * Process Markdown emphasis
 * Params:
 *  buf =               an OutputBuffer containing the DDoc
 *  i =                 the index within `buf` to end the Markdown heading at. Its value changes if any emphasis was replaced.
 *  inlineDelimiters =  the collection of delimiters found within a paragraph. When this function returns its length will be reduced to `downToLevel`.
 *  downToLevel =       the length within `inlineDelimiters`` to reduce emphasis to
 * Returns: the amount `i` was moved
 */
private size_t replaceMarkdownEmphasis(OutBuffer *buf, ref size_t i, ref MarkdownDelimiter[] inlineDelimiters, int downToLevel = 0)
{
    size_t replaceEmphasisPair(ref MarkdownDelimiter start, ref MarkdownDelimiter end)
    {
        int count = end.count == 1 ? 1 : 2;
        if (start.count < count)
            count = start.count;

        size_t iStart = start.iStart;
        size_t iEnd = end.iStart;
        end.count -= count;
        start.count -= count;
        iStart += start.count;

        if (!start.count)
            start.type = 0;
        if (!end.count)
            end.type = 0;

        buf.remove(iStart, count);
        iEnd -= count;
        buf.remove(iEnd, count);

        string macroName = count >= 2 ? "$(STRONG " : "$(EM ";
        buf.insert(iEnd, ")");
        buf.insert(iStart, macroName);

        size_t delta = 1 + macroName.length - (count + count);
        end.iStart += count;
        return delta;
    }

    size_t iStart = i;
    int start = (cast(int) inlineDelimiters.length) - 1;
    while (start >= downToLevel)
    {
        // find start emphasis
        while (start >= downToLevel &&
            (inlineDelimiters[start].type != '*' || !inlineDelimiters[start].leftFlanking))
            --start;
        if (start < downToLevel)
            break;

        // find the nearest end emphasis
        int end = start + 1;
        while (end < inlineDelimiters.length &&
            (inlineDelimiters[end].type != inlineDelimiters[start].type || !inlineDelimiters[end].rightFlanking))
            ++end;
        if (end == inlineDelimiters.length)
        {
            // the start emphasis has no matching end; if it isn't an end itself then kill it
            if (!inlineDelimiters[start].rightFlanking)
                inlineDelimiters[start].type = 0;
            --start;
            continue;
        }

        // multiple-of-3 rule
        if (((inlineDelimiters[start].leftFlanking && inlineDelimiters[start].rightFlanking) ||
                (inlineDelimiters[end].leftFlanking && inlineDelimiters[end].rightFlanking)) &&
            (inlineDelimiters[start].count + inlineDelimiters[end].count) % 3 == 0)
        {
            --start;
            continue;
        }

        immutable delta = replaceEmphasisPair(inlineDelimiters[start], inlineDelimiters[end]);

        for (; end < inlineDelimiters.length; ++end)
            inlineDelimiters[end].iStart += delta;
        i += delta;
    }

    inlineDelimiters.length = downToLevel;
    return i - iStart;
}

/****************************************************
 */
extern (C++) bool isIdentifier(Dsymbols* a, const(char)* p, size_t len)
{
    for (size_t i = 0; i < a.dim; i++)
    {
        const(char)* s = (*a)[i].ident.toChars();
        if (cmp(s, p, len) == 0)
            return true;
    }
    return false;
}

/****************************************************
 */
extern (C++) bool isKeyword(const(char)* p, size_t len)
{
    immutable string[3] table = ["true", "false", "null"];
    foreach (s; table)
    {
        if (cmp(s.ptr, p, len) == 0)
            return true;
    }
    return false;
}

/****************************************************
 */
extern (C++) TypeFunction isTypeFunction(Dsymbol s)
{
    FuncDeclaration f = s.isFuncDeclaration();
    /* f.type may be NULL for template members.
     */
    if (f && f.type)
    {
        Type t = f.originalType ? f.originalType : f.type;
        if (t.ty == Tfunction)
            return cast(TypeFunction)t;
    }
    return null;
}

/****************************************************
 */
private Parameter isFunctionParameter(Dsymbol s, const(char)* p, size_t len)
{
    TypeFunction tf = isTypeFunction(s);
    if (tf && tf.parameters)
    {
        for (size_t k = 0; k < tf.parameters.dim; k++)
        {
            Parameter fparam = (*tf.parameters)[k];
            if (fparam.ident && cmp(fparam.ident.toChars(), p, len) == 0)
            {
                return fparam;
            }
        }
    }
    return null;
}

/****************************************************
 */
extern (C++) Parameter isFunctionParameter(Dsymbols* a, const(char)* p, size_t len)
{
    for (size_t i = 0; i < a.dim; i++)
    {
        Parameter fparam = isFunctionParameter((*a)[i], p, len);
        if (fparam)
        {
            return fparam;
        }
    }
    return null;
}

/****************************************************
 */
private Parameter isEponymousFunctionParameter(Dsymbols *a, const(char) *p, size_t len)
{
    for (size_t i = 0; i < a.dim; i++)
    {
        TemplateDeclaration td = (*a)[i].isTemplateDeclaration();
        if (td && td.onemember)
        {
            /* Case 1: we refer to a template declaration inside the template

               /// ...ddoc...
               template case1(T) {
                 void case1(R)() {}
               }
             */
            td = td.onemember.isTemplateDeclaration();
        }
        if (!td)
        {
            /* Case 2: we're an alias to a template declaration

               /// ...ddoc...
               alias case2 = case1!int;
             */
            AliasDeclaration ad = (*a)[i].isAliasDeclaration();
            if (ad && ad.aliassym)
            {
                td = ad.aliassym.isTemplateDeclaration();
            }
        }
        while (td)
        {
            Dsymbol sym = getEponymousMember(td);
            if (sym)
            {
                Parameter fparam = isFunctionParameter(sym, p, len);
                if (fparam)
                {
                    return fparam;
                }
            }
            td = td.overnext;
        }
    }
    return null;
}

/****************************************************
 */
extern (C++) TemplateParameter isTemplateParameter(Dsymbols* a, const(char)* p, size_t len)
{
    for (size_t i = 0; i < a.dim; i++)
    {
        TemplateDeclaration td = (*a)[i].isTemplateDeclaration();
        // Check for the parent, if the current symbol is not a template declaration.
        if (!td)
            td = getEponymousParent((*a)[i]);
        if (td && td.origParameters)
        {
            for (size_t k = 0; k < td.origParameters.dim; k++)
            {
                TemplateParameter tp = (*td.origParameters)[k];
                if (tp.ident && cmp(tp.ident.toChars(), p, len) == 0)
                {
                    return tp;
                }
            }
        }
    }
    return null;
}

/****************************************************
 * Return true if str is a reserved symbol name
 * that starts with a double underscore.
 */
extern (C++) bool isReservedName(const(char)* str, size_t len)
{
    immutable string[] table =
    [
        "__ctor",
        "__dtor",
        "__postblit",
        "__invariant",
        "__unitTest",
        "__require",
        "__ensure",
        "__dollar",
        "__ctfe",
        "__withSym",
        "__result",
        "__returnLabel",
        "__vptr",
        "__monitor",
        "__gate",
        "__xopEquals",
        "__xopCmp",
        "__LINE__",
        "__FILE__",
        "__MODULE__",
        "__FUNCTION__",
        "__PRETTY_FUNCTION__",
        "__DATE__",
        "__TIME__",
        "__TIMESTAMP__",
        "__VENDOR__",
        "__VERSION__",
        "__EOF__",
        "__LOCAL_SIZE",
        "___tls_get_addr",
        "__entrypoint",
    ];
    foreach (s; table)
    {
        if (cmp(s.ptr, str, len) == 0)
            return true;
    }
    return false;
}

/****************************************************
* A delimiter for Markdown inline content like emphasis and links.
*/
private struct MarkdownDelimiter
{
    size_t iStart;  /// the index where this delimiter starts
    int count;      /// the length of this delimeter's start sequence
    int macroLevel; /// the count of nested DDoc macros when the delimiter is started
    bool leftFlanking;  /// whether the delimiter is left-flanking, as defined by the CommonMark spec
    bool rightFlanking; /// whether the delimiter is right-flanking, as defined by the CommonMark spec
    char type;      /// the type of delimiter, defined by its starting character
}

/****************************************************
* Info about a Markdown list.
*/
private struct MarkdownList
{
    string orderedStart;    /// an optional start number--if present then the list starts at this number
    size_t iStart;          /// the index where the list item starts
    size_t iContentStart;   /// the index where the content starts after the list delimiter
    int indent;             /// the level of indent the content starts at
    int macroLevel;         /// the count of nested DDoc macros when the list is started
    char type;              /// the type of list, defined by its starting character

    /// whether this describes a valid list
    @property bool isValid() { return type != 0; }

    /****************************************************
    * Try to parse a list item, returning whether successful.
    * Params:
    *  buf =        an OutputBuffer containing the DDoc
    *  iLineStart = the index within `buf` of the first character of the line
    *  i =          the index within `buf` of the potential list item
    * Returns: the parsed list item. Its `isValid` property describes whether parsing succeeded.
    */
    static MarkdownList parseItem(OutBuffer *buf, size_t iLineStart, size_t i)
    {
        MarkdownList list;
        if (buf.data[i] == '+' || buf.data[i] == '-' || buf.data[i] == '*')
            list = parseUnorderedListItem(buf, iLineStart, i);
        else
            list = parseOrderedListItem(buf, iLineStart, i);

        return list;
    }

    /****************************************************
    * Return whether the context is at a list item of the same type as this list.
    * Params:
    *  buf =        an OutputBuffer containing the DDoc
    *  iLineStart = the index within `buf` of the first character of the line
    *  i =          the index within `buf` of the list item
    * Returns: whether `i` is at a list item of the same type as this list
    */
    bool isAtItemInThisList(OutBuffer *buf, size_t iLineStart, size_t i)
    {
        MarkdownList item = (type == '.' || type == ')') ?
            parseOrderedListItem(buf, iLineStart, i) :
            parseUnorderedListItem(buf, iLineStart, i);
        if (item.type == type)
            return getMarkdownIndent(buf, iLineStart, i) < indent;
        return false;
    }

    /****************************************************
    * Start a Markdown list item by creating/deleting nested lists and starting the item.
    * Params:
    *  buf =            an OutputBuffer containing the DDoc
    *  iLineStart =     the index within `buf` of the first character of the line. If this function succeeds it will equal `i`.
    *  i =              the index within `buf` of the list item. If this function succeeds `i` will be adjusted to fit the inserted macro.
    *  nestedLists =    a set of nested lists. If this function succeeds it may contain a new nested list.
    *  macroLevel =     the current macro nesting level
    * Returns: whether a list was created
    */
    bool startItem(OutBuffer *buf, ref size_t iLineStart, ref size_t i, ref MarkdownList[] nestedLists, int macroLevel)
    {
        this.macroLevel = macroLevel;

        const itemIndent = getMarkdownIndent(buf, iLineStart, i);

        buf.remove(iStart, iContentStart - iStart);

        if (!nestedLists.length || itemIndent >= nestedLists[$-1].indent)
        {
            // start a list macro
            nestedLists ~= this;
            if (type == '.' || type == ')')
            {
                if (orderedStart.length && orderedStart != "1")
                {
                    iStart = buf.insert(iStart, "$(OL_START ");
                    iStart = buf.insert(iStart, orderedStart);
                    iStart = buf.insert(iStart, ",\n");
                }
                else
                    iStart = buf.insert(iStart, "$(OL\n");
            }
            else
                iStart = buf.insert(iStart, "$(UL\n");
        }
        else if (nestedLists.length)
        {
            nestedLists[$-1].indent = indent;
        }

        iStart = buf.insert(iStart, "$(LI\n");
        i = iStart - 1;
        iLineStart = i;

        return true;
    }

    /****************************************************
    * End all nested Markdown lists.
    * Params:
    *  buf =            an OutputBuffer containing the DDoc
    *  i =              the index within `buf` to end lists at. If there were lists `i` will be adjusted to fit the macro endings.
    *  nestedLists =    a set of nested lists. Upon return it will be empty.
    * Returns: the amount that `i` changed
    */
    static size_t endAllNestedLists(OutBuffer *buf, ref size_t i, ref MarkdownList[] nestedLists)
    {
        const iStart = i;
        for (; nestedLists.length; --nestedLists.length)
            i = buf.insert(i, ")\n)");
        return i - iStart;
    }

    /****************************************************
    * Look for a sibling list item or the end of nested list(s).
    * Params:
    *  buf =                an OutputBuffer containing the DDoc
    *  i =                  the index within `buf` to end lists at. If there was a sibling or ending lists `i` will be adjusted to fit the macro endings.
    *  iParagraphStart =    the index within `buf` to start the next paragraph at at. May be adjusted upon return.
    *  nestedLists =        a set of nested lists. Some nested lists may have been removed from it upon return.
    */
    static void handleSiblingOrEndingList(OutBuffer *buf, ref size_t i, ref size_t iParagraphStart, ref MarkdownList[] nestedLists)
    {
        size_t iAfterSpaces = skipChars(buf, i + 1, " \t");

        if (iAfterSpaces < buf.offset && buf.data[iAfterSpaces] == '>')
            return;

        if (nestedLists[$-1].isAtItemInThisList(buf, i + 1, iAfterSpaces))
        {
            // end a sibling list item
            i = buf.insert(i, ")");
            iParagraphStart = skipChars(buf, i, " \t\r\n");
        }
        else if (iAfterSpaces >= buf.offset || (buf.data[iAfterSpaces] != '\r' && buf.data[iAfterSpaces] != '\n'))
        {
            // end nested lists that are indented more than this content
            int indent = getMarkdownIndent(buf, i + 1, iAfterSpaces);
            while (nestedLists.length && nestedLists[$-1].indent > indent)
            {
                i = buf.insert(i, ")\n)");
                --nestedLists.length;
                iParagraphStart = skipChars(buf, i, " \t\r\n");
            }
        }
    }

    /****************************************************
    * Parse an unordered list item at the current position
    * Params:
    *  buf =        an OutputBuffer containing the DDoc
    *  iLineStart = the index within `buf` of the first character of the line
    *  i =          the index within `buf` of the list item
    * Returns: the parsed list item, or a list item with type `0` if no list item is available
    */
    private static MarkdownList parseUnorderedListItem(OutBuffer *buf, size_t iLineStart, size_t i)
    {
        if (i < buf.offset-1 &&
            (buf.data[i+1] == ' ' ||
                buf.data[i+1] == '\t' ||
                buf.data[i+1] == '\r' ||
                buf.data[i+1] == '\n'))
        {
            size_t iContentStart = skipChars(buf, i + 1, " \t");
            const indent = getMarkdownIndent(buf, iLineStart, iContentStart);
            auto list = MarkdownList(null, iLineStart, iContentStart, indent, 0, buf.data[i]);
            return list;
        }
        return MarkdownList(null, 0, 0, 0, 0, 0);
    }

    /****************************************************
    * Parse an ordered list item at the current position
    * Params:
    *  buf =        an OutputBuffer containing the DDoc
    *  iLineStart = the index within `buf` of the first character of the line
    *  i =          the index within `buf` of the list item
    * Returns: the parsed list item, or a list item with type `0` if no list item is available
    */
    private static MarkdownList parseOrderedListItem(OutBuffer *buf, size_t iLineStart, size_t i)
    {
        size_t iAfterNumbers = skipChars(buf, i, "0123456789");
        if (iAfterNumbers - i <= 9 &&
            iAfterNumbers + 1 < buf.offset &&
            buf.data[iAfterNumbers] == '.' &&
            (buf.data[iAfterNumbers+1] == ' ' ||
                buf.data[iAfterNumbers+1] == '\t' ||
                buf.data[iAfterNumbers+1] == '\r' ||
                buf.data[iAfterNumbers+1] == '\n'))
        {
            size_t iContentStart = skipChars(buf, iAfterNumbers + 1, " \t");
            const indent = getMarkdownIndent(buf, iLineStart, iContentStart);
            size_t iNumberStart = skipChars(buf, i, "0");
            if (iNumberStart == iAfterNumbers)
                --iNumberStart;
            return MarkdownList(cast(string) buf.data[iNumberStart..iAfterNumbers].idup, iLineStart, iContentStart, indent, 0, buf.data[iAfterNumbers]);
        }
        return MarkdownList(null, 0, 0, 0, 0, 0);
    }
}

/****************************************************
* A Markdown link.
*/
private struct MarkdownLink
{
    string href;    /// the link destination
    string title;   /// an optional title for the link

    /****************************************************
    * Replace a Markdown inline link in the form of `[foo](url/ 'optional title')`
    * Params:
    *  buf =                an OutputBuffer containing the DDoc
    *  i =                  the index within `buf` that points to the `]` character of the inline link.
    *                       If this function succeeds it will be adjusted to fit the inserted macro.
    *  inlineDelimiters =   previously parsed Markdown delimiters, including emphasis and link/image starts
    *  delimiterIndex =     the index within `inlineDelimiters` of the nearest link/image starting delimiter
    * Returns: whether an inline link was found and replaced at `i`
    */
    static bool replaceInlineLink(OutBuffer *buf, ref size_t i, ref MarkdownDelimiter[] inlineDelimiters, int delimiterIndex)
    {
        size_t iEnd = i + 1;
        if (iEnd >= buf.offset || buf.data[iEnd] != '(')
            return false;
        ++iEnd;
        MarkdownLink link;
        if (!link.parseHref(buf, iEnd))
            return false;
        iEnd = skipChars(buf, iEnd, " \t\r\n");
        if (buf.data[iEnd] != ')')
        {
            if (link.parseTitle(buf, iEnd))
                iEnd = skipChars(buf, iEnd, " \t\r\n");
        }
        if (buf.data[iEnd] != ')')
            return false;
        ++iEnd;

        MarkdownDelimiter delimiter = inlineDelimiters[delimiterIndex];

        iEnd += replaceMarkdownEmphasis(buf, i, inlineDelimiters, delimiterIndex);

        link.replaceLink(buf, i, iEnd, delimiter);
        return true;
    }

    /****************************************************
    * Replace a Markdown reference link in the form of `[foo][bar]`, `[foo][]` or `[foo]`
    * Params:
    *  buf =                an OutputBuffer containing the DDoc
    *  i =                  the index within `buf` that points to the `]` character of the inline link.
    *                       If this function succeeds it will be adjusted to fit the inserted macro.
    *  inlineDelimiters =   previously parsed Markdown delimiters, including emphasis and link/image starts
    *  delimiterIndex =     the index within `inlineDelimiters` of the nearest link/image starting delimiter
    *  linkReferences =     previously parsed link references. When this function returns it may contain
    *                       additional previously unparsed references.
    * Returns: whether a reference link was found and replaced at `i`
    */
    static bool replaceReferenceLink(OutBuffer *buf, ref size_t i, ref MarkdownDelimiter[] inlineDelimiters, int delimiterIndex, ref MarkdownLinkReferences linkReferences)
    {
        MarkdownDelimiter delimiter = inlineDelimiters[delimiterIndex];

        size_t iStart = i + 1;
        size_t iEnd = iStart;
        if (iEnd >= buf.offset || buf.data[iEnd] != '[' || (iEnd+1 < buf.offset && buf.data[iEnd+1] == ']'))
        {
            // collapsed reference [foo][] or shortcut reference [foo]
            iStart = delimiter.iStart + delimiter.count - 1;
            if (buf.data[iEnd] == '[')
                iEnd += 2;
        }

        string label = parseLabel(buf, iStart);
        if (!label.length)
            return false;
        if (label !in linkReferences.references && linkReferences.iParsedUntil < i)
            linkReferences.extractReferences(buf, i);
        if (label !in linkReferences.references)
            return false;

        if (iEnd < iStart)
            iEnd = iStart;

        iEnd += replaceMarkdownEmphasis(buf, i, inlineDelimiters, delimiterIndex);

        MarkdownLink reference = linkReferences.references[label];
        reference.replaceLink(buf, i, iEnd, delimiter);
        return true;
    }

    /****************************************************
    * Parse and normalize a Markdown reference label
    * Params:
    *  buf =                an OutputBuffer containing the DDoc
    *  i =                  the index within `buf` that points to the `[` character at the start of the label.
    *                       If this function returns a non-empty label then `i` will point just after the ']' at the end of the label.
    * Returns: the parsed and normalized label, possibly empty
    */
    private static string parseLabel(OutBuffer *buf, ref size_t i)
    {
        string label;
        if (buf.data[i] != '[')
            return label;
        const slice = buf.peekSlice();
        for (size_t j = i; j < slice.length; ++j)
        {
            char c = slice[j];
            switch (c)
            {
            case ' ':
            case '\t':
            case '\r':
            case '\n':
                if (label.length && label[$-1] != ' ')
                    label ~= ' ';
                break;
            case '\\':
                label ~= slice[j..j+2];
                ++j;
                break;
            case ']':
                if (label[$-1] == ' ')
                    --label.length;
                if (label.length)
                    i = j + 1;
                return label;
            default:
                // TODO: unicode case-insensitive matching
                if (c >= 'A' && c <= 'Z')
                    c += 'a' - 'A';
                label ~= c;
                break;
            }
        }
        return label;
    }

    /****************************************************
    * Parse and store a Markdown link URL, optionally enclosed in `<>` brackets
    * Params:
    *  buf =                an OutputBuffer containing the DDoc
    *  i =                  the index within `buf` that points to the first character of the URL.
    *                       If this function succeeds `i` will point just after the the end of the URL.
    * Returns: whether a URL was found and parsed
    */
    private bool parseHref(OutBuffer* buf, ref size_t i)
    {
        size_t j = skipChars(buf, i, " \t");

        size_t iHrefStart = j;
        size_t parenDepth = 1;
        bool inPointy = false;
        const slice = buf.peekSlice();
        for (; j < slice.length; j++)
        {
            switch (slice[j])
            {
            case '<':
                if (!inPointy && j == iHrefStart)
                {
                    inPointy = true;
                    ++iHrefStart;
                }
                break;
            case '>':
                if (inPointy && slice[j-1] != '\\')
                    goto LReturnHref;
                break;
            case '(':
                if (!inPointy && slice[j-1] != '\\')
                    ++parenDepth;
                break;
            case ')':
                if (!inPointy && slice[j-1] != '\\')
                {
                    --parenDepth;
                    if (!parenDepth)
                        goto LReturnHref;
                }
                break;
            case ' ':
            case '\t':
            case '\r':
            case '\n':
                if (inPointy)
                {
                    // invalid link
                    return false;
                }
                goto LReturnHref;
            default:
                break;
            }
        }
        return false;
    LReturnHref:
        if (iHrefStart == j)
            return false;
        href = slice[iHrefStart .. j].idup;
        href = removeEscapeBackslashes(href);
// TODO: percent-encode href
        i = j;
        if (inPointy)
            ++i;
        return true;
    }

    /****************************************************
    * Parse and store a Markdown link title, enclosed in parentheses or `'` or `"` quotes
    * Params:
    *  buf =                an OutputBuffer containing the DDoc
    *  i =                  the index within `buf` that points to the first character of the title.
    *                       If this function succeeds `i` will point just after the the end of the title.
    * Returns: whether a title was found and parsed
    */
    private bool parseTitle(OutBuffer* buf, ref size_t i)
    {
        size_t j = skipChars(buf, i, " \t");
        if (j >= buf.offset)
            return false;

        char type = buf.data[j];
        if (type != '"' && type != '\'' && type != '(')
            return false;
        if (type == '(')
            type = ')';

        size_t iTitleStart = j + 1;
        size_t iNewline = 0;
        const slice = buf.peekSlice();
        for (j = iTitleStart; j < slice.length; j++)
        {
            char c = slice[j];
            switch (c)
            {
            case ')':
            case '"':
            case '\'':
                if (type == c && slice[j-1] != '\\')
                    goto LEndTitle;
                iNewline = 0;
                break;
            case ' ':
            case '\t':
            case '\r':
                break;
            case '\n':
                if (iNewline)
                {
                    // no blank lines in titles
                    return false;
                }
                iNewline = j;
                break;
            default:
                iNewline = 0;
                break;
            }
        }
        return false;
    LEndTitle:
        title = slice[iTitleStart .. j].idup;
        title = removeEscapeBackslashes(title);
        i = j + 1;
        return true;
    }

    /****************************************************
    * Replace a Markdown link or image with the appropriate macro
    * Params:
    *  buf =        an OutputBuffer containing the DDoc
    *  i =          the index within `buf` that points to the `]` character of the inline link.
    *               When this function returns it will be adjusted to the end of the inserted macro.
    *  iLinkEnd =   the index within `buf` that points just after the last character of the link
    *  delimiter =  the Markdown delimiter that started the link or image
    */
    private void replaceLink(OutBuffer *buf, ref size_t i, size_t iLinkEnd, MarkdownDelimiter delimiter)
    {
        size_t iAfterLink = i - delimiter.count;
        string macroName;
        if (title.length)
        {
            if (delimiter.type == '[')
                macroName = "$(LINK_TITLE ";
            else
                macroName = "$(IMAGE_TITLE ";
        }
        else
        {
            if (delimiter.type == '[')
                macroName = "$(LINK2 ";
            else
                macroName = "$(IMAGE ";
        }
        buf.remove(delimiter.iStart, delimiter.count);
        buf.remove(i - 1, iLinkEnd - i);
        iLinkEnd = buf.insert(delimiter.iStart, macroName);
        iLinkEnd = buf.insert(iLinkEnd, href);
        iLinkEnd = buf.insert(iLinkEnd, ", ");
        iAfterLink += macroName.length + href.length + 2;
        if (title.length)
        {
            iLinkEnd = buf.insert(iLinkEnd, title);
            iLinkEnd = buf.insert(iLinkEnd, ", ");
            iAfterLink += title.length + 2;
        }
        buf.insert(iAfterLink, ")");
        i = iAfterLink;
    }

    /****************************************************
    * Remove Markdown escaping backslashes from the given string
    * Params:
    *  s =  the string to remove escaping backslashes from
    * Returns: `s` without escaping backslashes in it
    */
    private static string removeEscapeBackslashes(string s)
    {
        if (!s.length)
            return s;
        for (size_t i = 0; i < s.length-1; ++i)
        {
            if (s[i] == '\\' && isPunctuation(s[i+1]))
            {
                s = s[0..i] ~ s[i+1..$];
                --i;
            }
        }
        return s;
    }
}

/**************************************************
 * A set of Markdown link references.
 */
private struct MarkdownLinkReferences
{
    MarkdownLink[string] references;    // link references keyed by normalized label
    size_t iParsedUntil;    // the index into the buffer of the last-parsed reference

    /**************************************************
    * Remove and store a link reference from the document, in the form of `[bar]: url/ 'optional title'`
    * Params:
    *  buf =    an OutputBuffer containing the DDoc
    *  i =      the index within `buf` that points to the `[` character at the start of the reference label
    * Returns: whether a reference was extracted
    */
    bool extractReference(OutBuffer *buf, size_t i)
    {
        size_t iEnd = i;
        string label = MarkdownLink.parseLabel(buf, iEnd);
        if (!label.length)
            return false;
        if (iEnd >= buf.offset || buf.data[iEnd] != ':')
            return false;
        ++iEnd;
        iEnd = skipChars(buf, iEnd, " \t");
        skipOneNewline(buf, iEnd);

        MarkdownLink reference;
        if (!reference.parseHref(buf, iEnd))
            return false;
        iEnd = skipChars(buf, iEnd, " \t");
        bool requireNewline = !skipOneNewline(buf, iEnd);
        immutable iBeforeTitle = iEnd;

        if (reference.parseTitle(buf, iEnd))
        {
            iEnd = skipChars(buf, iEnd, " \t");
            if (iEnd < buf.offset && buf.data[iEnd] != '\r' && buf.data[iEnd] != '\n')
            {
                // the title must end with a newline
                reference.title.length = 0;
                iEnd = iBeforeTitle;
            }
        }

        iEnd = skipChars(buf, iEnd, " \t");
        if (requireNewline && buf.data[iEnd] != '\r' && buf.data[iEnd] != '\n')
            return false;
        iEnd = skipChars(buf, iEnd, " \t\r\n");
        buf.remove(i, iEnd - i);

        if (label !in references)
        {
            references[label] = reference;
            iParsedUntil = i;
        }
        return true;
    }

    /**************************************************
    * Remove and store all link references from the document after `iParsedUntil`
    * Params:
    *  buf =    an OutputBuffer containing the DDoc
    *  i =      the index within `buf` to start looking at
    * Returns: whether a reference was extracted
    */
    void extractReferences(OutBuffer *buf, size_t i)
    {
        static bool isFollowedBySpace(OutBuffer *buf, size_t i)
        {
            return i+1 < buf.offset && (buf.data[i+1] == ' ' || buf.data[i+1] == '\t');
        }

        bool leadingBlank = false;
        bool inCode = false;
        bool newParagraph = true;
        for (; i < buf.offset; ++i)
        {
            char c = buf.data[i];
            switch (c)
            {
            case ' ':
            case '\t':
                break;
            case '\n':
                if (leadingBlank && !inCode)
                    newParagraph = true;
                leadingBlank = true;
                break;
            case '\\':
                ++i;
                break;
            case '#':
                if (leadingBlank && !inCode)
                    newParagraph = true;
                leadingBlank = false;
                break;
            case '>':
                if (leadingBlank && !inCode)
                    newParagraph = true;
                break;
            case '+':
                if (leadingBlank && !inCode && isFollowedBySpace(buf, i))
                    newParagraph = true;
                else
                    leadingBlank = false;
                break;
            case '0':
            ..
            case '9':
                if (leadingBlank && !inCode)
                {
                    i = skipChars(buf, i, "0123456789");
                    if (i < buf.offset &&
                        (buf.data[i] == '.' || buf.data[i] == ')') &&
                        isFollowedBySpace(buf, i))
                        newParagraph = true;
                    else
                        leadingBlank = false;
                }
                break;
            case '*':
                if (leadingBlank && !inCode)
                {
                    newParagraph = true;
                    if (!isFollowedBySpace(buf, i))
                        leadingBlank = false;
                }
                break;
            case '`':
            case '~':
                if (leadingBlank && i+2 < buf.offset && buf.data[i+1] == c && buf.data[i+2] == c)
                {
                    inCode = !inCode;
                    i += 2;
                    newParagraph = true;
                }
                leadingBlank = false;
                break;
            case '-':
                if (leadingBlank && !inCode && isFollowedBySpace(buf, i))
                    goto case '+';
                else
                    goto case '`';
            case '[':
                if (leadingBlank && !inCode && newParagraph &&
                    extractReference(buf, i))
                    --i;
                break;
            default:
                if (leadingBlank)
                    newParagraph = false;
                leadingBlank = false;
                break;
            }
        }
    }

    /**************************************************
    * Skip a single newline at `i`
    * Params:
    *  buf =    an OutputBuffer containing the DDoc
    *  i =      the index within `buf` to start looking at.
    *           If this function succeeds `i` will point after the newline.
    * Returns: whether a newline was skipped
    */
    private static bool skipOneNewline(OutBuffer *buf, ref size_t i)
    {
        bool skipped = false;
        if (i < buf.offset && buf.data[i] == '\r')
            ++i;
        if (i < buf.offset && buf.data[i] == '\n')
        {
            ++i;
            skipped = true;
        }
        return skipped;
    }
}

/**************************************************
 * Highlight text section.
 */
extern (C++) void highlightText(Scope* sc, Dsymbols* a, OutBuffer* buf, size_t offset)
{
    Dsymbol s = a.dim ? (*a)[0] : null; // test
    //printf("highlightText()\n");
    bool leadingBlank = true;
    size_t iParagraphStart = offset;
    size_t iPreceedingBlankLine = 0;
    int headingLevel = 0;
    int headingMacroLevel = 0;
    int quoteLevel = 0;
    bool lineQuoted = false;
    int quoteMacroLevel = 0;
    MarkdownList[] nestedLists;
    MarkdownDelimiter[] inlineDelimiters;
    MarkdownLinkReferences linkReferences;
    int inCode = 0;
    int inBacktick = 0;
    int macroLevel = 0;
    int previousMacroLevel = 0;
    int parenLevel = 0;
    size_t iCodeStart = 0; // start of code section
    size_t codeFenceLength = 0;
    size_t codeIndent = 0;
    string codeLanguage;
    size_t iLineStart = offset;
    for (size_t i = offset; i < buf.offset; i++)
    {
        char c = buf.data[i];
    Lcont:
        switch (c)
        {
        case ' ':
        case '\t':
            break;
        case '\n':
            if (inBacktick)
            {
                // `inline code` is only valid if contained on a single line
                // otherwise, the backticks should be output literally.
                //
                // This lets things like `output from the linker' display
                // unmolested while keeping the feature consistent with GitHub.
                inBacktick = false;
                inCode = false; // the backtick also assumes we're in code
                // Nothing else is necessary since the DDOC_BACKQUOTED macro is
                // inserted lazily at the close quote, meaning the rest of the
                // text is already OK.
            }
            if (headingLevel)
            {
                replaceMarkdownEmphasis(buf, i, inlineDelimiters);
                endMarkdownHeading(buf, i, headingLevel, iParagraphStart);
                removeBlankLineMacro(buf, iPreceedingBlankLine, i);
                ++i;
                iParagraphStart = skipChars(buf, i, " \t\r\n");
            }
            if (!inCode && nestedLists.length && !quoteLevel)
            {
                MarkdownList.handleSiblingOrEndingList(buf, i, iParagraphStart, nestedLists);
            }
            iPreceedingBlankLine = 0;
            if (!inCode && i == iLineStart && i + 1 < buf.offset) // if "\n\n"
            {
                replaceMarkdownEmphasis(buf, i, inlineDelimiters);

                if (!lineQuoted && quoteLevel)
                {
                    MarkdownList.endAllNestedLists(buf, i, nestedLists);
                    endAllMarkdownQuotes(buf, i, quoteLevel, quoteMacroLevel);
                }

                if (iParagraphStart <= i)
                {
                    iPreceedingBlankLine = i;
                    i = buf.insert(i, "$(DDOC_BLANKLINE)");
                    iParagraphStart = i + 1;
                }
            }
            else if (inCode &&
                i == iLineStart &&
                i + 1 < buf.offset &&
                !lineQuoted &&
                quoteLevel) // if "\n\n" in quoted code
            {
                inCode = false;
                i = buf.insert(i, ")");
                endAllMarkdownQuotes(buf, i, quoteLevel, quoteMacroLevel);
            }
            leadingBlank = true;
            lineQuoted = false;
            iLineStart = i + 1;

            if (previousMacroLevel < macroLevel && iParagraphStart < iLineStart)
                iParagraphStart = iLineStart;
            previousMacroLevel = macroLevel;

            if (inlineDelimiters.length && iParagraphStart == i + 1)
                replaceMarkdownEmphasis(buf, i, inlineDelimiters);
            break;
        case '<':
            {
                leadingBlank = false;
                if (inCode)
                    break;
                const slice = buf.peekSlice();
                auto p = &slice[i];
                const se = sc._module.escapetable.escapeChar('<');
                if (se && strcmp(se, "&lt;") == 0)
                {
                    // Generating HTML
                    // Skip over comments
                    if (p[1] == '!' && p[2] == '-' && p[3] == '-')
                    {
                        size_t j = i + 4;
                        p += 4;
                        while (1)
                        {
                            if (j == slice.length)
                                goto L1;
                            if (p[0] == '-' && p[1] == '-' && p[2] == '>')
                            {
                                i = j + 2; // place on closing '>'
                                break;
                            }
                            j++;
                            p++;
                        }
                        break;
                    }
                    // Skip over HTML tag
                    if (isalpha(p[1]) || (p[1] == '/' && isalpha(p[2])))
                    {
                        size_t j = i + 2;
                        p += 2;
                        while (1)
                        {
                            if (j == slice.length)
                                break;
                            if (p[0] == '>')
                            {
                                i = j; // place on closing '>'
                                break;
                            }
                            j++;
                            p++;
                        }
                        break;
                    }
                }
            L1:
                // Replace '<' with '&lt;' character entity
                if (se)
                {
                    const len = strlen(se);
                    buf.remove(i, 1);
                    i = buf.insert(i, se, len);
                    i--; // point to ';'
                }
                break;
            }
        case '>':
            {
                if (leadingBlank && (!inCode || quoteLevel))
                {
                    lineQuoted = true;
                    int lineQuoteLevel = 1;
                    size_t iAfterDelimiters = i + 1;
                    for (; iAfterDelimiters < buf.offset; ++iAfterDelimiters)
                    {
                        const c0 = buf.data[iAfterDelimiters];
                        if (c0 == '>')
                            ++lineQuoteLevel;
                        else if (c0 != ' ' && c0 != '\t')
                            break;
                    }
                    if (!quoteMacroLevel)
                        quoteMacroLevel = macroLevel;
                    buf.remove(i, iAfterDelimiters - i);

                    if (quoteLevel < lineQuoteLevel)
                    {
                        if (nestedLists.length)
                        {
                            const indent = getMarkdownIndent(buf, iLineStart, i);
                            if (indent < nestedLists[$-1].indent)
                                MarkdownList.endAllNestedLists(buf, i, nestedLists);
                        }

                        for (; quoteLevel < lineQuoteLevel; ++quoteLevel)
                        {
                            i = buf.insert(i, "$(BLOCKQUOTE\n");
                            iLineStart = iParagraphStart = i;
                        }
                        --i;
                    }
                    else
                    {
                        --i;
                        if (nestedLists.length)
                            MarkdownList.handleSiblingOrEndingList(buf, i, iParagraphStart, nestedLists);
                    }
                    break;
                }

                leadingBlank = false;
                if (inCode)
                    break;
                // Replace '>' with '&gt;' character entity
                const(char)* se = sc._module.escapetable.escapeChar('>');
                if (se)
                {
                    size_t len = strlen(se);
                    buf.remove(i, 1);
                    i = buf.insert(i, se, len);
                    i--; // point to ';'
                }
                break;
            }
        case '&':
            {
                leadingBlank = false;
                if (inCode)
                    break;
                char* p = cast(char*)&buf.data[i];
                if (p[1] == '#' || isalpha(p[1]))
                    break;
                // already a character entity
                // Replace '&' with '&amp;' character entity
                const(char)* se = sc._module.escapetable.escapeChar('&');
                if (se)
                {
                    size_t len = strlen(se);
                    buf.remove(i, 1);
                    i = buf.insert(i, se, len);
                    i--; // point to ';'
                }
                break;
            }
        case '`':
            {
                size_t iAfterDelimiter = skipChars(buf, i, "`");
                int count = cast(int) (iAfterDelimiter - i);

                if (inBacktick == count)
                {
                    inBacktick = 0;
                    inCode = 0;
                    OutBuffer codebuf;
                    codebuf.write(buf.peekSlice().ptr + iCodeStart + count, i - (iCodeStart + count));
                    // escape the contents, but do not perform highlighting except for DDOC_PSYMBOL
                    highlightCode(sc, a, &codebuf, 0);
                    buf.remove(iCodeStart, i - iCodeStart + count); // also trimming off the current `
                    immutable pre = "$(DDOC_BACKQUOTED ";
                    i = buf.insert(iCodeStart, pre);
                    i = buf.insert(i, codebuf.peekSlice());
                    i = buf.insert(i, ")");
                    i--; // point to the ending ) so when the for loop does i++, it will see the next character
                    break;
                }

                if (leadingBlank)
                {
                    // Perhaps we're starting or ending a Markdown code block
                    if (count >= 3)
                    {
                        bool moreBackticks = false;
                        for (size_t j = iAfterDelimiter; !moreBackticks && j < buf.offset; ++j)
                            if (buf.data[j] == '`')
                                moreBackticks = true;
                            else if (buf.data[j] == '\r' || buf.data[j] == '\n')
                                break;
                        if (!moreBackticks)
                            goto case '-';
                    }
                }

                if (inCode)
                {
                    if (inBacktick)
                        i = iAfterDelimiter - 1;
                    break;
                }
                inCode = c;
                inBacktick = count;
                codeIndent = 0; // inline code is not indented
                // All we do here is set the code flags and record
                // the location. The macro will be inserted lazily
                // so we can easily cancel the inBacktick if we come
                // across a newline character.
                iCodeStart = i;
                i = iAfterDelimiter - 1;
                break;
            }
        case '~':
            {
                if (leadingBlank)
                {
                    // Perhaps we're starting or ending a Markdown code block
                    size_t iAfterDelimiter = skipChars(buf, i, "~");
                    if (iAfterDelimiter - i >= 3)
                        goto case '-';
                }
                break;
            }
        case '-':
            /* A line beginning with --- delimits a code section.
             * inCode tells us if it is start or end of a code section.
             */
            if (leadingBlank)
            {
                if (!inCode && c == '-')
                {
                    MarkdownList list = MarkdownList.parseItem(buf, iLineStart, i);
                    if (list.isValid)
                        goto case '+';
                }

                size_t istart = i;
                size_t eollen = 0;
                leadingBlank = false;
                char c0 = c; // if we jumped here from case '`' or case '~'
                size_t iInfoString = 0;
                if (!inCode)
                    codeLanguage.length = 0;
                while (1)
                {
                    ++i;
                    if (i >= buf.offset)
                        break;
                    c = buf.data[i];
                    if (c == '\n')
                    {
                        eollen = 1;
                        break;
                    }
                    if (c == '\r')
                    {
                        eollen = 1;
                        if (i + 1 >= buf.offset)
                            break;
                        if (buf.data[i + 1] == '\n')
                        {
                            eollen = 2;
                            break;
                        }
                    }
                    // BUG: handle UTF PS and LS too
                    if (c != c0 || iInfoString)
                    {
                        if (c0 == '-' && !iInfoString && replaceMarkdownThematicBreak(buf, istart, iLineStart))
                        {
                            i = istart;
                            removeBlankLineMacro(buf, iPreceedingBlankLine, i);
                            iParagraphStart = skipChars(buf, i+1, " \t\r\n");
                            break;
                        }
                        else if (!iInfoString && !inCode && c0 != '-' && i - istart >= 3)
                        {
                            // Start a Markdown info string, like ```ruby
                            codeFenceLength = i - istart;
                            i = iInfoString = skipChars(buf, i, " \t");
                        }
                        else if (iInfoString && c != '`')
                        {
                            if (!codeLanguage.length && (c == ' ' || c == '\t'))
                                codeLanguage = cast(string) buf.data[iInfoString..i].idup;
                        }
                        else
                        {
                            iInfoString = 0;
                            goto Lcont;
                        }
                    }
                }
                if (i - istart < 3 || (inCode && (inCode != c0 || i - istart < codeFenceLength)))
                    goto Lcont;
                if (iInfoString)
                {
                    if (!codeLanguage.length)
                        codeLanguage = cast(string) buf.data[iInfoString..i].idup;
                }
                else
                    codeFenceLength = i - istart;

                // We have the start/end of a code section
                // Remove the entire --- line, including blanks and \n
                buf.remove(iLineStart, i - iLineStart + eollen);
                i = iLineStart;
                if (eollen)
                    leadingBlank = true;
                if (inCode && (i <= iCodeStart))
                {
                    // Empty code section, just remove it completely.
                    inCode = 0;
                    break;
                }
                if (inCode)
                {
                    inCode = 0;
                    // The code section is from iCodeStart to i
                    OutBuffer codebuf;
                    codebuf.write(buf.data + iCodeStart, i - iCodeStart);
                    codebuf.writeByte(0);
                    // Remove leading indentations from all lines
                    bool lineStart = true;
                    char* endp = cast(char*)codebuf.data + codebuf.offset;
                    for (char* p = cast(char*)codebuf.data; p < endp;)
                    {
                        if (lineStart)
                        {
                            size_t j = codeIndent;
                            char* q = p;
                            while (j-- > 0 && q < endp && isIndentWS(q))
                                ++q;
                            codebuf.remove(p - cast(char*)codebuf.data, q - p);
                            assert(cast(char*)codebuf.data <= p);
                            assert(p < cast(char*)codebuf.data + codebuf.offset);
                            lineStart = false;
                            endp = cast(char*)codebuf.data + codebuf.offset; // update
                            continue;
                        }
                        if (*p == '\n')
                            lineStart = true;
                        ++p;
                    }
                    if (!codeLanguage.length || codeLanguage == "dlang")
                        highlightCode2(sc, a, &codebuf, 0);
                    buf.remove(iCodeStart, i - iCodeStart);
                    i = buf.insert(iCodeStart, codebuf.peekSlice());
                    i = buf.insert(i, ")\n");
                    i -= 2; // in next loop, c should be '\n'
                }
                else
                {
                    if (!lineQuoted && quoteLevel)
                    {
                        size_t delta = 0;
                        delta += MarkdownList.endAllNestedLists(buf, iLineStart, nestedLists);
                        delta += endAllMarkdownQuotes(buf, iLineStart, quoteLevel, quoteMacroLevel);
                        i += delta;
                        istart += delta;
                    }

                    inCode = c0;
                    codeIndent = istart - iLineStart; // save indent count
                    if (codeLanguage.length && codeLanguage != "dlang")
                    {
                        i = buf.insert(i, "$(OTHER_CODE ");
                        i = buf.insert(i, codeLanguage);
                        i = buf.insert(i, ",");
                    }
                    else
                        i = buf.insert(i, "$(D_CODE ");
                    iCodeStart = i;
                    i--; // place i on >
                    leadingBlank = true;
                }
            }
            break;

        case '#':
        {
            /* A line beginning with # indicates a Markdown heading. */
            if (leadingBlank && !inCode)
            {
                size_t iHeadingStart = i;
                leadingBlank = false;
                size_t iSkipped = skipChars(buf, i, "#");
                headingLevel = cast(int) (iSkipped - iHeadingStart);
                if (headingLevel > 6)
                {
                    headingLevel = 0;
                    break;
                }
                i = skipChars(buf, iSkipped, " \t");
                bool emptyHeading = buf.data[i] == '\r' || buf.data[i] == '\n';

                // require whitespace
                if (!emptyHeading && i == iSkipped)
                {
                    i = iHeadingStart;
                    headingLevel = 0;
                    break;
                }

                if (!lineQuoted && quoteLevel)
                {
                    i += MarkdownList.endAllNestedLists(buf, iLineStart, nestedLists);
                    i += endAllMarkdownQuotes(buf, iLineStart, quoteLevel, quoteMacroLevel);
                }

                // remove the ### prefix
                buf.remove(iLineStart, i - iLineStart);
                i = iParagraphStart = iLineStart;

                headingMacroLevel = macroLevel;

                if (emptyHeading)
                {
                    --i;
                    break;
                }

                // remove any ### suffix
                size_t j = i;
                size_t iSuffixStart = 0;
                size_t iWhitespaceStart = j;
                const slice = buf.peekSlice();
                for (; j < slice.length; j++)
                {
                    switch (slice[j])
                    {
                    case '#':
                        if (iWhitespaceStart && !iSuffixStart)
                            iSuffixStart = j;
                        break;
                    case ' ':
                    case '\t':
                        if (!iWhitespaceStart)
                            iWhitespaceStart = j;
                        break;
                    case '\r':
                    case '\n':
                        goto LendHeadingSuffix;
                    default:
                        iSuffixStart = 0;
                        iWhitespaceStart = 0;
                    }
                }
            LendHeadingSuffix:
                if (iSuffixStart)
                    buf.remove(iWhitespaceStart, j - iWhitespaceStart);
                --i;
            }
            break;
        }

        case '_':
        {
            if (leadingBlank && !inCode && replaceMarkdownThematicBreak(buf, i, iLineStart))
            {
                if (!lineQuoted && quoteLevel)
                {
                    i += MarkdownList.endAllNestedLists(buf, iLineStart, nestedLists);
                    i += endAllMarkdownQuotes(buf, iLineStart, quoteLevel, quoteMacroLevel);
                }
                removeBlankLineMacro(buf, iPreceedingBlankLine, i);
                iParagraphStart = skipChars(buf, i+1, " \t\r\n");
                break;
            }
            goto default;
        }

        case '+':
        case '0':
        ..
        case '9':
        {
            if (leadingBlank && !inCode)
            {
                MarkdownList list = MarkdownList.parseItem(buf, iLineStart, i);
                if (list.isValid)
                {
                    if (!lineQuoted && quoteLevel)
                    {
                        size_t delta = 0;
                        delta += MarkdownList.endAllNestedLists(buf, iLineStart, nestedLists);
                        delta += endAllMarkdownQuotes(buf, iLineStart, quoteLevel, quoteMacroLevel);
                        i += delta;
                        list.iStart += delta;
                        list.iContentStart += delta;
                    }

                    list.startItem(buf, iLineStart, i, nestedLists, macroLevel);
                }
                else
                    leadingBlank = false;
            }
            break;
        }

        case '=':
        {
            /* A line consisting solely of == indicates a Markdown heading on the previous line. */
            if (leadingBlank && !inCode)
            {
                if (!lineQuoted && quoteLevel)
                {
                    i += MarkdownList.endAllNestedLists(buf, iLineStart, nestedLists);
                    i += endAllMarkdownQuotes(buf, iLineStart, quoteLevel, quoteMacroLevel);
                    break;
                }

                leadingBlank = false;
                size_t iAfterUnderline = skipChars(buf, i, "=");
                iAfterUnderline = skipChars(buf, iAfterUnderline, " \t\r");
                if (iAfterUnderline >= buf.offset || buf.data[iAfterUnderline] != '\n')
                    break;
                size_t iBeforeNewline = iLineStart;
                while (iBeforeNewline > offset && (buf.data[iBeforeNewline-1] == '\r' || buf.data[iBeforeNewline-1] == '\n'))
                    --iBeforeNewline;
                if (iBeforeNewline <= iParagraphStart)
                {
                    iParagraphStart = iAfterUnderline;
                    break;
                }

                buf.remove(iBeforeNewline, iAfterUnderline - iBeforeNewline);
                i = iBeforeNewline;

                replaceMarkdownEmphasis(buf, i, inlineDelimiters);

                iLineStart = i;
                headingLevel = c == '=' ? 1 : 2;

                endMarkdownHeading(buf, i, headingLevel, iParagraphStart);

                iParagraphStart = skipChars(buf, i+1, " \t\r\n");
            }
            break;
        }

        case '*':
        {
            if (inCode || inBacktick)
                break;

            if (leadingBlank)
            {
                /* A line consisting solely of ** indicates a Markdown heading on the previous line, or a thematic break after an empty line. */
                leadingBlank = false;
                size_t iAfterUnderline = skipChars(buf, i, "* \t\r");
                if (iAfterUnderline >= buf.offset || buf.data[iAfterUnderline] == '\n')
                {
                    // see if there was whitespace within the ** line
                    size_t iStrictAfterUnderline = skipChars(buf, i, "*");
                    iStrictAfterUnderline = skipChars(buf, iStrictAfterUnderline, " \t\r");

                    if (iPreceedingBlankLine ||
                        iStrictAfterUnderline != iAfterUnderline ||
                        iParagraphStart == iLineStart ||
                        (!lineQuoted && quoteLevel))
                    {
                        // if in a new paragraph then treat it as a thematic break
                        if (!lineQuoted && quoteLevel)
                        {
                            i += MarkdownList.endAllNestedLists(buf, iLineStart, nestedLists);
                            i += endAllMarkdownQuotes(buf, iLineStart, quoteLevel, quoteMacroLevel);
                        }
                        replaceMarkdownThematicBreak(buf, i, iLineStart);
                        removeBlankLineMacro(buf, iPreceedingBlankLine, i);
                        iParagraphStart = skipChars(buf, i+1, " \t\r\n");
                        break;
                    }
                    else if (skipChars(buf, i, "*") - i >= 2)
                    {
                        // otherwise treat it as a 2nd-level heading
                        leadingBlank = true;
                        i = iAfterUnderline;
                        goto case '=';
                    }
                }
                else
                {
                    MarkdownList list = MarkdownList.parseItem(buf, iLineStart, i);
                    if (list.isValid)
                    {
                        leadingBlank = true;
                        goto case '+';
                    }
                }
            }

            // Markdown emphasis
            char leftC = i > offset ? buf.data[i-1] : '\0';
            size_t iAfterEmphasis = skipChars(buf, i+1, "*");
            char rightC = iAfterEmphasis < buf.offset ? buf.data[iAfterEmphasis] : '\0';
            int count = cast(int) (iAfterEmphasis - i);
            bool leftFlanking = (rightC != '\0' && !isWhitespace(rightC)) && (!isPunctuation(rightC) || leftC == '\0' || isWhitespace(leftC) || isPunctuation(leftC));
            bool rightFlanking = (leftC != '\0' && !isWhitespace(leftC)) && (!isPunctuation(leftC) || rightC == '\0' || isWhitespace(rightC) || isPunctuation(rightC));
            auto emphasis = MarkdownDelimiter(i, count, macroLevel, leftFlanking, rightFlanking, c);

            if (!emphasis.leftFlanking && !emphasis.rightFlanking)
            {
                i = iAfterEmphasis - 1;
                break;
            }

            inlineDelimiters ~= emphasis;
            i += emphasis.count;
            --i;
            break;
        }

        case '!':
        {
            if (inCode)
                break;

            if (i < buf.offset-1 && buf.data[i+1] == '[')
            {
                auto imageStart = MarkdownDelimiter(i, 2, macroLevel, false, false, c);
                inlineDelimiters ~= imageStart;
                ++i;
            }
            break;
        }
        case '[':
        {
            if (inCode)
                break;

            if (leadingBlank && iParagraphStart >= iLineStart && linkReferences.extractReference(buf, i))
            {
                --i;
            }
            else
            {
                auto linkStart = MarkdownDelimiter(i, 1, macroLevel, false, false, c);
                inlineDelimiters ~= linkStart;
            }
            break;
        }
        case ']':
        {
            if (inCode || i >= buf.offset - 2)
                break;

            for (int d = cast(int) inlineDelimiters.length - 1; d >= 0; --d)
            {
                auto delimiter = inlineDelimiters[d];
                if (delimiter.type == '[' || delimiter.type == '!')
                {
                    if (!MarkdownLink.replaceInlineLink(buf, i, inlineDelimiters, d) &&
                        !MarkdownLink.replaceReferenceLink(buf, i, inlineDelimiters, d, linkReferences))
                    {
                        // nothing found, so kill the delimiter
                        inlineDelimiters = inlineDelimiters[0..d] ~ inlineDelimiters[d+1..$];
                    }
                }
            }
            break;
        }

        case '\\':
        {
            /* Escape Markdown special characters */
            if (inCode || i+1 >= buf.offset)
                break;
            char c1 = buf.data[i+1];
            if (isPunctuation(c1))
            {
                buf.remove(i, 1);

                const se = sc._module.escapetable.escapeChar(c1);
                if (se)
                {
                    const len = strlen(se);
                    buf.remove(i, 1);
                    i = buf.insert(i, se, len);
                    i--; // point to ';'
                }
            }
            else if (!headingLevel && (c1 == '\r' || c1 == '\n'))
            {
                size_t iAfterBlanks = skipChars(buf, i + 2, " \t\r\n");
                size_t iAfterSetextHeader = skipChars(buf, iAfterBlanks, "*");
                if (iAfterSetextHeader == iAfterBlanks)
                    iAfterSetextHeader = skipChars(buf, iAfterBlanks, "=");
                if (iAfterSetextHeader - iAfterBlanks < 3)
                {
                    buf.remove(i, 1);
                    i = buf.insert(i, "$(BR)");
                }
            }
            leadingBlank = false;
            break;
        }

        case '$':
        {
            /* Look for the start of a macro, '$(Identifier'
             */
            leadingBlank = false;
            if (inCode || inBacktick)
                break;
            const slice = buf.peekSlice();
            auto p = &slice[i];
            if (p[1] == '(' && isIdStart(&p[2]))
                ++macroLevel;
            break;
        }

        case '(':
        {
            if (!inCode && i > offset && buf.data[i-1] != '$')
                ++parenLevel;
            break;
        }

        case ')':
        {   /* End of macro
             */
            leadingBlank = false;
            if (inCode || inBacktick)
                break;
            if (parenLevel > 0)
                --parenLevel;
            else if (macroLevel)
            {
                replaceMarkdownEmphasis(buf, i, inlineDelimiters);
                if (headingLevel && headingMacroLevel >= macroLevel)
                {
                    endMarkdownHeading(buf, i, headingLevel, iParagraphStart);
                    removeBlankLineMacro(buf, iPreceedingBlankLine, i);
                }
                if (quoteLevel && quoteMacroLevel >= macroLevel)
                    endAllMarkdownQuotes(buf, i, quoteLevel, quoteMacroLevel);
                while (nestedLists.length && nestedLists[$-1].macroLevel >= macroLevel)
                {
                    i = buf.insert(i, ")\n)");
                    --nestedLists.length;
                }
                while (inlineDelimiters.length && inlineDelimiters[$-1].macroLevel >= macroLevel)
                    --inlineDelimiters.length;
                if (linkReferences.iParsedUntil <= i)
                    linkReferences.iParsedUntil = i + 1;

                --macroLevel;
            }
            break;
        }

        default:
            leadingBlank = false;
            if (sc._module.isDocFile || inCode)
                break;
            const start = cast(char*)buf.data + i;
            if (isIdStart(start))
            {
                size_t j = skippastident(buf, i);
                if (i < j)
                {
                    size_t k = skippastURL(buf, i);
                    if (i < k)
                    {
                        /* The URL is buf[i..k]
                         */
                        if (macroLevel)
                            /* Leave alone if already in a macro
                             */
                            i = k - 1;
                        else
                        {
                            /* Replace URL with '$(DDOC_LINK_AUTODETECT URL)'
                             */
                            i = buf.bracket(i, "$(DDOC_LINK_AUTODETECT ", k, ")") - 1;
                        }
                        break;
                    }
                }
                else
                    break;
                size_t len = j - i;
                // leading '_' means no highlight unless it's a reserved symbol name
                if (c == '_' && (i == 0 || !isdigit(*(start - 1))) && (i == buf.offset - 1 || !isReservedName(start, len)))
                {
                    buf.remove(i, 1);
                    i = buf.bracket(i, "$(DDOC_AUTO_PSYMBOL_SUPPRESS ", j - 1, ")") - 1;
                    break;
                }
                if (isIdentifier(a, start, len))
                {
                    i = buf.bracket(i, "$(DDOC_AUTO_PSYMBOL ", j, ")") - 1;
                    break;
                }
                if (isKeyword(start, len))
                {
                    i = buf.bracket(i, "$(DDOC_AUTO_KEYWORD ", j, ")") - 1;
                    break;
                }
                if (isFunctionParameter(a, start, len))
                {
                    //printf("highlighting arg '%s', i = %d, j = %d\n", arg.ident.toChars(), i, j);
                    i = buf.bracket(i, "$(DDOC_AUTO_PARAM ", j, ")") - 1;
                    break;
                }
                i = j - 1;
            }
            break;
        }
    }

    if (inCode == '-')
        error(s ? s.loc : Loc.initial, "unmatched --- in DDoc comment");
    else if (inCode)
        buf.insert(buf.offset, ")");

    size_t i = buf.offset;
    replaceMarkdownEmphasis(buf, i, inlineDelimiters);
    if (headingLevel)
    {
        endMarkdownHeading(buf, i, headingLevel, iParagraphStart);
        removeBlankLineMacro(buf, iPreceedingBlankLine, i);
    }
    MarkdownList.endAllNestedLists(buf, i, nestedLists);
    endAllMarkdownQuotes(buf, i, quoteLevel, quoteMacroLevel);
    nestedLists.length = 0;
}

/**************************************************
 * Highlight code for DDOC section.
 */
extern (C++) void highlightCode(Scope* sc, Dsymbol s, OutBuffer* buf, size_t offset)
{
    //printf("highlightCode(s = %s '%s')\n", s.kind(), s.toChars());
    OutBuffer ancbuf;
    emitAnchor(&ancbuf, s, sc);
    buf.insert(offset, ancbuf.peekSlice());
    offset += ancbuf.offset;
    Dsymbols a;
    a.push(s);
    highlightCode(sc, &a, buf, offset);
}

/****************************************************
 */
extern (C++) void highlightCode(Scope* sc, Dsymbols* a, OutBuffer* buf, size_t offset)
{
    //printf("highlightCode(a = '%s')\n", a.toChars());
    bool resolvedTemplateParameters = false;

    for (size_t i = offset; i < buf.offset; i++)
    {
        char c = buf.data[i];
        const(char)* se = sc._module.escapetable.escapeChar(c);
        if (se)
        {
            size_t len = strlen(se);
            buf.remove(i, 1);
            i = buf.insert(i, se, len);
            i--; // point to ';'
            continue;
        }
        char* start = cast(char*)buf.data + i;
        if (isIdStart(start))
        {
            size_t j = skippastident(buf, i);
            if (i < j)
            {
                size_t len = j - i;
                if (isIdentifier(a, start, len))
                {
                    i = buf.bracket(i, "$(DDOC_PSYMBOL ", j, ")") - 1;
                    continue;
                }
                if (isFunctionParameter(a, start, len))
                {
                    //printf("highlighting arg '%s', i = %d, j = %d\n", arg.ident.toChars(), i, j);
                    i = buf.bracket(i, "$(DDOC_PARAM ", j, ")") - 1;
                    continue;
                }
                i = j - 1;
            }
        }
        else if (!resolvedTemplateParameters)
        {
            size_t previ = i;

            // hunt for template declarations:
            foreach (symi; 0 .. a.dim)
            {
                FuncDeclaration fd = (*a)[symi].isFuncDeclaration();

                if (!fd || !fd.parent || !fd.parent.isTemplateDeclaration())
                {
                    continue;
                }

                TemplateDeclaration td = fd.parent.isTemplateDeclaration();

                // build the template parameters
                Array!(size_t) paramLens;
                paramLens.reserve(td.parameters.dim);

                OutBuffer parametersBuf;
                HdrGenState hgs;

                parametersBuf.writeByte('(');

                foreach (parami; 0 .. td.parameters.dim)
                {
                    TemplateParameter tp = (*td.parameters)[parami];

                    if (parami)
                        parametersBuf.writestring(", ");

                    size_t lastOffset = parametersBuf.offset;

                    .toCBuffer(tp, &parametersBuf, &hgs);

                    paramLens[parami] = parametersBuf.offset - lastOffset;
                }
                parametersBuf.writeByte(')');

                const templateParams = parametersBuf.peekString();
                const templateParamsLen = parametersBuf.peekSlice().length;

                //printf("templateDecl: %s\ntemplateParams: %s\nstart: %s\n", td.toChars(), templateParams, start);

                if (cmp(templateParams, start, templateParamsLen) == 0)
                {
                    immutable templateParamListMacro = "$(DDOC_TEMPLATE_PARAM_LIST ";
                    buf.bracket(i, templateParamListMacro.ptr, i + templateParamsLen, ")");

                    // We have the parameter list. While we're here we might
                    // as well wrap the parameters themselves as well

                    // + 1 here to take into account the opening paren of the
                    // template param list
                    i += templateParamListMacro.length + 1;

                    foreach (const len; paramLens)
                    {
                        i = buf.bracket(i, "$(DDOC_TEMPLATE_PARAM ", i + len, ")");
                        // increment two here for space + comma
                        i += 2;
                    }

                    resolvedTemplateParameters = true;
                    // reset i to be positioned back before we found the template
                    // param list this assures that anything within the template
                    // param list that needs to be escaped or otherwise altered
                    // has an opportunity for that to happen outside of this context
                    i = previ;

                    continue;
                }
            }
        }
    }
}

/****************************************
 */
extern (C++) void highlightCode3(Scope* sc, OutBuffer* buf, const(char)* p, const(char)* pend)
{
    for (; p < pend; p++)
    {
        const(char)* s = sc._module.escapetable.escapeChar(*p);
        if (s)
            buf.writestring(s);
        else
            buf.writeByte(*p);
    }
}

/**************************************************
 * Highlight code for CODE section.
 */
extern (C++) void highlightCode2(Scope* sc, Dsymbols* a, OutBuffer* buf, size_t offset)
{
    uint errorsave = global.errors;
    scope Lexer lex = new Lexer(null, cast(char*)buf.data, 0, buf.offset - 1, 0, 1);
    OutBuffer res;
    const(char)* lastp = cast(char*)buf.data;
    //printf("highlightCode2('%.*s')\n", buf.offset - 1, buf.data);
    res.reserve(buf.offset);
    while (1)
    {
        Token tok;
        lex.scan(&tok);
        highlightCode3(sc, &res, lastp, tok.ptr);
        const(char)* highlight = null;
        switch (tok.value)
        {
        case TOK.identifier:
            {
                if (!sc)
                    break;
                size_t len = lex.p - tok.ptr;
                if (isIdentifier(a, tok.ptr, len))
                {
                    highlight = "$(D_PSYMBOL ";
                    break;
                }
                if (isFunctionParameter(a, tok.ptr, len))
                {
                    //printf("highlighting arg '%s', i = %d, j = %d\n", arg.ident.toChars(), i, j);
                    highlight = "$(D_PARAM ";
                    break;
                }
                break;
            }
        case TOK.comment:
            highlight = "$(D_COMMENT ";
            break;
        case TOK.string_:
            highlight = "$(D_STRING ";
            break;
        default:
            if (tok.isKeyword())
                highlight = "$(D_KEYWORD ";
            break;
        }
        if (highlight)
        {
            res.writestring(highlight);
            size_t o = res.offset;
            highlightCode3(sc, &res, tok.ptr, lex.p);
            if (tok.value == TOK.comment || tok.value == TOK.string_)
                /* https://issues.dlang.org/show_bug.cgi?id=7656
                 * https://issues.dlang.org/show_bug.cgi?id=7715
                 * https://issues.dlang.org/show_bug.cgi?id=10519
                 */
                escapeDdocString(&res, o);
            res.writeByte(')');
        }
        else
            highlightCode3(sc, &res, tok.ptr, lex.p);
        if (tok.value == TOK.endOfFile)
            break;
        lastp = lex.p;
    }
    buf.setsize(offset);
    buf.write(&res);
    global.errors = errorsave;
}

/****************************************
 * Determine if p points to the start of a "..." parameter identifier.
 */
extern (C++) bool isCVariadicArg(const(char)* p, size_t len)
{
    return len >= 3 && cmp("...", p, 3) == 0;
}

/****************************************
 * Determine if p points to the start of an identifier.
 */
extern (C++) bool isIdStart(const(char)* p)
{
    dchar c = *p;
    if (isalpha(c) || c == '_')
        return true;
    if (c >= 0x80)
    {
        size_t i = 0;
        if (utf_decodeChar(p, 4, i, c))
            return false; // ignore errors
        if (isUniAlpha(c))
            return true;
    }
    return false;
}

/****************************************
 * Determine if p points to the rest of an identifier.
 */
extern (C++) bool isIdTail(const(char)* p)
{
    dchar c = *p;
    if (isalnum(c) || c == '_')
        return true;
    if (c >= 0x80)
    {
        size_t i = 0;
        if (utf_decodeChar(p, 4, i, c))
            return false; // ignore errors
        if (isUniAlpha(c))
            return true;
    }
    return false;
}

/****************************************
 * Determine if p points to the indentation space.
 */
extern (C++) bool isIndentWS(const(char)* p)
{
    return (*p == ' ') || (*p == '\t');
}

/*****************************************
 * Return number of bytes in UTF character.
 */
extern (C++) int utfStride(const(char)* p)
{
    dchar c = *p;
    if (c < 0x80)
        return 1;
    size_t i = 0;
    utf_decodeChar(p, 4, i, c); // ignore errors, but still consume input
    return cast(int)i;
}

inout(char)* stripLeadingNewlines(inout(char)* s)
{
    while (s && *s == '\n' || *s == '\r')
        s++;

    return s;
}
