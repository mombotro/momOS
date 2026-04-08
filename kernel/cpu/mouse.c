#include "mouse.h"
#include "idt.h"
#include "io.h"
#include <stdint.h>

/* ── PS/2 controller helpers ─────────────────────────────────────────────── */
static int ps2_wait_write(void) {
    for (int i = 0; i < 100000; i++) { if (!(inb(0x64) & 0x02)) return 1; }
    return 0;
}
static int ps2_wait_read(void) {
    for (int i = 0; i < 100000; i++) { if (inb(0x64) & 0x01) return 1; }
    return 0;
}

static void mouse_write(uint8_t val) {
    if (!ps2_wait_write()) return; outb(0x64, 0xD4);
    if (!ps2_wait_write()) return; outb(0x60, val);
}
static uint8_t mouse_read(void) {
    if (!ps2_wait_read()) return 0;
    return inb(0x60);
}

/* ── State ───────────────────────────────────────────────────────────────── */
static int mx = 320, my = 240;   /* start at screen centre */
static uint8_t mbtns = 0;

static uint8_t pkt[3];
static int     pkt_idx = 0;

static void mouse_irq(regs_t *r) {
    (void)r;
    uint8_t data = inb(0x60);

    /* First byte must have bit 3 set — resync if not */
    if (pkt_idx == 0 && !(data & 0x08)) return;

    pkt[pkt_idx++] = data;
    if (pkt_idx < 3) return;
    pkt_idx = 0;

    uint8_t flags = pkt[0];

    /* Relative movement — sign-extend 9-bit values */
    int dx = (int)pkt[1] - ((flags & 0x10) ? 256 : 0);
    int dy = (int)pkt[2] - ((flags & 0x20) ? 256 : 0);

    mx += dx;
    my -= dy;   /* PS/2 Y is inverted relative to screen */

    if (mx < 0)   mx = 0;
    if (my < 0)   my = 0;
    if (mx > 639) mx = 639;
    if (my > 479) my = 479;

    mbtns = flags & 0x07;
}

/* ── Init ────────────────────────────────────────────────────────────────── */
void mouse_init(void) {
    /* Enable auxiliary device */
    ps2_wait_write(); outb(0x64, 0xA8);

    /* Enable IRQ12 (aux interrupt) via command byte */
    ps2_wait_write(); outb(0x64, 0x20);
    ps2_wait_read();
    uint8_t status = (inb(0x60) | 0x02) & ~0x20; /* enable aux IRQ, enable aux clock */
    ps2_wait_write(); outb(0x64, 0x60);
    ps2_wait_write(); outb(0x60, status);

    /* Set defaults, enable reporting */
    mouse_write(0xF6);  mouse_read();  /* set defaults */
    mouse_write(0xF4);  mouse_read();  /* enable streaming */

    irq_register(12, mouse_irq);

    /* Unmask IRQ2 (cascade) on master PIC so slave IRQs can reach the CPU */
    outb(0x21, inb(0x21) & ~0x04);
    /* Unmask IRQ12 on slave PIC (bit 4 of 0xA1) */
    outb(0xA1, inb(0xA1) & ~0x10);
}

/* ── Public API ──────────────────────────────────────────────────────────── */
int mouse_x  (void)      { return mx; }
int mouse_y  (void)      { return my; }
int mouse_btn(int b)     { return (mbtns >> b) & 1; }
