# src/ui/du_render.s - Disk Usage (ncdu) badge & TrueColor percentage bar renderer
.intel_syntax noprefix

.include "pal.inc"
.include "classes.inc"

.section .rodata
du_pct_sfx: .asciz "% "

.section .text
.global fp_draw_du_badge
.global fp_draw_du_pane

.extern ScreenBuffer_set_pen
.extern ScreenBuffer_set_cell
.extern ScreenBuffer_fill_rect
.extern ScreenBuffer_draw_text
.extern DirModel_get_entry
.extern theme_get
.extern i18n_get
.extern format_size
.extern u64_to_dec
.extern utf8_display_width

# void fp_draw_du_badge(FilePane *fp, ScreenBuffer *sb)
fp_draw_du_badge:
    mov rax, [rdi + FilePane.model]
    cmp dword ptr [rax + DirModel.du_mode], 0
    je .Lfddb_ret
    push rbx; push r12; push r13; sub rsp, 8
    mov rbx, rdi; mov r12, rsi
    call theme_get; mov r13, rax
    call i18n_get; mov rcx, [rax + LangStrings.fp_du_badge]
    push rcx
    mov rdi, rcx; call utf8_display_width; mov r8d, eax
    mov rdi, r12; mov esi, [r13 + Theme.accent_fg]; mov edx, [r13 + Theme.accent]; mov ecx, ATTR_BOLD
    call ScreenBuffer_set_pen
    pop rcx
    mov esi, [rbx + Widget.x]; add esi, [rbx + Widget.w]; sub esi, r8d; sub esi, 3
    cmp esi, [rbx + Widget.x]; jle .Lfddb_out
    mov edx, [rbx + Widget.y]
    mov rdi, r12; call ScreenBuffer_draw_text
.Lfddb_out:
    add rsp, 8; pop r13; pop r12; pop rbx
.Lfddb_ret:
    ret

# void fp_draw_du_pane(FilePane *fp, ScreenBuffer *sb, Theme *th)
fp_draw_du_pane:
    mov rax, [rdi + FilePane.model]
    cmp dword ptr [rax + DirModel.du_mode], 0
    je .Lfddp_ret
    push rbx; push r12; push r13; push r14; push r15; sub rsp, 64
    mov rbx, rdi; mov r12, rsi; mov r13, rdx
    mov r14, rax              # model
    mov eax, [rbx + Widget.h]; sub eax, 5
    cmp eax, 1; jl .Lfddp_out
    mov [rsp], eax            # list_h
    mov dword ptr [rsp + 4], 0  # row
.Lfddp_row:
    mov eax, [rsp + 4]; cmp eax, [rsp]; jge .Lfddp_out
    add eax, [rbx + FilePane.scroll]
    cmp rax, [r14 + DirModel.count]; jae .Lfddp_out
    mov [rsp + 8], eax        # entry idx
    mov rdi, r14; mov esi, eax; call DirModel_get_entry
    test rax, rax; jz .Lfddp_next
    mov r15, rax
    test dword ptr [r15 + FileEntry.flags], FE_IS_PARENT; jnz .Lfddp_next

    # Set pen (cursor vs normal)
    call fp_draw_du_pane__set_pen
    # Draw size at col = w - 26
    call fp_draw_du_pane__draw_size_col
.Lfddp_next:
    inc dword ptr [rsp + 4]; jmp .Lfddp_row
.Lfddp_out:
    add rsp, 64; pop r15; pop r14; pop r13; pop r12; pop rbx
.Lfddp_ret:
    ret

# fp_draw_du_pane step: Set pen (runs on the caller's frame)
fp_draw_du_pane__set_pen:
    lea rsp, [rsp - 8]
    mov edx, [r13 + Theme.surface]
    mov eax, [rsp + 8 + 16]
    cmp eax, [rbx + FilePane.cursor]
    jne .Lfddp_pen
    mov edx, [r13 + Theme.cursor_inactive_bg]
    test dword ptr [rbx + Widget.flags], WF_FOCUSED
    jz .Lfddp_pen
    mov edx, [r13 + Theme.cursor_active_bg]
