#include "string.h"
#include <stdint.h>

void *memcpy(void *dst, const void *src, size_t n) {
    uint8_t *d = dst; const uint8_t *s = src;
    while (n--) *d++ = *s++;
    return dst;
}
void *memmove(void *dst, const void *src, size_t n) {
    uint8_t *d = dst; const uint8_t *s = src;
    if (d < s) { while (n--) *d++ = *s++; }
    else { d += n; s += n; while (n--) *--d = *--s; }
    return dst;
}
void *memset(void *dst, int c, size_t n) {
    uint8_t *d = dst;
    while (n--) *d++ = (uint8_t)c;
    return dst;
}
int memcmp(const void *a, const void *b, size_t n) {
    const uint8_t *p = a, *q = b;
    while (n--) { if (*p != *q) return *p - *q; p++; q++; }
    return 0;
}
void *memchr(const void *s, int c, size_t n) {
    const uint8_t *p = s;
    while (n--) { if (*p == (uint8_t)c) return (void *)p; p++; }
    return 0;
}

size_t strlen(const char *s) {
    size_t n = 0; while (s[n]) n++; return n;
}
char *strcpy(char *dst, const char *src) {
    char *d = dst; while ((*d++ = *src++)); return dst;
}
char *strncpy(char *dst, const char *src, size_t n) {
    char *d = dst;
    while (n && (*d++ = *src++)) n--;
    while (n-- > 1) *d++ = 0;
    return dst;
}
char *strcat(char *dst, const char *src) {
    char *d = dst; while (*d) d++;
    while ((*d++ = *src++));
    return dst;
}
char *strncat(char *dst, const char *src, size_t n) {
    char *d = dst; while (*d) d++;
    while (n-- && (*d++ = *src++));
    *d = 0;
    return dst;
}
int strcmp(const char *a, const char *b) {
    while (*a && *a == *b) { a++; b++; }
    return (unsigned char)*a - (unsigned char)*b;
}
int strncmp(const char *a, const char *b, size_t n) {
    while (n-- && *a && *a == *b) { a++; b++; }
    return n == (size_t)-1 ? 0 : (unsigned char)*a - (unsigned char)*b;
}
int strcoll(const char *a, const char *b) { return strcmp(a, b); }
char *strchr(const char *s, int c) {
    for (; *s; s++) if (*s == (char)c) return (char *)s;
    return c == 0 ? (char *)s : 0;
}
char *strrchr(const char *s, int c) {
    const char *last = 0;
    for (; *s; s++) if (*s == (char)c) last = s;
    return (char *)last;
}
char *strstr(const char *h, const char *n) {
    size_t nl = strlen(n);
    if (!nl) return (char *)h;
    for (; *h; h++) if (!strncmp(h, n, nl)) return (char *)h;
    return 0;
}
char *strpbrk(const char *s, const char *accept) {
    for (; *s; s++) {
        const char *a = accept;
        while (*a) { if (*s == *a) return (char *)s; a++; }
    }
    return 0;
}
size_t strspn(const char *s, const char *accept) {
    size_t n = 0;
    while (s[n]) {
        const char *a = accept;
        while (*a && *a != s[n]) a++;
        if (!*a) break;
        n++;
    }
    return n;
}
size_t strcspn(const char *s, const char *reject) {
    size_t n = 0;
    while (s[n]) {
        const char *r = reject;
        while (*r && *r != s[n]) r++;
        if (*r) break;
        n++;
    }
    return n;
}
char *strtok(char *s, const char *delim) {
    static char *saved;
    if (s) saved = s;
    if (!saved || !*saved) return 0;
    saved += strspn(saved, delim);
    if (!*saved) return 0;
    char *tok = saved;
    saved += strcspn(saved, delim);
    if (*saved) *saved++ = 0;
    return tok;
}
char *strerror(int errnum) {
    (void)errnum;
    return "error";
}
