#include "math.h"

/* All math via x87 FPU inline asm */

double sqrt(double x) {
    double r;
    __asm__("fsqrt" : "=t"(r) : "0"(x));
    return r;
}

double sin(double x) {
    double r;
    __asm__("fsin" : "=t"(r) : "0"(x));
    return r;
}

double cos(double x) {
    double r;
    __asm__("fcos" : "=t"(r) : "0"(x));
    return r;
}

double tan(double x) {
    double r, dummy;
    __asm__("fptan" : "=t"(dummy), "=u"(r) : "0"(x));
    return r;
}

/* exp(x) = 2^(x * log2e) */
double exp(double x) {
    double r;
    __asm__(
        "fldl2e\n\t"          /* st0 = log2(e)           */
        "fmulp\n\t"           /* st0 = x * log2(e)       */
        "fld1\n\t"            /* st0 = 1, st1 = x*log2e  */
        "fld %%st(1)\n\t"     /* st0 = frac, st1 = 1     */
        "fprem\n\t"           /* st0 = frac(x*log2e)     */
        "f2xm1\n\t"           /* st0 = 2^frac - 1        */
        "faddp\n\t"           /* st0 = 2^frac            */
        "fscale\n\t"          /* st0 = 2^frac * 2^floor  */
        "fstp %%st(1)"        /* pop extra                */
        : "=t"(r) : "0"(x) : "st(1)"
    );
    return r;
}

/* ln(x) = log2(x) * ln(2) */
double log(double x) {
    double r;
    __asm__(
        "fldln2\n\t"
        "fxch\n\t"
        "fyl2x"
        : "=t"(r) : "0"(x)
    );
    return r;
}

double log2(double x) {
    double r;
    __asm__("fld1\n\t fxch\n\t fyl2x" : "=t"(r) : "0"(x));
    return r;
}

double log10(double x) {
    double r;
    __asm__("fldlg2\n\t fxch\n\t fyl2x" : "=t"(r) : "0"(x));
    return r;
}

/* pow(x,y) = 2^(y * log2(x)) */
double pow(double x, double y) {
    if (x == 0.0) return 0.0;
    return exp(y * log(x));
}

double atan(double x) {
    double r;
    __asm__("fld1\n\t fpatan" : "=t"(r) : "0"(x));
    return r;
}

double atan2(double y, double x) {
    double r;
    __asm__("fpatan" : "=t"(r) : "0"(x), "u"(y) : "st(1)");
    return r;
}

double asin(double x) {
    return atan2(x, sqrt(1.0 - x * x));
}

double acos(double x) {
    return atan2(sqrt(1.0 - x * x), x);
}

double fmod(double x, double y) {
    double r;
    __asm__("1: fprem1\n\t fnstsw %%ax\n\t testb $4, %%ah\n\t jnz 1b"
            : "=t"(r) : "0"(x), "u"(y) : "ax");
    return r;
}

double modf(double x, double *iptr) {
    double i = (x >= 0) ? floor(x) : ceil(x);
    *iptr = i;
    return x - i;
}

double ldexp(double x, int n) {
    double r, fn = (double)n;
    __asm__("fscale" : "=t"(r) : "0"(x), "u"(fn));
    return r;
}

double frexp(double x, int *exp) {
    if (x == 0.0) { *exp = 0; return 0.0; }
    double m, e;
    __asm__("fxtract" : "=t"(m), "=u"(e) : "0"(x));
    *exp = (int)e + 1;
    return m * 0.5;
}

double sinh(double x)  { return (exp(x) - exp(-x)) * 0.5; }
double cosh(double x)  { return (exp(x) + exp(-x)) * 0.5; }
double tanh(double x)  { double e2 = exp(2.0 * x); return (e2 - 1.0) / (e2 + 1.0); }
