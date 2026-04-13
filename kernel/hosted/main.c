/* main.c — momOS hosted mode entry point (SDL2)
 *
 * Replaces kernel/kernel.c for native Windows/Linux/macOS builds.
 * Usage:
 *   ./momos [initrd.lfs] [disk.img]
 *   (defaults to initrd.lfs and disk.img in current directory)
 */

#define SDL_MAIN_HANDLED  /* prevent SDL from hijacking main() on Windows */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <SDL.h>

#include "../lua/klua.h"
#include "../vfs/vfs.h"
#include "../wm/wm.h"
#include "../mm/heap.h"
#include "../cpu/pit.h"

/* ── Declarations for hosted HAL helpers ─────────────────────────────────── */
void hal_kbd_event(SDL_Keycode sym, SDL_Scancode scancode, int down);
void hal_text_event(const char *text);
void hal_mouse_move(int x, int y);
void hal_mouse_btn(int b, int down);

/* Provided by hal.c */
int  audio_init(void);
void acpi_shutdown(void);

/* ── momOS 32-color palette (same as kernel.c) ───────────────────────────── */
static const uint32_t pal[32] = {
    0x1a1a2e, 0x16213e, 0x0f3460, 0x533483,
    0xe94560, 0xff6b9d, 0xffb3c6, 0xffffff,
    0xc0c0c0, 0x808080, 0x404040, 0x000000,
    0xff4444, 0xff8800, 0xffdd00, 0x88cc00,
    0x00cc44, 0x00ccaa, 0x00aaff, 0x0055ff,
    0x6600ff, 0xcc00ff, 0xff00aa, 0xff6666,
    0xffcc99, 0xffff99, 0x99ff99, 0x99ffff,
    0x99ccff, 0xcc99ff, 0x663300, 0x336600,
};

/* ── Window dimensions ───────────────────────────────────────────────────── */
#define SCREEN_W  1024
#define SCREEN_H  600

/* ── Load a file into a malloc'd buffer. Returns NULL on failure. ────────── */
static void *load_file(const char *path, uint32_t *out_size) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    rewind(f);
    if (sz <= 0) { fclose(f); return NULL; }
    void *buf = malloc((size_t)sz);
    if (!buf) { fclose(f); return NULL; }
    if (fread(buf, 1, (size_t)sz, f) != (size_t)sz) { free(buf); fclose(f); return NULL; }
    fclose(f);
    if (out_size) *out_size = (uint32_t)sz;
    return buf;
}

/* ── Present: blit backbuf → SDL texture ─────────────────────────────────── */
static void present(SDL_Renderer *ren, SDL_Texture *tex, const uint32_t *backbuf) {
    /* Upload full backbuf (SDL texture update handles partial via dirty rect too,
       but for simplicity always update the whole surface. The texture is in
       ARGB8888; backbuf pixels are 0x00RRGGBB so they're already compatible
       as long as we set alpha = 0xFF. We write with pitch = SCREEN_W * 4. */
    SDL_UpdateTexture(tex, NULL, backbuf, SCREEN_W * 4);
    SDL_RenderClear(ren);
    SDL_RenderCopy(ren, tex, NULL, NULL);
    SDL_RenderPresent(ren);
}

