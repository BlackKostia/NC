# PNG pixel stage: scanline unfiltering (None/Sub/Up/Average/Paeth) and conversion of every
# color type / bit depth (1..16, palette + tRNS, gray/RGB color keys) to RGBA8.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"
.include "img_png.inc"

.section .text
.global png_run_pass

# uint8_t *png_run_pass(PngCtx *c, uint8_t *src, const PngPass *p) -> first byte after the pass
png_run_pass:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov eax, [r13 + PngPass.pw]       # stride = 1 + rowbytes
    imul eax, [rbx + PngCtx.bits]
    add eax, 7
    shr eax, 3
    mov [rsp], eax                    # rowbytes
    xor r14d, r14d                    # row
    xor r15d, r15d                    # previous row (0 = none)
.Lrp_row:
    cmp r14d, [r13 + PngPass.ph]
    jge .Lrp_done
    lea rdi, [r12 + 1]
    mov rsi, r15
    mov edx, [rsp]
    mov ecx, [rbx + PngCtx.fbpp]
    movzx r8d, byte ptr [r12]
    call png_unfilter_row
    lea rsi, [r12 + 1]
    mov rdi, rbx
    mov rdx, r13
    mov ecx, r14d
    call png_emit_row
    lea r15, [r12 + 1]
    mov eax, [rsp]
    lea r12, [r12 + rax + 1]
    inc r14d
    jmp .Lrp_row
.Lrp_done:
    mov rax, r12
    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: void png_unfilter_row(uint8_t *cur, const uint8_t *prev /*or 0*/, int n, int bpp, int ft)
png_unfilter_row:
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
    test r15d, r15d
    jz .Luf_done
    xor ecx, ecx                      # k
.Luf_loop:
    cmp ecx, r13d
    jge .Luf_done
    xor edi, edi                      # a = cur[k - bpp]
    xor esi, esi                      # b = prev[k]
    xor edx, edx                      # c = prev[k - bpp]
    mov eax, ecx
    sub eax, r14d
    js .Luf_up
    movzx edi, byte ptr [rbx + rax]
    test r12, r12
    jz .Luf_up
    movzx edx, byte ptr [r12 + rax]
.Luf_up:
    test r12, r12
    jz .Luf_op
    movzx esi, byte ptr [r12 + rcx]
.Luf_op:
    cmp r15d, 1; je .Luf_sub
    cmp r15d, 2; je .Luf_upd
    cmp r15d, 3; je .Luf_avg
    cmp r15d, 4; jne .Luf_next        # unknown filter: leave the byte as is
    call png_paeth
    jmp .Luf_add
.Luf_sub: mov eax, edi; jmp .Luf_add
.Luf_upd: mov eax, esi; jmp .Luf_add
.Luf_avg:
    lea eax, [edi + esi]
    shr eax, 1
.Luf_add:
    add [rbx + rcx], al
.Luf_next:
    inc ecx
    jmp .Luf_loop
.Luf_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: int png_paeth(int a /*edi*/, int b /*esi*/, int c /*edx*/) -- clobbers r8-r11 only
png_paeth:
    lea eax, [edi + esi]
    sub eax, edx                      # p
    mov r8d, eax
    sub r8d, edi
    mov r11d, r8d
    neg r11d
    cmovns r8d, r11d                  # pa
    mov r9d, eax
    sub r9d, esi
    mov r11d, r9d
    neg r11d
    cmovns r9d, r11d                  # pb
    mov r10d, eax
    sub r10d, edx
    mov r11d, r10d
    neg r11d
    cmovns r10d, r11d                 # pc
    cmp r8d, r9d
    jg .Lpa_b
    cmp r8d, r10d
    jg .Lpa_b
    mov eax, edi
    ret
.Lpa_b:
    cmp r9d, r10d
    jg .Lpa_c
    mov eax, esi
    ret
.Lpa_c:
    mov eax, edx
    ret

# Internal: void png_emit_row(PngCtx *c, const uint8_t *row, const PngPass *p, int r)
png_emit_row:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov eax, ecx                      # y = y0 + r * dy
    imul eax, [r13 + PngPass.dy]
    add eax, [r13 + PngPass.y0]
    imul eax, [rbx + PngCtx.w]
    mov r14, [rbx + PngCtx.out]
    mov r14, [r14 + Image.px]
    lea r14, [r14 + rax * 4]          # row base in the image
    xor r15d, r15d
.Ler_px:
    cmp r15d, [r13 + PngPass.pw]
    jge .Ler_done
    mov rdi, rbx
    mov rsi, r12
    mov edx, r15d
    call png_pixel
    mov ecx, r15d                     # x = x0 + i * dx
    imul ecx, [r13 + PngPass.dx]
    add ecx, [r13 + PngPass.x0]
    mov [r14 + rcx * 4], eax
    inc r15d
    jmp .Ler_px
