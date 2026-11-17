# Frozen reference oracle: the hand-written asm that src/fs/img_bmp.c replaced (tests/test_c_img_simple.py diffs against it)
# BMP decoder: OS/2 core and Windows DIB headers, 1/4/8-bit palettes, 16/32-bit BI_RGB and
# BI_BITFIELDS masks, 24-bit BGR; bottom-up and top-down rows.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

# BmpCtx (stack)
.equ BC_W,      0
.equ BC_H,      4
.equ BC_BPP,    8
.equ BC_STRIDE, 12
.equ BC_PALN,   16             # palette entries
.equ BC_PALE,   20             # bytes per palette entry (3 or 4)
.equ BC_PAL,    24             # palette pointer
.equ BC_MASK,   32             # r, g, b, a masks (4 x u32)
.equ BC_TOP,    48             # 1 = top-down rows
.equ BC_COMP,   52
.equ BC_DATA,   56             # pixel array
.equ BC_SIZE,   64

.section .text
.global img_bmp_decode

# int img_bmp_decode(const uint8_t *d, size_t n, Image *out)
img_bmp_decode:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, BC_SIZE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, rsp
    mov esi, BC_SIZE
    call mem_zero
    mov rdi, rsp
    mov rsi, rbx
    mov rdx, r12
    call bmp_header
    test eax, eax
    jnz .Lbd_ret
    mov rdi, r13
    mov esi, [rsp + BC_W]
    mov edx, [rsp + BC_H]
    call img_alloc
    test eax, eax
    jnz .Lbd_ret
    xor r14d, r14d                    # output row
.Lbd_row:
    cmp r14d, [rsp + BC_H]
    jge .Lbd_ok
    mov eax, r14d                     # source row (bottom-up unless top-down)
    cmp dword ptr [rsp + BC_TOP], 0
    jne 1f
    mov eax, [rsp + BC_H]
    sub eax, r14d
    dec eax
1:  imul eax, [rsp + BC_STRIDE]
    mov rsi, [rsp + BC_DATA]
    add rsi, rax
    mov eax, [rsp + BC_STRIDE]
    lea rcx, [rsi + rax]
    lea rdx, [rbx + r12]
    cmp rcx, rdx
    ja .Lbd_ok                        # truncated file: keep decoded rows
    mov eax, r14d
    imul eax, [rsp + BC_W]
    mov rdx, [r13 + Image.px]
    lea rdx, [rdx + rax * 4]
    mov rdi, rsp
    call bmp_row
    inc r14d
    jmp .Lbd_row
.Lbd_ok:
    xor eax, eax
.Lbd_ret:
    add rsp, BC_SIZE
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: int bmp_header(BmpCtx *c, const uint8_t *d, size_t n)
bmp_header:
    mov eax, IMG_E_FORMAT
    cmp rdx, 26
    jb .Lbh_ret
    mov r8d, [rsi + 10]               # pixel data offset
    cmp r8, rdx
    jae .Lbh_ret
    lea rax, [rsi + r8]
    mov [rdi + BC_DATA], rax
    mov r9d, [rsi + 14]               # DIB header size
    mov dword ptr [rdi + BC_PALE], 4
    cmp r9d, 12
    jne .Lbh_win
    movzx eax, word ptr [rsi + 18];  mov [rdi + BC_W], eax
    movzx eax, word ptr [rsi + 20];  mov [rdi + BC_H], eax
    movzx eax, word ptr [rsi + 24];  mov [rdi + BC_BPP], eax
    mov dword ptr [rdi + BC_PALE], 3
    jmp .Lbh_common
.Lbh_win:
    mov eax, IMG_E_FORMAT
    cmp r9d, 40
    jb .Lbh_ret
    cmp rdx, 54
    jb .Lbh_ret
    lea rax, [r9 + 14]
    cmp rax, rdx
    ja .Lbh_ret
    mov eax, [rsi + 18];  mov [rdi + BC_W], eax
    mov eax, [rsi + 22]
    test eax, eax
    jns 1f
    neg eax
    mov dword ptr [rdi + BC_TOP], 1
