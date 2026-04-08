#include "stdio.h"
#include "string.h"
#include "stdlib.h"
#include <stdint.h>

extern void serial_putc(char c);
extern void serial_puts(const char *s);

/* Fake FILE handles */
static FILE _stdout = {1};
static FILE _stderr = {2};
FILE *stdout = &_stdout;
FILE *stderr = &_stderr;

static void _out_char(char **buf, size_t *rem, char c) {
    if (*rem > 1) { **buf = c; (*buf)++; (*rem)--; }
}

static void _out_str(char **buf, size_t *rem, const char *s, int width, int left) {
    size_t slen = strlen(s);
    int pad = (width > (int)slen) ? width - (int)slen : 0;
    if (!left) while (pad--) _out_char(buf, rem, ' ');
    while (*s) _out_char(buf, rem, *s++);
    if (left)  while (pad--) _out_char(buf, rem, ' ');
}

/* Write unsigned long in given base; returns pointer to first char in tmp buf */
static int _uitoa(unsigned long v, char *tmp, int base, int upper) {
    const char *digits = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    int len = 0;
    if (!v) { tmp[0] = '0'; return 1; }
    while (v) { tmp[len++] = digits[v % base]; v /= base; }
    /* reverse */
    for (int i = 0, j = len-1; i < j; i++, j--) { char t = tmp[i]; tmp[i] = tmp[j]; tmp[j] = t; }
    return len;
}

/* Minimal float → string for %f/%g/%e */
static int _ftoa(double v, char *buf, int prec, char fmt) {
    (void)fmt;
    if (prec < 0) prec = 6;
    char *p = buf;
    if (v < 0) { *p++ = '-'; v = -v; }
    /* integer part */
    long long iv = (long long)v;
    double fv = v - (double)iv;
    char tmp[32]; int ilen = _uitoa((unsigned long long)iv, tmp, 10, 0);
    for (int i = 0; i < ilen; i++) *p++ = tmp[i];
    if (prec > 0) {
        *p++ = '.';
        for (int i = 0; i < prec; i++) {
            fv *= 10;
            int d = (int)fv;
            *p++ = '0' + d;
            fv -= d;
        }
    }
    *p = 0;
    return (int)(p - buf);
}

