# Frozen reference oracle: src/ui/dialogs_help.s (before C23 migration to src/ui/dialog_help.c).
# Modal Dialog Class Hierarchy (Dialog -> ConfirmDialog, InputDialog, HelpDialog; ViewerDialog: viewer_dialog.s) — help (split from dialogs.s)

.intel_syntax noprefix
.include "classes.inc"
.equ HELP_LINE_COUNT,  22
.equ HELP_INSTR_COUNT, 36

.section .rodata
str_HelpDialog:    .asciz "HelpDialog"

HelpDialog_vtbl:
    DIALOG_VTBL_SLOTS str_HelpDialog, Dialog_vtbl, HelpDialog._size, Dialog_dtor, HelpDialog_layout, HelpDialog_render, HelpDialog_on_key, HelpDialog_on_mouse, Widget_on_focus, Widget_hit_test, Dialog_on_cancel, Dialog_on_cancel

.section .text
.global HelpDialog_new
.global HelpDialog_vtbl

# ==============================================================================
# HelpDialog
# ==============================================================================
HelpDialog_new:
    push rbx
    push r12
    mov r12, rdi
    NEW_OBJ HelpDialog_vtbl, HelpDialog._size
    test rax, rax
    jz .Lhdn_fail
    mov rbx, rax
    call i18n_get
    mov rdx, [rax + LangStrings.dlg_title_help]
    mov rdi, rbx
    mov rsi, r12
    xor ecx, ecx
    call Dialog_init

    mov rdi, rbx
    xor esi, esi
    xor edx, edx
    mov ecx, [r12 + App.term_w]
    mov r8d, [r12 + App.term_h]
    call HelpDialog_layout
    mov rax, rbx
.Lhdn_fail:
    pop r12
    pop rbx
    ret

HelpDialog_layout:
    push rbx
    mov rbx, rdi
    mov r9d, ecx
    sub r9d, 6
    cmp r9d, 78
    jle .Lhdl_wmin
    mov r9d, 78
.Lhdl_wmin:
    cmp r9d, 40
    jge .Lhdl_wok
    mov r9d, ecx
.Lhdl_wok:
    mov r10d, HELP_LINE_COUNT + 4
    cmp r10d, r8d
    jle .Lhdl_hok
    mov r10d, r8d
.Lhdl_hok:
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

    mov rdi, rbx
    call help_max_scroll
    cmp [rbx + HelpDialog.scroll], eax
    jle .Lhdl_scroll_ok
    mov [rbx + HelpDialog.scroll], eax
.Lhdl_scroll_ok:

    # Single Close button bottom-right + tab HitZones at row y+1
    call i18n_get
    mov rsi, [rax + LangStrings.dlg_btn_close]
    xor edx, edx
    mov rdi, rbx
    call dlg_layout_right_buttons
    call help_layout_tabs
    pop rbx
    ret

help_layout_tabs:
    push r12
    push r13
    call i18n_get
    mov r12, rax
    mov rdi, [r12 + LangStrings.help_tab_overview]
    call utf8_display_width
    mov r13d, eax
    mov edi, [rbx + Widget.x]
    add edi, 3
    mov edx, [rbx + Widget.y]
    inc edx
    lea rsi, [rbx + HelpDialog.tab_zones]
    mov [rsi + HitZone.x1], di
    add edi, r13d
    mov [rsi + HitZone.x2], di
    mov [rsi + HitZone.y], dx
    mov word ptr [rsi + HitZone.id], 0
    push rdi
    mov rdi, [r12 + LangStrings.help_tab_instr]
    call utf8_display_width
    pop rdi
    add edi, 2
    lea rsi, [rbx + HelpDialog.tab_zones + HitZone._size]
    mov edx, [rbx + Widget.y]
    inc edx
    mov [rsi + HitZone.x1], di
    add edi, eax
    mov [rsi + HitZone.x2], di
    mov [rsi + HitZone.y], dx
    mov word ptr [rsi + HitZone.id], 1
    pop r13
    pop r12
    ret

