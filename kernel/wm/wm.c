#include "wm.h"
#include "../mm/heap.h"
#include "../lua/font8x8.h"
#include "../cpu/mouse.h"
#include <stdint.h>

/* 12×19 arrow cursor, 1=fg 2=outline */
static const uint8_t cursor_mask[19][12] = {
    {1,0,0,0,0,0,0,0,0,0,0,0},
    {1,1,0,0,0,0,0,0,0,0,0,0},
    {1,2,1,0,0,0,0,0,0,0,0,0},
    {1,2,2,1,0,0,0,0,0,0,0,0},
    {1,2,2,2,1,0,0,0,0,0,0,0},
    {1,2,2,2,2,1,0,0,0,0,0,0},
    {1,2,2,2,2,2,1,0,0,0,0,0},
    {1,2,2,2,2,2,2,1,0,0,0,0},
    {1,2,2,2,2,2,2,2,1,0,0,0},
    {1,2,2,2,2,2,2,2,2,1,0,0},
    {1,2,2,2,2,2,2,2,2,2,1,0},
    {1,2,2,2,2,2,2,1,1,1,1,1},
    {1,2,2,2,1,2,2,1,0,0,0,0},
    {1,2,2,1,0,1,2,2,1,0,0,0},
    {1,2,1,0,0,1,2,2,1,0,0,0},
    {1,1,0,0,0,0,1,2,2,1,0,0},
    {1,0,0,0,0,0,1,2,2,1,0,0},
    {0,0,0,0,0,0,0,1,2,1,0,0},
    {0,0,0,0,0,0,0,1,1,0,0,0},
};

static wm_win_t  wins[WM_MAX_WINS];
static int       next_z = 1;
static wm_win_t *focused_win = 0;
static wm_dirty_t dirty = {0,0,0,0,0};

/* Expand dirty rect to include region (x,y,w,h) */
void wm_mark_dirty(int x, int y, int w, int h) {
    int x1 = x + w - 1, y1 = y + h - 1;
    if (!dirty.valid) {
        dirty.x0 = x; dirty.y0 = y; dirty.x1 = x1; dirty.y1 = y1;
        dirty.valid = 1;
    } else {
        if (x  < dirty.x0) dirty.x0 = x;
        if (y  < dirty.y0) dirty.y0 = y;
        if (x1 > dirty.x1) dirty.x1 = x1;
        if (y1 > dirty.y1) dirty.y1 = y1;
    }
}

/* Mark a window's full chrome area (title bar + client) dirty */
void wm_mark_win_dirty(wm_win_t *win) {
    if (!win || !win->open || win->minimized) return;
    int bx = win->x - WM_BORDER - 1;
    int by = win->y - WM_TITLE_H - WM_BORDER - 1;
    int bw = win->w + WM_BORDER * 2 + 2;
    int bh = win->h + WM_TITLE_H + WM_BORDER * 2 + 2;
    wm_mark_dirty(bx, by, bw, bh);
}

wm_dirty_t wm_get_dirty(void)  { return dirty; }
void wm_clear_dirty(void)      { dirty.valid = 0; }

void wm_init(void) {
    for (int i = 0; i < WM_MAX_WINS; i++) wins[i].open = 0;
}

wm_win_t *wm_open(const char *title, int x, int y, int w, int h) {
    for (int i = 0; i < WM_MAX_WINS; i++) {
        if (wins[i].open) continue;
        wm_win_t *win = &wins[i];
        int j = 0;
        while (title[j] && j < 63) { win->title[j] = title[j]; j++; }
        win->title[j] = '\0';
        win->x = x; win->y = y; win->w = w; win->h = h;
        win->fb = (uint32_t *)kmalloc((uint32_t)(w * h) * sizeof(uint32_t));
        win->z = next_z++;
        win->open = 1;
        win->dirty = 1;
        for (int k = 0; k < w * h; k++) win->fb[k] = 0;
        wm_mark_win_dirty(win);
        return win;
    }
    return 0;
}

