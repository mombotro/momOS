#pragma once
#include <stdint.h>

struct lua_State;

/* Number of PIT ticks each app is allowed per update/draw call.
   At 60 Hz, 1 tick ≈ 16 ms. Budget of 6 = ~100 ms — enough for
   complex rendering in QEMU while still catching infinite loops. */
#define SCHED_BUDGET_TICKS   6

/* How often the Lua debug hook fires (every N instructions).
   Lower = more responsive preemption, higher = less overhead. */
#define SCHED_HOOK_INTERVAL  2000

void sched_init(void);

/* Call before executing an app's update or draw.
   pid = process id from proc_alloc(); name used in error messages. */
void sched_begin(struct lua_State *L, int pid, const char *name);

/* Call after the app returns (or pcall catches an error). */
void sched_end  (struct lua_State *L, int pid);

/* Returns 1 if the last sched_end detected an overrun */
int  sched_overran(void);