HelpDialog_render:
    push rbx
    push r12
    push r13
    push r14
    push r15
    call HelpDialog_render__draw_frame
    call HelpDialog_render__section_headings_start_xe2
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# HelpDialog_render step: draw_frame (runs on the caller's frame)
HelpDialog_render__draw_frame:
    lea rsp, [rsp - 8]
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx

    call i18n_get
    mov rcx, [rax + LangStrings.dlg_btn_close]
    xor r8d, r8d
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call Dialog_draw_frame

    mov rdi, r12
    mov esi, [r13 + Theme.muted]
    mov edx, [r13 + Theme.dialog_bg]
    xor ecx, ecx
    call ScreenBuffer_set_pen

    call i18n_get
    mov rcx, [rax + LangStrings.dlg_hlp_hint]
    movsx r8d, word ptr [rbx + Dialog.btns + HitZone.x1]
    mov eax, [rbx + Widget.x]
    add eax, 4
    sub r8d, eax
    cmp r8d, 0
    jle .Lhdr_skip_hint
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 3
    mov edx, [rbx + Widget.y]
    add edx, [rbx + Widget.h]
    sub edx, 2
    call ScreenBuffer_draw_text
.Lhdr_skip_hint:
    call help_draw_tabs

.LHelpDialog_render__draw_frame_ret:
    lea rsp, [rsp + 8]
    ret

help_draw_tabs:
    push r14
    push r15
    call i18n_get
    mov r14, rax
    xor r15d, r15d
.Lhdt_loop:
    mov esi, [r13 + Theme.muted]
    mov edx, [r13 + Theme.dialog_bg]
    xor ecx, ecx
    cmp r15d, [rbx + HelpDialog.tab]
    jne .Lhdt_pen
    mov esi, [r13 + Theme.accent_fg]
    mov edx, [r13 + Theme.accent]
    mov ecx, ATTR_BOLD
.Lhdt_pen:
    mov rdi, r12
    call ScreenBuffer_set_pen
    mov rcx, [r14 + LangStrings.help_tab_overview]
    test r15d, r15d
    jz .Lhdt_lbl
    mov rcx, [r14 + LangStrings.help_tab_instr]
.Lhdt_lbl:
    imul eax, r15d, HitZone._size
    lea r9, [rbx + HelpDialog.tab_zones]
    movsx esi, word ptr [r9 + rax + HitZone.x1]
    movsx edx, word ptr [r9 + rax + HitZone.y]
    movsx r8d, word ptr [r9 + rax + HitZone.x2]
    sub r8d, esi
    mov rdi, r12
    call ScreenBuffer_draw_text
    inc r15d
    cmp r15d, 2
    jl .Lhdt_loop
    pop r15
    pop r14
    ret

# HelpDialog_render step: Section headings start with xE2 accent bold (runs on the caller's frame)
HelpDialog_render__section_headings_start_xe2:
    lea rsp, [rsp - 8]
    mov r14d, [rbx + Widget.h]
    sub r14d, 4               # visible rows
    xor r15d, r15d            # r = 0
.Lhdr_loop:
    cmp r15d, r14d
    jge .Lhdr_done
    mov eax, [rbx + HelpDialog.scroll]
    add eax, r15d
    push rax
    mov rdi, rbx
    call help_active_count
    mov ecx, eax
    pop rax
    cmp eax, ecx
    jge .Lhdr_done

    push rax
    call i18n_get
    pop rcx
    cmp dword ptr [rbx + HelpDialog.tab], 0
    jne .Lhdr_instr
    mov rcx, [rax + LangStrings.help_lines + rcx*8]
    jmp .Lhdr_got_line
.Lhdr_instr:
    mov rcx, [rax + LangStrings.help_instr_lines + rcx*8]
.Lhdr_got_line:
    push rcx

    # Section headings start with 0xE2 ('◆') -> accent + bold
    mov esi, [r13 + Theme.text]
    xor edx, edx              # attrs
    cmp byte ptr [rcx], 0xE2
    jne .Lhdr_pen
    mov esi, [r13 + Theme.accent]
    mov edx, ATTR_BOLD
.Lhdr_pen:
    push rdx
    mov rdi, r12
    mov edx, [r13 + Theme.dialog_bg]
    pop rcx
    call ScreenBuffer_set_pen

    pop rcx
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 3
    mov edx, [rbx + Widget.y]
    add edx, 2
    add edx, r15d
    mov r8d, [rbx + Widget.w]
    sub r8d, 6
    call ScreenBuffer_draw_text

    inc r15d
    jmp .Lhdr_loop

.Lhdr_done:
.LHelpDialog_render__section_headings_start_xe2_ret:
    lea rsp, [rsp + 8]
    ret
