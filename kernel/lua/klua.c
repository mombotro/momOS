#include "klua.h"
#include "font8x8.h"
#include "../cpu/serial.h"
#include "../cpu/keyboard.h"
#include "../cpu/io.h"
#include "../vfs/vfs.h"
#include "../mm/heap.h"
#include "../mm/phys.h"
#include "../cpu/pit.h"
#include "../cpu/mouse.h"
#include "../wm/wm.h"
#include "../ipc/msgqueue.h"
#include "../proc/process.h"
#include "../proc/scheduler.h"
#include "../audio/audio.h"
#include "../disk/disk.h"
#include "../lua/lua.h"
#include "../lua/lauxlib.h"
#include "../lua/lualib.h"
#include <stdint.h>

/* ── Framebuffer state (set by klua_init) ───────────────────────────────── */
static uint32_t        *gfx_fb  = 0;
static uint32_t         gfx_w   = 0;
static uint32_t         gfx_h   = 0;
static uint32_t         gfx_pal_buf[32];        /* mutable copy of system palette */
static const uint32_t  *gfx_pal = 0;
static wm_win_t        *current_draw_win = 0;  /* window currently targeted by gfx draws */

static lua_State *L = 0;

/* ── Lua allocator → kernel heap ────────────────────────────────────────── */
static void *lua_kernel_alloc(void *ud, void *ptr, size_t osize, size_t nsize) {
    (void)ud; (void)osize;
    if (nsize == 0) { kfree(ptr); return 0; }
    if (!ptr) return kmalloc((unsigned int)nsize);
    return krealloc(ptr, (unsigned int)nsize);
}

/* ── gfx API ────────────────────────────────────────────────────────────── */
static uint32_t _color(int c) {
    return gfx_pal ? gfx_pal[c & 31] : 0;
}

static void _pset(int x, int y, uint32_t col) {
    if (!gfx_fb || (uint32_t)x >= gfx_w || (uint32_t)y >= gfx_h) return;
    gfx_fb[y * gfx_w + x] = col;
}

/* gfx.pset(x, y, color_index) */
static int l_pset(lua_State *ls) {
    int x = (int)luaL_checkinteger(ls, 1);
    int y = (int)luaL_checkinteger(ls, 2);
    int c = (int)luaL_checkinteger(ls, 3);
    _pset(x, y, _color(c));
    return 0;
}

/* gfx.cls(color_index) */
static int l_cls(lua_State *ls) {
    uint32_t col = _color((int)luaL_optinteger(ls, 1, 0));
    uint32_t total = gfx_w * gfx_h;
    for (uint32_t i = 0; i < total; i++) gfx_fb[i] = col;
    /* If drawing to the screen buffer (not a window), mark whole screen dirty */
    if (!current_draw_win)
        wm_mark_dirty(0, 0, (int)gfx_w, (int)gfx_h);
    return 0;
}

/* gfx.rect(x, y, w, h, color_index) */
static int l_rect(lua_State *ls) {
    int x = (int)luaL_checkinteger(ls, 1);
    int y = (int)luaL_checkinteger(ls, 2);
    int w = (int)luaL_checkinteger(ls, 3);
    int h = (int)luaL_checkinteger(ls, 4);
    uint32_t col = _color((int)luaL_checkinteger(ls, 5));
    for (int row = y; row < y + h; row++)
        for (int col2 = x; col2 < x + w; col2++)
            _pset(col2, row, col);
    return 0;
}

/* gfx.print(text, x, y, color_index) */
static int l_print(lua_State *ls) {
    const char *text = luaL_checkstring(ls, 1);
    int x0 = (int)luaL_checkinteger(ls, 2);
    int y  = (int)luaL_checkinteger(ls, 3);
    uint32_t col = _color((int)luaL_optinteger(ls, 4, 7));
    int cx = x0;
    for (; *text; text++) {
        if (*text == '\n') { cx = x0; y += 8; continue; }
        int ch = (unsigned char)*text;
        if (ch < 32 || ch > 127) ch = 32;
        const uint8_t *glyph = font8x8[ch - 32];
        for (int row = 0; row < 8; row++) {
            uint8_t bits = glyph[row];
            for (int col2 = 0; col2 < 8; col2++) {
                if (bits & (1 << col2))
                    _pset(cx + col2, y + row, col);
            }
        }
        cx += 8;
    }
    return 0;
}

