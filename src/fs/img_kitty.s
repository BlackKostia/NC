# Kitty graphics protocol encoder: RGBA8 picture -> "ESC _ G a=T,f=32,..." transmission split into
# base64 chunks of at most 4096 bytes (m=1 ... m=0), cursor not moved (C=1).

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .rodata
b64_alphabet: .ascii "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
str_k_first:  .asciz "\x1b_Ga=T,f=32,i=7,q=2,C=1,s="
str_k_tx:     .asciz "\x1b_Ga=t,f=32,i=7,q=2,s="
str_k_place:  .asciz "\x1b_Ga=p,i=7,p=1,q=2,C=1,x="
str_k_v:      .asciz ",v="
str_k_y:      .asciz ",y="
str_k_w:      .asciz ",w="
str_k_h:      .asciz ",h="
str_k_c:      .asciz ",c="
str_k_r:      .asciz ",r="
str_k_m:      .asciz ",m="
str_k_next:   .asciz "\x1b_Gm="
.equ KITTY_RAW_CHUNK, 3072                # -> 4096 base64 bytes

.section .text
.global img_kitty_encode
.global img_kitty_place
.global img_b64_encode

# size_t img_kitty_encode(const uint8_t *rgba, int w, int h, int cols /*0 = native size*/,
#                         uint8_t *out, size_t cap) -> bytes written, 0 if cap is too small
img_kitty_encode:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    mov rbx, rdi                      # source cursor
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    mov r12, r8                       # out cursor
    mov [rsp + 24], r8                # out start
    lea rax, [r8 + r9]
    mov [rsp + 16], rax               # out end
    mov r13d, esi
    imul r13d, edx
    shl r13, 2                        # bytes left
    mov r14d, 1                       # first chunk
.Lke_chunk:
    mov rax, [rsp + 16]
    sub rax, r12
    cmp rax, 4096 + 128
    jb .Lke_fail
    mov r15d, KITTY_RAW_CHUNK
    cmp r13, r15
    jae 1f
    mov r15d, r13d
1:  mov rdi, r12
    mov rsi, rsp
    mov edx, r14d
    xor ecx, ecx
    cmp r13, r15
    seta cl                           # more chunks follow
    call ke_header
    mov r12, rax
    mov rdi, rbx
    mov rsi, r15
    mov rdx, r12
    call img_b64_encode
    add r12, rax
    mov word ptr [r12], 0x5C1B        # ESC backslash
    add r12, 2
    add rbx, r15
    sub r13, r15
    xor r14d, r14d
    test r13, r13
    jnz .Lke_chunk
    mov rax, r12
    sub rax, [rsp + 24]
    jmp .Lke_ret
.Lke_fail:
    xor eax, eax
.Lke_ret:
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: uint8_t *ke_header(uint8_t *p, const int *dims /*w, h, cols*/, int first, int more)
ke_header:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13d, ecx
    test edx, edx
    jz .Lkh_next
    lea rsi, [rip + str_k_first]
    cmp dword ptr [r12 + 8], 0
    jge 0f
    lea rsi, [rip + str_k_tx]
0:  call kh_str
    mov edi, [r12]
    call kh_num
    lea rsi, [rip + str_k_v]
    call kh_str
    mov edi, [r12 + 4]
    call kh_num
    cmp dword ptr [r12 + 8], 0
    jle 1f
    lea rsi, [rip + str_k_c]
    call kh_str
    mov edi, [r12 + 8]
    call kh_num
1:  lea rsi, [rip + str_k_m]
    call kh_str
    jmp .Lkh_more
.Lkh_next:
    lea rsi, [rip + str_k_next]
    call kh_str
.Lkh_more:
    lea eax, [r13d + '0']
    mov [rbx], al
    mov byte ptr [rbx + 1], ';'
    lea rax, [rbx + 2]
    pop r13
    pop r12
    pop rbx
    ret

# Internal: append C string rsi at rbx (advances rbx)
kh_str:
    movzx eax, byte ptr [rsi]
    test eax, eax
    jz 1f
    mov [rbx], al
    inc rbx
    inc rsi
    jmp kh_str
1:  ret

# Internal: append decimal edi at rbx (advances rbx)
kh_num:
    sub rsp, 8
    mov rsi, rbx
    call u64_to_dec
    add rbx, rax
    add rsp, 8
    ret

# size_t img_kitty_place(uint8_t *out, const int *rect /*x,y,w,h*/, int cols, int rows) -> bytes
img_kitty_place:
    push rbx; push r12; push r13; push r14; push r15
    mov r15, rdi; mov rbx, rdi; mov r12, rsi; mov r13d, edx; mov r14d, ecx
    lea rsi, [rip + str_k_place]; call kh_str
    mov edi, [r12]; call kh_num
    lea rsi, [rip + str_k_y]; call kh_str
    mov edi, [r12 + 4]; call kh_num
    lea rsi, [rip + str_k_w]; call kh_str
    mov edi, [r12 + 8]; call kh_num
    lea rsi, [rip + str_k_h]; call kh_str
    mov edi, [r12 + 12]; call kh_num
    lea rsi, [rip + str_k_c]; call kh_str
    mov edi, r13d; call kh_num
    lea rsi, [rip + str_k_r]; call kh_str
    mov edi, r14d; call kh_num
    mov word ptr [rbx], 0x5C1B
    add rbx, 2
    mov rax, rbx
    sub rax, r15
    pop r15; pop r14; pop r13; pop r12; pop rbx
    ret

# size_t img_b64_encode(const uint8_t *src, size_t len, char *dst) -> bytes written (with padding)
img_b64_encode:
    push rbx
    lea r8, [rip + b64_alphabet]
    mov r9, rdx
    xor r10d, r10d
.Lb64_loop:
    cmp r10, rsi
    jae .Lb64_done
    movzx eax, byte ptr [rdi + r10]
    shl eax, 16
    mov r11d, 1
    lea rcx, [r10 + 1]
    cmp rcx, rsi
    jae 1f
    movzx ebx, byte ptr [rdi + rcx]
    shl ebx, 8
    or eax, ebx
    inc r11d
    lea rcx, [r10 + 2]
    cmp rcx, rsi
    jae 1f
    movzx ebx, byte ptr [rdi + rcx]
    or eax, ebx
    inc r11d
1:  mov ecx, 18
.Lb64_out:
    mov ebx, eax
    shr ebx, cl
    and ebx, 63
    movzx ebx, byte ptr [r8 + rbx]
    mov [rdx], bl
    inc rdx
    sub ecx, 6
    jns .Lb64_out
    cmp r11d, 3                       # pad 1 or 2 trailing symbols
    je 2f
    mov byte ptr [rdx - 1], '='
    cmp r11d, 2
    je 2f
    mov byte ptr [rdx - 2], '='
2:  add r10, 3
    jmp .Lb64_loop
.Lb64_done:
    mov rax, rdx
    sub rax, r9
    pop rbx
    ret
