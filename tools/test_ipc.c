/* test_ipc — IPC / msgqueue unit tests.
   Builds as a host binary. Links Lua 5.4 so luaL_ref works for real.
   Usage: make test
*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

/* ── Stubs ────────────────────────────────────────────────────────────────── */
void serial_init(void) {}
void serial_puts(const char *s) { (void)s; }
void serial_putc(char c)        { (void)c; }
void serial_write(const char *s, unsigned int l) { (void)s; (void)l; }
void serial_hex(uint32_t v)     { (void)v; }
void *kmalloc(unsigned int sz)  { return malloc(sz); }
void  kfree(void *p)            { free(p); }

/* ── Include msgqueue directly ────────────────────────────────────────────── */
#include "../kernel/ipc/msgqueue.c"

/* ── Lua headers (resolved via -Ikernel → kernel/../lua/lua.h = lua/lua.h) ── */
#include "../lua/lauxlib.h"

/* ── Test framework ───────────────────────────────────────────────────────── */
static int tests_run = 0, tests_passed = 0, tests_failed = 0;

#define CHECK(expr) do { \
    tests_run++; \
    if (expr) { tests_passed++; } \
    else { tests_failed++; \
           fprintf(stderr, "  FAIL %s:%d: %s\n", __FILE__, __LINE__, #expr); } \
} while(0)

#define SECTION(name) printf("\n[%s]\n", name)

int main(void) {
    lua_State *L = luaL_newstate();
    if (!L) { fprintf(stderr, "luaL_newstate failed\n"); return 1; }

    /* ── open/close ────────────────────────────────────────────────────────── */
    SECTION("open/close");
    ipc_init();
    CHECK(ipc_queue_open("app1") == 0);
    CHECK(ipc_queue_open("app1") == 0);    /* duplicate: idempotent */
    CHECK(ipc_queue_open("app2") == 0);
    ipc_queue_close("app1");
    CHECK(ipc_pending("app1") == 0);       /* closed: not found → 0 */
    CHECK(ipc_pending("app2") == 0);       /* open but empty */

    /* ── send/recv: string ─────────────────────────────────────────────────── */
    SECTION("send/recv string");
    ipc_init();
    ipc_queue_open("q");
    lua_pushstring(L, "hello");
    CHECK(ipc_send(L, "q", "alice") == 0);
    CHECK(ipc_pending("q") == 1);
    CHECK(ipc_recv(L, "q") == 1);
    /* stack: from(-2), data(-1) */
    CHECK(strcmp(lua_tostring(L, -1), "hello") == 0);
    CHECK(strcmp(lua_tostring(L, -2), "alice") == 0);
    lua_pop(L, 2);
    CHECK(ipc_pending("q") == 0);

    /* ── send/recv: number ─────────────────────────────────────────────────── */
    SECTION("send/recv number");
    ipc_init();
    ipc_queue_open("q");
    lua_pushnumber(L, 42.0);
    CHECK(ipc_send(L, "q", "src") == 0);
    CHECK(ipc_recv(L, "q") == 1);
    CHECK(lua_tonumber(L, -1) == 42.0);
    lua_pop(L, 2);

    /* ── send/recv: table ──────────────────────────────────────────────────── */
    SECTION("send/recv table");
    ipc_init();
    ipc_queue_open("q");
    lua_newtable(L);
    lua_pushinteger(L, 99);
    lua_setfield(L, -2, "x");
    CHECK(ipc_send(L, "q", "src") == 0);
    CHECK(ipc_recv(L, "q") == 1);
    lua_getfield(L, -1, "x");           /* -1=x, -2=table, -3=from */
    CHECK(lua_tointeger(L, -1) == 99);
    lua_pop(L, 3);

    /* ── pending count ─────────────────────────────────────────────────────── */
    SECTION("pending count");
    ipc_init();
    ipc_queue_open("q");
    for (int i = 0; i < 5; i++) {
        lua_pushinteger(L, i);
        ipc_send(L, "q", "s");
    }
    CHECK(ipc_pending("q") == 5);
    ipc_recv(L, "q"); lua_pop(L, 2);
    CHECK(ipc_pending("q") == 4);

    /* ── queue full ────────────────────────────────────────────────────────── */
    SECTION("queue full (64)");
    ipc_init();
    ipc_queue_open("q");
    for (int i = 0; i < 64; i++) {
        lua_pushinteger(L, i);
        CHECK(ipc_send(L, "q", "s") == 0);
    }
    /* 65th send: full → returns -1, does NOT pop the value */
    lua_pushinteger(L, 999);
    CHECK(ipc_send(L, "q", "s") == -1);
    lua_pop(L, 1);   /* clean up the unpoped value */

    /* ── send to nonexistent queue ─────────────────────────────────────────── */
    SECTION("send to nonexistent");
    ipc_init();
    lua_pushstring(L, "data");
    CHECK(ipc_send(L, "nobody", "s") == -1);
    lua_pop(L, 1);   /* clean up unpoped value */

    /* ── recv from empty queue ─────────────────────────────────────────────── */
    SECTION("recv from empty");
    ipc_init();
    ipc_queue_open("q");
    CHECK(ipc_recv(L, "q") == 0);   /* returns 0, pushes nothing */

    lua_close(L);

    printf("\n%d/%d tests passed\n", tests_passed, tests_run);
    return tests_failed ? 1 : 0;
}
