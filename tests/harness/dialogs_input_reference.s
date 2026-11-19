# Frozen reference oracle: original src/ui/dialogs_input.s before C23 migration (v2.6.48).
# Modal Dialog Class Hierarchy (Dialog -> ConfirmDialog, InputDialog, HelpDialog; ViewerDialog: viewer_dialog.s) — dialogs input (split from dialogs.s)

.intel_syntax noprefix
.include "classes.inc"
.equ HELP_LINE_COUNT, 22

.section .rodata
str_InputDialog:   .asciz "InputDialog"

InputDialog_vtbl:
    DIALOG_VTBL_SLOTS str_InputDialog, Dialog_vtbl, InputDialog._size, Dialog_dtor, InputDialog_layout, InputDialog_render, InputDialog_on_key, Dialog_on_mouse, Widget_on_focus, Widget_hit_test, Dialog_on_confirm, Dialog_on_cancel

.section .text
.global InputDialog_new
.global InputDialog_vtbl

# ==============================================================================
# InputDialog
# ==============================================================================
InputDialog_new:
    # rdi=app, rsi=title, rdx=prompt, rcx=initial_text, r8d=op_tag
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    push r8

    NEW_OBJ InputDialog_vtbl, InputDialog._size
    test rax, rax
    jz .Lidn_fail
    mov rbx, rax

    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    pop rcx
    call Dialog_init

    lea rdi, [rbx + InputDialog.prompt]
    mov rsi, r14
    mov edx, 128
    call str_copy

    test r15, r15
    jz .Lidn_empty
    lea rdi, [rbx + InputDialog.buf]
    mov rsi, r15
    mov edx, INPUT_MAX
    call str_copy
    mov [rbx + InputDialog.len], eax
    mov [rbx + InputDialog.cursor], eax
.Lidn_empty:
    mov rdi, rbx
    xor esi, esi
    xor edx, edx
    mov ecx, [r12 + App.term_w]
    mov r8d, [r12 + App.term_h]
    call InputDialog_layout

    mov rax, rbx
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.Lidn_fail:
    pop r8
    xor eax, eax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

InputDialog_layout:
    push rbx
    mov rbx, rdi
    # Center 68x9 box inside (x, y, w, h)
    mov r9d, ecx
    sub r9d, 6
    cmp r9d, 68
    jle .Lidl_wmin
    mov r9d, 68
.Lidl_wmin:
    cmp r9d, 36
    jge .Lidl_wok
    mov r9d, ecx
.Lidl_wok:
    mov r10d, 9
    cmp r10d, r8d
    jle .Lidl_hok
    mov r10d, r8d
.Lidl_hok:
    mov eax, ecx
    sub eax, r9d
    sar eax, 1
    add eax, esi
    mov r11d, r8d
    sub r11d, r10d
    sar r11d, 1
    add r11d, edx

    mov rdi, rbx
    mov esi, eax
    mov edx, r11d
    mov ecx, r9d
    mov r8d, r10d
    call Widget_layout

    call i18n_get
    mov rsi, [rax + LangStrings.dlg_btn_ok]
    mov rdx, [rax + LangStrings.dlg_btn_cancel]
    mov rdi, rbx
    call dlg_layout_center_buttons

    pop rbx
    ret

InputDialog_render:
    push rbx
    push r12
    push r13
    push r14
    call InputDialog_render__draw_frame
    # Prompt
    call InputDialog_render__prompt
    # Draw text starting at buf + scroll
    call InputDialog_render__draw_text_starting_buf
    # Draw visible cursor cell using reverse/accent highlight
    call InputDialog_render__draw_visible_cursor_cell
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# InputDialog_render step: draw_frame (runs on the caller's frame)
InputDialog_render__draw_frame:
    lea rsp, [rsp - 8]
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx

    call i18n_get
    mov rcx, [rax + LangStrings.dlg_btn_ok]
    mov r8,  [rax + LangStrings.dlg_btn_cancel]
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call Dialog_draw_frame

.LInputDialog_render__draw_frame_ret:
    lea rsp, [rsp + 8]
    ret

# InputDialog_render step: Prompt (runs on the caller's frame)
InputDialog_render__prompt:
    lea rsp, [rsp - 8]
    mov rdi, r12
    mov esi, [r13 + Theme.text]
    mov edx, [r13 + Theme.dialog_bg]
    xor ecx, ecx
    call ScreenBuffer_set_pen

    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 3
    mov edx, [rbx + Widget.y]
    add edx, 2
    lea rcx, [rbx + InputDialog.prompt]
    mov r8d, [rbx + Widget.w]
    sub r8d, 6
    call ScreenBuffer_draw_text

    # Input field background at y + 4
    mov r14d, [rbx + Widget.w]
    sub r14d, 6               # field_w
    mov rdi, r12
    mov esi, [r13 + Theme.text]
    mov edx, [r13 + Theme.surface_alt]
    xor ecx, ecx
    call ScreenBuffer_set_pen

    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 3
    mov edx, [rbx + Widget.y]
    add edx, 4
    mov ecx, r14d
    mov r8d, ' '
    call ScreenBuffer_draw_hline

    # Ensure cursor is inside visible horizontal window
    # (Simplified byte scroll for smooth cursor tracking)
    mov eax, [rbx + InputDialog.cursor]
    mov ecx, [rbx + InputDialog.scroll]
    cmp eax, ecx
    jge .Lidr_chk_right
    mov ecx, eax
    jmp .Lidr_scroll_ok
.Lidr_chk_right:
    lea edx, [ecx + r14d - 1]
    cmp eax, edx
    jl .Lidr_scroll_ok
    mov ecx, eax
    sub ecx, r14d
    add ecx, 2
.Lidr_scroll_ok:
    mov [rbx + InputDialog.scroll], ecx

.LInputDialog_render__prompt_ret:
    lea rsp, [rsp + 8]
    ret

# InputDialog_render step: Draw text starting at buf scroll (runs on the caller's frame)
InputDialog_render__draw_text_starting_buf:
    lea rsp, [rsp - 8]
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 3
    mov edx, [rbx + Widget.y]
    add edx, 4
    lea rcx, [rbx + InputDialog.buf]
    mov eax, [rbx + InputDialog.scroll]
    add rcx, rax
    mov r8d, r14d
    call ScreenBuffer_draw_text

.LInputDialog_render__draw_text_starting_buf_ret:
    lea rsp, [rsp + 8]
    ret

# InputDialog_render step: Draw visible cursor cell using reverse accent highlight (runs on the caller's frame)
InputDialog_render__draw_visible_cursor_cell:
    lea rsp, [rsp - 8]
    mov eax, [rbx + InputDialog.cursor]
    sub eax, [rbx + InputDialog.scroll]
    cmp eax, 0
    jl .Lidr_done
    cmp eax, r14d
    jge .Lidr_done
    mov ecx, [rbx + InputDialog.cursor]
    movzx r8d, byte ptr [rbx + InputDialog.buf + rcx]
    test r8d, r8d
    jnz .Lidr_cur_ch
    mov r8d, ' '
.Lidr_cur_ch:
    push rax
    push r8
    mov rdi, r12
    mov esi, [r13 + Theme.accent_fg]
    mov edx, [r13 + Theme.accent]
    mov ecx, ATTR_BOLD
    call ScreenBuffer_set_pen
    pop rcx
    pop rax
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 3
    add esi, eax
    mov edx, [rbx + Widget.y]
    add edx, 4
    call ScreenBuffer_set_cell_pen

.Lidr_done:
.LInputDialog_render__draw_visible_cursor_cell_ret:
    lea rsp, [rsp + 8]
    ret
