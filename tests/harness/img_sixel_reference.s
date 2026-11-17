# Frozen reference oracle: the hand-written asm that src/fs/img_sixel.c replaced (tests/test_c_img_out.py diffs against it)
# DEC Sixel encoder: RGBA8 -> adaptive palette (img_quantize) -> "ESC P q" raster with "#n;2;r;g;b"
# color registers and run-length compressed six-pixel bands (only colors used in a band are sent).

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

# SixCtx (stack)
.equ SC_IDX,   0               # palette index per pixel
.equ SC_W,     8
.equ SC_H,     12
.equ SC_NCOL,  16
.equ SC_END,   24              # end of the output buffer
.equ SC_PAL,   32              # uint32_t[256]
.equ SC_USED,  SC_PAL + 1024   # uint8_t[256] colors present in the current band
.equ SC_SIZE,  SC_USED + 256

.section .rodata
str_six_head: .asciz "\x1bPq\"1;1;"

.section .text
.global img_sixel_encode

# size_t img_sixel_encode(const uint8_t *rgba, int w, int h, uint32_t bg /*0xRRGGBB*/,
#                         uint8_t *out, size_t cap) -> bytes written, 0 on overflow / OOM
img_sixel_encode:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, SC_SIZE + 16
    mov rbx, rsp
    mov r13, rdi
    mov [rbx + SC_W], esi
    mov [rbx + SC_H], edx
    mov r14d, ecx                     # bg
    mov r12, r8                       # out cursor
    mov r15, r8                       # out start
    lea rax, [r8 + r9]
    mov [rbx + SC_END], rax
    test esi, esi; jle .Lse_fail
    test edx, edx; jle .Lse_fail
    cmp esi, IMG_MAX_DIM; ja .Lse_fail
    cmp edx, IMG_MAX_DIM; ja .Lse_fail
    mov eax, esi; movsxd rcx, edx; imul rax, rcx
    cmp rax, IMG_MAX_PIXELS; ja .Lse_fail
    mov rdi, rax
    call mem_alloc
    mov [rbx + SC_IDX], rax
    test rax, rax
    jz .Lse_fail
    mov rdi, r13
    mov esi, [rbx + SC_W]
    imul esi, [rbx + SC_H]
    mov edx, r14d
    mov rcx, [rbx + SC_IDX]
    lea r8, [rbx + SC_PAL]
    call img_quantize
    mov [rbx + SC_NCOL], eax
    test eax, eax
    jz .Lse_free_fail
    mov rdi, rbx
    mov rsi, r12
    call six_header                   # -> rax = cursor, 0 on overflow
    test rax, rax
    jz .Lse_free_fail
    mov r12, rax
    xor r13d, r13d                    # band top row
.Lse_band:
    cmp r13d, [rbx + SC_H]
    jge .Lse_tail
    mov rdi, rbx
    mov rsi, r12
    mov edx, r13d
    call six_band                     # -> rax = cursor, 0 on overflow
    test rax, rax
    jz .Lse_free_fail
    mov r12, rax
    add r13d, 6
    jmp .Lse_band
.Lse_tail:
    mov word ptr [r12], 0x5C1B        # ESC backslash (header left >= 64 bytes of slack)
    add r12, 2
    mov rdi, [rbx + SC_IDX]
    call mem_free
    mov rax, r12
    sub rax, r15
    jmp .Lse_ret
.Lse_free_fail:
    mov rdi, [rbx + SC_IDX]
    call mem_free
.Lse_fail:
    xor eax, eax
.Lse_ret:
    add rsp, SC_SIZE + 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: uint8_t *six_header(SixCtx *c, uint8_t *p) -- DCS, raster size and color registers
six_header:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov rbx, rsi
    lea rax, [rbx + 64]
    cmp rax, [r12 + SC_END]
    ja .Lsh_ovf
    lea rsi, [rip + str_six_head]
1:  movzx eax, byte ptr [rsi]
    test eax, eax
    jz 2f
    mov [rbx], al
    inc rbx
    inc rsi
    jmp 1b
2:  mov edi, [r12 + SC_W]
    call six_num
    mov byte ptr [rbx], ';'
    inc rbx
    mov edi, [r12 + SC_H]
    call six_num
    xor r13d, r13d
.Lsh_pal:
    cmp r13d, [r12 + SC_NCOL]
    jge .Lsh_done
    lea rax, [rbx + 64]
    cmp rax, [r12 + SC_END]
    ja .Lsh_ovf
    mov byte ptr [rbx], '#'
    inc rbx
    mov edi, r13d
    call six_num
    mov dword ptr [rbx], 0x3B323B     # ";2;"
    add rbx, 3
    mov eax, [r12 + SC_PAL + r13 * 4]
    mov ecx, 16
    call six_pct
    mov byte ptr [rbx], ';'
    inc rbx
    mov eax, [r12 + SC_PAL + r13 * 4]
    mov ecx, 8
    call six_pct
    mov byte ptr [rbx], ';'
    inc rbx
    mov eax, [r12 + SC_PAL + r13 * 4]
    xor ecx, ecx
    call six_pct
    inc r13d
    jmp .Lsh_pal
