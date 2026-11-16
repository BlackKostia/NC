# ScreenBuffer Class (Double-Buffered TrueColor ANSI Terminal Renderer) — screen buffer (split from screen.s)

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .text
.global ScreenBuffer_resize
.global ScreenBuffer_clear
.global ScreenBuffer_set_pen
.global ScreenBuffer_set_cell
.global ScreenBuffer_set_cell_pen
.global ScreenBuffer_fill_rect
.global ScreenBuffer_draw_hline

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

    movsxd rax, r12d
    movsxd rcx, r13d
    imul rax, rcx             # needed cell count
    cmp rax, [rbx + ScreenBuffer.cell_cap]
    jbe .Lsbr_commit

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
.Lsbr_commit:
    mov [rbx + ScreenBuffer.width], r12d
    mov [rbx + ScreenBuffer.height], r13d
    mov dword ptr [rbx + ScreenBuffer.force_full], 1
    xor eax, eax
    jmp .Lsbr_done

.Lsbr_pop_fail:
    pop rax
    mov rax, -ENOMEM
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
