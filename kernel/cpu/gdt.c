#include "gdt.h"
#include <stdint.h>

typedef struct {
    uint16_t limit_low;
    uint16_t base_low;
    uint8_t  base_mid;
    uint8_t  access;
    uint8_t  granularity; /* high 4 bits: flags, low 4 bits: limit[19:16] */
    uint8_t  base_high;
} __attribute__((packed)) gdt_entry_t;

typedef struct {
    uint16_t limit;
    uint32_t base;
} __attribute__((packed)) gdt_ptr_t;

static gdt_entry_t gdt[3];
static gdt_ptr_t   gdt_ptr;

extern void gdt_flush(uint32_t ptr);

static void gdt_set(int i, uint32_t base, uint32_t limit, uint8_t access, uint8_t gran) {
    gdt[i].base_low    = base & 0xFFFF;
    gdt[i].base_mid    = (base >> 16) & 0xFF;
    gdt[i].base_high   = (base >> 24) & 0xFF;
    gdt[i].limit_low   = limit & 0xFFFF;
    gdt[i].granularity = ((limit >> 16) & 0x0F) | (gran & 0xF0);
    gdt[i].access      = access;
}

void gdt_init(void) {
    gdt_ptr.limit = sizeof(gdt) - 1;
    gdt_ptr.base  = (uint32_t)&gdt;

    gdt_set(0, 0, 0,          0x00, 0x00); /* null descriptor          */
    gdt_set(1, 0, 0xFFFFFFFF, 0x9A, 0xCF); /* kernel code: ring 0, rx  */
    gdt_set(2, 0, 0xFFFFFFFF, 0x92, 0xCF); /* kernel data: ring 0, rw  */

    gdt_flush((uint32_t)&gdt_ptr);
}
