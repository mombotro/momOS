#pragma once
#include <stddef.h>

/* Memory — redirected to kernel heap in stdlib.c */
void *malloc (size_t n);
void *realloc(void *p, size_t n);
void  free   (void *p);

/* Program control */
void exit (int code) __attribute__((noreturn));
void abort(void)     __attribute__((noreturn));

/* Number parsing */
long          strtol (const char *s, char **end, int base);
unsigned long strtoul(const char *s, char **end, int base);
double        strtod (const char *s, char **end);
long          atol   (const char *s);
int           atoi   (const char *s);
double        atof   (const char *s);
int           abs    (int n);
long          labs   (long n);

/* Sorting / searching */
void qsort  (void *base, size_t n, size_t size,
             int (*cmp)(const void *, const void *));
void *bsearch(const void *key, const void *base, size_t n, size_t size,
              int (*cmp)(const void *, const void *));

#define RAND_MAX 0x7FFFFFFF
int  rand (void);
void srand(unsigned int seed);
