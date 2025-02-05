@__edition_latest_do_not_use
module edition_complex;

struct cfloat
{
    float re;
    ifloat im;
}
alias ifloat = float;

struct cdouble
{
    double re;
    idouble im;
}
alias idouble = double;

struct creal
{
    real re;
    ireal im;
}
alias ireal = real;