.Lsh_ovf:
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    ret
.Lsh_done:
    mov rax, rbx
    pop r13
    pop r12
    pop rbx
    ret

# Internal: append channel (eax >> cl & 255) as 0..100 percent at rbx
six_pct:
    shr eax, cl
    and eax, 0xFF
    imul eax, eax, 100
    add eax, 127
    xor edx, edx
    mov ecx, 255
    div ecx
    mov edi, eax
    jmp six_num

# Internal: append decimal edi at rbx (advances rbx)
six_num:
    sub rsp, 8
    mov rsi, rbx
    call u64_to_dec
    add rbx, rax
    add rsp, 8
    ret

# Internal: uint8_t *six_band(SixCtx *c, uint8_t *p, int y0) -- one six-row band, 0 on overflow
six_band:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov rbx, rsi
    mov r13d, edx
    mov rdi, r12
    mov esi, r13d
    call six_mark_used                # -> eax = rows in band
    mov r15d, eax
    xor r14d, r14d                    # color
.Lsb_col:
    cmp r14d, [r12 + SC_NCOL]
    jge .Lsb_end
    cmp byte ptr [r12 + SC_USED + r14], 0
    je .Lsb_next
    mov eax, [r12 + SC_W]             # room for this color line (worst case)
    add rax, 32
    add rax, rbx
    cmp rax, [r12 + SC_END]
    ja .Lsb_fail
    mov byte ptr [rbx], '#'
    inc rbx
    mov edi, r14d
    call six_num
    mov rdi, r12
    mov esi, r13d
    mov edx, r15d
    mov ecx, r14d
    mov r8, rbx
    call six_line                     # -> rax = cursor
    mov rbx, rax
    mov byte ptr [rbx], '$'           # carriage return: next color overprints the band
    inc rbx
.Lsb_next:
    inc r14d
    jmp .Lsb_col
.Lsb_end:
    lea rax, [rbx + 64]
    cmp rax, [r12 + SC_END]
    ja .Lsb_fail
    mov byte ptr [rbx], '-'           # next band
    lea rax, [rbx + 1]
    jmp .Lsb_ret
.Lsb_fail:
    xor eax, eax
.Lsb_ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: int six_mark_used(SixCtx *c, int y0) -- used[] for the band, returns its row count
six_mark_used:
    push rbx
    mov rbx, rdi
    lea rdi, [rbx + SC_USED]
    push rsi
    mov esi, 256
    call mem_zero
    pop rsi
    mov eax, [rbx + SC_H]
    sub eax, esi
    cmp eax, 6
    jle 1f
    mov eax, 6
1:  mov ecx, esi
    imul ecx, [rbx + SC_W]
    mov rdx, [rbx + SC_IDX]
    add rdx, rcx                      # band start
    mov ecx, eax
    imul ecx, [rbx + SC_W]            # band bytes
2:  test ecx, ecx
    jz 3f
    movzx r8d, byte ptr [rdx]
    mov byte ptr [rbx + SC_USED + r8], 1
    inc rdx
    dec ecx
    jmp 2b
3:  pop rbx
    ret

# Internal: uint8_t *six_line(SixCtx *c, int y0, int rows, int color, uint8_t *p) -- RLE sixels
six_line:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, r8                       # out
    mov r12, rdi
    mov r13d, edx                     # rows
    mov r14d, ecx                     # color
    mov eax, esi
    imul eax, [r12 + SC_W]
    mov r15, [r12 + SC_IDX]
    add r15, rax                      # band start
    xor r9d, r9d                      # x
    mov r10d, -1                      # run char
    xor r11d, r11d                    # run length
.Lsl_x:
    cmp r9d, [r12 + SC_W]
    jge .Lsl_end
    xor edx, edx                      # sixel bits
    xor ecx, ecx
    lea rsi, [r15 + r9]
.Lsl_k:
    cmp ecx, r13d
    jge .Lsl_char
    movzx eax, byte ptr [rsi]
    cmp eax, r14d
    jne 1f
    bts edx, ecx
1:  mov eax, [r12 + SC_W]
    add rsi, rax
    inc ecx
    jmp .Lsl_k
.Lsl_char:
    add edx, 63
    cmp edx, r10d
    jne .Lsl_flush
    inc r11d
    inc r9d
    jmp .Lsl_x
.Lsl_flush:
    call six_run
    mov r10d, edx
    mov r11d, 1
    inc r9d
    jmp .Lsl_x
.Lsl_end:
    cmp r10d, 63                      # trailing empty sixels are implicit
    je 2f
    call six_run
2:  mov rax, rbx
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: emit run (char r10d, length r11d) at rbx; keeps edx, r9-r11
six_run:
    test r11d, r11d
    jz .Lsr_ret
    cmp r11d, 3
    jbe .Lsr_plain
    push rdx
    push r9
    push r10
    push r11
    mov byte ptr [rbx], '!'
    inc rbx
    mov edi, r11d
    call six_num
    pop r11
    pop r10
    pop r9
    pop rdx
    mov [rbx], r10b
    inc rbx
    ret
.Lsr_plain:
    mov ecx, r11d
1:  mov [rbx], r10b
    inc rbx
    dec ecx
    jnz 1b
.Lsr_ret:
    ret
