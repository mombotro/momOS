#pragma once
#include <stdint.h>

#ifdef HOSTED
/* Hosted mode: no ring-0 I/O instructions */
static inline void    outb(uint16_t p, uint8_t  v) { (void)p; (void)v; }
static inline void    outw(uint16_t p, uint16_t v) { (void)p; (void)v; }
static inline uint8_t inb (uint16_t p)             { (void)p; return 0; }
#else
static inline void outb(uint16_t port, uint8_t val) {
    __asm__ volatile ("outb %0, %1" : : "a"(val), "Nd"(port));
}

static inline uint8_t inb(uint16_t port) {
    uint8_t val;
    __asm__ volatile ("inb %1, %0" : "=a"(val) : "Nd"(port));
    return val;
}

static inline void outw(uint16_t port, uint16_t val) {
    __asm__ volatile ("outw %0, %1" : : "a"(val), "Nd"(port));
}
#endif
