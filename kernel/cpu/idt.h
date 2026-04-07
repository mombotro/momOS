#pragma once
#include <stdint.h>

/* Register state pushed by isr_common / irq_common in isr.asm */
typedef struct {
    uint32_t ds;
    uint32_t edi, esi, ebp, esp_dummy, ebx, edx, ecx, eax; /* pusha */
    uint32_t int_no, err_code;
    uint32_t eip, cs, eflags; /* pushed by CPU (ring-0 → ring-0, no ss/esp) */
} __attribute__((packed)) regs_t;

void idt_init(void);
void irq_register(int irq, void (*handler)(regs_t *));