1:  mov [rdi + BC_H], eax
    movzx eax, word ptr [rsi + 28];  mov [rdi + BC_BPP], eax
    mov eax, [rsi + 30];  mov [rdi + BC_COMP], eax
    mov eax, [rsi + 46];  mov [rdi + BC_PALN], eax
.Lbh_common:
    lea rax, [rsi + r9 + 14]          # palette follows the header
    mov [rdi + BC_PAL], rax
    jmp bmp_formats
.Lbh_ret:
    ret

# Internal: validate bpp/compression, set masks, stride and palette size (tail of bmp_header)
bmp_formats:
    mov ecx, [rdi + BC_BPP]
    mov eax, IMG_E_UNSUP
    cmp dword ptr [rdi + BC_COMP], 3
    je .Lbf_fields
    cmp dword ptr [rdi + BC_COMP], 0
    jne .Lbf_ret
    mov dword ptr [rdi + BC_MASK], 0x7C00         # 16-bit BI_RGB = X1R5G5B5
    mov dword ptr [rdi + BC_MASK + 4], 0x03E0
    mov dword ptr [rdi + BC_MASK + 8], 0x001F
    cmp ecx, 32
    jne .Lbf_bpp
    mov dword ptr [rdi + BC_MASK], 0xFF0000       # 32-bit BI_RGB = X8R8G8B8 (alpha ignored)
    mov dword ptr [rdi + BC_MASK + 4], 0xFF00
    mov dword ptr [rdi + BC_MASK + 8], 0xFF
    jmp .Lbf_bpp
.Lbf_fields:
    cmp ecx, 16
    je 1f
    cmp ecx, 32
    jne .Lbf_ret
1:  cmp rdx, 66
    jb .Lbf_ret
    cmp r9d, 56
    jb 10f
    cmp rdx, 70
    jb .Lbf_ret
10: mov eax, [rsi + 54];  mov [rdi + BC_MASK], eax
    mov eax, [rsi + 58];  mov [rdi + BC_MASK + 4], eax
    mov eax, [rsi + 62];  mov [rdi + BC_MASK + 8], eax
    cmp r9d, 56
    jb 2f
    mov eax, [rsi + 66];  mov [rdi + BC_MASK + 12], eax
2:  cmp r9d, 40
    jne .Lbf_bpp
    add qword ptr [rdi + BC_PAL], 12              # masks sit between header and palette
.Lbf_bpp:
    mov eax, IMG_E_UNSUP
    mov r10d, 0x01010112                          # valid: 1,4,8,16,24 (bit = bpp), 32
    cmp ecx, 32
    ja .Lbf_ret
    cmp ecx, 32
    je 3f
    bt r10d, ecx
    jnc .Lbf_ret
3:  mov eax, [rdi + BC_W]                         # stride = ((w * bpp + 31) / 32) * 4
    imul eax, ecx
    add eax, 31
    shr eax, 5
    shl eax, 2
    mov [rdi + BC_STRIDE], eax
    cmp ecx, 8
    ja .Lbf_ok
    cmp dword ptr [rdi + BC_PALN], 0
    jne .Lbf_clamp
    mov eax, 1
    shl eax, cl
    mov [rdi + BC_PALN], eax
.Lbf_clamp:                                           # palette entries must lie inside the file:
    lea r8, [rsi + rdx]                               # bmp_pixel trusts the count it is given
    sub r8, [rdi + BC_PAL]                            # bytes of input behind the palette start
    jae .Lbf_room
    xor r8d, r8d
.Lbf_room:
    mov eax, [rdi + BC_PALE]
    xchg rax, r8                                      # rax = bytes left, r8 = entry size (3 or 4)
    xor edx, edx
    div r8
    mov r9d, 0xFFFFFFFF
    cmp rax, r9                                       # more than 2^32 entries fit: keep the header's count
    ja .Lbf_ok
    cmp eax, [rdi + BC_PALN]
    jae .Lbf_ok
    mov [rdi + BC_PALN], eax
