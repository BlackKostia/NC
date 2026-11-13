# Modal Dialog Class Hierarchy (Dialog -> ConfirmDialog, InputDialog, HelpDialog; ViewerDialog: viewer_dialog.s)
# Demonstrates OOP inheritance, virtual rendering, keyboard & mouse hit-testing, and UTF-8 input.

.intel_syntax noprefix
.include "classes.inc"

.section .rodata
str_Dialog:        .asciz "Dialog"
str_ConfirmDialog: .asciz "ConfirmDialog"
str_InputDialog:   .asciz "InputDialog"
str_HelpDialog:    .asciz "HelpDialog"

.equ HELP_LINE_COUNT, 22

.global Dialog_vtbl
Dialog_vtbl:
    DIALOG_VTBL_SLOTS str_Dialog, Widget_vtbl, Dialog._size, Dialog_dtor, Dialog_layout, Dialog_render, Dialog_on_key, Dialog_on_mouse, Widget_on_focus, Widget_hit_test, Dialog_on_confirm, Dialog_on_cancel

.global ConfirmDialog_vtbl
ConfirmDialog_vtbl:
    DIALOG_VTBL_SLOTS str_ConfirmDialog, Dialog_vtbl, ConfirmDialog._size, Dialog_dtor, ConfirmDialog_layout, ConfirmDialog_render, Dialog_on_key, Dialog_on_mouse, Widget_on_focus, Widget_hit_test, Dialog_on_confirm, Dialog_on_cancel

.global InputDialog_vtbl
InputDialog_vtbl:
    DIALOG_VTBL_SLOTS str_InputDialog, Dialog_vtbl, InputDialog._size, Dialog_dtor, InputDialog_layout, InputDialog_render, InputDialog_on_key, Dialog_on_mouse, Widget_on_focus, Widget_hit_test, Dialog_on_confirm, Dialog_on_cancel

.global HelpDialog_vtbl
HelpDialog_vtbl:
    DIALOG_VTBL_SLOTS str_HelpDialog, Dialog_vtbl, HelpDialog._size, Dialog_dtor, HelpDialog_layout, HelpDialog_render, HelpDialog_on_key, HelpDialog_on_mouse, Widget_on_focus, Widget_hit_test, Dialog_on_cancel, Dialog_on_cancel

.section .text
.global Dialog_init
.global Dialog_dtor
.global Dialog_layout
.global Dialog_render
.global Dialog_on_key
.global Dialog_on_mouse
.global Dialog_on_confirm
.global Dialog_on_cancel

.global ConfirmDialog_new
.global InputDialog_new
.global HelpDialog_new

# --- Base Dialog Methods ---
Dialog_init:
    # rdi=this, rsi=app, rdx=title, ecx=op_tag
    push rbx
    push r12
    push r13
    push r14
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14d, ecx
    mov edx, 200
    call Widget_init
    mov [rbx + Dialog.app], r12
    mov [rbx + Dialog.title], r13
    mov [rbx + Dialog.op_tag], r14d
    mov dword ptr [rbx + Dialog.hovered_btn], -1
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

Dialog_dtor:
    ret

Dialog_layout:
    jmp Widget_layout

Dialog_on_confirm:
    mov dword ptr [rdi + Dialog.result], DLG_OK
    mov rdi, [rdi + Dialog.app]
    mov esi, DLG_OK
    jmp App_close_dialog

Dialog_on_cancel:
    mov dword ptr [rdi + Dialog.result], DLG_CANCEL
    mov rdi, [rdi + Dialog.app]
    mov esi, DLG_CANCEL
    jmp App_close_dialog