/* gfx.line(x0, y0, x1, y1, color_index) — Bresenham line */
static int l_line(lua_State *ls) {
    int x0  = (int)luaL_checkinteger(ls, 1);
    int y0  = (int)luaL_checkinteger(ls, 2);
    int x1  = (int)luaL_checkinteger(ls, 3);
    int y1  = (int)luaL_checkinteger(ls, 4);
    uint32_t col = _color((int)luaL_checkinteger(ls, 5));
    int dx = x1>x0 ? x1-x0 : x0-x1, dy = y1>y0 ? y1-y0 : y0-y1;
    int sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1;
    int err = dx - dy;
    for (;;) {
        _pset(x0, y0, col);
        if (x0 == x1 && y0 == y1) break;
        int e2 = 2 * err;
        if (e2 > -dy) { err -= dy; x0 += sx; }
        if (e2 <  dx) { err += dx; y0 += sy; }
    }
    return 0;
}

/* gfx.circ(cx, cy, r, color_index) — Bresenham circle outline */
static int l_circ(lua_State *ls) {
    int cx = (int)luaL_checkinteger(ls, 1);
    int cy = (int)luaL_checkinteger(ls, 2);
    int r  = (int)luaL_checkinteger(ls, 3);
    uint32_t col = _color((int)luaL_checkinteger(ls, 4));
    int x = 0, y = r, d = 1 - r;
    while (x <= y) {
        _pset(cx+x,cy+y,col); _pset(cx-x,cy+y,col);
        _pset(cx+x,cy-y,col); _pset(cx-x,cy-y,col);
        _pset(cx+y,cy+x,col); _pset(cx-y,cy+x,col);
        _pset(cx+y,cy-x,col); _pset(cx-y,cy-x,col);
        if (d < 0) d += 2*x + 3;
        else       { d += 2*(x-y) + 5; y--; }
        x++;
    }
    return 0;
}

/* gfx.circfill(cx, cy, r, color_index) — filled circle */
static int l_circfill(lua_State *ls) {
    int cx = (int)luaL_checkinteger(ls, 1);
    int cy = (int)luaL_checkinteger(ls, 2);
    int r  = (int)luaL_checkinteger(ls, 3);
    uint32_t col = _color((int)luaL_checkinteger(ls, 4));
    int x = 0, y = r, d = 1 - r;
    while (x <= y) {
        for (int i = cx-y; i <= cx+y; i++) { _pset(i, cy+x, col); _pset(i, cy-x, col); }
        for (int i = cx-x; i <= cx+x; i++) { _pset(i, cy+y, col); _pset(i, cy-y, col); }
        if (d < 0) d += 2*x + 3;
        else       { d += 2*(x-y) + 5; y--; }
        x++;
    }
    return 0;
}

/* gfx.pget(x, y) → color_index (approximate — returns palette index 0) */
static int l_pget(lua_State *ls) {
    (void)ls; lua_pushinteger(ls, 0); return 1;
}

/* gfx.set_pal(idx, r, g, b) — set palette entry (idx 0–31, r/g/b 0–255) */
static int l_set_pal(lua_State *ls) {
    int idx = (int)luaL_checkinteger(ls, 1) & 31;
    int r   = (int)luaL_checkinteger(ls, 2) & 0xFF;
    int g   = (int)luaL_checkinteger(ls, 3) & 0xFF;
    int b   = (int)luaL_checkinteger(ls, 4) & 0xFF;
    gfx_pal_buf[idx] = ((uint32_t)r << 16) | ((uint32_t)g << 8) | (uint32_t)b;
    return 0;
}

/* gfx.get_pal(idx) → r, g, b */
static int l_get_pal(lua_State *ls) {
    int idx = (int)luaL_checkinteger(ls, 1) & 31;
    uint32_t col = gfx_pal_buf[idx];
    lua_pushinteger(ls, (col >> 16) & 0xFF);
    lua_pushinteger(ls, (col >>  8) & 0xFF);
    lua_pushinteger(ls, (col      ) & 0xFF);
    return 3;
}

/* gfx.reset_pal() — restore system palette */
static int l_reset_pal(lua_State *ls) {
    (void)ls;
    /* Re-init from kernel.c's palette — not stored here; set all to 0 as fallback.
       Apps that care should save/restore themselves. */
    return 0;
}

/* gfx.screen_w() / gfx.screen_h() */
static int l_screen_w(lua_State *ls) { lua_pushinteger(ls, (lua_Integer)gfx_w); return 1; }
static int l_screen_h(lua_State *ls) { lua_pushinteger(ls, (lua_Integer)gfx_h); return 1; }

/* pit_ticks() global (kept for back-compat) */
static int l_pit_ticks(lua_State *ls) { lua_pushinteger(ls, (lua_Integer)pit_ticks()); return 1; }

/* ── sys API ────────────────────────────────────────────────────────────── */
/* sys.ticks() → integer tick count */
static int l_sys_ticks(lua_State *ls) { lua_pushinteger(ls, (lua_Integer)pit_ticks()); return 1; }