int main(int argc, char **argv) {
    const char *initrd_path = (argc > 1) ? argv[1] : "initrd.lfs";

    /* ── SDL init ────────────────────────────────────────────────────────── */
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO | SDL_INIT_EVENTS) != 0) {
        fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
        return 1;
    }
    SDL_Window *win = SDL_CreateWindow(
        "momOS (hosted)",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        SCREEN_W, SCREEN_H,
        SDL_WINDOW_SHOWN);
    if (!win) {
        fprintf(stderr, "SDL_CreateWindow failed: %s\n", SDL_GetError());
        return 1;
    }
    SDL_Renderer *ren = SDL_CreateRenderer(win, -1,
        SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
    if (!ren) ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_SOFTWARE);
    if (!ren) {
        fprintf(stderr, "SDL_CreateRenderer failed: %s\n", SDL_GetError());
        return 1;
    }
    /* Texture: ARGB8888 matches our 0x00RRGGBB backbuf layout (top byte = 0) */
    SDL_Texture *tex = SDL_CreateTexture(ren,
        SDL_PIXELFORMAT_ARGB8888, SDL_TEXTUREACCESS_STREAMING,
        SCREEN_W, SCREEN_H);
    if (!tex) {
        fprintf(stderr, "SDL_CreateTexture failed: %s\n", SDL_GetError());
        return 1;
    }
    /* Enable relative mouse positioning inside window */
    SDL_SetRelativeMouseMode(SDL_FALSE);

    /* ── VFS: load initrd ────────────────────────────────────────────────── */
    uint32_t initrd_size = 0;
    void *initrd_buf = load_file(initrd_path, &initrd_size);
    if (!initrd_buf) {
        fprintf(stderr, "[VFS] cannot open %s\n", initrd_path);
        /* Continue without initrd — Lua will get no scripts */
    } else {
        fprintf(stderr, "[VFS] loaded %s (%u bytes)\n", initrd_path, initrd_size);
        vfs_init((uintptr_t)initrd_buf, initrd_size);
    }

    /* ── Audio ───────────────────────────────────────────────────────────── */
    audio_init();

    /* ── Backbuffer ──────────────────────────────────────────────────────── */
    uint32_t *backbuf = (uint32_t *)calloc(SCREEN_W * SCREEN_H, sizeof(uint32_t));
    if (!backbuf) { fprintf(stderr, "OOM: backbuf\n"); return 1; }

    /* ── Lua subsystem ───────────────────────────────────────────────────── */
    klua_init(backbuf, SCREEN_W, SCREEN_H, pal);

    char *script = vfs_read_alloc("/sys/main.lua");
    if (script) {
        fprintf(stderr, "[LUA] running /sys/main.lua\n");
        klua_run(script);
        kfree(script);
    } else {
        fprintf(stderr, "[LUA] /sys/main.lua not found\n");
    }

    fprintf(stderr, "=== hosted boot OK ===\n");

    /* ── Main loop ───────────────────────────────────────────────────────── */
    uint32_t frame_ms = 1000 / 60;   /* ~16 ms per frame */
    int running = 1;

    while (running) {
        Uint32 frame_start = SDL_GetTicks();

        /* Poll events */
        SDL_Event ev;
        while (SDL_PollEvent(&ev)) {
            switch (ev.type) {
            case SDL_QUIT:
                running = 0;
                break;
            case SDL_KEYDOWN:
                hal_kbd_event(ev.key.keysym.sym, ev.key.keysym.scancode, 1);
                /* Alt+F4 / Escape exits */
                if (ev.key.keysym.sym == SDLK_F4 &&
                    (ev.key.keysym.mod & KMOD_ALT))
                    running = 0;
                break;
            case SDL_KEYUP:
                hal_kbd_event(ev.key.keysym.sym, ev.key.keysym.scancode, 0);
                break;
            case SDL_TEXTINPUT:
                hal_text_event(ev.text.text);
                break;
            case SDL_MOUSEMOTION:
                hal_mouse_move(ev.motion.x, ev.motion.y);
                break;
            case SDL_MOUSEBUTTONDOWN:
                hal_mouse_move(ev.button.x, ev.button.y);
                /* SDL button: 1=left 3=right 2=middle → momOS: 0=left 1=right 2=middle */
                if (ev.button.button == SDL_BUTTON_LEFT)   hal_mouse_btn(0, 1);
                if (ev.button.button == SDL_BUTTON_RIGHT)  hal_mouse_btn(1, 1);
                if (ev.button.button == SDL_BUTTON_MIDDLE) hal_mouse_btn(2, 1);
                break;
            case SDL_MOUSEBUTTONUP:
                if (ev.button.button == SDL_BUTTON_LEFT)   hal_mouse_btn(0, 0);
                if (ev.button.button == SDL_BUTTON_RIGHT)  hal_mouse_btn(1, 0);
                if (ev.button.button == SDL_BUTTON_MIDDLE) hal_mouse_btn(2, 0);
                break;
            }
        }

        /* Lua update + draw */
        klua_call("_update");
        klua_call("_draw");

        /* Blit to screen */
        present(ren, tex, backbuf);

        /* Cap to 60 fps */
        Uint32 elapsed = SDL_GetTicks() - frame_start;
        if (elapsed < frame_ms)
            SDL_Delay(frame_ms - elapsed);
    }

    /* Cleanup */
    SDL_DestroyTexture(tex);
    SDL_DestroyRenderer(ren);
    SDL_DestroyWindow(win);
    SDL_Quit();
    free(backbuf);
    if (initrd_buf) free(initrd_buf);
    return 0;
}
