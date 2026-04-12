#include "keyboard.h"
#include "idt.h"
#include "io.h"
#include <stdint.h>

/* key_state[0..127]  = normal scancodes
   key_state[128..255] = extended (E0-prefixed) scancodes */
static uint8_t key_state[256];
static int     ext_next = 0;

/* ── Scancode set 1 → ASCII ──────────────────────────────────────────────── */
static const char sc_normal[128] = {
    0,   27,  '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', '\b',
    '\t','q',  'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']', '\n',
    0,   'a',  's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', '\'','`',
    0,   '\\', 'z', 'x', 'c', 'v', 'b', 'n', 'm', ',', '.', '/',
    0,   '*',  0,   ' ',
    /* rest zero */
};
static const char sc_shifted[128] = {
    0,   27,  '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '_', '+', '\b',
    '\t','Q',  'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '{', '}', '\n',
    0,   'A',  'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', ':', '"', '~',
    0,   '|',  'Z', 'X', 'C', 'V', 'B', 'N', 'M', '<', '>', '?',
    0,   '*',  0,   ' ',
};

/* ── Char ring buffer ────────────────────────────────────────────────────── */
#define CBUF_SIZE 64
static char    cbuf[CBUF_SIZE];
static uint8_t cbuf_head = 0, cbuf_tail = 0;

static void cbuf_push(char c) {
    uint8_t next = (cbuf_head + 1) & (CBUF_SIZE - 1);
    if (next != cbuf_tail) { cbuf[cbuf_head] = c; cbuf_head = next; }
}

/* ── IRQ handler ─────────────────────────────────────────────────────────── */
static void kbd_irq(regs_t *r) {
    (void)r;
    uint8_t sc = inb(0x60);

    if (sc == 0xE0) { ext_next = 1; return; }

    int base = ext_next ? 128 : 0;
    ext_next = 0;

    if (sc & 0x80) {
        key_state[base + (sc & 0x7F)] = 0;   /* release */
    } else {
        key_state[base + sc] = 1;             /* press   */

        if (base == 0 && sc < 128) {
            /* F-keys (non-extended) */
            if (sc == 0x3E) { cbuf_push('\x0f'); return; } /* F4 → close */

            /* Normal key → produce ASCII */
            int shifted = key_state[KEY_LSHIFT] || key_state[KEY_RSHIFT];
            char c = shifted ? sc_shifted[sc] : sc_normal[sc];
            if (c) cbuf_push(c);
        } else if (base == 128) {
            /* Extended key — push sentinel bytes for common keys */
            switch (sc) {
                case 0x48: cbuf_push('\x01'); break; /* up        */
                case 0x50: cbuf_push('\x02'); break; /* down      */
                case 0x4B: cbuf_push('\x03'); break; /* left      */
                case 0x4D: cbuf_push('\x04'); break; /* right     */
                case 0x53: cbuf_push('\x7f'); break; /* delete    */
                case 0x47: cbuf_push('\x05'); break; /* home      */
                case 0x4F: cbuf_push('\x06'); break; /* end       */
                case 0x49: cbuf_push('\x0b'); break; /* page up   */
                case 0x51: cbuf_push('\x0c'); break; /* page down */
            }
        }
    }
}

/* ── Public API ──────────────────────────────────────────────────────────── */
void kbd_init(void) {
    while (inb(0x64) & 0x01) inb(0x60);
    irq_register(1, kbd_irq);
    uint8_t mask = inb(0x21);
    outb(0x21, mask & ~0x02);
}

int kbd_key_down(int keycode) {
    if (keycode < 0 || keycode > 255) return 0;
    return key_state[keycode] ? 1 : 0;
}

/* Returns next char from buffer, or 0 if empty */
char kbd_getchar(void) {
    if (cbuf_tail == cbuf_head) return 0;
    char c = cbuf[cbuf_tail];
    cbuf_tail = (cbuf_tail + 1) & (CBUF_SIZE - 1);
    return c;
}
