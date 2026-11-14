# Baseline JPEG pixel stage: separable 8x8 inverse DCT with a 12-bit fixed-point cosine table
# (64-bit accumulators, zero-row fast path) into component planes, then YCbCr / gray -> RGBA.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"
.include "img_jpeg.inc"

.section .rodata
.align 16
# idct_t[x][u] = round(4096 * c(u) * cos((2x + 1) * u * pi / 16)), c(0) = 1 / (2 sqrt 2), c(u) = 1/2
idct_t:
    .long 1448, 2009, 1892, 1703, 1448, 1138, 784, 400
    .long 1448, 1703, 784, -400, -1448, -2009, -1892, -1138
    .long 1448, 1138, -784, -2009, -1448, 400, 1892, 1703
    .long 1448, 400, -1892, -1138, 1448, 1703, -784, -2009
    .long 1448, -400, -1892, 1138, 1448, -1703, -784, 2009
    .long 1448, -1138, -784, 2009, -1448, -400, 1892, -1703
    .long 1448, -1703, 784, 400, -1448, 2009, -1892, 1138
    .long 1448, -2009, 1892, -1703, 1448, -1138, 784, -400

.section .text
.global jpeg_idct_store
.global jpeg_color

# void jpeg_idct_store(Jpeg *j, JComp *c, int bx, int by) -- j->blk -> plane block (bx, by)
jpeg_idct_store:
    push rbx
    push r12
    push r13
    push r14
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov r14d, ecx
    lea rdi, [rbx + Jpeg.blk]
    lea rsi, [rbx + Jpeg.tmp]
    call idct_rows
    mov eax, r14d                     # dst = plane + (by * 8) * bw + bx * 8
    shl eax, 3
    imul eax, [r12 + JC.bw]
    lea edx, [r13d * 8]
    add eax, edx
    mov rdx, [r12 + JC.plane]
    add rdx, rax
    lea rdi, [rbx + Jpeg.tmp]
    mov rsi, rdx
    mov edx, [r12 + JC.bw]
    call idct_cols
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: void idct_rows(const int32_t *blk, int32_t *tmp) -- tmp[v][x] = sum_u blk[v][u] T[x][u] >> 8
idct_rows:
    push rbx
    push r12
    push r13
    push r14
    lea r12, [rip + idct_t]
    xor r8d, r8d                      # v
.Lir_row:
    cmp r8d, 8
    jge .Lir_done
    mov rax, r8
    shl rax, 5
    lea r9, [rdi + rax]               # blk row v
    lea r10, [rsi + rax]              # tmp row v
    xor edx, edx                      # OR of the AC terms (0 = DC-only row)
    mov ecx, 1
1:  or edx, [r9 + rcx * 4]
    inc ecx
    cmp ecx, 8
    jl 1b
    xor r11d, r11d                    # x
.Lir_x:
    cmp r11d, 8
    jge .Lir_next
    mov rax, r11
    shl rax, 5
    lea rbx, [r12 + rax]              # T[x]
    movsxd r13, dword ptr [r9]
    movsxd rax, dword ptr [rbx]
    imul r13, rax
    test edx, edx
    jz .Lir_store
    mov ecx, 1
2:  movsxd rax, dword ptr [r9 + rcx * 4]
    movsxd r14, dword ptr [rbx + rcx * 4]
    imul rax, r14
    add r13, rax
    inc ecx
    cmp ecx, 8
    jl 2b
.Lir_store:
    add r13, 128
    sar r13, 8
    mov [r10 + r11 * 4], r13d
    inc r11d
    jmp .Lir_x
.Lir_next:
    inc r8d
    jmp .Lir_row
.Lir_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: void idct_cols(const int32_t *tmp, uint8_t *dst, int stride)
# out[y][x] = clamp(((sum_v tmp[v][x] T[y][v]) + 2^15 >> 16) + 128)
idct_cols:
    push rbx
    push r12
    push r13
    push r14
    lea r12, [rip + idct_t]
    movsxd r13, edx                   # stride
    xor r8d, r8d                      # y
.Lic_y:
    cmp r8d, 8
    jge .Lic_done
    mov rax, r8
    shl rax, 5
    lea rbx, [r12 + rax]              # T[y]
    xor r9d, r9d                      # x
.Lic_x:
    cmp r9d, 8
    jge .Lic_next
    xor r10d, r10d                    # acc
    xor ecx, ecx                      # v
