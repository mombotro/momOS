#pragma once
#include <stdint.h>
/* stub — no signals in kernel */
typedef int sig_atomic_t;
typedef void (*sighandler_t)(int);
#define SIG_DFL ((sighandler_t)0)
#define SIG_IGN ((sighandler_t)1)
#define SIGABRT 6
static inline sighandler_t signal(int sig, sighandler_t h) { (void)sig; (void)h; return SIG_DFL; }
