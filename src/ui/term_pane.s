# Embedded Bottom PTY Terminal Pane (Ctrl+`)

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"
.equ TERM_COLS, 160
.equ TERM_ROWS, 48
.equ TERM_BUF_SZ, (TERM_COLS * TERM_ROWS)

.section .bss
g_term_visible: .space 4
g_term_inited:  .space 4
g_term_fd:      .space 4
g_term_pid:     .space 4
g_term_cx:      .space 4
g_term_cy:      .space 4
g_term_esc:     .space 4
g_term_vis_w:   .space 4
.align 8
g_term_buf:     .space 8
g_term_last_cwd: .space 4096

.section .text
.global term_height
.global term_toggle
.global term_poll_read
.global term_render
.global g_term_visible
.global g_term_inited
.global g_term_fd

# int term_height(int main_h) -> 0 if hidden, else max(6, main_h / 3)
term_height:
    xor eax, eax
    cmp dword ptr [rip + g_term_visible], 0
    je .Lth_ret
    cmp edi, 9                # main area too short (or negative) to host a bordered pane: hide it
    jl .Lth_ret
    mov eax, edi
    xor edx, edx
    mov ecx, 3
    div ecx
    cmp eax, 6
    jge .Lth_ret
    mov eax, 6
.Lth_ret:
    ret

term_scroll_up:
    push rbx
    mov rbx, [rip + g_term_buf]
    test rbx, rbx; jz .Ltsu_done
    mov rdi, rbx
    lea rsi, [rbx + TERM_COLS]
    mov rdx, TERM_COLS * (TERM_ROWS - 1)
    call mem_copy
    lea rdi, [rbx + TERM_COLS * (TERM_ROWS - 1)]
    mov esi, ' '
    mov edx, TERM_COLS
    call mem_set
.Ltsu_done:
    pop rbx; ret

term_put_byte:
    mov eax, [rip + g_term_esc]
    cmp eax, 1; je .Ltpb_esc1
    cmp eax, 2; je .Ltpb_esc2
    cmp eax, 3; je .Ltpb_esc3

    cmp edi, 0x1B; je .Ltpb_start_esc
    cmp edi, '\r'; je .Ltpb_cr
    cmp edi, '\n'; je .Ltpb_lf
    cmp edi, '\b'; je .Ltpb_bs
    cmp edi, 0x7F; je .Ltpb_bs
    cmp edi, '\t'; je .Ltpb_tab
    cmp edi, 0x20; jb .Ltpb_ret

    mov rcx, [rip + g_term_buf]
    test rcx, rcx; jz .Ltpb_ret
    mov eax, [rip + g_term_cy]
    imul eax, TERM_COLS
    add eax, [rip + g_term_cx]
    cmp eax, TERM_BUF_SZ; jae .Ltpb_ret
    mov [rcx + rax], dil
    mov eax, [rip + g_term_cx]
    inc eax
    mov edx, [rip + g_term_vis_w]
    cmp edx, 10; jge .Ltpb_w_ok
    mov edx, 80
.Ltpb_w_ok:
    cmp edx, TERM_COLS; jle .Ltpb_w_cap
    mov edx, TERM_COLS
.Ltpb_w_cap:
    cmp eax, edx; jl .Ltpb_setcx
    mov dword ptr [rip + g_term_cx], 0
    jmp .Ltpb_lf
.Ltpb_setcx:
    mov [rip + g_term_cx], eax
    ret

.Ltpb_start_esc:
    mov dword ptr [rip + g_term_esc], 1; ret
.Ltpb_esc1:
    cmp edi, '['; je .Ltpb_e2
    cmp edi, ']'; je .Ltpb_e3
    mov dword ptr [rip + g_term_esc], 0; ret
.Ltpb_e2:
    mov dword ptr [rip + g_term_esc], 2; ret
.Ltpb_e3:
    mov dword ptr [rip + g_term_esc], 3; ret
