#include "stdlib.h"
#include "string.h"
#include "errno.h"

/* ── Kernel heap bridge ─────────────────────────────────────────────────────*/
extern void *kmalloc(unsigned int size);
extern void  kfree(void *ptr);
extern void *krealloc(void *ptr, unsigned int size);

void *malloc(size_t n)          { return kmalloc((unsigned int)n); }
void *realloc(void *p, size_t n){ return krealloc(p, (unsigned int)n); }
void  free(void *p)             { kfree(p); }

void exit(int code) {
    (void)code;
    __asm__ volatile ("cli; hlt");
    __builtin_unreachable();
}
void abort(void) { exit(1); }

/* ── Integer parsing ─────────────────────────────────────────────────────── */
static int _digitval(char c, int base) {
    int v;
    if (c >= '0' && c <= '9') v = c - '0';
    else if (c >= 'a' && c <= 'z') v = c - 'a' + 10;
    else if (c >= 'A' && c <= 'Z') v = c - 'A' + 10;
    else return -1;
    return v < base ? v : -1;
}

unsigned long strtoul(const char *s, char **end, int base) {
    while (*s == ' ' || *s == '\t') s++;
    if (*s == '+') s++;
    if (base == 0) {
        if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) { base = 16; s += 2; }
        else if (s[0] == '0') { base = 8; s++; }
        else base = 10;
    } else if (base == 16 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) s += 2;
    unsigned long r = 0;
    const char *start = s;
    int d;
    while ((d = _digitval(*s, base)) >= 0) { r = r * base + d; s++; }
    if (end) *end = (char *)(s == start ? start : s);
    return r;
}

long strtol(const char *s, char **end, int base) {
    while (*s == ' ' || *s == '\t') s++;
    int neg = 0;
    if (*s == '-') { neg = 1; s++; }
    else if (*s == '+') s++;
    unsigned long u = strtoul(s, end, base);
    return neg ? -(long)u : (long)u;
}

long  atol(const char *s) { return strtol(s, 0, 10); }
int   atoi(const char *s) { return (int)atol(s); }

/* ── Float parsing (simple but correct for normal numbers) ──────────────── */
double strtod(const char *s, char **end) {
    while (*s == ' ' || *s == '\t') s++;
    int neg = 0;
    if (*s == '-') { neg = 1; s++; }
    else if (*s == '+') s++;
    double r = 0.0;
    const char *start = s;
    while (*s >= '0' && *s <= '9') r = r * 10.0 + (*s++ - '0');
    if (*s == '.') {
        s++;
        double f = 0.1;
        while (*s >= '0' && *s <= '9') { r += (*s++ - '0') * f; f *= 0.1; }
    }
    if (*s == 'e' || *s == 'E') {
        s++;
        int eneg = 0;
        if (*s == '-') { eneg = 1; s++; } else if (*s == '+') s++;
        int e = 0;
        while (*s >= '0' && *s <= '9') e = e * 10 + (*s++ - '0');
        double p = 1.0;
        while (e--) p *= 10.0;
        r = eneg ? r / p : r * p;
    }
    if (end) *end = (char *)(s == start ? start : s);
    return neg ? -r : r;
}
double atof(const char *s) { return strtod(s, 0); }

/* ── qsort (simple insertion sort — small arrays in Lua) ────────────────── */
void qsort(void *base, size_t n, size_t sz,
           int (*cmp)(const void *, const void *)) {
    char *b = base;
    for (size_t i = 1; i < n; i++) {
        size_t j = i;
        while (j > 0 && cmp(b + (j-1)*sz, b + j*sz) > 0) {
            /* swap */
            char *a = b + (j-1)*sz, *c = b + j*sz;
            for (size_t k = 0; k < sz; k++) { char t = a[k]; a[k] = c[k]; c[k] = t; }
            j--;
        }
    }
}

void *bsearch(const void *key, const void *base, size_t n, size_t sz,
              int (*cmp)(const void *, const void *)) {
    const char *b = base;
    size_t lo = 0, hi = n;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        int r = cmp(key, b + mid * sz);
        if (r < 0) hi = mid;
        else if (r > 0) lo = mid + 1;
        else return (void *)(b + mid * sz);
    }
    return 0;
}

/* ── Random (xorshift32) ────────────────────────────────────────────────── */
static unsigned int _rseed = 12345;
int  rand(void)            { _rseed ^= _rseed<<13; _rseed ^= _rseed>>17; _rseed ^= _rseed<<5; return (int)(_rseed & 0x7FFFFFFF); }
void srand(unsigned int s) { _rseed = s ? s : 1; }

int abs (int n)  { return n < 0 ? -n : n; }
long labs(long n) { return n < 0 ? -n : n; }

/* errno — global variable */
int errno = 0;
