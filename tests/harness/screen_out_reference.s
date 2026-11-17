# Frozen reference oracle: the hand-written asm that src/tui/screen*.c replaced (tests/test_c_screen.py diffs against it)
# ScreenBuffer Class (Double-Buffered TrueColor ANSI Terminal Renderer) — screen out (split from screen.s)

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .rodata

# 0..255 -> {len, d0, d1, d2}: RGB SGR digits without division
u8_dec_tbl:
    .byte 1, 48, 0, 0
    .byte 1, 49, 0, 0
    .byte 1, 50, 0, 0
    .byte 1, 51, 0, 0
    .byte 1, 52, 0, 0
    .byte 1, 53, 0, 0
    .byte 1, 54, 0, 0
    .byte 1, 55, 0, 0
    .byte 1, 56, 0, 0
    .byte 1, 57, 0, 0
    .byte 2, 49, 48, 0
    .byte 2, 49, 49, 0
    .byte 2, 49, 50, 0
    .byte 2, 49, 51, 0
    .byte 2, 49, 52, 0
    .byte 2, 49, 53, 0
    .byte 2, 49, 54, 0
    .byte 2, 49, 55, 0
    .byte 2, 49, 56, 0
    .byte 2, 49, 57, 0
    .byte 2, 50, 48, 0
    .byte 2, 50, 49, 0
    .byte 2, 50, 50, 0
    .byte 2, 50, 51, 0
    .byte 2, 50, 52, 0
    .byte 2, 50, 53, 0
    .byte 2, 50, 54, 0
    .byte 2, 50, 55, 0
    .byte 2, 50, 56, 0
    .byte 2, 50, 57, 0
    .byte 2, 51, 48, 0
    .byte 2, 51, 49, 0
    .byte 2, 51, 50, 0
    .byte 2, 51, 51, 0
    .byte 2, 51, 52, 0
    .byte 2, 51, 53, 0
    .byte 2, 51, 54, 0
    .byte 2, 51, 55, 0
    .byte 2, 51, 56, 0
    .byte 2, 51, 57, 0
    .byte 2, 52, 48, 0
    .byte 2, 52, 49, 0
    .byte 2, 52, 50, 0
    .byte 2, 52, 51, 0
    .byte 2, 52, 52, 0
    .byte 2, 52, 53, 0
    .byte 2, 52, 54, 0
    .byte 2, 52, 55, 0
    .byte 2, 52, 56, 0
    .byte 2, 52, 57, 0
    .byte 2, 53, 48, 0
    .byte 2, 53, 49, 0
    .byte 2, 53, 50, 0
    .byte 2, 53, 51, 0
    .byte 2, 53, 52, 0
    .byte 2, 53, 53, 0
    .byte 2, 53, 54, 0
    .byte 2, 53, 55, 0
    .byte 2, 53, 56, 0
    .byte 2, 53, 57, 0
    .byte 2, 54, 48, 0
    .byte 2, 54, 49, 0
    .byte 2, 54, 50, 0
    .byte 2, 54, 51, 0
    .byte 2, 54, 52, 0
    .byte 2, 54, 53, 0
    .byte 2, 54, 54, 0
    .byte 2, 54, 55, 0
    .byte 2, 54, 56, 0
    .byte 2, 54, 57, 0
    .byte 2, 55, 48, 0
    .byte 2, 55, 49, 0
    .byte 2, 55, 50, 0
    .byte 2, 55, 51, 0
    .byte 2, 55, 52, 0
    .byte 2, 55, 53, 0
    .byte 2, 55, 54, 0
    .byte 2, 55, 55, 0
    .byte 2, 55, 56, 0
    .byte 2, 55, 57, 0
    .byte 2, 56, 48, 0
    .byte 2, 56, 49, 0
    .byte 2, 56, 50, 0
    .byte 2, 56, 51, 0
    .byte 2, 56, 52, 0
    .byte 2, 56, 53, 0
    .byte 2, 56, 54, 0
    .byte 2, 56, 55, 0
    .byte 2, 56, 56, 0
    .byte 2, 56, 57, 0
    .byte 2, 57, 48, 0
    .byte 2, 57, 49, 0
    .byte 2, 57, 50, 0
    .byte 2, 57, 51, 0
    .byte 2, 57, 52, 0
    .byte 2, 57, 53, 0
    .byte 2, 57, 54, 0
    .byte 2, 57, 55, 0
    .byte 2, 57, 56, 0
    .byte 2, 57, 57, 0
    .byte 3, 49, 48, 48
    .byte 3, 49, 48, 49
    .byte 3, 49, 48, 50
    .byte 3, 49, 48, 51
    .byte 3, 49, 48, 52
    .byte 3, 49, 48, 53
    .byte 3, 49, 48, 54
    .byte 3, 49, 48, 55
    .byte 3, 49, 48, 56
    .byte 3, 49, 48, 57
    .byte 3, 49, 49, 48
    .byte 3, 49, 49, 49
    .byte 3, 49, 49, 50
    .byte 3, 49, 49, 51
    .byte 3, 49, 49, 52
    .byte 3, 49, 49, 53
    .byte 3, 49, 49, 54
    .byte 3, 49, 49, 55
    .byte 3, 49, 49, 56
    .byte 3, 49, 49, 57
    .byte 3, 49, 50, 48
    .byte 3, 49, 50, 49
    .byte 3, 49, 50, 50
    .byte 3, 49, 50, 51
    .byte 3, 49, 50, 52
    .byte 3, 49, 50, 53
    .byte 3, 49, 50, 54
    .byte 3, 49, 50, 55
    .byte 3, 49, 50, 56
    .byte 3, 49, 50, 57
    .byte 3, 49, 51, 48
    .byte 3, 49, 51, 49
    .byte 3, 49, 51, 50
    .byte 3, 49, 51, 51
    .byte 3, 49, 51, 52
    .byte 3, 49, 51, 53
    .byte 3, 49, 51, 54
    .byte 3, 49, 51, 55
    .byte 3, 49, 51, 56
    .byte 3, 49, 51, 57
    .byte 3, 49, 52, 48
    .byte 3, 49, 52, 49
    .byte 3, 49, 52, 50
    .byte 3, 49, 52, 51
    .byte 3, 49, 52, 52
    .byte 3, 49, 52, 53
    .byte 3, 49, 52, 54
    .byte 3, 49, 52, 55
    .byte 3, 49, 52, 56
    .byte 3, 49, 52, 57
    .byte 3, 49, 53, 48
    .byte 3, 49, 53, 49
    .byte 3, 49, 53, 50
    .byte 3, 49, 53, 51
    .byte 3, 49, 53, 52
    .byte 3, 49, 53, 53
    .byte 3, 49, 53, 54
    .byte 3, 49, 53, 55
    .byte 3, 49, 53, 56
    .byte 3, 49, 53, 57
    .byte 3, 49, 54, 48
    .byte 3, 49, 54, 49
    .byte 3, 49, 54, 50
    .byte 3, 49, 54, 51
    .byte 3, 49, 54, 52
    .byte 3, 49, 54, 53
    .byte 3, 49, 54, 54
    .byte 3, 49, 54, 55
    .byte 3, 49, 54, 56
    .byte 3, 49, 54, 57
    .byte 3, 49, 55, 48
    .byte 3, 49, 55, 49
    .byte 3, 49, 55, 50
    .byte 3, 49, 55, 51
    .byte 3, 49, 55, 52
    .byte 3, 49, 55, 53
    .byte 3, 49, 55, 54
    .byte 3, 49, 55, 55
    .byte 3, 49, 55, 56
    .byte 3, 49, 55, 57
    .byte 3, 49, 56, 48
    .byte 3, 49, 56, 49
    .byte 3, 49, 56, 50
    .byte 3, 49, 56, 51
    .byte 3, 49, 56, 52
    .byte 3, 49, 56, 53
    .byte 3, 49, 56, 54
    .byte 3, 49, 56, 55
    .byte 3, 49, 56, 56
    .byte 3, 49, 56, 57
    .byte 3, 49, 57, 48
    .byte 3, 49, 57, 49
    .byte 3, 49, 57, 50
    .byte 3, 49, 57, 51
    .byte 3, 49, 57, 52
    .byte 3, 49, 57, 53
    .byte 3, 49, 57, 54
    .byte 3, 49, 57, 55
    .byte 3, 49, 57, 56
    .byte 3, 49, 57, 57
    .byte 3, 50, 48, 48
    .byte 3, 50, 48, 49
    .byte 3, 50, 48, 50
    .byte 3, 50, 48, 51
    .byte 3, 50, 48, 52
    .byte 3, 50, 48, 53
    .byte 3, 50, 48, 54
    .byte 3, 50, 48, 55
    .byte 3, 50, 48, 56
    .byte 3, 50, 48, 57
    .byte 3, 50, 49, 48
    .byte 3, 50, 49, 49
    .byte 3, 50, 49, 50
    .byte 3, 50, 49, 51
    .byte 3, 50, 49, 52
    .byte 3, 50, 49, 53
    .byte 3, 50, 49, 54
    .byte 3, 50, 49, 55
    .byte 3, 50, 49, 56
    .byte 3, 50, 49, 57
    .byte 3, 50, 50, 48
    .byte 3, 50, 50, 49
    .byte 3, 50, 50, 50
    .byte 3, 50, 50, 51
    .byte 3, 50, 50, 52
    .byte 3, 50, 50, 53
    .byte 3, 50, 50, 54
    .byte 3, 50, 50, 55
    .byte 3, 50, 50, 56
    .byte 3, 50, 50, 57
    .byte 3, 50, 51, 48
    .byte 3, 50, 51, 49
    .byte 3, 50, 51, 50
    .byte 3, 50, 51, 51
    .byte 3, 50, 51, 52
    .byte 3, 50, 51, 53
    .byte 3, 50, 51, 54
    .byte 3, 50, 51, 55
    .byte 3, 50, 51, 56
    .byte 3, 50, 51, 57
    .byte 3, 50, 52, 48
    .byte 3, 50, 52, 49
    .byte 3, 50, 52, 50
    .byte 3, 50, 52, 51
    .byte 3, 50, 52, 52
    .byte 3, 50, 52, 53
    .byte 3, 50, 52, 54
    .byte 3, 50, 52, 55
    .byte 3, 50, 52, 56
    .byte 3, 50, 52, 57
    .byte 3, 50, 53, 48
    .byte 3, 50, 53, 49
    .byte 3, 50, 53, 50
    .byte 3, 50, 53, 51
    .byte 3, 50, 53, 52
    .byte 3, 50, 53, 53

