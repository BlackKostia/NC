# ScreenBuffer Class (Double-Buffered TrueColor ANSI Terminal Renderer) — screen text (split from screen.s)

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .text
.global ScreenBuffer_draw_box
.global ScreenBuffer_draw_text
.global ScreenBuffer_draw_text_pad
.global out_ensure
.global out_byte

# void ScreenBuffer_draw_box(ScreenBuffer *this, int x, int y, int w, int h, int fill_interior)
# Uses current pen! Draws rounded corners (╭╮╰╯─│). If fill_interior != 0, fills interior spaces.
ScreenBuffer_draw_box:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16
    call ScreenBuffer_draw_box__this
    cmp r14d, 2
    jl .Lsdb_done
    cmp r15d, 2
    jl .Lsdb_done

    # Optionally fill interior first
    call ScreenBuffer_draw_box__optionally_fill_interior_first
    # Top-left ╭
    call ScreenBuffer_draw_box__top_left
    # Top-right ╮
    call ScreenBuffer_draw_box__top_right
    # Bottom-left ╰
    call ScreenBuffer_draw_box__bottom_left
    # Bottom-right ╯
    call ScreenBuffer_draw_box__bottom_right
    # Top horizontal line
    call ScreenBuffer_draw_box__top_horizontal_line
    # Bottom horizontal line
    call ScreenBuffer_draw_box__bottom_horizontal_line
    # Left & right vertical edges
    call ScreenBuffer_draw_box__left_right_vertical_edges
.Lsdb_done:
    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# ScreenBuffer_draw_box step: this (runs on the caller's frame)
ScreenBuffer_draw_box__this:
    lea rsp, [rsp - 8]
    mov rbx, rdi              # this
    mov r12d, esi             # x
    mov r13d, edx             # y
    mov r14d, ecx             # w
    mov r15d, r8d             # h
    mov [rsp + 16], r9d  # fill_interior

.LScreenBuffer_draw_box__this_ret:
    lea rsp, [rsp + 8]
    ret

# ScreenBuffer_draw_box step: Optionally fill interior first (runs on the caller's frame)
ScreenBuffer_draw_box__optionally_fill_interior_first:
    lea rsp, [rsp - 8]
    cmp dword ptr [rsp + 16], 0
    je .Lsdb_corners
    mov rdi, rbx
    lea esi, [r12d + 1]
    lea edx, [r13d + 1]
    lea ecx, [r14d - 2]
    lea r8d, [r15d - 2]
    mov r9d, ' '
    call ScreenBuffer_fill_rect

.Lsdb_corners:
.LScreenBuffer_draw_box__optionally_fill_interior_first_ret:
    lea rsp, [rsp + 8]
    ret

# ScreenBuffer_draw_box step: Top left (runs on the caller's frame)
ScreenBuffer_draw_box__top_left:
    lea rsp, [rsp - 8]
    mov rdi, rbx
    mov esi, r12d
    mov edx, r13d
    mov ecx, CH_BOX_TL
    call ScreenBuffer_set_cell_pen

.LScreenBuffer_draw_box__top_left_ret:
    lea rsp, [rsp + 8]
    ret

# ScreenBuffer_draw_box step: Top right (runs on the caller's frame)
ScreenBuffer_draw_box__top_right:
    lea rsp, [rsp - 8]
    mov rdi, rbx
    lea esi, [r12d + r14d - 1]
    mov edx, r13d
    mov ecx, CH_BOX_TR
    call ScreenBuffer_set_cell_pen

.LScreenBuffer_draw_box__top_right_ret:
    lea rsp, [rsp + 8]
    ret

# ScreenBuffer_draw_box step: Bottom left (runs on the caller's frame)
ScreenBuffer_draw_box__bottom_left:
    lea rsp, [rsp - 8]
    mov rdi, rbx
    mov esi, r12d
    lea edx, [r13d + r15d - 1]
    mov ecx, CH_BOX_BL
    call ScreenBuffer_set_cell_pen

.LScreenBuffer_draw_box__bottom_left_ret:
    lea rsp, [rsp + 8]
    ret

# ScreenBuffer_draw_box step: Bottom right (runs on the caller's frame)
ScreenBuffer_draw_box__bottom_right:
    lea rsp, [rsp - 8]
    mov rdi, rbx
    lea esi, [r12d + r14d - 1]
    lea edx, [r13d + r15d - 1]
    mov ecx, CH_BOX_BR
    call ScreenBuffer_set_cell_pen

.LScreenBuffer_draw_box__bottom_right_ret:
    lea rsp, [rsp + 8]
    ret

# ScreenBuffer_draw_box step: Top horizontal line (runs on the caller's frame)
ScreenBuffer_draw_box__top_horizontal_line:
    lea rsp, [rsp - 8]
    mov rdi, rbx
    lea esi, [r12d + 1]
    mov edx, r13d
    lea ecx, [r14d - 2]
    mov r8d, CH_BOX_H
    call ScreenBuffer_draw_hline

.LScreenBuffer_draw_box__top_horizontal_line_ret:
    lea rsp, [rsp + 8]
    ret

# ScreenBuffer_draw_box step: Bottom horizontal line (runs on the caller's frame)
ScreenBuffer_draw_box__bottom_horizontal_line:
    lea rsp, [rsp - 8]
    mov rdi, rbx
    lea esi, [r12d + 1]
    lea edx, [r13d + r15d - 1]
    lea ecx, [r14d - 2]
    mov r8d, CH_BOX_H
    call ScreenBuffer_draw_hline

.LScreenBuffer_draw_box__bottom_horizontal_line_ret:
    lea rsp, [rsp + 8]
    ret

# ScreenBuffer_draw_box step: Left right vertical edges (runs on the caller's frame)
ScreenBuffer_draw_box__left_right_vertical_edges:
    lea rsp, [rsp - 8]
    mov dword ptr [rsp + 4 + 16], 1
.Lsdb_vloop:
    mov eax, [rsp + 4 + 16]
    lea ecx, [r15d - 1]
    cmp eax, ecx
    jge .LScreenBuffer_draw_box__left_right_vertical_edges_ret

    mov rdi, rbx
    mov esi, r12d
    lea edx, [r13d + eax]
    mov ecx, CH_BOX_V
    call ScreenBuffer_set_cell_pen

    mov eax, [rsp + 4 + 16]
    mov rdi, rbx
    lea esi, [r12d + r14d - 1]
    lea edx, [r13d + eax]
    mov ecx, CH_BOX_V
    call ScreenBuffer_set_cell_pen

    inc dword ptr [rsp + 4 + 16]
    jmp .Lsdb_vloop

.LScreenBuffer_draw_box__left_right_vertical_edges_ret:
    lea rsp, [rsp + 8]
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