3:  mov rax, rcx
    shl rax, 5
    lea r14, [rdi + rax]
    movsxd rax, dword ptr [r14 + r9 * 4]
    movsxd r11, dword ptr [rbx + rcx * 4]
    imul rax, r11
    add r10, rax
    inc ecx
    cmp ecx, 8
    jl 3b
    add r10, 32768
    sar r10, 16
    add r10, 128
    jns 4f
    xor r10d, r10d
4:  cmp r10, 255
    jle 5f
    mov r10d, 255
5:  mov [rsi + r9], r10b
    inc r9d
    jmp .Lic_x
.Lic_next:
    add rsi, r13
    inc r8d
    jmp .Lic_y
.Lic_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# void jpeg_color(Jpeg *j) -- planes -> RGBA (nearest upsampling of subsampled chroma)
jpeg_color:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, [rbx + Jpeg.out]
    mov r12, [r12 + Image.px]
    xor r13d, r13d
.Lcl_row:
    cmp r13d, [rbx + Jpeg.h]
    jge .Lcl_done
    mov rdi, rbx
    mov esi, r13d
    mov rdx, r12
    call jcol_row
    mov eax, [rbx + Jpeg.w]
    lea r12, [r12 + rax * 4]
    inc r13d
    jmp .Lcl_row
.Lcl_done:
    pop r13
    pop r12
    pop rbx
    ret

# Internal: void jcol_row(Jpeg *j, int y, uint32_t *dst)
jcol_row:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32                       # [0..23] = component row pointers
    mov rbx, rdi
    mov r15, rdx
    xor ecx, ecx
.Lcr_ptr:
    cmp ecx, [rbx + Jpeg.ncomp]
    jge .Lcr_px
    imul r8, rcx, JC._size
    lea r8, [rbx + Jpeg.comp + r8]
    push rcx
    mov eax, esi
    mov ecx, [r8 + JC.sy]
    shr eax, cl
    pop rcx
    imul eax, [r8 + JC.bw]
    add rax, [r8 + JC.plane]
    mov [rsp + rcx * 8], rax
    inc ecx
    jmp .Lcr_ptr
.Lcr_px:
    xor r12d, r12d                    # x
.Lcr_loop:
    cmp r12d, [rbx + Jpeg.w]
    jge .Lcr_done
    mov rdi, rbx
    mov esi, r12d
    mov rdx, rsp
    call jcol_pixel
    mov [r15 + r12 * 4], eax
    inc r12d
    jmp .Lcr_loop
.Lcr_done:
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: uint32_t jcol_pixel(Jpeg *j, int x, uint8_t **rows) -> RGBA
jcol_pixel:
    mov ecx, [rdi + Jpeg.comp + JC.sx]
    mov eax, esi
    shr eax, cl
    mov r8, [rdx]
    movzx r9d, byte ptr [r8 + rax]    # Y
    cmp dword ptr [rdi + Jpeg.ncomp], 1
    jne .Lcp_ycc
    imul eax, r9d, 0x010101
    or eax, 0xFF000000
    ret
.Lcp_ycc:
    mov ecx, [rdi + Jpeg.comp + JC._size + JC.sx]
    mov eax, esi
    shr eax, cl
    mov r8, [rdx + 8]
    movzx r10d, byte ptr [r8 + rax]
    sub r10d, 128                     # cb'
    mov ecx, [rdi + Jpeg.comp + 2 * JC._size + JC.sx]
    mov eax, esi
    shr eax, cl
    mov r8, [rdx + 16]
    movzx r11d, byte ptr [r8 + rax]
    sub r11d, 128                     # cr'
    imul eax, r11d, 91881             # R = Y + 1.402 cr'
    add eax, 32768
    sar eax, 16
    add eax, r9d
    call jc_clamp
    mov r8d, eax
    imul eax, r10d, -22554            # G = Y - 0.344 cb' - 0.714 cr'
    imul ecx, r11d, -46802
    add eax, ecx
    add eax, 32768
    sar eax, 16
    add eax, r9d
    call jc_clamp
    shl eax, 8
    or r8d, eax
    imul eax, r10d, 116130            # B = Y + 1.772 cb'
    add eax, 32768
    sar eax, 16
    add eax, r9d
    call jc_clamp
    shl eax, 16
    or eax, r8d
    or eax, 0xFF000000
    ret

# Internal: eax = clamp(eax, 0, 255)
jc_clamp:
    test eax, eax
    jns 1f
    xor eax, eax
1:  cmp eax, 255
    jle 2f
    mov eax, 255
2:  ret
