# Terminal image output: Kitty-mode detection, base64 for the Kitty protocol and the TrueColor
# half-block (▀) renderer for any decoded RGBA picture (alpha blended over the theme surface).

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"
.extern env_getenv
.extern str_casecmp
.extern str_contains_ci
.extern str_copy
.extern u64_to_dec
.extern sys_write_all
.extern mem_alloc
.extern mem_free
.extern ScreenBuffer_set_pen
.extern ScreenBuffer_set_cell

.section .rodata

b64_table:      .ascii "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
env_img_mode:   .asciz "DUOP_IMG_MODE"
val_halfblock:  .asciz "halfblock"
env_kitty_id:   .asciz "KITTY_WINDOW_ID"
env_term:       .asciz "TERM"
val_kitty:      .asciz "kitty"
seq_kitty_end:  .asciz "\x1b\\"

.section .text
.global img_is_kitty_mode
.global b64_encode
.global img_draw_rgba

# int img_is_kitty_mode(PreviewPane *pv)
img_is_kitty_mode:
    push rbx
    mov rax, [rdi + PreviewPane.app]
    mov rbx, [rax + App.envp]
    mov rdi, rbx
    lea rsi, [rip + env_img_mode]
    call env_getenv
    test rax, rax
    jz .Likm_chk_env
    mov rdi, rax
    lea rsi, [rip + val_halfblock]
    call str_casecmp
    test eax, eax
    jz .Likm_no
.Likm_chk_env:
    mov rdi, rbx
    lea rsi, [rip + env_kitty_id]
    call env_getenv
    test rax, rax
    jnz .Likm_yes
    mov rdi, rbx
    lea rsi, [rip + env_term]
    call env_getenv
    test rax, rax
    jz .Likm_no
    mov rdi, rax
    lea rsi, [rip + val_kitty]
    call str_contains_ci
    test eax, eax
    jnz .Likm_yes
.Likm_no:
    xor eax, eax
    pop rbx
    ret
.Likm_yes:
    mov eax, 1
    pop rbx
    ret


# void b64_encode(const uint8_t *src, size_t len, char *dst, size_t *out_len)
b64_encode:
    push rbx
    push r12
    lea r8, [rip + b64_table]
    mov r9, rdx               # dst start
    xor r10d, r10d            # i = 0
.Lb64_loop:
    cmp r10, rsi
    jae .Lb64_done
    movzx eax, byte ptr [rdi + r10]
    shl eax, 16
    mov r11d, 1
    lea r12, [r10 + 1]
    cmp r12, rsi
    jae .Lb64_b2
    movzx ebx, byte ptr [rdi + r12]
    shl ebx, 8
    or eax, ebx
    inc r11d
.Lb64_b2:
    lea r12, [r10 + 2]
    cmp r12, rsi
    jae .Lb64_emit
    movzx ebx, byte ptr [rdi + r12]
    or eax, ebx
    inc r11d
.Lb64_emit:
    mov ebx, eax
    shr ebx, 18
    and ebx, 63
    mov bl, [r8 + rbx]
    mov [rdx], bl
    mov ebx, eax
    shr ebx, 12
    and ebx, 63
    mov bl, [r8 + rbx]
    mov [rdx + 1], bl
    mov bl, '='
    cmp r11d, 2
    jl .Lb64_p3
    mov ebx, eax
    shr ebx, 6
    and ebx, 63
    mov bl, [r8 + rbx]
.Lb64_p3:
    mov [rdx + 2], bl
    mov bl, '='
    cmp r11d, 3
    jl .Lb64_p4
    mov ebx, eax
    and ebx, 63
    mov bl, [r8 + rbx]
.Lb64_p4:
    mov [rdx + 3], bl
    add rdx, 4
    add r10, 3
    jmp .Lb64_loop
.Lb64_done:
    mov byte ptr [rdx], 0
    sub rdx, r9
    mov [rcx], rdx
    pop r12
    pop rbx
    ret