/* sys.mem() → free_bytes, total_bytes */
static int l_sys_mem(lua_State *ls) {
    lua_pushinteger(ls, (lua_Integer)phys_free_count()  * PAGE_SIZE);
    lua_pushinteger(ls, (lua_Integer)phys_total_count() * PAGE_SIZE);
    return 2;
}

/* sys.proc_alloc(name) → pid */
static int l_sys_proc_alloc(lua_State *ls) {
    const char *name = luaL_checkstring(ls, 1);
    lua_pushinteger(ls, proc_alloc(name));
    return 1;
}

/* sys.proc_free(pid) */
static int l_sys_proc_free(lua_State *ls) {
    proc_free((int)luaL_checkinteger(ls, 1));
    return 0;
}

/* sys.proc_info(pid) → {name, cpu_ticks, overruns, uptime_ticks} or nil */
static int l_sys_proc_info(lua_State *ls) {
    int pid = (int)luaL_checkinteger(ls, 1);
    proc_t *p = proc_get(pid);
    if (!p) { lua_pushnil(ls); return 1; }
    lua_newtable(ls);
    lua_pushstring(ls, p->name);    lua_setfield(ls, -2, "name");
    lua_pushinteger(ls, (lua_Integer)p->cpu_ticks);  lua_setfield(ls, -2, "cpu_ticks");
    lua_pushinteger(ls, (lua_Integer)p->overruns);   lua_setfield(ls, -2, "overruns");
    lua_pushinteger(ls, (lua_Integer)(pit_ticks() - p->spawn_tick));
    lua_setfield(ls, -2, "uptime_ticks");
    return 1;
}

/* sys.sched_begin(pid, name) */
static int l_sys_sched_begin(lua_State *ls) {
    int pid = (int)luaL_checkinteger(ls, 1);
    const char *name = luaL_optstring(ls, 2, "?");
    sched_begin(ls, pid, name);
    return 0;
}

/* sys.sched_end(pid) */
static int l_sys_sched_end(lua_State *ls) {
    int pid = (int)luaL_checkinteger(ls, 1);
    sched_end(ls, pid);
    return 0;
}

/* sys.disk_ready() → bool */
static int l_sys_disk_ready(lua_State *ls) {
    lua_pushboolean(ls, disk_ready());
    return 1;
}

/* sys.save() → bool, errmsg
   Snapshot the in-memory VFS image to the HDD LFS partition. */
static int l_sys_save(lua_State *ls) {
    if (disk_drive() < 0) { /* no drive configured at all */
        lua_pushboolean(ls, 0);
        lua_pushstring(ls, "no disk");
        return 2;
    }
    void    *base = vfs_get_base();
    uint32_t size = vfs_get_size();
    if (!base || !size) {
        lua_pushboolean(ls, 0);
        lua_pushstring(ls, "VFS not mounted");
        return 2;
    }
    /* Round size up to next 512-byte boundary */
    uint32_t aligned = (size + 511) & ~511u;
    if (aligned > disk_lfs_size()) {
        lua_pushboolean(ls, 0);
        lua_pushstring(ls, "VFS too large for partition");
        return 2;
    }
    int r = disk_lfs_write(base, 0, aligned);
    lua_pushboolean(ls, r == 0);
    if (r != 0) lua_pushstring(ls, "write error");
    else        lua_pushnil(ls);
    return 2;
}

/* sys.load() → bool, errmsg
   Load the VFS image from HDD, replacing the current in-memory VFS.
   Fails gracefully if no valid LFS magic is found on disk. */
static int l_sys_load(lua_State *ls) {
    if (!disk_ready()) {
        lua_pushboolean(ls, 0);
        lua_pushstring(ls, "disk not ready");
        return 2;
    }
    uint32_t part_size = disk_lfs_size();
    /* Read the superblock first to get the real image size */
    uint8_t sb_buf[512];
    if (disk_lfs_read(sb_buf, 0, 512) != 0) {
        lua_pushboolean(ls, 0);
        lua_pushstring(ls, "read error");
        return 2;
    }
    /* Check magic */
    if (sb_buf[0]!='L' || sb_buf[1]!='F' || sb_buf[2]!='S' || sb_buf[3]!='!') {
        lua_pushboolean(ls, 0);
        lua_pushstring(ls, "no LFS magic on disk");
        return 2;
    }
    /* total_blocks is at offset 12 in the superblock (see lfs_super_t) */
    uint32_t total_blocks = *(uint32_t *)(sb_buf + 12);
    uint32_t image_size   = total_blocks * 512;
    if (image_size > part_size || image_size < 512) {
        lua_pushboolean(ls, 0);
        lua_pushstring(ls, "bad superblock");
        return 2;
    }
    /* Allocate a buffer and read the full image */
    void *buf = kmalloc(image_size);
    if (!buf) {
        lua_pushboolean(ls, 0);
        lua_pushstring(ls, "out of memory");
        return 2;
    }
    /* Aligned read (image_size is already a multiple of 512) */
    if (disk_lfs_read(buf, 0, image_size) != 0) {
        kfree(buf);
        lua_pushboolean(ls, 0);
        lua_pushstring(ls, "read error");
        return 2;
    }
    /* Reinitialise VFS from the new buffer */
    vfs_init((uint32_t)(uintptr_t)buf, image_size);
    lua_pushboolean(ls, 1);
    lua_pushnil(ls);
    return 2;
}

