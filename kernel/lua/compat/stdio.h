#pragma once
#include <stddef.h>
#include <stdarg.h>

#define BUFSIZ  512
#define EOF     (-1)

typedef struct { int _fd; } FILE;
extern FILE *stdout;
extern FILE *stderr;
#define stdin  ((FILE*)0)

int    vsnprintf(char *buf, size_t size, const char *fmt, va_list ap);
int    snprintf (char *buf, size_t size, const char *fmt, ...);
int    sprintf  (char *buf, const char *fmt, ...);
int    vfprintf (FILE *f,   const char *fmt, va_list ap);
int    fprintf  (FILE *f,   const char *fmt, ...);
int    printf   (const char *fmt, ...);
int    puts     (const char *s);

size_t fwrite  (const void *ptr, size_t size, size_t nmemb, FILE *f);
size_t fread   (void *ptr, size_t size, size_t nmemb, FILE *f);
int    fflush  (FILE *f);
int    fclose  (FILE *f);
int    feof    (FILE *f);
int    ferror  (FILE *f);
int    getc    (FILE *f);
int    ungetc  (int c, FILE *f);
FILE  *fopen   (const char *path, const char *mode);
FILE  *freopen (const char *path, const char *mode, FILE *f);
long   ftell   (FILE *f);
int    fseek   (FILE *f, long offset, int whence);
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2