.global Dialog_draw_frame
.global dlg_layout_right_buttons
# Helper: draw dialog frame, title badge, and clickable buttons
# void Dialog_draw_frame(Dialog *this, ScreenBuffer *scr, Theme *theme, const char *b0_lbl, const char *b1_lbl)
Dialog_draw_frame:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi              # this
    mov r12, rsi              # scr
    mov r13, rdx              # theme
    mov r14, rcx              # b0_lbl
    mov r15, r8               # b1_lbl

    # Box + interior fill
    mov rdi, r12
    mov esi, [r13 + Theme.dialog_border]
    mov edx, [r13 + Theme.dialog_bg]
    mov ecx, ATTR_BOLD
    call ScreenBuffer_set_pen

    mov rdi, r12
    mov esi, [rbx + Widget.x]
    mov edx, [rbx + Widget.y]
    mov ecx, [rbx + Widget.w]
    mov r8d, [rbx + Widget.h]
    mov r9d, 1
    call ScreenBuffer_draw_box

    # Title pill on top border
    mov rdi, r12
    mov esi, [r13 + Theme.accent_fg]
    mov edx, [r13 + Theme.dialog_border]
    mov ecx, ATTR_BOLD
    call ScreenBuffer_set_pen

    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 3
    mov edx, [rbx + Widget.y]
    mov rcx, [rbx + Dialog.title]
    mov r8d, [rbx + Widget.w]
    sub r8d, 6
    call ScreenBuffer_draw_text

    # Draw buttons stored in Dialog.btns[0..btn_count-1]
    xor ecx, ecx
.Lddf_bloop:
    cmp ecx, [rbx + Dialog.btn_count]
    jge .Lddf_done
    imul rax, rcx, HitZone._size
    lea r9, [rbx + Dialog.btns + rax]
    movsx esi, word ptr [r9 + HitZone.x1]
    movsx edx, word ptr [r9 + HitZone.y]
    movsx r8d, word ptr [r9 + HitZone.x2]
    sub r8d, esi              # btn width

    mov r10d, [r13 + Theme.badge_fg]
    mov r11d, [r13 + Theme.badge_bg]
    xor eax, eax
    cmp ecx, [rbx + Dialog.focus_btn]
    jne .Lddf_chk_hov
    mov r10d, [r13 + Theme.accent_fg]
    mov r11d, [r13 + Theme.accent]
    mov eax, ATTR_BOLD
    jmp .Lddf_bpen
.Lddf_chk_hov:
    cmp ecx, [rbx + Dialog.hovered_btn]
    jne .Lddf_bpen
    mov r11d, [r13 + Theme.badge_hover_bg]
    mov eax, ATTR_BOLD
.Lddf_bpen:
    push rcx
    push rsi
    push rdx
    push r8
    mov rdi, r12
    mov esi, r10d
    mov edx, r11d
    mov ecx, eax
    call ScreenBuffer_set_pen
    pop r8
    pop rdx
    pop rsi
    pop rcx

    mov rax, r14
    test ecx, ecx
    jz .Lddf_btext
    mov rax, r15
.Lddf_btext:
    test rax, rax
    jz .Lddf_bnext
    push rcx
    mov rdi, r12
    # esi=x, edx=y, r8d=w
    mov rcx, rax
    call ScreenBuffer_draw_text_pad
    pop rcx
.Lddf_bnext:
    inc ecx
    jmp .Lddf_bloop

.Lddf_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

Dialog_render:
    ret

Dialog_on_key:
    mov eax, [rsi + Event.key]
    cmp eax, KEY_ESC
    je .Ldok_cancel
    cmp eax, KEY_ENTER
    je .Ldok_enter
    cmp eax, KEY_TAB
    je .Ldok_tab
    cmp eax, KEY_LEFT
    je .Ldok_tab
    cmp eax, KEY_RIGHT
    je .Ldok_tab
    mov eax, 1                # modal swallows unhandled keys
    ret
.Ldok_tab:
    cmp dword ptr [rdi + Dialog.btn_count], 1
    jle .Ldok_swallow
    xor dword ptr [rdi + Dialog.focus_btn], 1
    mov rax, [rdi + Dialog.app]
    mov dword ptr [rax + App.need_redraw], 1
.Ldok_swallow:
    mov eax, 1
    ret
.Ldok_enter:
    cmp dword ptr [rdi + Dialog.focus_btn], 0
    jne .Ldok_cancel
    VCALL DialogVtbl.on_confirm
    mov eax, 1
    ret
.Ldok_cancel:
    VCALL DialogVtbl.on_cancel
    mov eax, 1
    ret

Dialog_on_mouse:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi

    mov r8d, [r12 + Event.mouse_x]
    mov r9d, [r12 + Event.mouse_y]
    mov r13d, -1

    xor ecx, ecx
