BITS 32

; ── gdt_flush(gdt_ptr*) ───────────────────────────────────────────────────────
; Loads the GDT and reloads all segment registers.
; CS is reloaded via a far jump (only way to change it in protected mode).
GLOBAL gdt_flush
gdt_flush:
    mov  eax, [esp+4]
    lgdt [eax]
    mov  ax, 0x10       ; kernel data segment (GDT index 2, RPL 0)
    mov  ds, ax
    mov  es, ax
    mov  fs, ax
    mov  gs, ax
    mov  ss, ax
    jmp  0x08:.reload_cs ; far jump → reloads CS with kernel code segment
.reload_cs:
    ret

; ── idt_flush(idt_ptr*) ───────────────────────────────────────────────────────
GLOBAL idt_flush
idt_flush:
    mov  eax, [esp+4]
    lidt [eax]
    ret
