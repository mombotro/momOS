#include "serial.h"
#include "io.h"

#define COM1 0x3F8

void serial_init(void) {
    outb(COM1 + 1, 0x00); // disable interrupts
    outb(COM1 + 3, 0x80); // enable DLAB (baud rate divisor mode)
    outb(COM1 + 0, 0x03); // divisor low  → 38400 baud
    outb(COM1 + 1, 0x00); // divisor high
    outb(COM1 + 3, 0x03); // 8 bits, no parity, 1 stop bit
    outb(COM1 + 2, 0xC7); // enable FIFO, 14-byte threshold
    outb(COM1 + 4, 0x0B); // RTS + DSR + out2
}

void serial_putc(char c) {
    while (!(inb(COM1 + 5) & 0x20)); // wait for transmit-hold-empty
    outb(COM1, (uint8_t)c);
}

void serial_puts(const char *s) {
    for (; *s; s++) {
        if (*s == '\n') serial_putc('\r');
        serial_putc(*s);
    }
}

void serial_write(const char *s, unsigned int len) {
    for (unsigned int i = 0; i < len; i++) serial_putc(s[i]);
}

void serial_hex(uint32_t n) {
    serial_puts("0x");
    char buf[9];
    for (int i = 7; i >= 0; i--) {
        buf[i] = "0123456789ABCDEF"[n & 0xF];
        n >>= 4;
    }
    buf[8] = '\0';
    serial_puts(buf);
}
