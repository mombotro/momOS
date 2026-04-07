BITS 32

EXTERN isr_handler
EXTERN irq_handler

; ── Macros ────────────────────────────────────────────────────────────────────
; Exceptions without an error code: push dummy 0 so the stack layout is uniform
%macro ISR_NOERR 1
GLOBAL isr%1
isr%1:
    push dword 0
    push dword %1
    jmp isr_common
%endmacro

; Exceptions that push an error code: CPU already pushed it, just push int number
%macro ISR_ERR 1
GLOBAL isr%1
isr%1:
    push dword %1
    jmp isr_common
%endmacro

; IRQs: always push dummy 0 + remapped vector number
%macro IRQ 2
GLOBAL irq%1
irq%1:
    push dword 0
    push dword %2
    jmp irq_common
%endmacro

; ── Exception stubs (0–31) ────────────────────────────────────────────────────
; Exceptions 8, 10, 11, 12, 13, 14, 17 push an error code
ISR_NOERR 0
ISR_NOERR 1
ISR_NOERR 2
ISR_NOERR 3
ISR_NOERR 4
ISR_NOERR 5
ISR_NOERR 6
ISR_NOERR 7
ISR_ERR   8
ISR_NOERR 9
ISR_ERR   10
ISR_ERR   11
ISR_ERR   12
ISR_ERR   13
ISR_ERR   14
ISR_NOERR 15
ISR_NOERR 16
ISR_ERR   17
ISR_NOERR 18
ISR_NOERR 19
ISR_NOERR 20
ISR_NOERR 21
ISR_NOERR 22
ISR_NOERR 23
ISR_NOERR 24
ISR_NOERR 25
ISR_NOERR 26
ISR_NOERR 27
ISR_NOERR 28
ISR_NOERR 29
ISR_NOERR 30
ISR_NOERR 31

; ── IRQ stubs (0–15 → vectors 32–47) ─────────────────────────────────────────
IRQ  0, 32
IRQ  1, 33
IRQ  2, 34
IRQ  3, 35
IRQ  4, 36
IRQ  5, 37
IRQ  6, 38
IRQ  7, 39
IRQ  8, 40
IRQ  9, 41
IRQ 10, 42
IRQ 11, 43
IRQ 12, 44
IRQ 13, 45
IRQ 14, 46
IRQ 15, 47

; ── Common exception path ─────────────────────────────────────────────────────
; Stack at entry: [eflags, cs, eip, err_code, int_no]  (top → bottom)
isr_common:
    pusha                   ; save eax,ecx,edx,ebx,esp,ebp,esi,edi
    mov  ax, ds
    push eax                ; save ds (zero-extended to 32 bits)
    mov  ax, 0x10           ; kernel data segment
    mov  ds, ax
    mov  es, ax
    mov  fs, ax
    mov  gs, ax
    push esp                ; pass pointer to regs_t to C handler
    call isr_handler
    add  esp, 4             ; pop pointer
    pop  eax                ; restore ds
    mov  ds, ax
    mov  es, ax
    mov  fs, ax
    mov  gs, ax
    popa
    add  esp, 8             ; discard int_no + err_code
    iret

; ── Common IRQ path ───────────────────────────────────────────────────────────
irq_common:
    pusha
    mov  ax, ds
    push eax
    mov  ax, 0x10
    mov  ds, ax
    mov  es, ax
    mov  fs, ax
    mov  gs, ax
    push esp
    call irq_handler
    add  esp, 4
    pop  eax
    mov  ds, ax
    mov  es, ax
    mov  fs, ax
    mov  gs, ax
    popa
    add  esp, 8
    iret
