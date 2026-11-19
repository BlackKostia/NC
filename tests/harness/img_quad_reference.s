# Frozen reference oracle: the hand-written asm that src/ui/img_quad.c replaced (tests/test_c_img_cells.py diffs against it)
# Quadrant-block image output: every cell shows 2x2 picture pixels with the best two-color split
# (one of the 7 quadrant patterns or a uniform cell), doubling the horizontal detail of half
# blocks without any terminal graphics support. Pixels are alpha blended over the background.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .rodata
.align 4
# glyph for pixel mask (bit0 TL, bit1 TR, bit2 BL, bit3 BR set = foreground), masks 1..7
quad_glyph: .long 0x2580, 0x2598, 0x259D, 0x2580, 0x2596, 0x258C, 0x259E, 0x259B

.section .text
.global img_draw_quad

# void img_draw_quad(ScreenBuffer *scr, int bx, int by, int bw, int bh, const ImgView *v)
# ImgView = { const uint8_t *rgba; int iw; int ih; uint32_t bg (0x01RRGGBB) }
img_draw_quad:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 64                       # [0]=dw [4]=dh [8]=x0 [12]=y0 [16]=cols [20]=rows [24]=cy [28]=cx
    mov rbx, rdi
    mov r12, r9
    mov [rsp + 32], esi
    mov [rsp + 36], edx
    mov [rsp + 40], ecx
    mov [rsp + 44], r8d
    mov edi, [r12 + 8]
    mov esi, [r12 + 12]
    lea edx, [ecx * 2]
    lea ecx, [r8d * 2]
    call img_fit                      # picture size in quadrant pixels
    mov [rsp], eax
    mov [rsp + 4], edx
    inc eax
    shr eax, 1
    mov [rsp + 16], eax               # cols = ceil(dw / 2)
    inc edx
    shr edx, 1
    mov [rsp + 20], edx               # rows = ceil(dh / 2)
    mov ecx, [rsp + 40]
    sub ecx, eax
    sar ecx, 1
    add ecx, [rsp + 32]
    mov [rsp + 8], ecx
    mov ecx, [rsp + 44]
    sub ecx, edx
    sar ecx, 1
    add ecx, [rsp + 36]
    mov [rsp + 12], ecx
    mov dword ptr [rsp + 24], 0
.Lqd_row:
    mov eax, [rsp + 24]
    cmp eax, [rsp + 20]
    jge .Lqd_done
    mov dword ptr [rsp + 28], 0
.Lqd_col:
    mov eax, [rsp + 28]
    cmp eax, [rsp + 16]
    jge .Lqd_next
    mov rdi, rbx
    mov rsi, r12
    mov rdx, rsp
    call qd_cell
    inc dword ptr [rsp + 28]
    jmp .Lqd_col
.Lqd_next:
    inc dword ptr [rsp + 24]
    jmp .Lqd_row
.Lqd_done:
    add rsp, 64
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: void qd_cell(ScreenBuffer *scr, const ImgView *v, const int *st)
qd_cell:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32                       # [0..15] = 4 pixels 0x00RRGGBB (TL, TR, BL, BR)
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    xor r14d, r14d
.Lqc_px:
    mov eax, r14d                     # px = 2 * cx + (k & 1), py = 2 * cy + (k >> 1)
    and eax, 1
    mov edi, [r13 + 28]
    lea edi, [edi * 2 + eax]
    mov eax, r14d
    shr eax, 1
    mov esi, [r13 + 24]
    lea esi, [esi * 2 + eax]
    call qd_sample
    mov [rsp + r14 * 4], eax
    inc r14d
    cmp r14d, 4
    jl .Lqc_px
    mov rdi, rsp
    call qd_best_split                # eax = mask, edx = fg, ecx = bg (0x00RRGGBB)
    lea r8, [rip + quad_glyph]
    mov r15d, [r8 + rax * 4]
    mov r8d, edx
    mov r9d, ecx
    call qd_color
    mov r14d, eax
    mov r8d, r9d
    call qd_color
    mov r9d, eax
    mov r8d, r14d
    mov rdi, rbx
    mov esi, [r13 + 8]
    add esi, [r13 + 28]
    mov edx, [r13 + 12]
    add edx, [r13 + 24]
    mov ecx, r15d
    call ScreenBuffer_set_cell
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: eax = 0x01RRGGBB for 0x00RRGGBB in r8d (pure black would read as "default color")
qd_color:
    mov eax, r8d
    test eax, eax
    jnz 1f
    mov eax, 0x010101
1:  or eax, 0x01000000
    ret

