#pragma once
#include <stdint.h>

#define WM_MAX_WINS  8
#define WM_TITLE_H   16   /* pixels */
#define WM_BORDER    1    /* pixels */

typedef struct wm_win {
    char      title[64];
    int       x, y;      /* client area top-left on screen */
    int       w, h;      /* client area size */
    uint32_t *fb;        /* heap-allocated w*h pixel buffer */
    int       z;         /* z-order; higher = on top */
    int       open;
    int       minimized;
} wm_win_t;

void      wm_init      (void);
wm_win_t *wm_open      (const char *title, int x, int y, int w, int h);
void      wm_close     (wm_win_t *win);
void      wm_move      (wm_win_t *win, int x, int y);
void      wm_raise     (wm_win_t *win);
void      wm_retitle   (wm_win_t *win, const char *title);
void      wm_set_focused  (wm_win_t *win);
void      wm_set_minimized(wm_win_t *win, int v);
int       wm_is_minimized (wm_win_t *win);
void      wm_resize       (wm_win_t *win, int w, int h);

/* Composite all open windows onto dst (the back buffer) */
void wm_composite  (uint32_t *dst, int sw, int sh, const uint32_t *pal);
/* Draw mouse cursor on top of dst */
void wm_draw_cursor(uint32_t *dst, int sw, int sh, const uint32_t *pal);
