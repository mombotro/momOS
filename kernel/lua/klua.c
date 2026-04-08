#include "klua.h"
#include "font8x8.h"
#include "../cpu/serial.h"
#include "../cpu/keyboard.h"
#include "../vfs/vfs.h"
#include "../mm/heap.h"
#include "../cpu/pit.h"
#include "../cpu/mouse.h"
#include "../wm/wm.h"
#include "../lua/lua.h"
#include "../lua/lauxlib.h"
#include "../lua/lualib.h"
#include <stdint.h>

/* ── Framebuffer state (set by klua_init) ───────────────────────────────── */
static uint32_t        *gfx_fb  = 0;
static uint32_t         gfx_w   = 0;
static uint32_t         gfx_h   = 0;
static const uint32_t  *gfx_pal = 0;

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

/* gfx.pget(x, y) → color_index (approximate — returns palette index 0) */
static int l_pget(lua_State *ls) {
    (void)ls; lua_pushinteger(ls, 0); return 1;
}

/* gfx.screen_w() / gfx.screen_h() */
static int l_screen_w(lua_State *ls) { lua_pushinteger(ls, (lua_Integer)gfx_w); return 1; }
static int l_screen_h(lua_State *ls) { lua_pushinteger(ls, (lua_Integer)gfx_h); return 1; }

/* pit_ticks() global */
static int l_pit_ticks(lua_State *ls) { lua_pushinteger(ls, (lua_Integer)pit_ticks()); return 1; }

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
/* fs.read(path) → string or nil */
static int l_fs_read(lua_State *ls) {
    const char *path = luaL_checkstring(ls, 1);
    char *buf = vfs_read_alloc(path);
    if (!buf) { lua_pushnil(ls); return 1; }
    lua_pushstring(ls, buf);
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
    vfs_file_t *f = vfs_open(path);
    if (f) { vfs_close(f); lua_pushboolean(ls, 1); }
    else lua_pushboolean(ls, 0);
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
    wm_close(win);
    return 0;
}

/* wm.focus(win) — redirect gfx calls into win->fb */
static int l_wm_focus(lua_State *ls) {
    wm_win_t *win = (wm_win_t *)lua_touserdata(ls, 1);
    if (!win || !win->fb) return 0;
    /* save screen state once */
    if (!gfx_screen_fb) {
        gfx_screen_fb = gfx_fb;
        gfx_screen_w  = gfx_w;
        gfx_screen_h  = gfx_h;
    }
    gfx_fb = win->fb;
    gfx_w  = (uint32_t)win->w;
    gfx_h  = (uint32_t)win->h;
    return 0;
}

/* wm.unfocus() — restore gfx to screen backbuf */
static int l_wm_unfocus(lua_State *ls) {
    (void)ls;
    if (gfx_screen_fb) {
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
    {NULL, NULL}
};

static const luaL_Reg gfx_lib[] = {
    {"pset",     l_pset},
    {"cls",      l_cls},
    {"rect",     l_rect},
    {"print",    l_print},
    {"pget",     l_pget},
    {"screen_w", l_screen_w},
    {"screen_h", l_screen_h},
    {NULL, NULL}
};

/* ── Init ───────────────────────────────────────────────────────────────── */
void klua_init(uint32_t *fb, uint32_t fb_w, uint32_t fb_h,
               const uint32_t *pal) {
    gfx_fb  = fb;
    gfx_w   = fb_w;
    gfx_h   = fb_h;
    gfx_pal = pal;

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

    /* pit_ticks global function */
    lua_pushcfunction(L, l_pit_ticks); lua_setglobal(L, "pit_ticks");

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
