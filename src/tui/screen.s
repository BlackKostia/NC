# ScreenBuffer Class (Double-Buffered TrueColor ANSI Terminal Renderer)
# Inherits from Object.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .rodata
str_ScreenBuffer:
    .asciz "ScreenBuffer"

.global ScreenBuffer_vtbl
ScreenBuffer_vtbl:
    OBJECT_VTBL_SLOTS str_ScreenBuffer, Object_vtbl, ScreenBuffer._size, ScreenBuffer_dtor

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
seq_sync_begin: .ascii "\x1b[?2026h"
.equ seq_sync_begin_len, . - seq_sync_begin
seq_sync_end:   .ascii "\x1b[0m\x1b[?2026l"
.equ seq_sync_end_len, . - seq_sync_end

.section .text
.global ScreenBuffer_new
.global ScreenBuffer_dtor
.global ScreenBuffer_resize
.global ScreenBuffer_clear
.global ScreenBuffer_set_pen
.global ScreenBuffer_set_cell
.global ScreenBuffer_set_cell_pen
.global ScreenBuffer_fill_rect
.global ScreenBuffer_draw_box
.global ScreenBuffer_draw_hline
.global ScreenBuffer_draw_text
.global ScreenBuffer_draw_text_pad
.global ScreenBuffer_flush

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

    mov rax, rbx
    pop r13
    pop r12
    pop rbx
    ret

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

# void ScreenBuffer_resize(ScreenBuffer *this, int width, int height)
ScreenBuffer_resize:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    cmp esi, 1
    jge .Lsbr_w_ok
    mov esi, 1
.Lsbr_w_ok:
    cmp edx, 1
    jge .Lsbr_h_ok
    mov edx, 1
.Lsbr_h_ok:
    mov r12d, esi
    mov r13d, edx
    mov [rbx + ScreenBuffer.width], r12d
    mov [rbx + ScreenBuffer.height], r13d
    mov dword ptr [rbx + ScreenBuffer.force_full], 1

    movsxd rax, r12d
    movsxd rcx, r13d
    imul rax, rcx             # needed cell count
    cmp rax, [rbx + ScreenBuffer.cell_cap]
    jbe .Lsbr_done

    # Allocate front & back with a little slack (+256 cells)
    add rax, 256
    push rax
    shl rax, 4                # * 16 bytes per Cell
    mov rdi, [rbx + ScreenBuffer.front]
    mov rsi, rax
    call mem_realloc
    test rax, rax
    jz .Lsbr_pop_fail
    mov [rbx + ScreenBuffer.front], rax

    mov rax, [rsp]
    shl rax, 4
    mov rdi, [rbx + ScreenBuffer.back]
    mov rsi, rax
    call mem_realloc
    test rax, rax
    jz .Lsbr_pop_fail
    mov [rbx + ScreenBuffer.back], rax

    pop rax
    mov [rbx + ScreenBuffer.cell_cap], rax
    jmp .Lsbr_done

.Lsbr_pop_fail:
    pop rax
.Lsbr_done:
    pop r13
    pop r12
    pop rbx
    ret

# void ScreenBuffer_clear(ScreenBuffer *this, uint32_t fg, uint32_t bg)
ScreenBuffer_clear:
    mov eax, [rdi + ScreenBuffer.width]
    imul eax, [rdi + ScreenBuffer.height]
    test eax, eax
    jle .Lsbc_done
    mov rcx, [rdi + ScreenBuffer.back]
    test rcx, rcx
    jz .Lsbc_done
    mov r8d, ' '
.Lsbc_loop:
    mov [rcx + Cell.ch], r8d
    mov [rcx + Cell.fg], esi
    mov [rcx + Cell.bg], edx
    mov dword ptr [rcx + Cell.attrs], ATTR_NONE
    add rcx, Cell._size
    dec eax
    jnz .Lsbc_loop
.Lsbc_done:
    ret

# void ScreenBuffer_set_pen(ScreenBuffer *this, uint32_t fg, uint32_t bg, uint32_t attrs)
ScreenBuffer_set_pen:
    mov [rdi + ScreenBuffer.pen_fg], esi
    mov [rdi + ScreenBuffer.pen_bg], edx
    mov [rdi + ScreenBuffer.pen_attrs], ecx
    ret