.Lbf_ok:
    xor eax, eax
.Lbf_ret:
    ret

# Internal: void bmp_row(BmpCtx *c, const uint8_t *src, uint32_t *dst)
bmp_row:
    push rbx
    push r12
    push r13
    push r14
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    xor r14d, r14d
.Lbr_px:
    cmp r14d, [rbx + BC_W]
    jge .Lbr_done
    mov rdi, rbx
    mov rsi, r12
    mov edx, r14d
    call bmp_pixel
    mov [r13 + r14 * 4], eax
    inc r14d
    jmp .Lbr_px
.Lbr_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: uint32_t bmp_pixel(BmpCtx *c, const uint8_t *row, int x)
bmp_pixel:
    mov ecx, [rdi + BC_BPP]
    cmp ecx, 24
    je .Lbp_24
    cmp ecx, 16
    je .Lbp_16
    cmp ecx, 32
    je .Lbp_32
    mov eax, edx                      # 1/4/8-bit index
    imul eax, ecx
    mov r8d, eax
    shr r8d, 3
    movzx r8d, byte ptr [rsi + r8]
    and eax, 7
    neg eax
    add eax, 8
    sub eax, ecx
    xchg eax, ecx
    shr r8d, cl
    mov ecx, eax
    mov eax, 1
    shl eax, cl
    dec eax
    and r8d, eax
    mov eax, 0xFF000000
    cmp r8d, [rdi + BC_PALN]
    jae .Lbp_ret
    mov eax, r8d
    imul eax, [rdi + BC_PALE]
    add rax, [rdi + BC_PAL]
    mov rsi, rax
    xor edx, edx
.Lbp_24:
    lea rax, [rdx + rdx * 2]
    movzx ecx, byte ptr [rsi + rax]           # B
    shl ecx, 16
    movzx r8d, byte ptr [rsi + rax + 1]       # G
    shl r8d, 8
    or ecx, r8d
    movzx eax, byte ptr [rsi + rax + 2]       # R
    or eax, ecx
    or eax, 0xFF000000
.Lbp_ret:
    ret
.Lbp_16:
    movzx esi, word ptr [rsi + rdx * 2]
    jmp bmp_masked
.Lbp_32:
    mov esi, [rsi + rdx * 4]
    jmp bmp_masked

# Internal: uint32_t bmp_masked(BmpCtx *c, uint32_t v /*esi*/)
bmp_masked:
    push rbx
    mov ebx, 3                        # channel: a, b, g, r (pack high to low)
    xor r11d, r11d
.Lbm_ch:
    mov ecx, [rdi + BC_MASK + rbx * 4]
    mov eax, 0xFF                     # missing alpha mask = opaque
    test ecx, ecx
    jz .Lbm_put
    call bmp_extract
.Lbm_put:
    shl r11d, 8
    or r11d, eax
    dec ebx
    jns .Lbm_ch
    mov eax, r11d                     # A<<24|B<<16|G<<8|R = bytes R,G,B,A
    pop rbx
    ret

# Internal: int bmp_extract(uint32_t v /*esi*/, uint32_t mask /*ecx*/) -> 8-bit channel
bmp_extract:
    bsf r8d, ecx                      # shift
    bsr r9d, ecx
    sub r9d, r8d
    inc r9d                           # bits
    mov eax, esi
    and eax, ecx
    mov ecx, r8d
    shr eax, cl
    cmp r9d, 8
    jb .Lbe_small
    lea ecx, [r9d - 8]
    shr eax, cl
    ret
.Lbe_small:
    imul eax, eax, 255
    mov ecx, r9d
    mov r8d, 1
    shl r8d, cl
    dec r8d
    xor edx, edx
    div r8d
    ret
