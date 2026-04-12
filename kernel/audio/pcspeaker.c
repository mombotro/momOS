#include "audio.h"
#include <stdint.h>

/* PC Speaker via PIT channel 2 + port 0x61 */

#define PIT_BASE_FREQ  1193182u   /* Hz */

static void outb(uint16_t port, uint8_t val) {
    __asm__ volatile ("outb %0, %1" : : "a"(val), "Nd"(port));
}
static uint8_t inb(uint16_t port) {
    uint8_t val;
    __asm__ volatile ("inb %1, %0" : "=a"(val) : "Nd"(port));
    return val;
}

void pcspeaker_tone(uint32_t freq) {
    if (freq == 0) {
        /* Turn off speaker */
        outb(0x61, inb(0x61) & 0xFC);
        return;
    }
    uint32_t divisor = PIT_BASE_FREQ / freq;
    if (divisor == 0) divisor = 1;
    if (divisor > 0xFFFF) divisor = 0xFFFF;

    /* PIT channel 2, mode 3 (square wave) */
    outb(0x43, 0xB6);                          /* channel 2, mode 3, binary */
    outb(0x42, (uint8_t)(divisor & 0xFF));     /* low byte */
    outb(0x42, (uint8_t)(divisor >> 8));       /* high byte */

    /* Enable speaker (bits 0 and 1 of port 0x61) */
    outb(0x61, inb(0x61) | 0x03);
}
