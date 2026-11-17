# Frozen reference oracle: the hand-written asm that src/fs/img_tga.c replaced (tests/test_c_img.py diffs against it)
# Truevision TGA decoder: color-mapped (1/9), true-color (2/10) and gray (3/11) images,
# raw or RLE, 8/15/16/24/32-bit pixels, bottom-left or top-left origin.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

# TgaCtx (stack)
.equ TC_W,     0
.equ TC_H,     4
.equ TC_BPP,   8               # bytes per stored pixel
.equ TC_TYPE,  12              # 1 cmap, 2 true color, 3 gray (RLE flag stripped)
.equ TC_RLE,   16
.equ TC_TOP,   20
.equ TC_CMAPE, 24              # color map entry bytes
.equ TC_CMAPN, 28              # color map entries
.equ TC_CMAP,  32              # color map pointer
.equ TC_END,   40              # end of file
.equ TC_PX,    48              # output pixels
.equ TC_SIZE,  56

.section .text
.global img_tga_decode

# int img_tga_decode(const uint8_t *d, size_t n, Image *out)
img_tga_decode:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, TC_SIZE + 8
    mov rbx, rdi
    mov r13, rdx
    lea rax, [rdi + rsi]
    mov [rsp + TC_END], rax
    mov rdi, rsp
    mov rsi, rbx
    call tga_header                   # -> rax = first pixel byte or 0
    test rax, rax
    jz .Ltd_bad
    mov r12, rax
    mov rdi, r13
    mov esi, [rsp + TC_W]
    mov edx, [rsp + TC_H]
    call img_alloc
    test eax, eax
    jnz .Ltd_ret
    mov rax, [r13 + Image.px]
    mov [rsp + TC_PX], rax
    mov rdi, rsp
    mov rsi, r12
    call tga_pixels
    xor eax, eax
    jmp .Ltd_ret
.Ltd_bad:
    mov eax, IMG_E_UNSUP
.Ltd_ret:
    add rsp, TC_SIZE + 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: uint8_t *tga_header(TgaCtx *c, const uint8_t *d) -> pixel data or 0 if unsupported
tga_header:
    movzx eax, byte ptr [rsi + 2]     # image type
    mov ecx, eax
    and ecx, 7
    mov [rdi + TC_TYPE], ecx
    shr eax, 3
    and eax, 1
    mov [rdi + TC_RLE], eax
    cmp ecx, 1
    jb .Lth_no
    cmp ecx, 3
    ja .Lth_no
    movzx eax, word ptr [rsi + 12];  mov [rdi + TC_W], eax
    movzx eax, word ptr [rsi + 14];  mov [rdi + TC_H], eax
    movzx eax, byte ptr [rsi + 16]
    add eax, 7
    shr eax, 3
    jz .Lth_no
    cmp eax, 4
    ja .Lth_no
    mov [rdi + TC_BPP], eax
    movzx eax, byte ptr [rsi + 17]
    shr eax, 5
    and eax, 1
    mov [rdi + TC_TOP], eax
    movzx eax, word ptr [rsi + 5];   mov [rdi + TC_CMAPN], eax
    movzx eax, byte ptr [rsi + 7]
    add eax, 7
    shr eax, 3
    mov [rdi + TC_CMAPE], eax
    movzx eax, byte ptr [rsi]         # id length
    lea rax, [rsi + rax + 18]
    mov [rdi + TC_CMAP], rax
    cmp byte ptr [rsi + 1], 0         # color map present?
    jne .Lth_has_cmap
    cmp dword ptr [rdi + TC_TYPE], 1
    je .Lth_no
    jmp .Lth_ret
.Lth_has_cmap:
    cmp dword ptr [rdi + TC_CMAPE], 1
    jb .Lth_no
    cmp dword ptr [rdi + TC_CMAPE], 4
    ja .Lth_no
    cmp dword ptr [rdi + TC_CMAPN], 0
    je .Lth_no
    mov ecx, [rdi + TC_CMAPN]
    imul ecx, [rdi + TC_CMAPE]
    add rax, rcx
.Lth_ret:
    cmp rax, [rdi + TC_END]
    jae .Lth_no
    ret
.Lth_no:
    xor eax, eax
    ret

# Internal: void tga_pixels(TgaCtx *c, const uint8_t *p) -- raw or RLE pixel stream
tga_pixels:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    mov r12, rsi
    xor r13d, r13d                    # pixel index
    mov r14d, [rbx + TC_W]
    imul r14d, [rbx + TC_H]           # total
.Ltp_loop:
    cmp r13d, r14d
    jge .Ltp_done
    mov r15d, 1                       # count
    xor ecx, ecx                      # 1 = repeat one pixel
    cmp dword ptr [rbx + TC_RLE], 0
    je .Ltp_packet
    cmp r12, [rbx + TC_END]
    jae .Ltp_done
    movzx eax, byte ptr [r12]
    inc r12
    mov r15d, eax
    and r15d, 0x7F
    inc r15d
    mov ecx, eax
    shr ecx, 7
