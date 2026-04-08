#pragma once
#include <stdint.h>
typedef uint32_t time_t;
typedef uint32_t clock_t;
#define CLOCKS_PER_SEC 60
static inline time_t  time(time_t *t)   { if (t) *t = 0; return 0; }
static inline clock_t clock(void)       { return 0; }