.section .text
.global out_u32
.global out_cstr
.global out_rgb_sgr

# void out_u32(ScreenBuffer *this, uint32_t val)
out_u32:
    push rbx
    mov rbx, rdi
    sub rsp, 24
    mov edi, esi
    mov rsi, rsp
    call u64_to_dec           # rax = len
    mov rcx, [rbx + ScreenBuffer.out_len]
    lea r9, [rcx + rax]
    cmp r9, [rbx + ScreenBuffer.out_cap]
    ja .Lou_ret_early
    mov rdx, [rbx + ScreenBuffer.out_buf]
    xor r8d, r8d
.Lou_cp:
    cmp r8, rax
    jae .Lou_done
    mov r9b, byte ptr [rsp + r8]
    mov byte ptr [rdx + rcx], r9b
    inc rcx
    inc r8
    jmp .Lou_cp
.Lou_done:
    mov [rbx + ScreenBuffer.out_len], rcx
.Lou_ret_early:
    add rsp, 24
    pop rbx
    ret

# void out_cstr(ScreenBuffer *this, const char *s, size_t len)
out_cstr:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rax, [rbx + ScreenBuffer.out_len]
    add rax, r13
    jc .Loc_ret
    cmp rax, [rbx + ScreenBuffer.out_cap]
    ja .Loc_ret
    mov rdi, [rbx + ScreenBuffer.out_buf]
    add rdi, [rbx + ScreenBuffer.out_len]
    mov rsi, r12
    mov rdx, r13
    call mem_copy
    add [rbx + ScreenBuffer.out_len], r13