.Ldom_find:
    cmp ecx, [rbx + Dialog.btn_count]
    jge .Ldom_found
    imul rax, rcx, HitZone._size
    lea r10, [rbx + Dialog.btns + rax]
    movsx edx, word ptr [r10 + HitZone.y]
    cmp r9d, edx
    jne .Ldom_fnext
    movsx edx, word ptr [r10 + HitZone.x1]
    cmp r8d, edx
    jl .Ldom_fnext
    movsx edx, word ptr [r10 + HitZone.x2]
    cmp r8d, edx
    jge .Ldom_fnext
    movsx r13d, word ptr [r10 + HitZone.id]
    jmp .Ldom_found
.Ldom_fnext:
    inc ecx
    jmp .Ldom_find

.Ldom_found:
    mov eax, [r12 + Event.mouse_kind]
    cmp eax, MACT_MOVE
    je .Ldom_hover
    cmp eax, MACT_PRESS
    je .Ldom_press
    mov eax, 1
    jmp .Ldom_ret

.Ldom_hover:
    cmp r13d, [rbx + Dialog.hovered_btn]
    je .Ldom_swallow
    mov [rbx + Dialog.hovered_btn], r13d
    mov rax, [rbx + Dialog.app]
    mov dword ptr [rax + App.need_redraw], 1
    jmp .Ldom_swallow

.Ldom_press:
    cmp dword ptr [r12 + Event.mouse_btn], MOUSE_LEFT
    jne .Ldom_swallow
    cmp r13d, 0
    je .Ldom_btn0
    cmp r13d, 1
    je .Ldom_btn1
    # Click outside dialog cancels? No, keep modal safe unless clicking Cancel.
    jmp .Ldom_swallow
.Ldom_btn0:
    VCALL_REG rbx, DialogVtbl.on_confirm
    jmp .Ldom_swallow
.Ldom_btn1:
    VCALL_REG rbx, DialogVtbl.on_cancel

.Ldom_swallow:
    mov eax, 1
.Ldom_ret:
    pop r13
    pop r12
    pop rbx
    ret

# ==============================================================================
# ConfirmDialog
# ==============================================================================
ConfirmDialog_new:
    # rdi=app, rsi=title, rdx=message, rcx=detail, r8d=op_tag
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi              # app
    mov r13, rsi              # title
    mov r14, rdx              # message
    mov r15, rcx              # detail
    push r8                   # op_tag

    NEW_OBJ ConfirmDialog_vtbl, ConfirmDialog._size
    test rax, rax
    jz .Lcdn_fail
    mov rbx, rax

    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    pop rcx                   # op_tag
    call Dialog_init

    lea rdi, [rbx + ConfirmDialog.message]
    mov rsi, r14
    mov edx, 512
    call str_copy

    lea rdi, [rbx + ConfirmDialog.detail]
    mov rsi, r15
    mov edx, 512
    call str_copy

    mov rdi, rbx
    xor esi, esi
    xor edx, edx
    mov ecx, [r12 + App.term_w]
    mov r8d, [r12 + App.term_h]
    call ConfirmDialog_layout

    mov rax, rbx
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.Lcdn_fail:
    pop r8
    xor eax, eax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Helper: position two centered dialog buttons at y = dlg_y + dlg_h - 3
# rdi = Dialog*, rsi = btn0_str, rdx = btn1_str
dlg_layout_center_buttons:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx

    mov rdi, r12
    call utf8_display_width
    mov r12d, eax             # w0
    mov rdi, r13
    call utf8_display_width
    mov r13d, eax             # w1

    mov eax, r12d
    add eax, 2
    add eax, r13d             # total_w
    sar eax, 1

    mov ecx, [rbx + Widget.x]
    mov edx, [rbx + Widget.w]
    shr edx, 1
    add ecx, edx
    sub ecx, eax              # x0

    mov eax, [rbx + Widget.y]
    add eax, [rbx + Widget.h]
    sub eax, 3                # btn_y

    mov dword ptr [rbx + Dialog.btn_count], 2
    lea r8, [rbx + Dialog.btns]
    mov [r8 + HitZone.x1], cx
    add ecx, r12d
    mov [r8 + HitZone.x2], cx
    mov [r8 + HitZone.y], ax
    mov word ptr [r8 + HitZone.id], 0

    add r8, HitZone._size
    add ecx, 2
    mov [r8 + HitZone.x1], cx
    add ecx, r13d
    mov [r8 + HitZone.x2], cx
    mov [r8 + HitZone.y], ax
    mov word ptr [r8 + HitZone.id], 1

    pop r13
    pop r12
    pop rbx
    ret

