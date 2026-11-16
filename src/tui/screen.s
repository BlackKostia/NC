# ScreenBuffer Class (Double-Buffered TrueColor ANSI Terminal Renderer)
# Inherits from Object.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .rodata
str_ScreenBuffer:
    .asciz "ScreenBuffer"

ScreenBuffer_vtbl:
    OBJECT_VTBL_SLOTS str_ScreenBuffer, Object_vtbl, ScreenBuffer._size, ScreenBuffer_dtor
seq_sync_begin: .ascii "\x1b[?2026h"
.equ seq_sync_begin_len, . - seq_sync_begin
seq_sync_end:   .ascii "\x1b[0m\x1b[?2026l"
.equ seq_sync_end_len, . - seq_sync_end

.section .text
.global ScreenBuffer_new
.global ScreenBuffer_dtor
.global ScreenBuffer_flush
.global ScreenBuffer_vtbl

# ScreenBuffer *ScreenBuffer_new(int width, int height)
ScreenBuffer_new:
    push rbx
    push r12
    push r13
    mov r12d, edi             # width
    mov r13d, esi             # height

    NEW_OBJ ScreenBuffer_vtbl, ScreenBuffer._size
    test rax, rax
    jz .Lsbn_fail
    mov rbx, rax

    mov edi, OUT_BUF_INIT_CAP
    call mem_alloc
    test rax, rax
    jz .Lsbn_fail_free
    mov [rbx + ScreenBuffer.out_buf], rax
    mov qword ptr [rbx + ScreenBuffer.out_cap], OUT_BUF_INIT_CAP
    mov qword ptr [rbx + ScreenBuffer.out_len], 0

    mov rdi, rbx
    mov esi, r12d
    mov edx, r13d
    call ScreenBuffer_resize
    test eax, eax
    js .Lsbn_fail_destroy

    mov rax, rbx
    pop r13
    pop r12
    pop rbx
    ret

.Lsbn_fail_destroy:
    mov rdi, rbx
    call ScreenBuffer_dtor
.Lsbn_fail_free:
    mov rdi, rbx
    call mem_free
.Lsbn_fail:
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    ret

# void ScreenBuffer_dtor(ScreenBuffer *this)
ScreenBuffer_dtor:
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + ScreenBuffer.front]
    call mem_free
    mov rdi, [rbx + ScreenBuffer.back]
    call mem_free
    mov rdi, [rbx + ScreenBuffer.out_buf]
    call mem_free
    mov qword ptr [rbx + ScreenBuffer.front], 0
    mov qword ptr [rbx + ScreenBuffer.back], 0
    mov qword ptr [rbx + ScreenBuffer.out_buf], 0
    pop rbx
    ret

# void ScreenBuffer_flush(ScreenBuffer *this)
ScreenBuffer_flush:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    # Stack frame:
    # [rsp+0]  cur_fg (4)
    # [rsp+4]  cur_bg (4)
    # [rsp+8]  cur_attrs (4)
    # [rsp+12] last_x (4)
    # [rsp+16] last_y (4)
    # [rsp+20] y (4)
    # [rsp+24] x (4)
    # [rsp+28] width (4)
    # [rsp+32] height (4)

    mov rbx, rdi              # this
    mov qword ptr [rbx + ScreenBuffer.out_len], 0
    # DEC 2026 synchronized update: the terminal presents the whole frame atomically
    mov rdi, rbx
    mov esi, 64
    call out_ensure
    mov rdi, rbx
    lea rsi, [rip + seq_sync_begin]
    mov edx, seq_sync_begin_len
    call out_cstr

    mov eax, [rbx + ScreenBuffer.width]
    mov ecx, [rbx + ScreenBuffer.height]
    mov [rsp + 28], eax
    mov [rsp + 32], ecx
    imul eax, ecx
    test eax, eax
    jle .Lfl_done

    cmp dword ptr [rbx + ScreenBuffer.force_full], 0
    je .Lfl_start_diff
    mov dword ptr [rbx + ScreenBuffer.force_full], 0
    # Invalidate front buffer (fill with 0xFF)
    mov rdi, [rbx + ScreenBuffer.front]
    mov esi, 0xFF
    mov edx, eax
    shl rdx, 4
    call mem_set