# void ScreenBuffer_set_cell(ScreenBuffer *this, int x, int y, uint32_t cp, uint32_t fg, uint32_t bg)
ScreenBuffer_set_cell:
    test esi, esi
    js .Lscell_done
    test edx, edx
    js .Lscell_done
    cmp esi, [rdi + ScreenBuffer.width]
    jge .Lscell_done
    cmp edx, [rdi + ScreenBuffer.height]
    jge .Lscell_done

    mov eax, edx
    imul eax, [rdi + ScreenBuffer.width]
    add eax, esi
    movsxd rax, eax
    shl rax, 4
    add rax, [rdi + ScreenBuffer.back]
    mov [rax + Cell.ch], ecx
    mov [rax + Cell.fg], r8d
    mov [rax + Cell.bg], r9d
    mov dword ptr [rax + Cell.attrs], ATTR_NONE
.Lscell_done:
    ret

# void ScreenBuffer_set_cell_pen(ScreenBuffer *this, int x, int y, uint32_t cp)
ScreenBuffer_set_cell_pen:
    test esi, esi
    js .Lscp_done
    test edx, edx
    js .Lscp_done
    cmp esi, [rdi + ScreenBuffer.width]
    jge .Lscp_done
    cmp edx, [rdi + ScreenBuffer.height]
    jge .Lscp_done

    mov eax, edx
    imul eax, [rdi + ScreenBuffer.width]
    add eax, esi
    movsxd rax, eax
    shl rax, 4
    add rax, [rdi + ScreenBuffer.back]
    mov [rax + Cell.ch], ecx
    mov r8d, [rdi + ScreenBuffer.pen_fg]
    mov r9d, [rdi + ScreenBuffer.pen_bg]
    mov r10d, [rdi + ScreenBuffer.pen_attrs]
    mov [rax + Cell.fg], r8d
    mov [rax + Cell.bg], r9d
    mov [rax + Cell.attrs], r10d
.Lscp_done:
    ret

# void ScreenBuffer_fill_rect(ScreenBuffer *this, int x, int y, int w, int h, uint32_t cp)
# Uses current pen colors/attrs!
ScreenBuffer_fill_rect:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi              # this
    mov r12d, esi             # x
    mov r13d, edx             # y
    mov r14d, ecx             # w
    mov r15d, r8d             # h
    push r9                   # cp

    test r14d, r14d
    jle .Lsfr_done
    test r15d, r15d
    jle .Lsfr_done

    xor esi, esi              # dy = 0
.Lsfr_y:
    cmp esi, r15d
    jge .Lsfr_done
    xor edx, edx              # dx = 0
.Lsfr_x:
    cmp edx, r14d
    jge .Lsfr_next_y
    push rsi
    push rdx
    lea eax, [r12d + edx]     # px
    lea r8d, [r13d + esi]     # py
    mov rdi, rbx
    mov esi, eax
    mov edx, r8d
    mov ecx, [rsp + 16]       # cp
    call ScreenBuffer_set_cell_pen
    pop rdx
    pop rsi
    inc edx
    jmp .Lsfr_x
.Lsfr_next_y:
    inc esi
    jmp .Lsfr_y

.Lsfr_done:
    pop r9
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# void ScreenBuffer_draw_hline(ScreenBuffer *this, int x, int y, int len, uint32_t cp)
ScreenBuffer_draw_hline:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    mov r12d, esi             # x
    mov r13d, edx             # y
    mov r14d, ecx             # len
    mov r15d, r8d             # cp
    xor ecx, ecx
.Lsdh_loop:
    cmp ecx, r14d
    jge .Lsdh_done
    push rcx
    mov rdi, rbx
    lea esi, [r12d + ecx]
    mov edx, r13d
    mov ecx, r15d
    call ScreenBuffer_set_cell_pen
    pop rcx
    inc ecx
    jmp .Lsdh_loop
.Lsdh_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# void ScreenBuffer_draw_box(ScreenBuffer *this, int x, int y, int w, int h, int fill_interior)
# Uses current pen! Draws rounded corners (╭╮╰╯─│). If fill_interior != 0, fills interior spaces.
ScreenBuffer_draw_box:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16
    mov rbx, rdi              # this
    mov r12d, esi             # x
    mov r13d, edx             # y
    mov r14d, ecx             # w
    mov r15d, r8d             # h
    mov [rsp], r9d            # fill_interior

    cmp r14d, 2
    jl .Lsdb_done
    cmp r15d, 2
    jl .Lsdb_done

    # Optionally fill interior first
    cmp dword ptr [rsp], 0
    je .Lsdb_corners
    mov rdi, rbx
    lea esi, [r12d + 1]
    lea edx, [r13d + 1]
    lea ecx, [r14d - 2]
    lea r8d, [r15d - 2]
    mov r9d, ' '
    call ScreenBuffer_fill_rect

