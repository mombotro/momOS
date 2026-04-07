#include "pit.h"
#include "idt.h"
#include "io.h"
#include "serial.h"

#define PIT_HZ      60
#define PIT_DIVISOR (1193182 / PIT_HZ)   /* 19886 → ~60.00 Hz */

#define PIT_DATA0   0x40
#define PIT_CMD     0x43

static volatile uint32_t tick_count = 0;

static void pit_irq(regs_t *r) {
    (void)r;
    tick_count++;
}

void pit_init(void) {
    /* Mode 3: square wave generator, lobyte/hibyte, channel 0 */
    outb(PIT_CMD,   0x36);
    outb(PIT_DATA0, (uint8_t)(PIT_DIVISOR & 0xFF));
    outb(PIT_DATA0, (uint8_t)(PIT_DIVISOR >> 8));

    irq_register(0, pit_irq);

    /* Unmask IRQ0 in master PIC */
    uint8_t mask = inb(0x21);
    outb(0x21, mask & ~(1 << 0));

    serial_puts("[PIT] 60 Hz\n");
}

uint32_t pit_ticks(void) {
    return tick_count;
}

/* Spin-wait for n ticks (cooperative — fine until we have a scheduler) */
void pit_sleep(uint32_t ticks) {
    uint32_t end = tick_count + ticks;
    while (tick_count < end)
        __asm__ volatile ("hlt"); /* sleep until next interrupt */
}