.Lfl_start_diff:
    mov dword ptr [rsp + 0], -1   # cur_fg
    mov dword ptr [rsp + 4], -1   # cur_bg
    mov dword ptr [rsp + 8], -1   # cur_attrs
    mov dword ptr [rsp + 12], -2  # last_x
    mov dword ptr [rsp + 16], -2  # last_y

    mov r12, [rbx + ScreenBuffer.back]
    mov r13, [rbx + ScreenBuffer.front]
    mov dword ptr [rsp + 20], 0   # y = 0

.Lfl_row:
    mov eax, [rsp + 20]
    cmp eax, [rsp + 32]
    jge .Lfl_finish
    mov dword ptr [rsp + 24], 0   # x = 0

.Lfl_col:
    # SIMD skip over unchanged cells (whole unchanged rows cost one PAL call)
    mov edx, [rsp + 28]
    sub edx, [rsp + 24]
    jle .Lfl_next_row
    mov rdi, r12
    mov rsi, r13
    call os_mem_mismatch16        # index of first differing Cell in the row remainder
    add [rsp + 24], eax
    shl rax, 4
    add r12, rax
    add r13, rax
    mov eax, [rsp + 24]
    cmp eax, [rsp + 28]
    jge .Lfl_next_row
    mov r8, [r12]
    mov r9, [r12 + 8]

.Lfl_dirty:
    # Update front cell
    mov [r13], r8
    mov [r13 + 8], r9

    # Skip CELL_WIDE_TAIL output
    cmp dword ptr [r12 + Cell.ch], CELL_WIDE_TAIL
    je .Lfl_next_cell

    # Reserve room for one cell (cursor move + SGR + 2 TrueColor sequences + UTF-8 <= 96 B)
    mov rdi, rbx
    mov esi, 128
    call out_ensure

    # Check if cursor move needed
    mov eax, [rsp + 20]       # y
    cmp eax, [rsp + 16]       # last_y
    jne .Lfl_move_cursor
    mov eax, [rsp + 12]       # last_x
    inc eax
    cmp eax, [rsp + 24]       # x
    je .Lfl_check_style

.Lfl_move_cursor:
    mov rdi, rbx
    mov esi, 0x1B
    call out_byte
    mov rdi, rbx
    mov esi, '['
    call out_byte
    mov rdi, rbx
    mov esi, [rsp + 20]
    inc esi                   # 1-based row
    call out_u32
    mov rdi, rbx
    mov esi, ';'
    call out_byte
    mov rdi, rbx
    mov esi, [rsp + 24]
    inc esi                   # 1-based col
    call out_u32
    mov rdi, rbx
    mov esi, 'H'
    call out_byte

.Lfl_check_style:
    mov r14d, [r12 + Cell.attrs]
    cmp r14d, [rsp + 8]
    je .Lfl_check_fg

    # Reset attrs and apply new ones
    mov rdi, rbx
    mov esi, 0x1B
    call out_byte
    mov rdi, rbx
    mov esi, '['
    call out_byte
    mov rdi, rbx
    mov esi, '0'
    call out_byte
    test r14d, ATTR_BOLD
    jz .Lfl_a_dim
    mov rdi, rbx
    mov esi, ';'
    call out_byte
    mov rdi, rbx
    mov esi, '1'
    call out_byte
.Lfl_a_dim:
    test r14d, ATTR_DIM
    jz .Lfl_a_ital
    mov rdi, rbx
    mov esi, ';'
    call out_byte
    mov rdi, rbx
    mov esi, '2'
    call out_byte
.Lfl_a_ital:
    test r14d, ATTR_ITALIC
    jz .Lfl_a_ul
    mov rdi, rbx
    mov esi, ';'
    call out_byte
    mov rdi, rbx
    mov esi, '3'
    call out_byte