.Lsdb_corners:
    # Top-left ╭
    mov rdi, rbx
    mov esi, r12d
    mov edx, r13d
    mov ecx, CH_BOX_TL
    call ScreenBuffer_set_cell_pen

    # Top-right ╮
    mov rdi, rbx
    lea esi, [r12d + r14d - 1]
    mov edx, r13d
    mov ecx, CH_BOX_TR
    call ScreenBuffer_set_cell_pen

    # Bottom-left ╰
    mov rdi, rbx
    mov esi, r12d
    lea edx, [r13d + r15d - 1]
    mov ecx, CH_BOX_BL
    call ScreenBuffer_set_cell_pen

    # Bottom-right ╯
    mov rdi, rbx
    lea esi, [r12d + r14d - 1]
    lea edx, [r13d + r15d - 1]
    mov ecx, CH_BOX_BR
    call ScreenBuffer_set_cell_pen

    # Top horizontal line
    mov rdi, rbx
    lea esi, [r12d + 1]
    mov edx, r13d
    lea ecx, [r14d - 2]
    mov r8d, CH_BOX_H
    call ScreenBuffer_draw_hline

    # Bottom horizontal line
    mov rdi, rbx
    lea esi, [r12d + 1]
    lea edx, [r13d + r15d - 1]
    lea ecx, [r14d - 2]
    mov r8d, CH_BOX_H
    call ScreenBuffer_draw_hline

    # Left & right vertical edges
    mov dword ptr [rsp + 4], 1
.Lsdb_vloop:
    mov eax, [rsp + 4]
    lea ecx, [r15d - 1]
    cmp eax, ecx
    jge .Lsdb_done

    mov rdi, rbx
    mov esi, r12d
    lea edx, [r13d + eax]
    mov ecx, CH_BOX_V
    call ScreenBuffer_set_cell_pen

    mov eax, [rsp + 4]
    mov rdi, rbx
    lea esi, [r12d + r14d - 1]
    lea edx, [r13d + eax]
    mov ecx, CH_BOX_V
    call ScreenBuffer_set_cell_pen

    inc dword ptr [rsp + 4]
    jmp .Lsdb_vloop

.Lsdb_done:
    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# int ScreenBuffer_draw_text(ScreenBuffer *this, int x, int y, const char *utf8, int max_cols)
# Uses current pen! Returns display columns written.
ScreenBuffer_draw_text:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16
    mov rbx, rdi              # this
    mov r12d, esi             # cur_x
    mov r13d, edx             # y
    mov r14, rcx              # str ptr
    mov r15d, r8d             # max_cols
    mov dword ptr [rsp], 0    # cols written

    test r14, r14
    jz .Lsdt_done
    test r15d, r15d
    jle .Lsdt_done

.Lsdt_loop:
    mov rdi, r14
    call utf8_decode          # eax = cp, rdx = bytes
    test rdx, rdx
    jz .Lsdt_done
    add r14, rdx

    # Replace control chars < 0x20 or 0x7F with space
    cmp eax, 0x20
    jae .Lsdt_chk_del
    mov eax, ' '
    jmp .Lsdt_width
.Lsdt_chk_del:
    cmp eax, 0x7F
    jne .Lsdt_width
    mov eax, ' '

.Lsdt_width:
    mov [rsp + 4], eax        # save cp
    mov edi, eax
    call utf8_char_width      # eax = 0, 1, or 2
    test eax, eax
    jz .Lsdt_loop             # skip zero-width combining marks

    mov ecx, [rsp]            # cols written so far
    add ecx, eax
    cmp ecx, r15d
    jg .Lsdt_done

    mov [rsp + 8], eax        # save width (1 or 2)
    mov rdi, rbx
    mov esi, r12d
    mov edx, r13d
    mov ecx, [rsp + 4]        # cp
    call ScreenBuffer_set_cell_pen

    cmp dword ptr [rsp + 8], 2
    jne .Lsdt_adv1
    # Mark second column as wide tail
    mov rdi, rbx
    lea esi, [r12d + 1]
    mov edx, r13d
    mov ecx, CELL_WIDE_TAIL
    call ScreenBuffer_set_cell_pen
    add r12d, 2
    add dword ptr [rsp], 2
    jmp .Lsdt_loop