# Helper: position 1 or 2 right-aligned buttons at y = dlg_y + dlg_h - 2
# rdi = Dialog*, rsi = btn0_str, rdx = btn1_str (or 0 for single button)
dlg_layout_right_buttons:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx

    mov rdi, r12
    call utf8_display_width
    mov r12d, eax             # w0

    mov eax, [rbx + Widget.y]
    add eax, [rbx + Widget.h]
    sub eax, 2                # btn_y
    mov ecx, [rbx + Widget.x]
    add ecx, [rbx + Widget.w]
    sub ecx, 2                # right margin edge

    test r13, r13
    jz .Ldlrb_one

    push rax
    push rcx
    mov rdi, r13
    call utf8_display_width
    mov r13d, eax             # w1
    pop rcx
    pop rax

    mov dword ptr [rbx + Dialog.btn_count], 2
    # btn 1 (rightmost)
    mov edx, ecx
    sub edx, r13d             # x1
    lea r8, [rbx + Dialog.btns + HitZone._size]
    mov [r8 + HitZone.x1], dx
    mov [r8 + HitZone.x2], cx
    mov [r8 + HitZone.y], ax
    mov word ptr [r8 + HitZone.id], 1

    # btn 0 (left of btn 1 with 2-col gap)
    sub edx, 2
    mov ecx, edx
    sub ecx, r12d
    lea r8, [rbx + Dialog.btns]
    mov [r8 + HitZone.x1], cx
    mov [r8 + HitZone.x2], dx
    mov [r8 + HitZone.y], ax
    mov word ptr [r8 + HitZone.id], 0
    jmp .Ldlrb_done

.Ldlrb_one:
    mov dword ptr [rbx + Dialog.btn_count], 1
    mov edx, ecx
    sub edx, r12d
    lea r8, [rbx + Dialog.btns]
    mov [r8 + HitZone.x1], dx
    mov [r8 + HitZone.x2], cx
    mov [r8 + HitZone.y], ax
    mov word ptr [r8 + HitZone.id], 0

.Ldlrb_done:
    pop r13
    pop r12
    pop rbx
    ret

ConfirmDialog_layout:
    # rdi=this, esi=term_w, edx=term_h (or x,y,w,h from App: App calls layout(0,0,term_w,term_h) or we center inside!)
    # Wait: WidgetVtbl.layout signature is (this, x, y, w, h) where container gives bounds!
    # Dialog centers itself inside (x, y, w, h)!
    push rbx
    mov rbx, rdi
    cmp r8d, 0
    jg .Lcdl_have_rect
    # Fallback if called with (term_w, term_h) directly
    mov ecx, esi
    mov r8d, edx
    xor esi, esi
    xor edx, edx
.Lcdl_have_rect:
    # Desired w = min(64, max(36, container_w - 6)), h = 9
    mov r9d, ecx
    sub r9d, 6
    cmp r9d, 64
    jle .Lcdl_w_min
    mov r9d, 64
.Lcdl_w_min:
    cmp r9d, 34
    jge .Lcdl_w_ok
    mov r9d, ecx
.Lcdl_w_ok:
    mov r10d, 9
    cmp r10d, r8d
    jle .Lcdl_h_ok
    mov r10d, r8d
.Lcdl_h_ok:
    # Center x = x + (w - dlg_w)/2, y = y + (h - dlg_h)/2
    mov eax, ecx
    sub eax, r9d
    sar eax, 1
    add eax, esi              # dlg_x
    mov r11d, r8d
    sub r11d, r10d
    sar r11d, 1
    add r11d, edx             # dlg_y

    mov rdi, rbx
    mov esi, eax
    mov edx, r11d
    mov ecx, r9d
    mov r8d, r10d
    call Widget_layout

    call i18n_get
    mov rsi, [rax + LangStrings.dlg_btn_yes]
    mov rdx, [rax + LangStrings.dlg_btn_no]
    mov rdi, rbx
    call dlg_layout_center_buttons

    pop rbx
    ret