.Ltp_packet:
    mov rdi, rbx
    mov rsi, r12
    mov edx, r13d
    mov r8d, r15d
    call tga_packet                   # -> rax = new cursor, 0 when out of data
    test rax, rax
    jz .Ltp_done
    mov r12, rax
    add r13d, r15d
    jmp .Ltp_loop
.Ltp_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: uint8_t *tga_packet(TgaCtx *c, const uint8_t *p, int index, int repeat /*ecx*/, int count /*r8d*/)
tga_packet:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov r14d, ecx
    mov r15d, r8d
.Ltk_px:
    test r15d, r15d
    jz .Ltk_ret
    mov eax, [rbx + TC_BPP]
    lea rcx, [r12 + rax]
    cmp rcx, [rbx + TC_END]
    ja .Ltk_eof
    mov rdi, rbx
    mov rsi, r12
    call tga_color
    mov rdi, rbx
    mov esi, r13d
    mov edx, eax
    call tga_put
    test r14d, r14d
    jnz 1f
    mov eax, [rbx + TC_BPP]
    add r12, rax                      # raw packet: next stored pixel
1:  inc r13d
    dec r15d
    jmp .Ltk_px
.Ltk_ret:
    test r14d, r14d
    jz 2f
    mov eax, [rbx + TC_BPP]
    add r12, rax                      # run packet consumed one stored pixel
2:  mov rax, r12
    jmp .Ltk_out
.Ltk_eof:
    xor eax, eax
.Ltk_out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: void tga_put(TgaCtx *c, int index, uint32_t rgba) -- honours the image origin
tga_put:
    mov r9d, edx                      # rgba
    mov eax, esi
    xor edx, edx
    div dword ptr [rdi + TC_W]        # eax = row, edx = col
    mov r8d, edx
    cmp dword ptr [rdi + TC_TOP], 0
    jne 1f
    neg eax
    add eax, [rdi + TC_H]
    dec eax
1:  cmp eax, [rdi + TC_H]
    jae 2f
    imul eax, [rdi + TC_W]
    add eax, r8d
    mov rcx, [rdi + TC_PX]
    mov [rcx + rax * 4], r9d
2:  ret

# Internal: uint32_t tga_color(TgaCtx *c, const uint8_t *p)
tga_color:
    mov ecx, [rdi + TC_BPP]
    cmp dword ptr [rdi + TC_TYPE], 1
    jne tga_decode_px
    movzx eax, byte ptr [rsi]         # color-mapped: index (8 or 16 bit)
    cmp ecx, 2
    jne 1f
    movzx eax, word ptr [rsi]
1:  cmp eax, [rdi + TC_CMAPN]
    jae .Ltc_black
    mov ecx, [rdi + TC_CMAPE]
    imul eax, ecx
    mov rsi, [rdi + TC_CMAP]
    add rsi, rax
    jmp tga_decode_px
.Ltc_black:
    mov eax, 0xFF000000
    ret

# Internal: uint32_t tga_decode_px(const uint8_t *p /*rsi*/, int bytes /*ecx*/, TgaCtx *c)
tga_decode_px:
    cmp ecx, 1
    je .Ltx_gray
    cmp ecx, 2
    je .Ltx_16
    movzx eax, byte ptr [rsi + 2]     # BGR(A) -> RGBA
    movzx edx, byte ptr [rsi + 1]
    shl edx, 8
    or eax, edx
    movzx edx, byte ptr [rsi]
    shl edx, 16
    or eax, edx
    mov edx, 0xFF
    cmp ecx, 4
    jne 1f
    movzx edx, byte ptr [rsi + 3]
1:  shl edx, 24
    or eax, edx
    ret
.Ltx_gray:
    movzx eax, byte ptr [rsi]
    imul eax, eax, 0x010101
    or eax, 0xFF000000
    ret
.Ltx_16:
    movzx edx, word ptr [rsi]         # ARRRRRGG GGGBBBBB
    mov eax, edx
    shr eax, 10
    and eax, 31
    imul eax, eax, 255
    mov r8d, 31
    push rdx
    xor edx, edx
    div r8d
    pop rdx
    mov r9d, eax                      # r
    mov eax, edx
    shr eax, 5
    and eax, 31
    imul eax, eax, 255
    push rdx
    xor edx, edx
    div r8d
    pop rdx
    shl eax, 8
    or r9d, eax                       # g
    mov eax, edx
    and eax, 31
    imul eax, eax, 255
    xor edx, edx
    div r8d
    shl eax, 16
    or eax, r9d                       # b
    or eax, 0xFF000000
    ret