.Ltpb_esc2:
    cmp edi, 0x40; jb .Ltpb_ret
    cmp edi, 0x7E; ja .Ltpb_ret
    mov dword ptr [rip + g_term_esc], 0; ret
.Ltpb_esc3:
    cmp edi, 7; je .Ltpb_e0
    cmp edi, '\n'; je .Ltpb_e0
    ret
.Ltpb_e0:
    mov dword ptr [rip + g_term_esc], 0; ret
.Ltpb_cr:
    mov dword ptr [rip + g_term_cx], 0; ret
.Ltpb_lf:
    mov dword ptr [rip + g_term_cx], 0
    mov eax, [rip + g_term_cy]
    inc eax
    cmp eax, TERM_ROWS; jl .Ltpb_setcy
    call term_scroll_up
    mov eax, TERM_ROWS - 1
.Ltpb_setcy:
    mov [rip + g_term_cy], eax
    ret
.Ltpb_bs:
    mov eax, [rip + g_term_cx]
    test eax, eax; jz .Ltpb_ret
    dec eax; mov [rip + g_term_cx], eax; ret
.Ltpb_tab:
    mov eax, [rip + g_term_cx]
    add eax, 8; and eax, ~7
    cmp eax, TERM_COLS; jl .Ltpb_setcx
    mov eax, TERM_COLS - 1; jmp .Ltpb_setcx
.Ltpb_ret:
    ret

# void term_sync_cwd(App *app)
term_sync_cwd:
    push rbx; push r12
    sub rsp, 4136
    mov eax, [rip + g_term_fd]
    test eax, eax; js .Ltsc_done
    mov rax, [rdi + App.active_pane]
    test rax, rax; jz .Ltsc_done
    mov rax, [rax + FilePane.model]
    test rax, rax; jz .Ltsc_done
    lea rbx, [rax + DirModel.path]
    cmp byte ptr [rbx], 0; je .Ltsc_done
    mov rdi, rbx; lea rsi, [rip + g_term_last_cwd]
    call str_cmp
    test eax, eax; jz .Ltsc_done
    lea rdi, [rip + g_term_last_cwd]; mov rsi, rbx; mov edx, 4096
    call str_copy
    mov dword ptr [rsp], 0x27206463  # "cd '"
    mov ecx, 4; xor r8d, r8d
.Ltsc_loop:
    movzx eax, byte ptr [rbx + r8]
    test al, al; jz .Ltsc_end
    cmp ecx, 4120; jae .Ltsc_end
    cmp al, 0x27; jne .Ltsc_char
    mov dword ptr [rsp + rcx], 0x27275c27  # "'\''"
    add ecx, 4; inc r8d; jmp .Ltsc_loop
.Ltsc_char:
    mov [rsp + rcx], al
    inc ecx; inc r8d; jmp .Ltsc_loop
.Ltsc_end:
    mov word ptr [rsp + rcx], 0x0d27  # "'\r"
    add ecx, 2
    mov edi, [rip + g_term_fd]; mov rsi, rsp; mov edx, ecx
    call os_pty_write
.Ltsc_done:
    add rsp, 4136
    pop r12; pop rbx; ret

# void term_toggle(App *app)
term_toggle:
    push rbx; push r12
    mov rbx, rdi
    xor dword ptr [rip + g_term_visible], 1
    cmp dword ptr [rip + g_term_visible], 0
    je .Ltt_layout

    mov eax, [rbx + App.term_w]; sub eax, 2
    mov [rip + g_term_vis_w], eax
    cmp dword ptr [rip + g_term_inited], 0
    je .Ltt_spawn
    mov rdi, rbx
    call term_sync_cwd
    jmp .Ltt_layout

.Ltt_spawn:
    mov dword ptr [rip + g_term_inited], 1
    mov dword ptr [rip + g_term_fd], -1
    mov edi, TERM_BUF_SZ
    call mem_alloc
    test rax, rax; jz .Ltt_oom
    mov [rip + g_term_buf], rax
    mov rdi, rax; mov esi, ' '; mov edx, TERM_BUF_SZ
    call mem_set

    mov eax, [rbx + App.term_h]; sub eax, 3
    mov edi, eax; call term_height
    sub eax, 2
    cmp eax, 1; jge .Ltt_rows_ok
    mov eax, 1                # tiny terminal: the shell still needs a sane (positive) window size
