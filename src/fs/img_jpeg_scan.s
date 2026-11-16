# Baseline JPEG scan layer: interleaved MCUs and single-component scans, restart intervals,
# DC prediction and AC run-length decoding with dequantization into natural order.
# Bits/Huffman: img_jpeg_bits.s; IDCT: img_jpeg_idct.s.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"
.include "img_jpeg.inc"

.section .rodata
jpeg_zigzag:
    .byte 0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28
    .byte 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63

.section .text
.global jpeg_scan

# int jpeg_scan(Jpeg *j, const uint8_t *data) -- leaves j->p at the marker that ended the scan
jpeg_scan:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov [rbx + Jpeg.p], rsi
    mov qword ptr [rbx + Jpeg.bits], 0
    mov dword ptr [rbx + Jpeg.nbits], 0
    mov dword ptr [rbx + Jpeg.marker], 0
    mov eax, [rbx + Jpeg.rst]
    mov [rbx + Jpeg.todo], eax
    cmp dword ptr [rbx + Jpeg.sncomp], 1
    je .Ljs_single
    xor r12d, r12d                    # my
.Ljs_my:
    cmp r12d, [rbx + Jpeg.mcuy]
    jge .Ljs_done
    xor r13d, r13d                    # mx
.Ljs_mx:
    cmp r13d, [rbx + Jpeg.mcux]
    jge .Ljs_next_row
    mov rdi, rbx
    call js_restart_check
    mov rdi, rbx
    mov esi, r13d
    mov edx, r12d
    call js_mcu
    inc r13d
    jmp .Ljs_mx
.Ljs_next_row:
    inc r12d
    jmp .Ljs_my
.Ljs_single:
    mov rdi, rbx
    call js_single
.Ljs_done:
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    ret

# Internal: void js_mcu(Jpeg *j, int mx, int my) -- every block of every scan component
js_mcu:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16
    mov rbx, rdi
    mov [rsp], esi
    mov [rsp + 4], edx
    xor r12d, r12d                    # scan component
.Lmc_comp:
    cmp r12d, [rbx + Jpeg.sncomp]
    jge .Lmc_done
    mov eax, [rbx + Jpeg.scomp + r12 * 4]
    imul r13, rax, JC._size
    lea r13, [rbx + Jpeg.comp + r13]
    xor r14d, r14d                    # v
.Lmc_v:
    cmp r14d, [r13 + JC.v]
    jge .Lmc_next
    xor r15d, r15d                    # h
.Lmc_h:
    cmp r15d, [r13 + JC.h]
    jge .Lmc_nv
    mov rdi, rbx
    mov rsi, r13
    call js_block
    mov edx, [rsp]                    # bx = mx * H + h, by = my * V + v
    imul edx, [r13 + JC.h]
    add edx, r15d
    mov ecx, [rsp + 4]
    imul ecx, [r13 + JC.v]
    add ecx, r14d
    mov rdi, rbx
    mov rsi, r13
    call jpeg_idct_store
    inc r15d
    jmp .Lmc_h
.Lmc_nv:
    inc r14d
    jmp .Lmc_v
.Lmc_next:
    inc r12d
    jmp .Lmc_comp
.Lmc_done:
    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: void js_single(Jpeg *j) -- non-interleaved scan: one block per MCU
js_single:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16
    mov rbx, rdi
    mov eax, [rbx + Jpeg.scomp]
    imul r13, rax, JC._size
    lea r13, [rbx + Jpeg.comp + r13]
    mov edi, [rbx + Jpeg.w]
    mov esi, [r13 + JC.h]
    mov edx, [rbx + Jpeg.hmax]
    call js_blocks_span
    mov [rsp], eax                    # blocks per row
    mov edi, [rbx + Jpeg.h]
    mov esi, [r13 + JC.v]
    mov edx, [rbx + Jpeg.vmax]
    call js_blocks_span
    mov [rsp + 4], eax                # block rows
    xor r14d, r14d
.Lsi_by:
    cmp r14d, [rsp + 4]
    jge .Lsi_done
    xor r15d, r15d
.Lsi_bx:
    cmp r15d, [rsp]
    jge .Lsi_nby
    mov rdi, rbx
    call js_restart_check
    mov rdi, rbx
    mov rsi, r13
    call js_block
    mov rdi, rbx
    mov rsi, r13
    mov edx, r15d
    mov ecx, r14d
    call jpeg_idct_store
    inc r15d
    jmp .Lsi_bx