# Internal: uint32_t qd_sample(int px, int py) with r12 = view, r13 = state -> 0x00RRGGBB
qd_sample:
    mov eax, [r12 + 16]               # outside the picture: background
    and eax, 0xFFFFFF
    cmp edi, [r13]
    jge .Lqs_ret
    cmp esi, [r13 + 4]
    jge .Lqs_ret
    mov eax, esi                      # sy = py * ih / dh
    imul eax, [r12 + 12]
    xor edx, edx
    div dword ptr [r13 + 4]
    mov ecx, eax
    mov eax, edi                      # sx = px * iw / dw
    imul eax, [r12 + 8]
    xor edx, edx
    div dword ptr [r13]
    imul ecx, [r12 + 8]
    add eax, ecx
    mov rcx, [r12]
    mov eax, [rcx + rax * 4]          # R,G,B,A
    mov edx, [r12 + 16]
    call img_blend                    # -> 0x01RRGGBB
    and eax, 0xFFFFFF
.Lqs_ret:
    ret

# Internal: (mask, fg, bg) qd_best_split(const uint32_t px[4]) -- least squared error two-color split
qd_best_split:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16
    mov rbx, rdi
    xor r12d, r12d                    # best mask (0 = uniform)
    mov r13d, -1                      # best error
    xor r14d, r14d                    # mask under test
.Lbs_mask:
    cmp r14d, 7
    jg .Lbs_done
    mov rdi, rbx
    mov esi, r14d
    call qd_split_error               # eax = error, edx = fg mean, ecx = bg mean
    cmp eax, r13d
    jae 1f
    mov r13d, eax
    mov r12d, r14d
    mov [rsp], edx
    mov [rsp + 4], ecx
1:  inc r14d
    jmp .Lbs_mask
.Lbs_done:
    mov eax, r12d
    mov edx, [rsp]
    mov ecx, [rsp + 4]
    test eax, eax
    jnz 2f
    mov ecx, edx                      # uniform: fg = bg (drawn as ▀)
2:  add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: (err, fg, bg) qd_split_error(const uint32_t px[4], int mask) -- mask 0 = one group
qd_split_error:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    mov r12d, esi
    mov rdi, rbx
    mov esi, r12d
    mov edx, 1
    call qd_group_mean                # fg = mean of pixels in mask (mask 0: all)
    mov r13d, eax
    mov rdi, rbx
    mov esi, r12d
    xor edx, edx
    call qd_group_mean                # bg = mean of the others
    mov r14d, eax
    test r12d, r12d
    jnz 1f
    mov r14d, r13d
1:  xor r15d, r15d                    # error
    xor ecx, ecx
.Lse_px:
    mov eax, r14d
    bt r12d, ecx
    jnc 2f
    mov eax, r13d
2:  test r12d, r12d
    jnz 3f
    mov eax, r13d
3:  mov edx, [rbx + rcx * 4]
    call qd_dist
    add r15d, eax
    inc ecx
    cmp ecx, 4
    jl .Lse_px
    mov eax, r15d
    mov edx, r13d
    mov ecx, r14d
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: uint32_t qd_group_mean(const uint32_t px[4], int mask, int inside) -> 0x00RRGGBB
# mask 0 with inside = 1 means every pixel.
qd_group_mean:
    push rbx
    push r12
    xor r8d, r8d                      # R sum
    xor r9d, r9d                      # G sum
    xor r10d, r10d                    # B sum
    xor r11d, r11d                    # count
    xor ecx, ecx
.Lgm_px:
    test esi, esi
    jz 1f                             # mask 0: all pixels belong
    bt esi, ecx
    setc al
    movzx eax, al
    cmp eax, edx
    jne 2f
1:  mov eax, [rdi + rcx * 4]
    movzx ebx, al
    add r10d, ebx
    movzx ebx, ah
    add r9d, ebx
    shr eax, 16
    and eax, 0xFF
    add r8d, eax
    inc r11d
2:  inc ecx
    cmp ecx, 4
    jl .Lgm_px
    xor eax, eax
    test r11d, r11d
    jz .Lgm_ret
    mov r12d, edx
    mov eax, r8d
    xor edx, edx
    div r11d
    mov ebx, eax
    shl ebx, 16
    mov eax, r9d
    xor edx, edx
    div r11d
    shl eax, 8
    or ebx, eax
    mov eax, r10d
    xor edx, edx
    div r11d
    or eax, ebx
    mov edx, r12d
.Lgm_ret:
    pop r12
    pop rbx
    ret

# Internal: int qd_dist(uint32_t a /*eax*/, uint32_t b /*edx*/) -> squared RGB distance (keeps ecx)
qd_dist:
    push rbx
    push rcx
    xor r8d, r8d
    mov ecx, 16
.Ld_ch:
    mov ebx, eax
    shr ebx, cl
    and ebx, 0xFF
    mov r9d, edx
    shr r9d, cl
    and r9d, 0xFF
    sub ebx, r9d
    imul ebx, ebx
    add r8d, ebx
    sub ecx, 8
    jns .Ld_ch
    mov eax, r8d
    pop rcx
    pop rbx
    ret
