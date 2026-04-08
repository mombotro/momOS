BITS 32
; setjmp / longjmp for i686 kernel
; jmp_buf layout: [ebx, esi, edi, ebp, esp, eip]  (6 × 4 = 24 bytes)

GLOBAL setjmp
GLOBAL longjmp

; int setjmp(jmp_buf env)
setjmp:
    mov  edx, [esp+4]     ; edx = env
    mov  [edx+0],  ebx
    mov  [edx+4],  esi
    mov  [edx+8],  edi
    mov  [edx+12], ebp
    lea  ecx, [esp+8]     ; esp value as seen by caller (after ret + pop arg)
    mov  [edx+16], ecx
    mov  ecx, [esp]       ; return address
    mov  [edx+20], ecx
    xor  eax, eax
    ret

; void longjmp(jmp_buf env, int val)   — noreturn
longjmp:
    mov  edx, [esp+4]     ; edx = env
    mov  eax, [esp+8]     ; eax = val
    test eax, eax
    jnz  .ok
    inc  eax              ; val must not be 0 (setjmp would return 0)
.ok:
    mov  ebx, [edx+0]
    mov  esi, [edx+4]
    mov  edi, [edx+8]
    mov  ebp, [edx+12]
    mov  esp, [edx+16]
    jmp  dword [edx+20]