/* sys.shutdown() — power off.
   QEMU: write 0x2000 to port 0x604 (Bochs/QEMU ACPI shutdown).
   Real hardware fallback: ACPI S5 via port 0x4004 (common ICH chipset). */
static int l_sys_shutdown(lua_State *ls) {
    (void)ls;
    /* QEMU / Bochs ACPI power-off */
    outw(0x604, 0x2000);
    /* ICH/PIIX ACPI power-off fallback (port varies; try common ones) */
    outw(0x4004, 0x3400);
    /* Spin forever if neither worked */
    for (;;) { __asm__ volatile ("hlt"); }
    return 0;
}

/* sys.reboot() — warm reboot via keyboard controller reset line. */
static int l_sys_reboot(lua_State *ls) {
    (void)ls;
    /* Pulse the reset line via the 8042 keyboard controller */
    outb(0x64, 0xFE);
    /* Triple fault fallback */
    for (;;) { __asm__ volatile ("hlt"); }
    return 0;
}

static const luaL_Reg sys_lib[] = {
    {"ticks",       l_sys_ticks},
    {"mem",         l_sys_mem},
    {"proc_alloc",  l_sys_proc_alloc},
    {"proc_free",   l_sys_proc_free},
    {"proc_info",   l_sys_proc_info},
    {"sched_begin", l_sys_sched_begin},
    {"sched_end",   l_sys_sched_end},
    {"disk_ready",  l_sys_disk_ready},
    {"save",        l_sys_save},
    {"load",        l_sys_load},
    {"shutdown",    l_sys_shutdown},
    {"reboot",      l_sys_reboot},
    {NULL, NULL}
};

/* ── ipc API ────────────────────────────────────────────────────────────── */
/* ipc.open(name) — register a named queue for this app */
static int l_ipc_open(lua_State *ls) {
    const char *name = luaL_checkstring(ls, 1);
    lua_pushboolean(ls, ipc_queue_open(name) == 0);
    return 1;
}

/* ipc.close(name) */
static int l_ipc_close(lua_State *ls) {
    const char *name = luaL_checkstring(ls, 1);
    ipc_queue_close(name);
    return 0;
}

/* ipc.send(to, from, data) — data is any Lua value */
static int l_ipc_send(lua_State *ls) {
    const char *to   = luaL_checkstring(ls, 1);
    const char *from = luaL_checkstring(ls, 2);
    luaL_checkany(ls, 3);
    lua_settop(ls, 3);          /* ensure exactly 3 args; data is at index 3 */
    /* ipc_send pops the top value */
    int r = ipc_send(ls, to, from);
    lua_pushboolean(ls, r == 0);
    return 1;
}

/* ipc.recv(name) → from, data  or  nil if empty */
static int l_ipc_recv(lua_State *ls) {
    const char *name = luaL_checkstring(ls, 1);
    if (!ipc_recv(ls, name)) { lua_pushnil(ls); return 1; }
    return 2; /* from_string, data already on stack */
}

/* ipc.pending(name) → count */
static int l_ipc_pending(lua_State *ls) {
    const char *name = luaL_checkstring(ls, 1);
    lua_pushinteger(ls, ipc_pending(name));
    return 1;
}

static const luaL_Reg ipc_lib[] = {
    {"open",    l_ipc_open},
    {"close",   l_ipc_close},
    {"send",    l_ipc_send},
    {"recv",    l_ipc_recv},
    {"pending", l_ipc_pending},
    {NULL, NULL}
};

/* ── audio API ──────────────────────────────────────────────────────────── */
/* audio.set(ch, wave, freq, vol)
   wave: 0=square 1=sawtooth 2=triangle 3=noise 4=off
   freq: Hz, vol: 0–255 */
static int l_audio_set(lua_State *ls) {
    int ch   = (int)luaL_checkinteger(ls, 1);
    int wave = (int)luaL_checkinteger(ls, 2);
    int freq = (int)luaL_checkinteger(ls, 3);
    int vol  = (int)luaL_checkinteger(ls, 4);
    audio_set_channel(ch, (uint8_t)wave, (uint32_t)freq, (uint8_t)vol);
    return 0;
}