ConfirmDialog_render:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx

    call i18n_get
    mov rcx, [rax + LangStrings.dlg_btn_yes]
    mov r8,  [rax + LangStrings.dlg_btn_no]
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call Dialog_draw_frame

    mov rdi, r12
    mov esi, [r13 + Theme.text]
    mov edx, [r13 + Theme.dialog_bg]
    mov ecx, ATTR_BOLD
    call ScreenBuffer_set_pen

    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 3
    mov edx, [rbx + Widget.y]
    add edx, 2
    lea rcx, [rbx + ConfirmDialog.message]
    mov r8d, [rbx + Widget.w]
    sub r8d, 6
    call ScreenBuffer_draw_text

    mov rdi, r12
    mov esi, [r13 + Theme.warn_fg]
    mov edx, [r13 + Theme.dialog_bg]
    xor ecx, ecx
    call ScreenBuffer_set_pen

    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 3
    mov edx, [rbx + Widget.y]
    add edx, 4
    lea rcx, [rbx + ConfirmDialog.detail]
    mov r8d, [rbx + Widget.w]
    sub r8d, 6
    call ScreenBuffer_draw_text

    pop r13
    pop r12
    pop rbx
    ret

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

    # Prompt
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

    # Draw text starting at buf + scroll
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

    # Draw visible cursor cell using reverse/accent highlight
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
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

InputDialog_on_key:
    push rbx
    push r12
    sub rsp, 16
    mov rbx, rdi
    mov r12, rsi

    mov eax, [r12 + Event.key]
    mov ecx, [r12 + Event.mods]

    # Ctrl+U clears buffer
    test ecx, MOD_CTRL
    jz .Lidk_plain
    cmp eax, 'u'
    jne .Lidk_handled
    mov dword ptr [rbx + InputDialog.len], 0
    mov dword ptr [rbx + InputDialog.cursor], 0
    mov byte ptr [rbx + InputDialog.buf], 0
    jmp .Lidk_dirty

.Lidk_plain:
    cmp eax, KEY_ESC
    je .Lidk_cancel
    cmp eax, KEY_ENTER
    je .Lidk_enter
    cmp eax, KEY_TAB
    je .Lidk_tab
    cmp eax, KEY_HOME
    je .Lidk_home
    cmp eax, KEY_END
    je .Lidk_end
    cmp eax, KEY_LEFT
    je .Lidk_left
    cmp eax, KEY_RIGHT
    je .Lidk_right
    cmp eax, KEY_BACKSPACE
    je .Lidk_bs
    cmp eax, KEY_DELETE
    je .Lidk_del

    # Printable Unicode/ASCII?
    cmp eax, 0x20
    jb .Lidk_handled
    cmp eax, 0x10FFFF
    ja .Lidk_handled

    # Encode key as UTF-8 into [rsp]
    mov edi, eax
    mov rsi, rsp
    call utf8_encode          # eax = byte len (1..4)
    mov ecx, [rbx + InputDialog.len]
    add ecx, eax
    cmp ecx, INPUT_MAX - 1
    jae .Lidk_handled

    # Shift tail [cursor..len] right by eax
    push rax
    lea rdi, [rbx + InputDialog.buf]
    mov edx, [rbx + InputDialog.cursor]
    lea rsi, [rdi + rdx]
    add rdi, rdx
    add rdi, rax
    mov ecx, [rbx + InputDialog.len]
    sub ecx, edx
    inc ecx                   # include NUL
    mov rdx, rcx
    call mem_move
    pop rax

    # Copy encoded bytes into cursor slot
    lea rdi, [rbx + InputDialog.buf]
    mov ecx, [rbx + InputDialog.cursor]
    add rdi, rcx
    mov rsi, rsp
    mov edx, eax
    push rax
    call mem_copy
    pop rax
    add [rbx + InputDialog.len], eax
    add [rbx + InputDialog.cursor], eax
    jmp .Lidk_dirty