.Lfddp_pen:
    mov [rsp + 12 + 16], edx  # bg
    mov rdi, r12; mov esi, [r13 + Theme.text]; xor ecx, ecx
    call ScreenBuffer_set_pen
    mov esi, [rbx + Widget.x]; add esi, [rbx + Widget.w]; sub esi, 27
    mov edx, [rbx + Widget.y]; add edx, 3; add edx, [rsp + 4 + 16]
    mov rdi, r12; mov ecx, 25; mov r8d, 1; mov r9d, ' '
    call ScreenBuffer_fill_rect

.Lfp_draw_du_pane__set_pen_ret:
    lea rsp, [rsp + 8]
    ret

# fp_draw_du_pane step: Draw size at col (runs on the caller's frame)
fp_draw_du_pane__draw_size_col:
    lea rsp, [rsp - 8]
    mov rdi, [r15 + FileEntry.size]; lea rsi, [rsp + 16 + 16]
    call format_size
    mov esi, [rbx + Widget.x]; add esi, [rbx + Widget.w]; sub esi, 26
    mov edx, [rbx + Widget.y]; add edx, 3; add edx, [rsp + 4 + 16]
    mov rdi, r12; lea rcx, [rsp + 16 + 16]; mov r8d, 9
    call ScreenBuffer_draw_text

    # Compute permille / bar (8 cells) + pct
    mov rax, [r15 + FileEntry.size]; imul rax, 100
    mov rcx, [r14 + DirModel.du_total]
    xor edx, edx
    test rcx, rcx; jz .Lfddp_pct0
    div rcx
    cmp rax, 100; jbe .Lfddp_pct_ok; mov eax, 100; jmp .Lfddp_pct_ok
.Lfddp_pct0:
    xor eax, eax
.Lfddp_pct_ok:
    mov [rsp + 56 + 16], eax  # pct (0..100)
    imul eax, 8; xor edx, edx; mov ecx, 100; div ecx
    mov [rsp + 60 + 16], eax  # filled cells (0..8)

    mov rdi, r12; mov esi, [r13 + Theme.accent]; mov edx, [rsp + 12 + 16]; xor ecx, ecx
    call ScreenBuffer_set_pen
    xor r8d, r8d              # cell i
.Lfddp_bar:
    cmp r8d, 8; jge .Lfddp_pct_txt
    mov ecx, 0x2588           # '█'
    cmp r8d, [rsp + 60 + 16]; jl .Lfddp_put_b
    mov ecx, 0x2591           # '░'
.Lfddp_put_b:
    push r8
    mov esi, [rbx + Widget.x]; add esi, [rbx + Widget.w]; sub esi, 16; add esi, r8d
    mov edx, [rbx + Widget.y]; add edx, 3; add edx, [rsp + 12 + 16]
    mov rdi, r12; call ScreenBuffer_set_cell
    pop r8; inc r8d; jmp .Lfddp_bar

.Lfddp_pct_txt:
    mov rdi, r12; mov esi, [r13 + Theme.muted]; mov edx, [rsp + 12 + 16]; xor ecx, ecx
    call ScreenBuffer_set_pen
    mov edi, [rsp + 56 + 16]; lea rsi, [rsp + 16 + 16]; call u64_to_dec
    mov byte ptr [rsp + 16 + rax + 16], '%'; mov byte ptr [rsp + 17 + rax + 16], ' '; mov byte ptr [rsp + 18 + rax + 16], 0
    mov esi, [rbx + Widget.x]; add esi, [rbx + Widget.w]; sub esi, 7
    mov edx, [rbx + Widget.y]; add edx, 3; add edx, [rsp + 4 + 16]
    mov rdi, r12; lea rcx, [rsp + 16 + 16]; mov r8d, 5
    call ScreenBuffer_draw_text

.Lfp_draw_du_pane__draw_size_col_ret:
    lea rsp, [rsp + 8]
    ret
