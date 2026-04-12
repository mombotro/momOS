#include "process.h"
#include "../cpu/pit.h"
#include "../cpu/serial.h"
#include <stdint.h>

static proc_t procs[PROC_MAX];
static int    next_pid = 1;

static void kstrncpy(char *dst, const char *src, int n) {
    int i = 0;
    while (i < n - 1 && src[i]) { dst[i] = src[i]; i++; }
    dst[i] = '\0';
}
static int kstrcmp(const char *a, const char *b) {
    while (*a && *a == *b) { a++; b++; }
    return (unsigned char)*a - (unsigned char)*b;
}

void proc_init(void) {
    for (int i = 0; i < PROC_MAX; i++) procs[i].state = PROC_DEAD;
}

int proc_alloc(const char *name) {
    for (int i = 0; i < PROC_MAX; i++) {
        if (procs[i].state == PROC_DEAD) {
            procs[i].pid        = next_pid++;
            procs[i].state      = PROC_RUNNING;
            procs[i].cpu_ticks  = 0;
            procs[i].overruns   = 0;
            procs[i].spawn_tick = pit_ticks();
            kstrncpy(procs[i].name, name, PROC_NAME_MAX + 1);
            serial_puts("[PROC] alloc pid=");
            serial_hex((uint32_t)procs[i].pid);
            serial_puts(" name=");
            serial_puts(procs[i].name);
            serial_puts("\n");
            return procs[i].pid;
        }
    }
    return -1; /* out of process slots */
}

void proc_free(int pid) {
    for (int i = 0; i < PROC_MAX; i++)
        if (procs[i].state != PROC_DEAD && procs[i].pid == pid) {
            procs[i].state = PROC_DEAD;
            return;
        }
}

proc_t *proc_get(int pid) {
    for (int i = 0; i < PROC_MAX; i++)
        if (procs[i].state != PROC_DEAD && procs[i].pid == pid)
            return &procs[i];
    return 0;
}

proc_t *proc_find(const char *name) {
    for (int i = 0; i < PROC_MAX; i++)
        if (procs[i].state != PROC_DEAD &&
            kstrcmp(procs[i].name, name) == 0)
            return &procs[i];
    return 0;
}

void proc_add_cpu(int pid, uint32_t ticks) {
    proc_t *p = proc_get(pid);
    if (p) p->cpu_ticks += ticks;
}

void proc_add_overrun(int pid) {
    proc_t *p = proc_get(pid);
    if (p) p->overruns++;
}

int proc_next(int start_pid) {
    for (int i = 0; i < PROC_MAX; i++)
        if (procs[i].state != PROC_DEAD && procs[i].pid >= start_pid)
            return procs[i].pid;
    return -1;
}
