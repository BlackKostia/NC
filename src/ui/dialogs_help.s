# Modal Dialog Class Hierarchy (Dialog -> ConfirmDialog, InputDialog, HelpDialog; ViewerDialog: viewer_dialog.s) — help (split from dialogs.s)

.intel_syntax noprefix
.include "classes.inc"
.equ HELP_LINE_COUNT, 22

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

# int help_max_scroll(HelpDialog *this)
# Returns maximum valid HelpDialog.scroll based on current visible dialog height.
help_max_scroll:
    mov eax, [rdi + Widget.h]
    sub eax, 4
    cmp eax, 1
    jge .Lhms_vis_ok
    mov eax, 1
.Lhms_vis_ok:
    mov edx, HELP_LINE_COUNT
    sub edx, eax
    xor eax, eax
    cmp edx, 0
    jle .Lhms_ret
    mov eax, edx
.Lhms_ret:
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

    # Single Close button bottom-right
    call i18n_get
    mov rsi, [rax + LangStrings.dlg_btn_close]
    xor edx, edx
    mov rdi, rbx
    call dlg_layout_right_buttons
    pop rbx
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

.LHelpDialog_render__draw_frame_ret:
    lea rsp, [rsp + 8]
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
    cmp eax, HELP_LINE_COUNT
    jge .Lhdr_done

    push rax
    call i18n_get
    pop rcx
    mov rcx, [rax + LangStrings.help_lines + rcx*8]
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

HelpDialog_on_key:
    mov eax, [rsi + Event.key]
    cmp eax, KEY_ESC
    je .Lhdk_close
    cmp eax, KEY_ENTER
    je .Lhdk_close
    cmp eax, 'q'
    je .Lhdk_close
    cmp eax, KEY_F1
    je .Lhdk_close
    cmp eax, KEY_UP
    je .Lhdk_up
    cmp eax, KEY_DOWN
    je .Lhdk_dn
    mov eax, 1
    ret
.Lhdk_close:
    VCALL DialogVtbl.on_cancel
    mov eax, 1
    ret
.Lhdk_up:
    dec dword ptr [rdi + HelpDialog.scroll]
    jns .Lhdk_dirty
    mov dword ptr [rdi + HelpDialog.scroll], 0
    jmp .Lhdk_dirty
.Lhdk_dn:
    call help_max_scroll
    cmp [rdi + HelpDialog.scroll], eax
    jge .Lhdk_dirty
    inc dword ptr [rdi + HelpDialog.scroll]
.Lhdk_dirty:
    mov rax, [rdi + Dialog.app]
    mov dword ptr [rax + App.need_redraw], 1
    mov eax, 1
    ret

HelpDialog_on_mouse:
    cmp dword ptr [rsi + Event.mouse_kind], MACT_WHEEL
    jne Dialog_on_mouse
    cmp dword ptr [rsi + Event.mouse_btn], MOUSE_WHEEL_UP
    jne .Lhdm_dn
    mov eax, [rdi + HelpDialog.scroll]
    dec eax
    jns .Lhdm_apply
    xor eax, eax
    jmp .Lhdm_apply
.Lhdm_dn:
    call help_max_scroll
    mov ecx, [rdi + HelpDialog.scroll]
    cmp ecx, eax
    jge .Lhdm_done
    lea eax, [rcx + 1]
.Lhdm_apply:
    mov [rdi + HelpDialog.scroll], eax
    mov rax, [rdi + Dialog.app]
    mov dword ptr [rax + App.need_redraw], 1
.Lhdm_done:
    mov eax, 1
    ret