/* audio.stop(ch) — stop one channel */
static int l_audio_stop(lua_State *ls) {
    audio_stop_channel((int)luaL_checkinteger(ls, 1));
    return 0;
}

/* audio.stop_all() */
static int l_audio_stop_all(lua_State *ls) {
    (void)ls; audio_stop_all(); return 0;
}

/* audio.beep(freq) — PC speaker tone (0 = off) */
static int l_audio_beep(lua_State *ls) {
    uint32_t freq = (uint32_t)luaL_optinteger(ls, 1, 0);
    pcspeaker_tone(freq);
    return 0;
}

/* audio.refill() — manually refill AC97 DMA buffer (call from update loop) */
static int l_audio_refill(lua_State *ls) {
    (void)ls;
    extern void audio_refill(void);
    audio_refill();
    return 0;
}

static const luaL_Reg audio_lib[] = {
    {"set",      l_audio_set},
    {"stop",     l_audio_stop},
    {"stop_all", l_audio_stop_all},
    {"beep",     l_audio_beep},
    {"refill",   l_audio_refill},
    {NULL, NULL}
};

/* ── input API ──────────────────────────────────────────────────────────── */
typedef struct { const char *name; int code; } key_entry_t;
static const key_entry_t key_map[] = {
    {"esc",    KEY_ESC},   {"space",  KEY_SPACE},
    {"enter",  KEY_ENTER}, {"bksp",   KEY_BKSP},
    {"tab",    KEY_TAB},   {"lshift", KEY_LSHIFT},
    {"rshift", KEY_RSHIFT},{"lctrl",  KEY_LCTRL},
    {"lalt",   KEY_LALT},
    {"up",     KEY_UP},    {"down",   KEY_DOWN},
    {"left",   KEY_LEFT},  {"right",  KEY_RIGHT},
    {"home",   KEY_HOME},  {"end",    KEY_END},
    {"pgup",   KEY_PGUP},  {"pgdn",   KEY_PGDN},
    {"ins",    KEY_INS},   {"del",    KEY_DEL},
    {"a",KEY_A},{"b",KEY_B},{"c",KEY_C},{"d",KEY_D},{"e",KEY_E},
    {"f",KEY_F},{"g",KEY_G},{"h",KEY_H},{"i",KEY_I},{"j",KEY_J},
    {"k",KEY_K},{"l",KEY_L},{"m",KEY_M},{"n",KEY_N},{"o",KEY_O},
    {"p",KEY_P},{"q",KEY_Q},{"r",KEY_R},{"s",KEY_S},{"t",KEY_T},
    {"u",KEY_U},{"v",KEY_V},{"w",KEY_W},{"x",KEY_X},{"y",KEY_Y},
    {"z",KEY_Z},
    {"0",KEY_0},{"1",KEY_1},{"2",KEY_2},{"3",KEY_3},{"4",KEY_4},
    {"5",KEY_5},{"6",KEY_6},{"7",KEY_7},{"8",KEY_8},{"9",KEY_9},
    {"f1",KEY_F1},{"f2",KEY_F2},{"f3",KEY_F3},{"f4",KEY_F4},
    {"f5",KEY_F5},{"f6",KEY_F6},{"f7",KEY_F7},{"f8",KEY_F8},
    {"f9",KEY_F9},{"f10",KEY_F10},
    {0, 0}
};

static int _key_code(const char *name) {
    for (int i = 0; key_map[i].name; i++)
        if (__builtin_strcmp(key_map[i].name, name) == 0)
            return key_map[i].code;
    return -1;
}

/* input.key_down("name") → bool */
static int l_key_down(lua_State *ls) {
    const char *name = luaL_checkstring(ls, 1);
    int code = _key_code(name);
    lua_pushboolean(ls, code >= 0 && kbd_key_down(code));
    return 1;
}

/* input.getchar() → string (one char) or nil */
static int l_getchar(lua_State *ls) {
    char c = kbd_getchar();
    if (!c) { lua_pushnil(ls); return 1; }
    lua_pushlstring(ls, &c, 1);
    return 1;
}

static const luaL_Reg input_lib[] = {
    {"key_down", l_key_down},
    {"getchar",  l_getchar},
    {NULL, NULL}
};

/* ── fs API ─────────────────────────────────────────────────────────────── */
/* fs.read(path) → string or nil  (binary-safe: uses pushlstring) */
static int l_fs_read(lua_State *ls) {
    const char *path = luaL_checkstring(ls, 1);
    vfs_file_t *f = vfs_open(path);
    if (!f) { lua_pushnil(ls); return 1; }
    uint32_t sz = vfs_size(f);
    char *buf = (char *)kmalloc(sz + 1);
    if (!buf) { vfs_close(f); lua_pushnil(ls); return 1; }
    vfs_read(f, 0, buf, sz);
    vfs_close(f);
    lua_pushlstring(ls, buf, sz);
    kfree(buf);
    return 1;
}

