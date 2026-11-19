# Frozen reference oracle: the hand-written asm that src/ui/img_braille.c replaced (tests/test_c_img_cells.py diffs against it)
# 2x4 Braille high-detail image output (U+2800..U+28FF): 8 subpixels per cell with adaptive
# local luminance thresholding and two TrueColor colors (ink fg + background bg) per cell.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .rodata
br_dx: .byte 0, 0, 0, 1, 1, 1, 0, 1
br_dy: .byte 0, 1, 2, 0, 1, 2, 3, 3

.section .text
.global img_draw_braille

# void img_draw_braille(ScreenBuffer *scr, int bx, int by, int bw, int bh, const ImgView *v)
img_draw_braille:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, 64                       # [0]=dw [4]=dh [8]=x0 [12]=y0 [16]=cols [20]=rows [24]=cy [28]=cx
    mov rbx, rdi; mov r12, r9
    mov [rsp + 32], esi; mov [rsp + 36], edx
    mov [rsp + 40], ecx; mov [rsp + 44], r8d
    mov edi, [r12 + 8]; mov esi, [r12 + 12]
    lea edx, [ecx * 2]; lea ecx, [r8d * 4]
    call img_fit
    mov [rsp], eax; mov [rsp + 4], edx
    inc eax; shr eax, 1; mov [rsp + 16], eax
    add edx, 3; shr edx, 2; mov [rsp + 20], edx
    mov ecx, [rsp + 40]; sub ecx, eax; sar ecx, 1; add ecx, [rsp + 32]; mov [rsp + 8], ecx
    mov ecx, [rsp + 44]; sub ecx, edx; sar ecx, 1; add ecx, [rsp + 36]; mov [rsp + 12], ecx
    mov dword ptr [rsp + 24], 0
.Ldb_row:
    mov eax, [rsp + 24]; cmp eax, [rsp + 20]; jge .Ldb_done
    mov dword ptr [rsp + 28], 0
.Ldb_col:
    mov eax, [rsp + 28]; cmp eax, [rsp + 16]; jge .Ldb_next
    mov rdi, rbx; mov rsi, r12; mov rdx, rsp
    call br_cell
    inc dword ptr [rsp + 28]; jmp .Ldb_col
.Ldb_next:
    inc dword ptr [rsp + 24]; jmp .Ldb_row
.Ldb_done:
    add rsp, 64
    pop r15; pop r14; pop r13; pop r12; pop rbx
    ret

# Internal: void br_cell(ScreenBuffer *scr, const ImgView *v, const int *st)
br_cell:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, 48                       # [0..31]=px[8], [32..39]=lum[8]
    mov rbx, rdi; mov r12, rsi; mov r13, rdx
    xor r14d, r14d
.Lbc_smp:
    lea r8, [rip + br_dx]; movzx edi, byte ptr [r8 + r14]
    mov eax, [r13 + 28]; lea edi, [eax * 2 + edi]
    lea r8, [rip + br_dy]; movzx esi, byte ptr [r8 + r14]
    mov eax, [r13 + 24]; lea esi, [eax * 4 + esi]
    call br_sample
    mov [rsp + r14 * 4], eax
    mov r8d, eax; shr r8d, 16; and r8d, 0xFF; imul r8d, 77
    mov r9d, eax; shr r9d, 8;  and r9d, 0xFF; imul r9d, 150
    and eax, 0xFF; imul eax, 29
    add eax, r8d; add eax, r9d; shr eax, 8
    mov [rsp + 32 + r14], al
    inc r14d; cmp r14d, 8; jl .Lbc_smp
    mov rdi, rsp; lea rsi, [rsp + 32]
    call br_pick_mask                 # eax = mask (0..255)
    mov r15d, eax
    mov rdi, rsp; mov esi, r15d; mov edx, 1; call br_mean_rgb
    mov r14d, eax
    mov rdi, rsp; mov esi, r15d; xor edx, edx; call br_mean_rgb
    test r15d, r15d; jnz 1f
    mov r14d, eax
1:  mov r9d, eax; or r9d, 0x01000000
    test eax, eax; jnz 2f; mov r9d, 0x01010101
2:  mov r8d, r14d; or r8d, 0x01000000
    test r14d, r14d; jnz 3f; mov r8d, 0x01010101
3:  mov rdi, rbx
    mov esi, [r13 + 8]; add esi, [r13 + 28]
    mov edx, [r13 + 12]; add edx, [r13 + 24]
    lea ecx, [r15d + 0x2800]
    call ScreenBuffer_set_cell
    add rsp, 48
    pop r15; pop r14; pop r13; pop r12; pop rbx
    ret

# Internal: uint32_t br_sample(int px, int py) with r12 = view, r13 = st -> 0x00RRGGBB
br_sample:
    mov eax, [r12 + 16]; and eax, 0xFFFFFF
    cmp edi, [r13]; jge .Lbs_ret
    cmp esi, [r13 + 4]; jge .Lbs_ret
    mov eax, esi; imul eax, [r12 + 12]; xor edx, edx; div dword ptr [r13 + 4]
    mov ecx, eax
    mov eax, edi; imul eax, [r12 + 8]; xor edx, edx; div dword ptr [r13]
    imul ecx, [r12 + 8]; add eax, ecx
    mov rcx, [r12]; mov eax, [rcx + rax * 4]
    mov edx, [r12 + 16]
    call img_blend
    and eax, 0xFFFFFF
.Lbs_ret:
    ret

# Internal: int br_pick_mask(const uint32_t px[8], const uint8_t lum[8])
br_pick_mask:
    mov r8d, 255; xor r9d, r9d; xor ecx, ecx
.Lpm_mm:
    movzx eax, byte ptr [rsi + rcx]
    cmp eax, r8d; jge 1f; mov r8d, eax
1:  cmp eax, r9d; jle 2f; mov r9d, eax
2:  inc ecx; cmp ecx, 8; jl .Lpm_mm
    mov eax, r9d; sub eax, r8d
    cmp eax, 16; jge 3f
    xor eax, eax; ret
3:  add r8d, r9d; shr r8d, 1          # mid
    xor eax, eax; xor r10d, r10d; xor ecx, ecx
.Lpm_mk:
    movzx edx, byte ptr [rsi + rcx]
    cmp edx, r8d; jle 4f
    bts eax, ecx; inc r10d
4:  inc ecx; cmp ecx, 8; jl .Lpm_mk
    cmp r10d, 4; jle 5f
    not eax; and eax, 0xFF
5:  ret

# Internal: uint32_t br_mean_rgb(const uint32_t px[8], int mask, int inside)
br_mean_rgb:
    push rbx; push r12
    xor r8d, r8d; xor r9d, r9d; xor r10d, r10d; xor r11d, r11d; xor ecx, ecx
.Lbm_lp:
    test esi, esi; jz 1f
    bt esi, ecx; setc al; movzx eax, al
    cmp eax, edx; jne 2f
1:  mov eax, [rdi + rcx * 4]
    movzx ebx, al; add r10d, ebx
    movzx ebx, ah; add r9d, ebx
    shr eax, 16; and eax, 0xFF; add r8d, eax
    inc r11d
2:  inc ecx; cmp ecx, 8; jl .Lbm_lp
    xor eax, eax; test r11d, r11d; jz .Lbm_ret
    mov eax, r8d; xor edx, edx; div r11d; mov ebx, eax; shl ebx, 16
    mov eax, r9d; xor edx, edx; div r11d; shl eax, 8; or ebx, eax
    mov eax, r10d; xor edx, edx; div r11d; or eax, ebx
.Lbm_ret:
    pop r12; pop rbx
    ret