.Ler_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: uint32_t png_pixel(PngCtx *c, const uint8_t *row, int i) -> RGBA (R = low byte)
png_pixel:
    mov r10d, [rdi + PngCtx.depth]
    cmp r10d, 8
    jae png_px_wide
    mov eax, edx                      # sub-byte sample: v = row[bit >> 3] >> shift & mask
    imul eax, r10d
    mov r8d, eax
    shr r8d, 3
    movzx r8d, byte ptr [rsi + r8]
    and eax, 7
    mov ecx, 8
    sub ecx, eax
    sub ecx, r10d
    shr r8d, cl
    mov ecx, r10d
    mov eax, 1
    shl eax, cl
    dec eax
    and r8d, eax
    cmp dword ptr [rdi + PngCtx.ctype], 3
    jne .Lpp_gray
    mov esi, r8d
    jmp png_palette
.Lpp_gray:
    mov r9d, eax                      # g = v * 255 / mask
    imul eax, r8d, 255
    xor edx, edx
    div r9d
    mov esi, r8d                      # raw value for the tRNS key
    jmp png_gray_key

# Internal: uint32_t png_gray_key(PngCtx *c, int raw /*esi*/, int g8 /*eax*/)
png_gray_key:
    mov r11d, 0xFF
    cmp dword ptr [rdi + PngCtx.trns_n], 2
    jb .Lgk_pack
    mov rcx, [rdi + PngCtx.trns]
    movzx ecx, word ptr [rcx]
    xchg cl, ch
    cmp ecx, esi
    jne .Lgk_pack
    xor r11d, r11d
.Lgk_pack:
    imul eax, eax, 0x010101
    shl r11d, 24
    or eax, r11d
    ret

# Internal: 8/16-bit samples (r10d = depth)
png_px_wide:
    mov r9d, 1                        # bytes per sample
    cmp r10d, 16
    jne 1f
    mov r9d, 2
1:  mov r8d, [rdi + PngCtx.ctype]
    cmp r8d, 3
    jne .Lpw_samples
    movzx esi, byte ptr [rsi + rdx]
    jmp png_palette
.Lpw_samples:
    mov eax, edx                      # p = row + i * ch * s
    imul eax, [rdi + PngCtx.ch]
    imul eax, r9d
    add rsi, rax
    cmp r8d, 0; je .Lpw_gray
    cmp r8d, 4; je .Lpw_ga
    cmp r8d, 2; je .Lpw_rgb
    lea rax, [r9 + r9 * 2]            # RGBA: a = sample 3
    movzx eax, byte ptr [rsi + rax]
    shl eax, 24
    jmp .Lpw_rgb_body
.Lpw_rgb:
    call png_rgb_key                  # eax = alpha << 24
.Lpw_rgb_body:
    movzx ecx, byte ptr [rsi + r9 * 2]        # b
    shl ecx, 16
    or eax, ecx
    movzx ecx, byte ptr [rsi + r9]            # g
    shl ecx, 8
    or eax, ecx
    movzx ecx, byte ptr [rsi]                 # r
    or eax, ecx
    ret
.Lpw_ga:
    movzx eax, byte ptr [rsi]
    imul eax, eax, 0x010101
    movzx ecx, byte ptr [rsi + r9]
    shl ecx, 24
    or eax, ecx
    ret
.Lpw_gray:
    movzx eax, byte ptr [rsi]         # g8 = high byte, raw = full sample for the tRNS key
    movzx ecx, byte ptr [rsi]
    cmp r9d, 2
    jne 1f
    shl ecx, 8
    movzx edx, byte ptr [rsi + 1]
    or ecx, edx
1:  mov esi, ecx
    jmp png_gray_key

# Internal: int png_rgb_key(PngCtx *c, const uint8_t *p /*rsi*/, int s /*r9d*/) -> eax = A << 24
png_rgb_key:
    mov eax, 0xFF000000
    cmp dword ptr [rdi + PngCtx.trns_n], 6
    jb .Lrk_ret
    mov r11, [rdi + PngCtx.trns]
    xor ecx, ecx
.Lrk_ch:
    cmp ecx, 3
    jge .Lrk_hit
    movzx edx, word ptr [r11 + rcx * 2]
    xchg dl, dh                       # key sample (BE16)
    mov r8d, ecx
    imul r8d, r9d
    movzx r10d, byte ptr [rsi + r8]
    cmp r9d, 2
    jne 1f
    shl r10d, 8
    movzx r8d, byte ptr [rsi + r8 + 1]
    or r10d, r8d
1:  cmp edx, r10d
    jne .Lrk_ret
    inc ecx
    jmp .Lrk_ch
.Lrk_hit:
    xor eax, eax
.Lrk_ret:
    ret

# Internal: uint32_t png_palette(PngCtx *c, int idx /*esi*/)
png_palette:
    mov eax, 0xFF000000
    cmp esi, [rdi + PngCtx.plte_n]
    jae .Lpl_ret
    lea ecx, [esi + esi * 2]
    mov r8, [rdi + PngCtx.plte]
    movzx eax, byte ptr [r8 + rcx + 2]
    shl eax, 16
    movzx edx, byte ptr [r8 + rcx + 1]
    shl edx, 8
    or eax, edx
    movzx edx, byte ptr [r8 + rcx]
    or eax, edx
    mov edx, 0xFF
    cmp esi, [rdi + PngCtx.trns_n]
    jae 1f
    mov rcx, [rdi + PngCtx.trns]
    movzx edx, byte ptr [rcx + rsi]
1:  shl edx, 24
    or eax, edx
.Lpl_ret:
    ret