/* callback state for fs.list */
typedef struct { lua_State *ls; int idx; } list_ud_t;
static void _list_cb(const vfs_dirent_t *e, void *ud) {
    list_ud_t *s = (list_ud_t *)ud;
    lua_newtable(s->ls);
    lua_pushstring(s->ls, e->name);  lua_setfield(s->ls, -2, "name");
    lua_pushboolean(s->ls, e->is_dir); lua_setfield(s->ls, -2, "is_dir");
    lua_pushinteger(s->ls, (lua_Integer)e->size); lua_setfield(s->ls, -2, "size");
    lua_rawseti(s->ls, -2, ++s->idx);
}

/* fs.list(path) → array of {name, is_dir, size} or nil */
static int l_fs_list(lua_State *ls) {
    const char *path = luaL_checkstring(ls, 1);
    lua_newtable(ls);
    list_ud_t ud = { ls, 0 };
    if (vfs_list(path, _list_cb, &ud) < 0) {
        lua_pop(ls, 1); lua_pushnil(ls);
    }
    return 1;
}

/* fs.exists(path) → bool */
static int l_fs_exists(lua_State *ls) {
    const char *path = luaL_checkstring(ls, 1);
    lua_pushboolean(ls, vfs_exists(path));
    return 1;
}

/* fs.write(path, data) → bool */
static int l_fs_write(lua_State *ls) {
    const char *path = luaL_checkstring(ls, 1);
    size_t len;
    const char *data = luaL_checklstring(ls, 2, &len);
    lua_pushboolean(ls, vfs_write(path, data, (uint32_t)len) == 0);
    return 1;
}

/* fs.mkdir(path) → bool */
static int l_fs_mkdir(lua_State *ls) {
    const char *path = luaL_checkstring(ls, 1);
    lua_pushboolean(ls, vfs_mkdir(path) == 0);
    return 1;
}

/* fs.delete(path) → bool */
static int l_fs_delete(lua_State *ls) {
    const char *path = luaL_checkstring(ls, 1);
    lua_pushboolean(ls, vfs_delete(path) == 0);
    return 1;
}

/* ── wm API ─────────────────────────────────────────────────────────────── */
/* saved screen state for focus/unfocus */
static uint32_t *gfx_screen_fb = 0;
static uint32_t  gfx_screen_w  = 0;
static uint32_t  gfx_screen_h  = 0;

/* wm.open(title, x, y, w, h) → lightuserdata */
static int l_wm_open(lua_State *ls) {
    const char *title = luaL_checkstring(ls, 1);
    int x = (int)luaL_checkinteger(ls, 2);
    int y = (int)luaL_checkinteger(ls, 3);
    int w = (int)luaL_checkinteger(ls, 4);
    int h = (int)luaL_checkinteger(ls, 5);
    wm_win_t *win = wm_open(title, x, y, w, h);
    if (!win) { lua_pushnil(ls); return 1; }
    lua_pushlightuserdata(ls, win);
    return 1;
}

/* wm.close(win) */
static int l_wm_close(lua_State *ls) {
    wm_win_t *win = (wm_win_t *)lua_touserdata(ls, 1);
    /* If this window was being drawn to (e.g. killed mid-draw by scheduler),
       restore gfx back to the screen back buffer now.  Without this, gfx_fb
       keeps pointing into the freed window buffer, causing corrupted draws and
       gfx.cls() won't mark the screen dirty (it checks current_draw_win). */
    if (win && current_draw_win == win) {
        current_draw_win = 0;
        if (gfx_screen_fb) {
            gfx_fb = gfx_screen_fb;
            gfx_w  = gfx_screen_w;
            gfx_h  = gfx_screen_h;
        }
        /* Force a full-screen redraw so stale pixels are overwritten */
        wm_mark_dirty(0, 0, (int)gfx_w, (int)gfx_h);
    }
    wm_close(win);
    return 0;
}

/* wm.focus(win) — redirect gfx calls into win->fb */
static int l_wm_focus(lua_State *ls) {
    wm_win_t *win = (wm_win_t *)lua_touserdata(ls, 1);
    if (!win || !win->fb) return 0;
    if (!gfx_screen_fb) {
        gfx_screen_fb = gfx_fb;
        gfx_screen_w  = gfx_w;
        gfx_screen_h  = gfx_h;
    }
    gfx_fb = win->fb;
    gfx_w  = (uint32_t)win->w;
    gfx_h  = (uint32_t)win->h;
    current_draw_win = win;
    return 0;
}