void wm_close(wm_win_t *win) {
    if (!win) return;
    wm_mark_win_dirty(win);   /* mark old position dirty before closing */
    kfree(win->fb);
    win->fb = 0;
    win->open = 0;
}

void wm_move(wm_win_t *win, int x, int y) {
    if (!win) return;
    wm_mark_win_dirty(win);   /* old position */
    win->x = x; win->y = y;
    wm_mark_win_dirty(win);   /* new position */
    win->dirty = 1;
}

void wm_raise(wm_win_t *win) {
    if (win) win->z = next_z++;
}

void wm_set_focused  (wm_win_t *win) { focused_win = win; }
void wm_set_minimized(wm_win_t *win, int v) { if (win) win->minimized = v; }
int  wm_is_minimized (wm_win_t *win) { return win ? win->minimized : 0; }

void wm_resize(wm_win_t *win, int w, int h) {
    if (!win) return;
    wm_mark_win_dirty(win);   /* old bounds */
    kfree(win->fb);
    win->w = w; win->h = h;
    win->fb = (uint32_t *)kmalloc((uint32_t)(w * h) * sizeof(uint32_t));
    for (int k = 0; k < w * h; k++) win->fb[k] = 0;
    wm_mark_win_dirty(win);   /* new bounds */
    win->dirty = 1;
}

void wm_retitle(wm_win_t *win, const char *title) {
    if (!win) return;
    int j = 0;
    while (title[j] && j < 63) { win->title[j] = title[j]; j++; }
    win->title[j] = '\0';
}

/* ── Drawing helpers (direct to dst buffer) ──────────────────────────────── */
static void _rect(uint32_t *dst, int sw, int sh,
                  int x, int y, int w, int h, uint32_t col) {
    for (int row = y; row < y + h; row++) {
        if (row < 0 || row >= sh) continue;
        for (int col2 = x; col2 < x + w; col2++) {
            if (col2 < 0 || col2 >= sw) continue;
            dst[row * sw + col2] = col;
        }
    }
}

static void _text(uint32_t *dst, int sw, int sh,
                  int x, int y, const char *s, uint32_t col) {
    int cx = x;
    for (; *s; s++) {
        int ch = (unsigned char)*s;
        if (ch < 32 || ch > 127) ch = 32;
        const uint8_t *glyph = font8x8[ch - 32];
        for (int row = 0; row < 8; row++) {
            uint8_t bits = glyph[row];
            for (int c = 0; c < 8; c++) {
                if (!(bits & (1 << c))) continue;
                int px = cx + c, py = y + row;
                if (px < 0 || px >= sw || py < 0 || py >= sh) continue;
                dst[py * sw + px] = col;
            }
        }
        cx += 8;
    }
}

/* Blit src (w×h) into dst at (dx,dy), clipped to dst bounds */
static void _blit(uint32_t *dst, int sw, int sh,
                  const uint32_t *src, int dx, int dy, int w, int h) {
    for (int row = 0; row < h; row++) {
        int py = dy + row;
        if (py < 0 || py >= sh) continue;
        for (int col = 0; col < w; col++) {
            int px = dx + col;
            if (px < 0 || px >= sw) continue;
            dst[py * sw + px] = src[row * w + col];
        }
    }
}

/* ── Composite ───────────────────────────────────────────────────────────── */
static void _draw_cursor(uint32_t *dst, int sw, int sh, const uint32_t *pal) {
    int cx = mouse_x(), cy = mouse_y();
    uint32_t fg = pal[7], outline = pal[11];
    for (int row = 0; row < 19; row++)
        for (int col = 0; col < 12; col++) {
            uint8_t v = cursor_mask[row][col];
            if (!v) continue;
            int px = cx + col, py = cy + row;
            if (px < 0 || px >= sw || py < 0 || py >= sh) continue;
            dst[py * sw + px] = (v == 1) ? outline : fg;
        }
}

