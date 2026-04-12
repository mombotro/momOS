#pragma once
#include <stdint.h>

/* Maximum number of named queues (one per app slot) */
#define IPC_MAX_QUEUES  8
/* Maximum messages waiting in a single queue */
#define IPC_QUEUE_CAP   64
/* Max app name length */
#define IPC_NAME_MAX    63

typedef struct {
    char name[IPC_NAME_MAX + 1];   /* destination app name */
    int  active;

    struct ipc_msg {
        char from[IPC_NAME_MAX + 1];
        int  lua_ref;              /* luaL_ref() index in Lua registry */
    } msgs[IPC_QUEUE_CAP];

    int head;   /* next write position */
    int tail;   /* next read position  */
    int count;
} ipc_queue_t;

/* Forward declaration — ipc functions need the Lua state */
struct lua_State;

void ipc_init      (void);
int  ipc_queue_open(const char *name);
void ipc_queue_close(const char *name);

/* Push a message (lua value at top of stack) into named queue.
   Returns 0 on success, -1 if queue full or not found. */
int  ipc_send(struct lua_State *L, const char *to, const char *from);

/* Pop the next message for 'name' — pushes (from_string, data_value)
   onto the Lua stack. Returns 1 if a message was delivered, 0 if empty. */
int  ipc_recv(struct lua_State *L, const char *name);

/* How many messages are waiting for 'name' */
int  ipc_pending(const char *name);
