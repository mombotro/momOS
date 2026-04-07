BITS 32

; ── Multiboot1 header ────────────────────────────────────────────────────────
; Bit 1 = give us a memory map
; Bit 2 = give us a video mode (framebuffer)
SECTION .multiboot
ALIGN 4
    dd 0x1BADB002                   ; magic
    dd 0x00000006                   ; flags: bits 1+2
    dd -(0x1BADB002 + 0x00000006)   ; checksum

    ; Bits 1+2 require these 8 padding fields before the video fields
    dd 0    ; header_addr   (unused, bit 16 not set)
    dd 0    ; load_addr
    dd 0    ; load_end_addr
    dd 0    ; bss_end_addr
    dd 0    ; entry_addr

    ; Video mode request (bit 2)
    dd 0    ; mode_type: 0 = linear RGB framebuffer
    dd 640  ; width
    dd 480  ; height
    dd 32   ; depth (bits per pixel)

; ── Stack ────────────────────────────────────────────────────────────────────
SECTION .bss
ALIGN 16
stack_bottom:
    resb 16384
stack_top:

; ── Entry point ──────────────────────────────────────────────────────────────
SECTION .text
GLOBAL _start
EXTERN kernel_main

_start:
    mov  esp, stack_top
    push ebx            ; multiboot info pointer
    push eax            ; multiboot magic
    call kernel_main
.hang:
    cli
    hlt
    jmp .hang
