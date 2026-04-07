#include "idt.h"
#include "io.h"
#include "serial.h"
#include <stdint.h>

static void (*irq_handlers[16])(regs_t *);

void irq_register(int irq, void (*handler)(regs_t *)) {
    if (irq >= 0 && irq < 16)
        irq_handlers[irq] = handler;
}

typedef struct {
    uint16_t base_low;
    uint16_t sel;
    uint8_t  zero;
    uint8_t  flags;
    uint16_t base_high;
} __attribute__((packed)) idt_entry_t;

typedef struct {
    uint16_t limit;
    uint32_t base;
} __attribute__((packed)) idt_ptr_t;

static idt_entry_t idt[256];
static idt_ptr_t   idt_ptr;

extern void idt_flush(uint32_t ptr);

/* ISR stubs — defined in isr.asm */
extern void isr0(void);  extern void isr1(void);  extern void isr2(void);
extern void isr3(void);  extern void isr4(void);  extern void isr5(void);
extern void isr6(void);  extern void isr7(void);  extern void isr8(void);
extern void isr9(void);  extern void isr10(void); extern void isr11(void);
extern void isr12(void); extern void isr13(void); extern void isr14(void);
extern void isr15(void); extern void isr16(void); extern void isr17(void);
extern void isr18(void); extern void isr19(void); extern void isr20(void);
extern void isr21(void); extern void isr22(void); extern void isr23(void);
extern void isr24(void); extern void isr25(void); extern void isr26(void);
extern void isr27(void); extern void isr28(void); extern void isr29(void);
extern void isr30(void); extern void isr31(void);

/* IRQ stubs — defined in isr.asm */
extern void irq0(void);  extern void irq1(void);  extern void irq2(void);
extern void irq3(void);  extern void irq4(void);  extern void irq5(void);
extern void irq6(void);  extern void irq7(void);  extern void irq8(void);
extern void irq9(void);  extern void irq10(void); extern void irq11(void);
extern void irq12(void); extern void irq13(void); extern void irq14(void);
extern void irq15(void);

static void idt_set(int i, uint32_t base) {
    idt[i].base_low  = base & 0xFFFF;
    idt[i].base_high = (base >> 16) & 0xFFFF;
    idt[i].sel       = 0x08; /* kernel code segment */
    idt[i].zero      = 0;
    idt[i].flags     = 0x8E; /* present, ring 0, 32-bit interrupt gate */
}

static void pic_remap(void) {
    /* ICW1: start initialisation */
    outb(0x20, 0x11); outb(0xA0, 0x11);
    /* ICW2: vector offsets — master → 32, slave → 40 */
    outb(0x21, 0x20); outb(0xA1, 0x28);
    /* ICW3: cascade wiring */
    outb(0x21, 0x04); outb(0xA1, 0x02);
    /* ICW4: 8086 mode */
    outb(0x21, 0x01); outb(0xA1, 0x01);
    /* Mask all IRQs for now; PIT (IRQ0) unmasked when PIT is initialised */
    outb(0x21, 0xFF); outb(0xA1, 0xFF);
}

void idt_init(void) {
    idt_ptr.limit = sizeof(idt) - 1;
    idt_ptr.base  = (uint32_t)&idt;

    pic_remap();

    idt_set(0,  (uint32_t)isr0);  idt_set(1,  (uint32_t)isr1);
    idt_set(2,  (uint32_t)isr2);  idt_set(3,  (uint32_t)isr3);
    idt_set(4,  (uint32_t)isr4);  idt_set(5,  (uint32_t)isr5);
    idt_set(6,  (uint32_t)isr6);  idt_set(7,  (uint32_t)isr7);
    idt_set(8,  (uint32_t)isr8);  idt_set(9,  (uint32_t)isr9);
    idt_set(10, (uint32_t)isr10); idt_set(11, (uint32_t)isr11);
    idt_set(12, (uint32_t)isr12); idt_set(13, (uint32_t)isr13);
    idt_set(14, (uint32_t)isr14); idt_set(15, (uint32_t)isr15);
    idt_set(16, (uint32_t)isr16); idt_set(17, (uint32_t)isr17);
    idt_set(18, (uint32_t)isr18); idt_set(19, (uint32_t)isr19);
    idt_set(20, (uint32_t)isr20); idt_set(21, (uint32_t)isr21);
    idt_set(22, (uint32_t)isr22); idt_set(23, (uint32_t)isr23);
    idt_set(24, (uint32_t)isr24); idt_set(25, (uint32_t)isr25);
    idt_set(26, (uint32_t)isr26); idt_set(27, (uint32_t)isr27);
    idt_set(28, (uint32_t)isr28); idt_set(29, (uint32_t)isr29);
    idt_set(30, (uint32_t)isr30); idt_set(31, (uint32_t)isr31);

    idt_set(32, (uint32_t)irq0);  idt_set(33, (uint32_t)irq1);
    idt_set(34, (uint32_t)irq2);  idt_set(35, (uint32_t)irq3);
    idt_set(36, (uint32_t)irq4);  idt_set(37, (uint32_t)irq5);
    idt_set(38, (uint32_t)irq6);  idt_set(39, (uint32_t)irq7);
    idt_set(40, (uint32_t)irq8);  idt_set(41, (uint32_t)irq9);
    idt_set(42, (uint32_t)irq10); idt_set(43, (uint32_t)irq11);
    idt_set(44, (uint32_t)irq12); idt_set(45, (uint32_t)irq13);
    idt_set(46, (uint32_t)irq14); idt_set(47, (uint32_t)irq15);

    idt_flush((uint32_t)&idt_ptr);
}

static const char *exception_names[] = {
    "Divide by Zero",       "Debug",                "NMI",
    "Breakpoint",           "Overflow",             "Bound Range",
    "Invalid Opcode",       "Device Not Available",  "Double Fault",
    "Coprocessor Overrun",  "Invalid TSS",          "Segment Not Present",
    "Stack Fault",          "General Protection",   "Page Fault",
    "Reserved",             "x87 FP Exception",     "Alignment Check",
    "Machine Check",        "SIMD FP Exception",    "Virtualisation",
    "Reserved", "Reserved", "Reserved", "Reserved",
    "Reserved", "Reserved", "Reserved", "Reserved",
    "Reserved",             "Security Exception",   "Reserved",
};

void isr_handler(regs_t *r) {
    serial_puts("[EXCEPTION] ");
    if (r->int_no < 32) serial_puts(exception_names[r->int_no]);
    serial_puts(" (int=");
    serial_hex(r->int_no);
    serial_puts(", err=");
    serial_hex(r->err_code);
    serial_puts(", eip=");
    serial_hex(r->eip);
    serial_puts(")\n");
    __asm__ volatile ("cli; hlt");
}

void irq_handler(regs_t *r) {
    int irq = (int)r->int_no - 32;
    if (irq >= 0 && irq < 16 && irq_handlers[irq])
        irq_handlers[irq](r);
    if (r->int_no >= 40) outb(0xA0, 0x20); /* slave EOI  */
    outb(0x20, 0x20);                       /* master EOI */
}