.Lsi_nby:
    inc r14d
    jmp .Lsi_by
.Lsi_done:
    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: int js_blocks_span(int size, int factor, int max) -> ceil(ceil(size * factor / max) / 8)
js_blocks_span:
    mov eax, edi
    imul eax, esi
    add eax, edx
    dec eax
    mov ecx, edx
    xor edx, edx
    div ecx
    add eax, 7
    shr eax, 3
    ret

# Internal: void js_restart_check(Jpeg *j) -- skip the RSTn marker every j->rst MCUs
js_restart_check:
    cmp dword ptr [rdi + Jpeg.rst], 0
    je .Lrc_ret
    cmp dword ptr [rdi + Jpeg.todo], 0
    jne .Lrc_count
    mov eax, [rdi + Jpeg.rst]
    mov [rdi + Jpeg.todo], eax
    mov qword ptr [rdi + Jpeg.bits], 0
    mov dword ptr [rdi + Jpeg.nbits], 0
    mov dword ptr [rdi + Jpeg.marker], 0
    mov rsi, [rdi + Jpeg.p]
    mov rdx, [rdi + Jpeg.end]
.Lrc_seek:
    lea rax, [rsi + 1]
    cmp rax, rdx
    jae .Lrc_found
    cmp byte ptr [rsi], 0xFF
    jne .Lrc_step
    movzx eax, byte ptr [rsi + 1]
    and eax, 0xF8
    cmp eax, 0xD0
    jne .Lrc_step
    add rsi, 2
    jmp .Lrc_found
.Lrc_step:
    inc rsi
    jmp .Lrc_seek
.Lrc_found:
    mov [rdi + Jpeg.p], rsi
    xor ecx, ecx
.Lrc_pred:
    imul rax, rcx, JC._size
    mov dword ptr [rdi + Jpeg.comp + rax + JC.pred], 0
    inc ecx
    cmp ecx, 4
    jl .Lrc_pred
.Lrc_count:
    dec dword ptr [rdi + Jpeg.todo]
.Lrc_ret:
    ret

# Internal: void js_block(Jpeg *j, JComp *c) -- decode + dequantize one 8x8 block into j->blk
js_block:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    mov r12, rsi
    lea rdi, [rbx + Jpeg.blk]
    mov esi, 256
    call mem_zero
    mov r13d, [r12 + JC.tq]
    shl r13d, 7
    lea r13, [rbx + Jpeg.qt + r13]    # quantizers (zigzag order)
    mov eax, [r12 + JC.td]
    imul rax, rax, HT._size
    lea rsi, [rbx + Jpeg.huff + rax]
    mov rdi, rbx
    call jb_huff
    cmp eax, 15
    ja .Lbk_done
    mov esi, eax
    mov rdi, rbx
    call jb_extend
    add eax, [r12 + JC.pred]
    mov [r12 + JC.pred], eax
    movzx ecx, word ptr [r13]
    imul eax, ecx
    mov [rbx + Jpeg.blk], eax
    mov eax, [r12 + JC.ta]
    add eax, 4
    imul r14, rax, HT._size
    lea r14, [rbx + Jpeg.huff + r14]  # AC table
    mov r15d, 1                       # k (zigzag index)
.Lbk_ac:
    cmp r15d, 64
    jge .Lbk_done
    mov rdi, rbx
    mov rsi, r14
    call jb_huff
    mov ecx, eax
    shr ecx, 4                        # run
    and eax, 15                       # size
    jnz .Lbk_coef
    cmp ecx, 15
    jne .Lbk_done                     # EOB
    add r15d, 16
    jmp .Lbk_ac
.Lbk_coef:
    add r15d, ecx
    cmp r15d, 63
    jg .Lbk_done
    mov esi, eax
    mov rdi, rbx
    call jb_extend
    movzx ecx, word ptr [r13 + r15 * 2]
    imul eax, ecx
    lea rcx, [rip + jpeg_zigzag]
    movzx ecx, byte ptr [rcx + r15]
    mov [rbx + Jpeg.blk + rcx * 4], eax
    inc r15d
    jmp .Lbk_ac
.Lbk_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