.Lfl_a_ul:
    test r14d, ATTR_UNDERLINE
    jz .Lfl_a_rev
    mov rdi, rbx
    mov esi, ';'
    call out_byte
    mov rdi, rbx
    mov esi, '4'
    call out_byte
.Lfl_a_rev:
    test r14d, ATTR_REVERSE
    jz .Lfl_a_end
    mov rdi, rbx
    mov esi, ';'
    call out_byte
    mov rdi, rbx
    mov esi, '7'
    call out_byte
.Lfl_a_end:
    mov rdi, rbx
    mov esi, 'm'
    call out_byte
    mov [rsp + 8], r14d
    mov dword ptr [rsp + 0], -1   # force fg/bg re-emit after SGR 0
    mov dword ptr [rsp + 4], -1

.Lfl_check_fg:
    mov r14d, [r12 + Cell.fg]
    cmp r14d, [rsp + 0]
    je .Lfl_check_bg
    test r14d, 0x01000000
    jz .Lfl_check_bg
    mov rdi, rbx
    mov esi, r14d
    xor edx, edx
    call out_rgb_sgr
    mov [rsp + 0], r14d

.Lfl_check_bg:
    mov r15d, [r12 + Cell.bg]
    cmp r15d, [rsp + 4]
    je .Lfl_emit_char
    test r15d, 0x01000000
    jz .Lfl_emit_char
    mov rdi, rbx
    mov esi, r15d
    mov edx, 1
    call out_rgb_sgr
    mov [rsp + 4], r15d

.Lfl_emit_char:
    mov edi, [r12 + Cell.ch]
    cmp edi, 0x20; jae .Lfl_cp_ok
    mov edi, ' '
.Lfl_cp_ok:
    mov rax, [rbx + ScreenBuffer.out_len]; add rax, 4
    cmp rax, [rbx + ScreenBuffer.out_cap]; ja .Lfl_next_cell
    mov rsi, [rbx + ScreenBuffer.out_buf]
    add rsi, [rbx + ScreenBuffer.out_len]
    mov [rsp + 36], edi
    call utf8_encode          # rax = 1..4 bytes
    add [rbx + ScreenBuffer.out_len], rax
    mov edi, [rsp + 36]

    call utf8_char_width
    test eax, eax
    jnz .Lfl_w_ok
    mov eax, 1
.Lfl_w_ok:
    mov ecx, [rsp + 24]       # x
    lea ecx, [ecx + eax - 1]
    mov [rsp + 12], ecx       # last_x
    mov eax, [rsp + 20]
    mov [rsp + 16], eax       # last_y

.Lfl_next_cell:
    add r12, Cell._size
    add r13, Cell._size
    inc dword ptr [rsp + 24]
    jmp .Lfl_col

.Lfl_next_row:
    inc dword ptr [rsp + 20]
    jmp .Lfl_row

.Lfl_finish:
    mov rdx, [rbx + ScreenBuffer.out_len]
    cmp rdx, seq_sync_begin_len
    jbe .Lfl_nothing              # no cell changed: emit nothing at all

    # "\x1b[0m" + end of synchronized update
    mov rdi, rbx
    mov esi, 32
    call out_ensure
    mov rdi, rbx
    lea rsi, [rip + seq_sync_end]
    mov edx, seq_sync_end_len
    call out_cstr

    mov edi, STDOUT_FD
    mov rsi, [rbx + ScreenBuffer.out_buf]; mov rdx, [rbx + ScreenBuffer.out_len]
    call sys_write_all
    test rax, rax
    jns .Lfl_nothing
    mov dword ptr [rbx + ScreenBuffer.force_full], 1
.Lfl_nothing:
    mov qword ptr [rbx + ScreenBuffer.out_len], 0
.Lfl_done:
    add rsp, 48
    pop r15; pop r14; pop r13; pop r12; pop rbx
    ret
