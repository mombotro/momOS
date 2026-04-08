#pragma once
#include <stdint.h>

void serial_init(void);
void serial_putc(char c);
void serial_puts(const char *s);
void serial_write(const char *s, unsigned int len);
void serial_hex(uint32_t n);