void wm_composite(uint32_t *dst, int sw, int sh, const uint32_t *pal) {
    /* Sort windows by z-order (simple selection — max 8 windows) */
    int order[WM_MAX_WINS], n = 0;
    for (int i = 0; i < WM_MAX_WINS; i++)
        if (wins[i].open) order[n++] = i;
    /* bubble sort ascending z */
    for (int a = 0; a < n - 1; a++)
        for (int b = a + 1; b < n; b++)
            if (wins[order[a]].z > wins[order[b]].z) {
                int tmp = order[a]; order[a] = order[b]; order[b] = tmp;
            }

    /* Palette colours for chrome */
    uint32_t col_border   = pal[9];
    uint32_t col_title_bg = pal[2];
    uint32_t col_title_fg = pal[7];

    for (int i = 0; i < n; i++) {
        wm_win_t *win = &wins[order[i]];

        if (win->minimized) continue;

        /* Mark dirty if this window changed */
        if (win->dirty) {
            wm_mark_win_dirty(win);
            win->dirty = 0;
        }

        int bx = win->x - WM_BORDER;
        int by = win->y - WM_TITLE_H - WM_BORDER;
        int bw = win->w + WM_BORDER * 2;
        int bh = win->h + WM_TITLE_H + WM_BORDER * 2;

        /* Outer border */
        _rect(dst, sw, sh, bx - 1, by - 1, bw + 2, bh + 2, col_border);
        /* Title bar — brighter if focused */
        uint32_t tbcol = (win == focused_win) ? pal[3] : col_title_bg;
        _rect(dst, sw, sh, bx, by, bw, WM_TITLE_H, tbcol);
        /* Title text — vertically centred in title bar */
        int txt_y = by + (WM_TITLE_H - 8) / 2;
        _text(dst, sw, sh, bx + 4, txt_y, win->title, col_title_fg);

        /* Chrome buttons — right side, vertically centred, 12×10 each with 2px gap */
        int btn_r = bx + bw - 3;
        int btn_y = by + (WM_TITLE_H - 10) / 2;
        /* close (x) — red */
        _rect(dst, sw, sh, btn_r - 12, btn_y, 12, 10, pal[12]);
        _text(dst, sw, sh, btn_r - 10, btn_y + 1, "x", pal[7]);
        /* maximize/restore (o) — green */
        _rect(dst, sw, sh, btn_r - 26, btn_y, 12, 10, pal[10]);
        _text(dst, sw, sh, btn_r - 24, btn_y + 1, "o", pal[7]);
        /* minimize (-) — grey */
        _rect(dst, sw, sh, btn_r - 40, btn_y, 12, 10, pal[9]);
        _text(dst, sw, sh, btn_r - 38, btn_y + 1, "-", pal[7]);

        /* Client area border fill */
        _rect(dst, sw, sh, bx, win->y - WM_BORDER, bw, win->h + WM_BORDER * 2, col_border);
        /* Blit client fb */
        _blit(dst, sw, sh, win->fb, win->x, win->y, win->w, win->h);

        /* Resize grip — 3 diagonal dots in bottom-right corner */
        int gx = win->x + win->w - 2;
        int gy = win->y + win->h - 2;
        _rect(dst, sw, sh, gx,     gy,     2, 2, pal[8]);
        _rect(dst, sw, sh, gx - 4, gy,     2, 2, pal[8]);
        _rect(dst, sw, sh, gx,     gy - 4, 2, 2, pal[8]);
    }

}

void wm_draw_cursor(uint32_t *dst, int sw, int sh, const uint32_t *pal) {
    static int prev_cx = -1, prev_cy = -1;
    int cx = mouse_x(), cy = mouse_y();
    /* Mark previous cursor position dirty */
    if (prev_cx >= 0) wm_mark_dirty(prev_cx - 1, prev_cy - 1, 14, 22);
    /* Mark new cursor position dirty */
    wm_mark_dirty(cx - 1, cy - 1, 14, 22);
    prev_cx = cx; prev_cy = cy;
    _draw_cursor(dst, sw, sh, pal);
}