# void img_draw_rgba(ScreenBuffer *scr, int bx, int by, int bw, int bh, const ImgView *v)
# ImgView = { const uint8_t *rgba; int iw; int ih; uint32_t bg (0x01RRGGBB) }
# Fits the picture into bw x (2*bh) half-block pixels (nearest sampling), centred in the box.
img_draw_rgba:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48                       # [0]=dw [4]=dh [8]=x0 [12]=y0 [16]=rows [20]=cy [24]=cx
    mov rbx, rdi
    mov r12, r9                       # view
    mov [rsp + 32], esi
    mov [rsp + 36], edx
    mov [rsp + 40], ecx
    mov [rsp + 44], r8d
    mov edi, [r12 + 8]
    mov esi, [r12 + 12]
    mov edx, ecx
    lea ecx, [r8d * 2]
    call img_fit                      # eax = dw, edx = dh (pixels)
    mov [rsp], eax
    mov [rsp + 4], edx
    inc edx
    shr edx, 1
    mov [rsp + 16], edx               # cell rows = ceil(dh / 2)
    mov ecx, [rsp + 40]               # x0 = bx + (bw - dw) / 2
    sub ecx, eax
    sar ecx, 1
    add ecx, [rsp + 32]
    mov [rsp + 8], ecx
    mov ecx, [rsp + 44]               # y0 = by + (bh - rows) / 2
    sub ecx, edx
    sar ecx, 1
    add ecx, [rsp + 36]
    mov [rsp + 12], ecx
    mov dword ptr [rsp + 20], 0
.Ldr_row:
    mov eax, [rsp + 20]
    cmp eax, [rsp + 16]
    jge .Ldr_done
    mov dword ptr [rsp + 24], 0
.Ldr_col:
    mov eax, [rsp + 24]
    cmp eax, [rsp]
    jge .Ldr_next
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rsp]
    call idr_cell
    inc dword ptr [rsp + 24]
    jmp .Ldr_col
.Ldr_next:
    inc dword ptr [rsp + 20]
    jmp .Ldr_row
.Ldr_done:
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: void idr_cell(ScreenBuffer *scr, const ImgView *v, const int *st /*img_draw_rgba locals*/)
idr_cell:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov eax, [r13 + 20]               # top pixel row = 2 * cy
    shl eax, 1
    mov edi, eax
    call idr_sample
    mov r14d, eax                     # top color
    mov eax, [r13 + 20]
    lea edi, [eax * 2 + 1]
    mov r15d, [r12 + 16]              # bottom: background past the last row
    cmp edi, [r13 + 4]
    jge 1f
    call idr_sample
    mov r15d, eax
1:  mov rdi, rbx
    mov esi, [r13 + 8]
    add esi, [r13 + 24]
    mov edx, [r13 + 12]
    add edx, [r13 + 20]
    mov ecx, 0x2580                   # ▀
    mov r8d, r14d
    mov r9d, r15d
    call ScreenBuffer_set_cell
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: uint32_t idr_sample(int py /*edi*/) with r12 = view, r13 = locals -> 0x01RRGGBB
idr_sample:
    mov eax, edi                      # sy = py * ih / dh
    imul eax, [r12 + 12]
    xor edx, edx
    div dword ptr [r13 + 4]
    mov ecx, eax
    mov eax, [r13 + 24]               # sx = cx * iw / dw
    imul eax, [r12 + 8]
    xor edx, edx
    div dword ptr [r13]
    imul ecx, [r12 + 8]
    add eax, ecx
    mov rcx, [r12]
    mov eax, [rcx + rax * 4]          # R,G,B,A
    mov edx, [r12 + 16]
    jmp img_blend

# uint32_t img_blend(uint32_t rgba /*eax*/, uint32_t bg /*edx, 0x01RRGGBB*/) -> 0x01RRGGBB
img_blend:
    push rbx
    mov r8d, eax
    shr r8d, 24                       # alpha
    xor r11d, r11d
    xor ecx, ecx                      # channel 0 = R
.Lbl_ch:
    movzx r9d, al                     # source channel
    mov r10d, edx                     # background channel: R at bits 16..23
    push rcx
    neg ecx
    lea ecx, [ecx * 8 + 16]
    shr r10d, cl
    pop rcx
    and r10d, 0xFF
    imul r9d, r8d
    mov ebx, 255
    sub ebx, r8d
    imul r10d, ebx
    add r9d, r10d
    imul r9d, r9d, 257                # / 255 (rounded): (x * 257 + 257) >> 16
    add r9d, 257
    shr r9d, 16
    shl r11d, 8
    or r11d, r9d
    shr eax, 8
    inc ecx
    cmp ecx, 3
    jl .Lbl_ch
    test r11d, r11d                   # pure black would read as "default color"
    jnz 2f
    mov r11d, 0x010101
2:  or r11d, 0x01000000
    mov eax, r11d
    pop rbx
    ret