.Ltt_rows_ok:
    mov r9d, eax              # rows
    mov r8d, [rbx + App.term_w]; sub r8d, 2  # cols
    cmp r8d, 1; jge .Ltt_cols_ok
    mov r8d, 1
.Ltt_cols_ok:
    mov rax, [rbx + App.active_pane]
    mov rax, [rax + FilePane.model]
    lea rdx, [rax + DirModel.path]
    mov r12, rdx
    mov rcx, [rbx + App.envp]
    lea rdi, [rip + g_term_fd]
    lea rsi, [rip + g_term_pid]
    call os_pty_spawn
    test eax, eax; jnz .Ltt_layout
    lea rdi, [rip + g_term_last_cwd]
    mov rsi, r12; mov edx, 4096
    call str_copy
    mov edi, 3; mov esi, [rip + g_term_fd]
    call input_set_aux_fd

    jmp .Ltt_layout
.Ltt_oom:
    mov dword ptr [rip + g_term_visible], 0       # no screen buffer: stay closed and say why
    mov dword ptr [rip + g_term_inited], 0
    mov edi, -ENOMEM
    call fs_errno_message
    mov rdi, rbx; mov rsi, rax; mov edx, MSG_ERR
    call App_set_status
.Ltt_layout:
    mov dword ptr [rbx + App.need_redraw], 1
    pop r12; pop rbx; ret

# void term_poll_read(App *app)
term_poll_read:
    push rbx; push r12; push r13
    sub rsp, 1024
    mov rbx, rdi
    cmp dword ptr [rip + g_term_inited], 0; je .Ltpr_done
    mov eax, [rip + g_term_fd]
    test eax, eax; js .Ltpr_done
.Ltpr_loop:
    mov edi, [rip + g_term_fd]
    mov rsi, rsp; mov edx, 1024
    call os_pty_read
    test rax, rax; jle .Ltpr_done
    mov r12, rax
    xor r13d, r13d
.Ltpr_bytes:
    cmp r13, r12; jge .Ltpr_dirty
    movzx edi, byte ptr [rsp + r13]
    call term_put_byte
    inc r13; jmp .Ltpr_bytes
.Ltpr_dirty:
    mov dword ptr [rbx + App.need_redraw], 1
    jmp .Ltpr_loop
.Ltpr_done:
    add rsp, 1024; pop r13; pop r12; pop rbx; ret

# void term_render(App *app, ScreenBuffer *scr, Theme *theme)
term_render:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, 32
    cmp dword ptr [rip + g_term_visible], 0; je .Ltr_done
    mov rbx, rdi; mov r12, rsi; mov r13, rdx
    cmp dword ptr [rbx + App.term_w], 4; jl .Ltr_done     # no room for the border + one cell
    mov edi, [rbx + App.term_h]; sub edi, 3
    call term_height
    mov r14d, eax             # th
    test r14d, r14d; jle .Ltr_done
    mov r15d, [rbx + App.term_h]; sub r15d, 2; sub r15d, r14d  # y0

    mov rdi, r12; mov esi, [r13 + Theme.text]; mov edx, [r13 + Theme.surface]; xor ecx, ecx
    call ScreenBuffer_set_pen
    mov rdi, r12; xor esi, esi; mov edx, r15d; mov ecx, [rbx + App.term_w]; mov r8d, r14d; mov r9d, ' '
    call ScreenBuffer_fill_rect

    mov rdi, r12; mov esi, [r13 + Theme.border_active]; mov edx, [r13 + Theme.surface]; xor ecx, ecx
    call ScreenBuffer_set_pen
    mov rdi, r12; xor esi, esi; mov edx, r15d; mov ecx, [rbx + App.term_w]; mov r8d, r14d; mov r9d, 1
    call ScreenBuffer_draw_box

    call i18n_get
    mov rcx, [rax + LangStrings.term_title]
    mov rdi, r12; mov esi, 2; mov edx, r15d; mov r8d, 20
    call ScreenBuffer_draw_text

    mov rdi, r12; mov esi, [r13 + Theme.text]; mov edx, [r13 + Theme.surface]; xor ecx, ecx
    call ScreenBuffer_set_pen

    mov eax, r14d; sub eax, 2 # inner_h
    mov [rsp + 0], eax
    mov ecx, [rip + g_term_cy]; inc ecx; sub ecx, eax
    jns .Ltr_start_ok
    xor ecx, ecx
