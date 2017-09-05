module ddmd.semantic;

import ddmd.arraytypes;
import ddmd.dsymbol;
import ddmd.dscope;
import ddmd.dtemplate;
import ddmd.expression;
import ddmd.init;
import ddmd.mtype;
import ddmd.statement;

import ddmd.initsem;
import ddmd.dsymbolsem;
import ddmd.expressionsem;
import ddmd.statementsem;
import ddmd.templateparamsem;

/*************************************
 * Does semantic analysis on the public face of declarations.
 */
extern(C++) void semantic(Dsymbol dsym, Scope* sc)
{
    scope v = new DsymbolSemanticVisitor(sc);
    dsym.accept(v);
}

// entrypoint for semantic ExpressionSemanticVisitor
extern (C++) Expression semantic(Expression e, Scope* sc)
{
    scope v = new ExpressionSemanticVisitor(sc);
    e.accept(v);
    return v.result;
}

/******************************************
 * Perform semantic analysis on init.
 * Params:
 *      init = Initializer AST node
 *      sc = context
 *      t = type that the initializer needs to become
 *      needInterpret = if CTFE needs to be run on this,
 *                      such as if it is the initializer for a const declaration
 * Returns:
 *      `Initializer` with completed semantic analysis, `ErrorInitializer` if errors
 *      were encountered
 */
extern (C++) Initializer semantic(Initializer init, Scope* sc, Type t, NeedInterpret needInterpret)
{
    scope v = new InitializerSemanticVisitor(sc, t, needInterpret);
    init.accept(v);
    return v.result;
}

// Performs semantic analisys in Statement AST nodes
extern (C++) Statement semantic(Statement s, Scope* sc)
{
    scope v = new StatementSemanticVisitor(sc);
    s.accept(v);
    return v.result;
}

// Performs semantic on TemplateParamter AST nodes
extern (C++) bool semantic(TemplateParameter tp, Scope* sc, TemplateParameters* parameters)
{
    scope v = new TemplateParameterSemanticVisitor(sc, parameters);
    tp.accept(v);
    return v.result;
}

void semantic(Catch c, Scope* sc)
{
    semanticWrapper(c, sc);
}

/*************************************
 * Does semantic analysis on initializers and members of aggregates.
 */
void semantic2(Dsymbol dsym, Scope* sc)
{
    scope v = new Semantic2Visitor(sc);
    dsym.accept(v);
}
