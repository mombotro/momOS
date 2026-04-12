#include "msgqueue.h"
#include "../lua/lua.h"
#include "../lua/lauxlib.h"
#include "../cpu/serial.h"
#include <stdint.h>

static ipc_queue_t queues[IPC_MAX_QUEUES];

static int kstrncmp(const char *a, const char *b, int n) {
    while (n-- > 0 && *a && *a == *b) { a++; b++; }
    if (n < 0) return 0;
    return (unsigned char)*a - (unsigned char)*b;
}
static void kstrncpy(char *dst, const char *src, int n) {
    int i = 0;
    while (i < n - 1 && src[i]) { dst[i] = src[i]; i++; }
    dst[i] = '\0';
}

void ipc_init(void) {
    for (int i = 0; i < IPC_MAX_QUEUES; i++) {
        queues[i].active = 0;
        queues[i].head   = 0;
        queues[i].tail   = 0;
        queues[i].count  = 0;
    }
}

/* Find a queue by name; returns pointer or NULL */
static ipc_queue_t *find_queue(const char *name) {
    for (int i = 0; i < IPC_MAX_QUEUES; i++)
        if (queues[i].active &&
            kstrncmp(queues[i].name, name, IPC_NAME_MAX + 1) == 0)
            return &queues[i];
    return 0;
}

/* Open (register) a named queue. Returns 0 on success. */
int ipc_queue_open(const char *name) {
    if (find_queue(name)) return 0; /* already open */
    for (int i = 0; i < IPC_MAX_QUEUES; i++) {
        if (!queues[i].active) {
            kstrncpy(queues[i].name, name, IPC_NAME_MAX + 1);
            queues[i].active = 1;
            queues[i].head   = 0;
            queues[i].tail   = 0;
            queues[i].count  = 0;
            return 0;
        }
    }
    serial_puts("[IPC] no free queue slots\n");
    return -1;
}

/* Close and flush a named queue, unreffing any pending Lua values */
void ipc_queue_close(const char *name) {
    /* Note: caller must pass the Lua state to unref pending messages.
       Since we may not have it here, we just mark inactive and accept the leak.
       In practice close_app() is called while L is valid, so main.lua
       calls ipc.flush(name) first. */
    ipc_queue_t *q = find_queue(name);
    if (!q) return;
    q->active = 0;
    q->count  = 0;
    q->head   = q->tail = 0;
}

/* Send: pops top of Lua stack as the message data, stores in registry */
int ipc_send(lua_State *L, const char *to, const char *from) {
    ipc_queue_t *q = find_queue(to);
    if (!q) return -1;
    if (q->count >= IPC_QUEUE_CAP) return -1; /* queue full */

    /* Store value from top of stack into Lua registry */
    int ref = luaL_ref(L, LUA_REGISTRYINDEX); /* pops the value */

    struct ipc_msg *m = &q->msgs[q->head];
    kstrncpy(m->from, from, IPC_NAME_MAX + 1);
    m->lua_ref = ref;

    q->head  = (q->head + 1) % IPC_QUEUE_CAP;
    q->count++;
    return 0;
}

/* Recv: pushes (from_string, data) onto Lua stack.
   Returns 1 if message delivered, 0 if queue empty. */
int ipc_recv(lua_State *L, const char *name) {
    ipc_queue_t *q = find_queue(name);
    if (!q || q->count == 0) return 0;

    struct ipc_msg *m = &q->msgs[q->tail];
    /* Push from string */
    lua_pushstring(L, m->from);
    /* Push data from registry */
    lua_rawgeti(L, LUA_REGISTRYINDEX, m->lua_ref);
    luaL_unref(L, LUA_REGISTRYINDEX, m->lua_ref);
    m->lua_ref = LUA_NOREF;

    q->tail  = (q->tail + 1) % IPC_QUEUE_CAP;
    q->count--;
    return 1;
}

int ipc_pending(const char *name) {
    ipc_queue_t *q = find_queue(name);
    return q ? q->count : 0;
}