/* wm.unfocus() — restore gfx to screen backbuf, mark window dirty */
static int l_wm_unfocus(lua_State *ls) {
    (void)ls;
    if (gfx_screen_fb) {
        if (current_draw_win) {
            current_draw_win->dirty = 1;
            wm_mark_win_dirty(current_draw_win);
            current_draw_win = 0;
        }
        gfx_fb = gfx_screen_fb;
        gfx_w  = gfx_screen_w;
        gfx_h  = gfx_screen_h;
    }
    return 0;
}

/* wm.present() — composite all windows onto screen backbuf */
static int l_wm_present(lua_State *ls) {
    (void)ls;
    uint32_t *dst = gfx_screen_fb ? gfx_screen_fb : gfx_fb;
    int sw = (int)(gfx_screen_fb ? gfx_screen_w : gfx_w);
    int sh = (int)(gfx_screen_fb ? gfx_screen_h : gfx_h);
    wm_composite(dst, sw, sh, gfx_pal);
    return 0;
}

/* wm.draw_cursor() — draw cursor on top of everything */
static int l_wm_draw_cursor(lua_State *ls) {
    (void)ls;
    uint32_t *dst = gfx_screen_fb ? gfx_screen_fb : gfx_fb;
    int sw = (int)(gfx_screen_fb ? gfx_screen_w : gfx_w);
    int sh = (int)(gfx_screen_fb ? gfx_screen_h : gfx_h);
    wm_draw_cursor(dst, sw, sh, gfx_pal);
    return 0;
}

/* wm.move(win, x, y) */
static int l_wm_move(lua_State *ls) {
    wm_win_t *win = (wm_win_t *)lua_touserdata(ls, 1);
    int x = (int)luaL_checkinteger(ls, 2);
    int y = (int)luaL_checkinteger(ls, 3);
    wm_move(win, x, y);
    return 0;
}

/* wm.raise(win) */
static int l_wm_raise(lua_State *ls) {
    wm_win_t *win = (wm_win_t *)lua_touserdata(ls, 1);
    wm_raise(win);
    return 0;
}

/* wm.z(win) → z-order integer */
static int l_wm_z(lua_State *ls) {
    wm_win_t *win = (wm_win_t *)lua_touserdata(ls, 1);
    lua_pushinteger(ls, win ? win->z : 0);
    return 1;
}

/* wm.set_focused(win) */
static int l_wm_set_focused(lua_State *ls) {
    wm_win_t *win = (wm_win_t *)lua_touserdata(ls, 1);
    wm_set_focused(win);
    return 0;
}

/* wm.minimize(win, bool) */
static int l_wm_minimize(lua_State *ls) {
    wm_win_t *win = (wm_win_t *)lua_touserdata(ls, 1);
    wm_set_minimized(win, lua_toboolean(ls, 2));
    return 0;
}

/* wm.is_minimized(win) → bool */
static int l_wm_is_minimized(lua_State *ls) {
    wm_win_t *win = (wm_win_t *)lua_touserdata(ls, 1);
    lua_pushboolean(ls, wm_is_minimized(win));
    return 1;
}

/* wm.rect(win) → x, y, w, h */
static int l_wm_rect(lua_State *ls) {
    wm_win_t *win = (wm_win_t *)lua_touserdata(ls, 1);
    if (!win) { lua_pushnil(ls); return 1; }
    lua_pushinteger(ls, win->x);
    lua_pushinteger(ls, win->y);
    lua_pushinteger(ls, win->w);
    lua_pushinteger(ls, win->h);
    return 4;
}

/* wm.retitle(win, title) */
static int l_wm_retitle(lua_State *ls) {
    wm_win_t *win = (wm_win_t *)lua_touserdata(ls, 1);
    const char *title = luaL_checkstring(ls, 2);
    wm_retitle(win, title);
    return 0;
}

/* wm.resize(win, w, h) */
static int l_wm_resize(lua_State *ls) {
    wm_win_t *win = (wm_win_t *)lua_touserdata(ls, 1);
    int w = (int)luaL_checkinteger(ls, 2);
    int h = (int)luaL_checkinteger(ls, 3);
    wm_resize(win, w, h);
    return 0;
}

/* ── mouse API ──────────────────────────────────────────────────────────── */
static int l_mouse_x  (lua_State *ls) { lua_pushinteger(ls, mouse_x());    return 1; }
static int l_mouse_y  (lua_State *ls) { lua_pushinteger(ls, mouse_y());    return 1; }
static int l_mouse_btn(lua_State *ls) {
    int b = (int)luaL_optinteger(ls, 1, 0);
    lua_pushboolean(ls, mouse_btn(b));
    return 1;
}
static const luaL_Reg mouse_lib[] = {
    {"x",   l_mouse_x},
    {"y",   l_mouse_y},
    {"btn", l_mouse_btn},
    {NULL, NULL}
};