.Lsdt_adv1:
    inc r12d
    inc dword ptr [rsp]
    jmp .Lsdt_loop

.Lsdt_done:
    mov eax, [rsp]
    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# void ScreenBuffer_draw_text_pad(ScreenBuffer *this, int x, int y, const char *utf8, int width)
# Draws utf8 up to `width` columns and pads remaining columns with spaces using current pen.
ScreenBuffer_draw_text_pad:
    push rbx
    push r12
    push r13
    push r14
    mov rbx, rdi
    mov r12d, esi             # x
    mov r13d, edx             # y
    mov r14d, r8d             # width
    call ScreenBuffer_draw_text
    # eax = cols written
.Lsdtp_pad:
    cmp eax, r14d
    jge .Lsdtp_done
    push rax
    mov rdi, rbx
    lea esi, [r12d + eax]
    mov edx, r13d
    mov ecx, ' '
    call ScreenBuffer_set_cell_pen
    pop rax
    inc eax
    jmp .Lsdtp_pad
.Lsdtp_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# --- Internal Output Buffer Helpers for ScreenBuffer_flush ---
# void out_ensure(ScreenBuffer *this, size_t need)
out_ensure:
    mov rax, [rdi + ScreenBuffer.out_len]
    add rax, rsi
    cmp rax, [rdi + ScreenBuffer.out_cap]
    jbe .Loe_ok
    push rbx
    mov rbx, rdi
    mov rsi, [rbx + ScreenBuffer.out_cap]
    shl rsi, 1
    add rsi, 4096
    mov [rbx + ScreenBuffer.out_cap], rsi
    mov rdi, [rbx + ScreenBuffer.out_buf]
    call mem_realloc
    test rax, rax
    jz .Loe_fail
    mov [rbx + ScreenBuffer.out_buf], rax
.Loe_fail:
    pop rbx
.Loe_ok:
    ret

# void out_byte(ScreenBuffer *this, uint8_t b)
out_byte:
    mov rax, [rdi + ScreenBuffer.out_len]
    mov rcx, [rdi + ScreenBuffer.out_buf]
    mov byte ptr [rcx + rax], sil
    inc rax
    mov [rdi + ScreenBuffer.out_len], rax
    ret

# void out_u32(ScreenBuffer *this, uint32_t val)
out_u32:
    push rbx
    mov rbx, rdi
    sub rsp, 24
    mov edi, esi
    mov rsi, rsp
    call u64_to_dec           # rax = len
    mov rcx, [rbx + ScreenBuffer.out_len]
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
    mov rdi, [rbx + ScreenBuffer.out_buf]
    add rdi, [rbx + ScreenBuffer.out_len]
    mov rsi, r12
    mov rdx, r13
    call mem_copy
    add [rbx + ScreenBuffer.out_len], r13
    pop r13
    pop r12
    pop rbx
    ret

# void out_rgb_sgr(ScreenBuffer *this, uint32_t rgb, int is_bg)
# Emits "\x1b[38;2;R;G;Bm" / "\x1b[48;2;R;G;Bm" straight into out_buf (caller reserved room);
# channel digits come from u8_dec_tbl (no division, no per-byte calls).
out_rgb_sgr:
    mov rax, [rdi + ScreenBuffer.out_len]
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
    cmp edi, 0x20
    jae .Lfl_cp_ok
    mov edi, ' '
.Lfl_cp_ok:
    mov rsi, [rbx + ScreenBuffer.out_buf]
    add rsi, [rbx + ScreenBuffer.out_len]
    push rdi
    call utf8_encode          # rax = 1..4 bytes
    add [rbx + ScreenBuffer.out_len], rax
    pop rdi

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
    mov rsi, [rbx + ScreenBuffer.out_buf]
    mov rdx, [rbx + ScreenBuffer.out_len]
    call sys_write_all
    mov qword ptr [rbx + ScreenBuffer.out_len], 0

.Lfl_nothing:
    mov qword ptr [rbx + ScreenBuffer.out_len], 0
.Lfl_done:
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
