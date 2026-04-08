#pragma once
#include <stddef.h>

#define HUGE_VAL  __builtin_huge_val()
#define HUGE_VALF __builtin_huge_valf()
#define NAN       __builtin_nan("")
#define INFINITY  __builtin_inf()
#define M_PI      3.14159265358979323846

static inline double fabs(double x)  { return __builtin_fabs(x); }
static inline float  fabsf(float x)  { return __builtin_fabsf(x); }
static inline double floor(double x) { return __builtin_floor(x); }
static inline double ceil(double x)  { return __builtin_ceil(x); }

/* Implemented in math.c */
double sqrt(double x);
double sin (double x);
double cos (double x);
double tan  (double x);
double exp  (double x);
double log  (double x);
double log2 (double x);
double log10(double x);
double pow  (double x, double y);
double atan (double x);
double atan2(double y, double x);
double asin (double x);
double acos (double x);
double fmod (double x, double y);
double modf (double x, double *iptr);
double ldexp(double x, int n);
double frexp(double x, int *exp);
double sinh (double x);
double cosh (double x);
double tanh (double x);