.Lidk_tab:
    xor dword ptr [rbx + Dialog.focus_btn], 1
    jmp .Lidk_dirty
.Lidk_home:
    mov dword ptr [rbx + InputDialog.cursor], 0
    jmp .Lidk_dirty
.Lidk_end:
    mov eax, [rbx + InputDialog.len]
    mov [rbx + InputDialog.cursor], eax
    jmp .Lidk_dirty
.Lidk_left:
    mov ecx, [rbx + InputDialog.cursor]
    test ecx, ecx
    jz .Lidk_handled
.Lidk_lstep:
    dec ecx
    jz .Lidk_lset
    mov al, byte ptr [rbx + InputDialog.buf + rcx]
    and al, 0xC0
    cmp al, 0x80
    je .Lidk_lstep
.Lidk_lset:
    mov [rbx + InputDialog.cursor], ecx
    jmp .Lidk_dirty

.Lidk_right:
    mov ecx, [rbx + InputDialog.cursor]
    cmp ecx, [rbx + InputDialog.len]
    jae .Lidk_handled
.Lidk_rstep:
    inc ecx
    cmp ecx, [rbx + InputDialog.len]
    jae .Lidk_rset
    mov al, byte ptr [rbx + InputDialog.buf + rcx]
    and al, 0xC0
    cmp al, 0x80
    je .Lidk_rstep
.Lidk_rset:
    mov [rbx + InputDialog.cursor], ecx
    jmp .Lidk_dirty

.Lidk_bs:
    mov ecx, [rbx + InputDialog.cursor]
    test ecx, ecx
    jz .Lidk_handled
    mov edx, ecx              # old cursor
.Lidk_bs_step:
    dec ecx
    jz .Lidk_bs_cut
    mov al, byte ptr [rbx + InputDialog.buf + rcx]
    and al, 0xC0
    cmp al, 0x80
    je .Lidk_bs_step
.Lidk_bs_cut:
    mov r8d, edx
    sub r8d, ecx              # bytes removed
    push rcx
    push r8
    lea rdi, [rbx + InputDialog.buf + rcx]
    lea rsi, [rbx + InputDialog.buf + rdx]
    mov eax, [rbx + InputDialog.len]
    sub eax, edx
    inc eax
    mov edx, eax
    call mem_move
    pop r8
    pop rcx
    sub [rbx + InputDialog.len], r8d
    mov [rbx + InputDialog.cursor], ecx
    jmp .Lidk_dirty

.Lidk_del:
    mov ecx, [rbx + InputDialog.cursor]
    cmp ecx, [rbx + InputDialog.len]
    jae .Lidk_handled
    mov edx, ecx
.Lidk_del_step:
    inc edx
    cmp edx, [rbx + InputDialog.len]
    jae .Lidk_del_cut
    mov al, byte ptr [rbx + InputDialog.buf + rdx]
    and al, 0xC0
    cmp al, 0x80
    je .Lidk_del_step
.Lidk_del_cut:
    mov r8d, edx
    sub r8d, ecx
    push r8
    lea rdi, [rbx + InputDialog.buf + rcx]
    lea rsi, [rbx + InputDialog.buf + rdx]
    mov eax, [rbx + InputDialog.len]
    sub eax, edx
    inc eax
    mov edx, eax
    call mem_move
    pop r8
    sub [rbx + InputDialog.len], r8d
    jmp .Lidk_dirty

.Lidk_enter:
    cmp dword ptr [rbx + Dialog.focus_btn], 0
    jne .Lidk_cancel
    mov rdi, rbx
    VCALL DialogVtbl.on_confirm
    jmp .Lidk_handled
.Lidk_cancel:
    mov rdi, rbx
    VCALL DialogVtbl.on_cancel
    jmp .Lidk_handled

.Lidk_dirty:
    mov rax, [rbx + Dialog.app]
    mov dword ptr [rax + App.need_redraw], 1
.Lidk_handled:
    mov eax, 1
    add rsp, 16
    pop r12
    pop rbx
    ret

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
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
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