int vsnprintf(char *buf, size_t size, const char *fmt, va_list ap) {
    char *p = buf;
    size_t rem = size;
    char tmp[64];

    for (; *fmt; fmt++) {
        if (*fmt != '%') { _out_char(&p, &rem, *fmt); continue; }
        fmt++;
        /* flags */
        int left = 0, zero = 0;
        while (*fmt == '-' || *fmt == '0') {
            if (*fmt == '-') left = 1;
            if (*fmt == '0') zero = 1;
            fmt++;
        }
        /* width */
        int width = 0;
        while (*fmt >= '0' && *fmt <= '9') width = width * 10 + (*fmt++ - '0');
        /* precision */
        int prec = -1;
        if (*fmt == '.') { fmt++; prec = 0; while (*fmt >= '0' && *fmt <= '9') prec = prec * 10 + (*fmt++ - '0'); }
        /* length modifier */
        int lng = 0;
        if (*fmt == 'l') { lng = 1; fmt++; if (*fmt == 'l') { lng = 2; fmt++; } }
        else if (*fmt == 'z') { lng = 1; fmt++; }

        char spec = *fmt;
        switch (spec) {
        case 'd': case 'i': {
            long long v = lng >= 2 ? va_arg(ap, long long) : lng ? va_arg(ap, long) : va_arg(ap, int);
            int neg = v < 0; if (neg) v = -v;
            int len = _uitoa((unsigned long long)v, tmp, 10, 0);
            int pad = width - len - neg;
            if (!left && !zero) while (pad-- > 0) _out_char(&p, &rem, ' ');
            if (neg) _out_char(&p, &rem, '-');
            if (!left && zero) while (pad-- > 0) _out_char(&p, &rem, '0');
            for (int i = 0; i < len; i++) _out_char(&p, &rem, tmp[i]);
            if (left) while (pad-- > 0) _out_char(&p, &rem, ' ');
            break;
        }
        case 'u': case 'x': case 'X': case 'p': {
            unsigned long long v = (spec == 'p') ? (unsigned long long)(uintptr_t)va_arg(ap, void*) :
                                   lng >= 2 ? va_arg(ap, unsigned long long) :
                                   lng ? va_arg(ap, unsigned long) : va_arg(ap, unsigned int);
            int base = (spec == 'u') ? 10 : 16;
            int upper = (spec == 'X');
            if (spec == 'p') { _out_str(&p, &rem, "0x", 0, 0); width = width > 2 ? width - 2 : 0; }
            int len = _uitoa(v, tmp, base, upper);
            int pad = width - len;
            if (!left && !zero) while (pad-- > 0) _out_char(&p, &rem, ' ');
            if (!left && zero)  while (pad-- > 0) _out_char(&p, &rem, '0');
            for (int i = 0; i < len; i++) _out_char(&p, &rem, tmp[i]);
            if (left) while (pad-- > 0) _out_char(&p, &rem, ' ');
            break;
        }
        case 'f': case 'g': case 'G': case 'e': case 'E': {
            double v = va_arg(ap, double);
            int len = _ftoa(v, tmp, prec < 0 ? (spec=='g'||spec=='G' ? 6 : 6) : prec, spec);
            int pad = width - len;
            if (!left) while (pad-- > 0) _out_char(&p, &rem, zero ? '0' : ' ');
            for (int i = 0; i < len; i++) _out_char(&p, &rem, tmp[i]);
            if (left)  while (pad-- > 0) _out_char(&p, &rem, ' ');
            break;
        }
        case 's': {
            const char *s = va_arg(ap, const char *);
            if (!s) s = "(null)";
            if (prec >= 0) {
                size_t sl = strlen(s);
                if ((size_t)prec < sl) { /* use prec as max length */
                    char tmp2[256]; size_t l = (size_t)prec < sizeof(tmp2)-1 ? (size_t)prec : sizeof(tmp2)-1;
                    for (size_t i = 0; i < l; i++) tmp2[i] = s[i]; tmp2[l] = 0;
                    _out_str(&p, &rem, tmp2, width, left); break;
                }
            }
            _out_str(&p, &rem, s, width, left);
            break;
        }
        case 'c': { char c = (char)va_arg(ap, int); _out_char(&p, &rem, c); break; }
        case '%': _out_char(&p, &rem, '%'); break;
        default:  _out_char(&p, &rem, '%'); _out_char(&p, &rem, spec); break;
        }
    }
    if (size > 0) *p = 0;
    return (int)(p - buf);
}

int snprintf(char *buf, size_t sz, const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    int r = vsnprintf(buf, sz, fmt, ap);
    va_end(ap); return r;
}
int sprintf(char *buf, const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    int r = vsnprintf(buf, 0x7FFFFFFF, fmt, ap);
    va_end(ap); return r;
}

static void _serial_puts_n(const char *s, size_t n) {
    for (size_t i = 0; i < n; i++) serial_putc(s[i]);
}

int vfprintf(FILE *f, const char *fmt, va_list ap) {
    (void)f;
    char buf[512];
    int r = vsnprintf(buf, sizeof(buf), fmt, ap);
    _serial_puts_n(buf, (size_t)r < sizeof(buf) ? (size_t)r : sizeof(buf)-1);
    return r;
}
int fprintf(FILE *f, const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    int r = vfprintf(f, fmt, ap);
    va_end(ap); return r;
}
int printf(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    int r = vfprintf(stdout, fmt, ap);
    va_end(ap); return r;
}
int puts(const char *s) { serial_puts(s); serial_putc('\n'); return 0; }
size_t fwrite(const void *ptr, size_t sz, size_t n, FILE *f) {
    (void)f; _serial_puts_n((const char *)ptr, sz * n); return n;
}
int    fflush (FILE *f)                          { (void)f; return 0; }
int    fclose (FILE *f)                          { (void)f; return 0; }
size_t fread  (void *p, size_t sz, size_t n, FILE *f) { (void)p;(void)sz;(void)n;(void)f; return 0; }
int    feof   (FILE *f)                          { (void)f; return 1; }
int    ferror (FILE *f)                          { (void)f; return 0; }
int    getc   (FILE *f)                          { (void)f; return -1; /* EOF */ }
int    ungetc (int c, FILE *f)                   { (void)c;(void)f; return -1; }
FILE  *fopen  (const char *p, const char *m)     { (void)p;(void)m; return 0; }
FILE  *freopen(const char *p, const char *m, FILE *f) { (void)p;(void)m;(void)f; return 0; }
long   ftell  (FILE *f)                          { (void)f; return -1; }
int    fseek  (FILE *f, long o, int w)           { (void)f;(void)o;(void)w; return -1; }
