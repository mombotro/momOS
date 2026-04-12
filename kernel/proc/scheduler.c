#include "scheduler.h"
#include "process.h"
#include "../cpu/pit.h"
#include "../cpu/serial.h"
#include "../lua/lua.h"
#include "../lua/lauxlib.h"
#include <stdint.h>

static int      sched_pid     = -1;
static uint32_t sched_t0      = 0;
static int      last_overran  = 0;

/* ── Lua debug hook ─────────────────────────────────────────────────────────
   Called every SCHED_HOOK_INTERVAL Lua VM instructions.
   If the current app has used more than SCHED_BUDGET_TICKS PIT ticks,
   raise a Lua error to forcibly unwind through the pcall wrapper. */
static void sched_hook(lua_State *L, lua_Debug *ar) {
    (void)ar;
    if (sched_pid < 0) return;
    uint32_t elapsed = pit_ticks() - sched_t0;
    if (elapsed > SCHED_BUDGET_TICKS) {
        /* Uninstall hook before erroring to prevent re-entry */
        lua_sethook(L, NULL, 0, 0);
        proc_add_overrun(sched_pid);
        last_overran = 1;
        sched_pid = -1;
        luaL_error(L, "time budget exceeded");
    }
}

void sched_init(void) {
    sched_pid    = -1;
    last_overran = 0;
}

void sched_begin(lua_State *L, int pid, const char *name) {
    (void)name;
    sched_pid    = pid;
    sched_t0     = pit_ticks();
    last_overran = 0;
    lua_sethook(L, sched_hook, LUA_MASKCOUNT, SCHED_HOOK_INTERVAL);
}

void sched_end(lua_State *L, int pid) {
    lua_sethook(L, NULL, 0, 0);
    if (sched_pid >= 0) {
        /* Normal completion — record CPU time */
        uint32_t elapsed = pit_ticks() - sched_t0;
        proc_add_cpu(pid, elapsed);
        sched_pid = -1;
    }
    (void)L;
}

int sched_overran(void) { return last_overran; }
