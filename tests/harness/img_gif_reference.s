# Frozen reference oracle: the hand-written asm that src/fs/img_gif.c replaced (tests/test_c_img_gif.py diffs against it)
# GIF decoder: first frame of GIF87a/89a — global/local palettes, graphic-control transparency,
# interlaced rows and variable-width LZW (2..12 bits), drawn onto the logical screen.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.include "img_gif.inc"

.section .text
.global img_gif_decode

# int img_gif_decode(const uint8_t *d, size_t n, Image *out)
img_gif_decode:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, GC_SIZE
    mov rbx, rdi
    lea r12, [rdi + rsi]
    mov r13, rdx
    mov rdi, rsp
    mov esi, GC_SIZE
    call mem_zero
    mov dword ptr [rsp + GC_TRANS], -1
    mov eax, IMG_E_FORMAT
    lea rcx, [rbx + 13]
    cmp rcx, r12
    ja .Lgd_ret
    movzx esi, word ptr [rbx + 6]
    movzx edx, word ptr [rbx + 8]
    mov [rsp + GC_CW], esi
    mov [rsp + GC_CH], edx
    mov rdi, r13
    call img_alloc
    test eax, eax
    jnz .Lgd_ret
    mov rax, [r13 + Image.px]
    mov [rsp + GC_PX], rax
    lea r14, [rbx + 13]               # cursor
    movzx ecx, byte ptr [rbx + 10]
    mov rdi, rsp
    mov rsi, r14
    call gif_palette                  # global color table -> rax = cursor after it
    mov r14, rax
    mov rdi, rsp
    mov rsi, r14
    mov rdx, r12
    call gif_blocks
    jmp .Lgd_ret
.Lgd_ret:
    add rsp, GC_SIZE
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: uint8_t *gif_palette(GifCtx *c, uint8_t *p, int flags /*ecx*/) -- optional color table
gif_palette:
    mov rax, rsi
    test ecx, 0x80
    jz .Lgp_ret
    mov [rdi + GC_PAL], rsi
    and ecx, 7
    mov edx, 2
    shl edx, cl
    mov [rdi + GC_PALN], edx
    lea edx, [edx + edx * 2]
    add rax, rdx
.Lgp_ret:
    ret

# Internal: int gif_blocks(GifCtx *c, uint8_t *p, uint8_t *end) -- extensions, then the first image
gif_blocks:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
.Lgb_loop:
    mov eax, IMG_E_CORRUPT
    cmp r12, r13
    jae .Lgb_ret
    movzx eax, byte ptr [r12]
    inc r12
    cmp eax, 0x2C
    je .Lgb_image
    cmp eax, 0x21
    jne .Lgb_end
    lea rcx, [r12 + 6]
    cmp rcx, r13
    ja .Lgb_end
    cmp byte ptr [r12], 0xF9          # graphic control: transparency
    jne .Lgb_skip
    test byte ptr [r12 + 2], 1
    jz .Lgb_skip
    movzx eax, byte ptr [r12 + 5]
    mov [rbx + GC_TRANS], eax
.Lgb_skip:
    inc r12                           # label
    mov rdi, r12
    mov rsi, r13
    xor edx, edx
    call gif_subblocks                # rax = bytes, rdx = cursor after terminator
    mov r12, rdx
    jmp .Lgb_loop
.Lgb_image:
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call gif_image
    jmp .Lgb_ret
.Lgb_end:
    mov eax, IMG_E_CORRUPT            # trailer / garbage before any image
.Lgb_ret:
    pop r13
    pop r12
    pop rbx
    ret

# Internal: (size_t len, uint8_t *next) gif_subblocks(uint8_t *p, uint8_t *end, uint8_t *dst /*or 0*/)
gif_subblocks:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    xor ebx, ebx
.Lgs_loop:
    cmp r12, r13
    jae .Lgs_done
    movzx ecx, byte ptr [r12]
    inc r12
    test ecx, ecx
    jz .Lgs_done
    lea rax, [r12 + rcx]
    cmp rax, r13
    jbe 1f
    mov rcx, r13
    sub rcx, r12
1:  test r14, r14
    jz 2f
    push rcx
    sub rsp, 8
    lea rdi, [r14 + rbx]
    mov rsi, r12
    mov rdx, rcx
    call mem_copy
    add rsp, 8
    pop rcx
2:  add rbx, rcx
    add r12, rcx
    jmp .Lgs_loop
.Lgs_done:
    mov rax, rbx
    mov rdx, r12
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: int gif_image(GifCtx *c, uint8_t *p /*after 0x2C*/, uint8_t *end)
gif_image:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov eax, IMG_E_CORRUPT
    lea rcx, [r12 + 10]
    cmp rcx, r13
    ja .Lgi_ret
    movzx eax, word ptr [r12];     mov [rbx + GC_IX], eax
    movzx eax, word ptr [r12 + 2]; mov [rbx + GC_IY], eax
    movzx eax, word ptr [r12 + 4]; mov [rbx + GC_IW], eax
    movzx eax, word ptr [r12 + 6]; mov [rbx + GC_IH], eax
    movzx ecx, byte ptr [r12 + 8]
    mov eax, ecx
    shr eax, 6
    and eax, 1
    mov [rbx + GC_ILACE], eax
    lea rsi, [r12 + 9]
    mov rdi, rbx
    call gif_palette                  # local table overrides the global one
    mov r12, rax
    mov eax, IMG_E_CORRUPT
    cmp r12, r13
    jae .Lgi_ret
    movzx eax, byte ptr [r12]
    mov [rbx + GC_MCS], eax
    inc r12
    mov rdi, rbx
    call gif_lace_counts
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call gif_gather_decode
.Lgi_ret:
    pop r13
    pop r12
    pop rbx
    ret

# Internal: void gif_lace_counts(GifCtx *c) -- rows in interlace passes 1..3
gif_lace_counts:
    mov eax, [rdi + GC_IH]
    lea ecx, [eax + 7]
    shr ecx, 3
    mov [rdi + GC_C1], ecx            # rows 0, 8, 16 ...
    lea ecx, [eax + 3]
    shr ecx, 3
    mov [rdi + GC_C2], ecx            # rows 4, 12 ...
    lea ecx, [eax + 1]
    shr ecx, 2
    mov [rdi + GC_C3], ecx            # rows 2, 6 ...
    ret

# Internal: int gif_gather_decode(GifCtx *c, uint8_t *p, uint8_t *end)
gif_gather_decode:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, r12
    mov rsi, r13
    xor edx, edx
    call gif_subblocks
    mov [rbx + GC_DLEN], rax
    lea rdi, [rax + GIF_TAB_BYTES + 16]
    call mem_alloc
    test rax, rax
    jz .Lgg_nomem
    mov [rbx + GC_TAB], rax
    add rax, GIF_TAB_BYTES
    mov [rbx + GC_DATA], rax
    mov rdi, r12
    mov rsi, r13
    mov rdx, rax
    call gif_subblocks
    mov rdi, rbx
    call gif_lzw
    mov rdi, [rbx + GC_TAB]
    call mem_free
    xor eax, eax
    jmp .Lgg_ret
.Lgg_nomem:
    mov eax, IMG_E_NOMEM
.Lgg_ret:
    pop r13
    pop r12
    pop rbx
    ret