.Ltr_start_ok:
    mov [rsp + 4], ecx        # start_row
    xor ecx, ecx              # i = 0
.Ltr_rows:
    cmp ecx, [rsp + 0]; jge .Ltr_cursor
    mov eax, [rsp + 4]; add eax, ecx
    cmp eax, TERM_ROWS; jge .Ltr_cursor
    imul eax, TERM_COLS
    mov r8, [rip + g_term_buf]; add r8, rax
    mov edx, [rbx + App.term_w]; sub edx, 2
    cmp edx, TERM_COLS; jle .Ltr_w_ok
    mov edx, TERM_COLS
.Ltr_w_ok:
    mov [rsp + 8], ecx
    mov [rsp + 12], edx
    sub rsp, 176
    mov rdi, rsp; mov rsi, r8
    call mem_copy
    mov edx, [rsp + 176 + 12]
    mov byte ptr [rsp + rdx], 0
    mov eax, [rsp + 176 + 8]
    lea edx, [r15d + eax + 1]
    mov rdi, r12; mov esi, 1; mov rcx, rsp; mov r8d, [rbx + App.term_w]; sub r8d, 2
    call ScreenBuffer_draw_text
    add rsp, 176
    mov ecx, [rsp + 8]
    inc ecx; jmp .Ltr_rows
.Ltr_cursor:
    mov rdi, r12; mov rsi, r13; mov edx, r15d
    mov ecx, [rsp + 4]; mov r8d, [rsp + 0]
    mov r9d, [rbx + App.term_w]; dec r9d
    call term_draw_cursor
.Ltr_done:
    add rsp, 32; pop r15; pop r14; pop r13; pop r12; pop rbx; ret

# Internal: void term_draw_cursor(ScreenBuffer *scr, Theme *theme, int y0, int start_row,
#                                 int inner_h, int max_x) -- inverted cell at the shell cursor
term_draw_cursor:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, 176
    mov eax, [rip + g_term_cy]
    sub eax, ecx; js .Ltdc_done
    cmp eax, r8d; jge .Ltdc_done
    mov rbx, rdi; mov r12, rsi; mov r14d, r9d
    lea r13d, [edx + eax + 1]             # screen row
    mov eax, [rip + g_term_cy]; imul eax, TERM_COLS
    mov r15, [rip + g_term_buf]; add r15, rax  # row start
    mov rdi, rsp; mov rsi, r15; mov edx, [rip + g_term_cx]
    call mem_copy
    mov eax, [rip + g_term_cx]
    mov byte ptr [rsp + rax], 0
    mov rdi, rsp; call utf8_display_width
    lea esi, [eax + 1]                    # screen column
    cmp esi, r14d; jge .Ltdc_done
    mov eax, [rip + g_term_cx]
    movzx ecx, byte ptr [r15 + rax]
    cmp ecx, 0x21; jb .Ltdc_blank
    cmp ecx, 0x7F; jb .Ltdc_draw
.Ltdc_blank:
    mov ecx, ' '
.Ltdc_draw:
    mov rdi, rbx; mov edx, r13d
    mov r8d, [r12 + Theme.surface]; mov r9d, [r12 + Theme.text]
    call ScreenBuffer_set_cell
.Ltdc_done:
    add rsp, 176; pop r15; pop r14; pop r13; pop r12; pop rbx; ret