static const luaL_Reg wm_lib[] = {
    {"open",    l_wm_open},
    {"close",   l_wm_close},
    {"focus",   l_wm_focus},
    {"unfocus", l_wm_unfocus},
    {"present", l_wm_present},
    {"move",    l_wm_move},
    {"raise",   l_wm_raise},
    {"z",       l_wm_z},
    {"rect",        l_wm_rect},
    {"retitle",     l_wm_retitle},
    {"resize",      l_wm_resize},
    {"set_focused",  l_wm_set_focused},
    {"minimize",     l_wm_minimize},
    {"is_minimized", l_wm_is_minimized},
    {"draw_cursor",  l_wm_draw_cursor},
    {NULL, NULL}
};

static const luaL_Reg fs_lib[] = {
    {"read",   l_fs_read},
    {"list",   l_fs_list},
    {"exists", l_fs_exists},
    {"write",  l_fs_write},
    {"mkdir",  l_fs_mkdir},
    {"delete", l_fs_delete},
    {NULL, NULL}
};

static const luaL_Reg gfx_lib[] = {
    {"pset",      l_pset},
    {"cls",       l_cls},
    {"rect",      l_rect},
    {"line",      l_line},
    {"circ",      l_circ},
    {"circfill",  l_circfill},
    {"print",     l_print},
    {"pget",      l_pget},
    {"screen_w",  l_screen_w},
    {"screen_h",  l_screen_h},
    {"set_pal",   l_set_pal},
    {"get_pal",   l_get_pal},
    {"reset_pal", l_reset_pal},
    {NULL, NULL}
};

/* ── Init ───────────────────────────────────────────────────────────────── */
void klua_init(uint32_t *fb, uint32_t fb_w, uint32_t fb_h,
               const uint32_t *pal) {
    gfx_fb  = fb;
    gfx_w   = fb_w;
    gfx_h   = fb_h;
    /* Copy palette into mutable buffer so Lua can edit it */
    for (int i = 0; i < 32; i++) gfx_pal_buf[i] = pal ? pal[i] : 0;
    gfx_pal = gfx_pal_buf;

    L = lua_newstate(lua_kernel_alloc, 0);
    if (!L) { serial_puts("[LUA] lua_newstate failed\n"); return; }

    luaL_openlibs(L);

    /* Register gfx table */
    luaL_newlib(L, gfx_lib);
    lua_setglobal(L, "gfx");

    /* Register input table */
    luaL_newlib(L, input_lib);
    lua_setglobal(L, "input");

    /* Register fs table */
    luaL_newlib(L, fs_lib);
    lua_setglobal(L, "fs");

    /* Register wm table */
    wm_init();
    luaL_newlib(L, wm_lib);
    lua_setglobal(L, "wm");

    /* Register mouse table */
    luaL_newlib(L, mouse_lib);
    lua_setglobal(L, "mouse");

    /* Constants */
    lua_pushinteger(L, (lua_Integer)fb_w); lua_setglobal(L, "SCREEN_W");
    lua_pushinteger(L, (lua_Integer)fb_h); lua_setglobal(L, "SCREEN_H");

    /* pit_ticks global function (kept for back-compat) */
    lua_pushcfunction(L, l_pit_ticks); lua_setglobal(L, "pit_ticks");

    /* Register sys table (spawn/kill/ps added from main.lua) */
    luaL_newlib(L, sys_lib);
    lua_setglobal(L, "sys");

    /* Register ipc table */
    ipc_init();
    luaL_newlib(L, ipc_lib);
    lua_setglobal(L, "ipc");

    /* Init process table and scheduler */
    proc_init();
    sched_init();

    /* Register audio table and init subsystem */
    audio_init();
    luaL_newlib(L, audio_lib);
    lua_setglobal(L, "audio");

    serial_puts("[LUA] ready\n");
}

/* ── Run / call ─────────────────────────────────────────────────────────── */
int klua_run(const char *script) {
    if (!L) return -1;
    int r = luaL_dostring(L, script);
    if (r != LUA_OK) {
        serial_puts("[LUA] error: ");
        serial_puts(lua_tostring(L, -1));
        serial_putc('\n');
        lua_pop(L, 1);
    }
    return r;
}

int klua_call(const char *name) {
    if (!L) return -1;
    lua_getglobal(L, name);
    if (!lua_isfunction(L, -1)) { lua_pop(L, 1); return 0; }
    int r = lua_pcall(L, 0, 0, 0);
    if (r != LUA_OK) {
        serial_puts("[LUA] ");
        serial_puts(name);
        serial_puts(": ");
        serial_puts(lua_tostring(L, -1));
        serial_putc('\n');
        lua_pop(L, 1);
    }
    return r;
}