.Loc_ret:
    pop r13
    pop r12
    pop rbx
    ret

# void out_rgb_sgr(ScreenBuffer *this, uint32_t rgb, int is_bg)
# Emits "\x1b[38;2;R;G;Bm" / "\x1b[48;2;R;G;Bm" straight into out_buf (caller reserved room);
# channel digits come from u8_dec_tbl (no division, no per-byte calls).
out_rgb_sgr:
    mov rax, [rdi + ScreenBuffer.out_len]
    lea r9, [rax + 24]
    cmp r9, [rdi + ScreenBuffer.out_cap]
    ja .Lors_ret
    mov rcx, [rdi + ScreenBuffer.out_buf]
    add rcx, rax                      # write cursor
    mov dword ptr [rcx], 0x38335B1B   # ESC [ 3 8
    test edx, edx
    jz .Lors_fg
    mov byte ptr [rcx + 2], '4'
.Lors_fg:
    mov word ptr [rcx + 4], 0x323B    # ; 2
    add rcx, 6
    lea r8, [rip + u8_dec_tbl]
    mov edx, 16                       # shift: R, G, B
.Lors_chan:
    mov byte ptr [rcx], ';'
    mov eax, esi
    push rcx
    mov ecx, edx
    shr eax, cl
    pop rcx
    and eax, 0xFF
    mov r9d, [r8 + rax * 4]           # len | d0 << 8 | d1 << 16 | d2 << 24
    mov eax, r9d
    shr eax, 8
    mov [rcx + 1], eax                # up to 3 digits (+1 scratch byte, overwritten)
    and r9d, 0xFF
    lea rcx, [rcx + r9 + 1]
    sub edx, 8
    jns .Lors_chan
    mov byte ptr [rcx], 'm'
    inc rcx
    sub rcx, [rdi + ScreenBuffer.out_buf]
    mov [rdi + ScreenBuffer.out_len], rcx
.Lors_ret:
    ret
