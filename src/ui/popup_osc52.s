# OSC 52 Clipboard helper (split from popup_menu.s)
.intel_syntax noprefix
.include "pal.inc"

.section .rodata
b64_table:
    .ascii "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
osc52_pfx:
    .ascii "\x1b]52;c;"
.equ OSC52_PFX_LEN, 7

.section .text
.global osc52_copy_text

.extern mem_alloc
.extern mem_free
.extern str_len
.extern sys_write_all

# void osc52_copy_text(const char *str)
osc52_copy_text:
    push rbx; push r12; push r13; push r14
    mov rbx, rdi
    test rbx, rbx; jz .Losc_done
    call str_len
    mov r12, rax
    lea rdi, [rax * 2 + 64]
    call mem_alloc
    mov r13, rax
    xor r14d, r14d
    lea rsi, [rip + osc52_pfx]
    mov ecx, OSC52_PFX_LEN
.Losc_pfx:
    mov al, [rsi]
    mov [r13 + r14], al
    inc rsi; inc r14
    dec ecx; jnz .Losc_pfx

    lea r8, [rip + b64_table]
    xor ecx, ecx
.Losc_b64:
    cmp rcx, r12; jae .Losc_end
    movzx eax, byte ptr [rbx + rcx]
    shl eax, 16
    mov r9d, 1
    lea rdx, [rcx + 1]
    cmp rdx, r12; jae .Losc_emit
    movzx edx, byte ptr [rbx + rdx]
    shl edx, 8
    or eax, edx
    inc r9d
    lea rdx, [rcx + 2]
    cmp rdx, r12; jae .Losc_emit
    movzx edx, byte ptr [rbx + rdx]
    or eax, edx
    inc r9d
.Losc_emit:
    mov edx, eax; shr edx, 18; and edx, 0x3F
    mov dl, [r8 + rdx]; mov [r13 + r14], dl; inc r14
    mov edx, eax; shr edx, 12; and edx, 0x3F
    mov dl, [r8 + rdx]; mov [r13 + r14], dl; inc r14
    cmp r9d, 2; jb .Losc_eq1
    mov edx, eax; shr edx, 6; and edx, 0x3F
    mov dl, [r8 + rdx]; mov [r13 + r14], dl; inc r14
    jmp .Losc_c3
.Losc_eq1:
    mov byte ptr [r13 + r14], '='; inc r14
.Losc_c3:
    cmp r9d, 3; jb .Losc_eq2
    mov edx, eax; and edx, 0x3F
    mov dl, [r8 + rdx]; mov [r13 + r14], dl; inc r14
    jmp .Losc_next3
.Losc_eq2:
    mov byte ptr [r13 + r14], '='; inc r14
.Losc_next3:
    add rcx, 3
    jmp .Losc_b64

.Losc_end:
    mov byte ptr [r13 + r14], 7
    inc r14
    mov edi, 1
    mov rsi, r13
    mov rdx, r14
    call sys_write_all
    mov rdi, r13
    call mem_free
.Losc_done:
    pop r14; pop r13; pop r12; pop rbx; ret
