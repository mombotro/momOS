#pragma once
#include <stdint.h>

#define PROC_MAX   8
#define PROC_NAME_MAX 63

typedef enum {
    PROC_DEAD    = 0,
    PROC_RUNNING = 1,
    PROC_SLEEPING = 2,
} proc_state_t;

typedef struct {
    int          pid;
    char         name[PROC_NAME_MAX + 1];
    proc_state_t state;
    uint32_t     cpu_ticks;    /* total PIT ticks consumed */
    uint32_t     overruns;     /* times time budget exceeded */
    uint32_t     spawn_tick;   /* pit_ticks() when created */
} proc_t;

void    proc_init  (void);
int     proc_alloc (const char *name);    /* returns pid or -1 */
void    proc_free  (int pid);
proc_t *proc_get   (int pid);
proc_t *proc_find  (const char *name);
void    proc_add_cpu(int pid, uint32_t ticks);
void    proc_add_overrun(int pid);

/* Iterate: returns next active pid >= start_pid, or -1 */
int     proc_next  (int start_pid);
