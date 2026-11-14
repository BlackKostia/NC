# Modal Dialog Class Hierarchy (Dialog -> ConfirmDialog, InputDialog, HelpDialog; ViewerDialog: viewer_dialog.s) — dialogs confirm (split from dialogs.s)

.intel_syntax noprefix
.include "classes.inc"
.equ HELP_LINE_COUNT, 22

.section .rodata
str_Dialog:        .asciz "Dialog"
str_ConfirmDialog: .asciz "ConfirmDialog"

Dialog_vtbl:
    DIALOG_VTBL_SLOTS str_Dialog, Widget_vtbl, Dialog._size, Dialog_dtor, Dialog_layout, Dialog_render, Dialog_on_key, Dialog_on_mouse, Widget_on_focus, Widget_hit_test, Dialog_on_confirm, Dialog_on_cancel

ConfirmDialog_vtbl:
    DIALOG_VTBL_SLOTS str_ConfirmDialog, Dialog_vtbl, ConfirmDialog._size, Dialog_dtor, ConfirmDialog_layout, ConfirmDialog_render, Dialog_on_key, Dialog_on_mouse, Widget_on_focus, Widget_hit_test, Dialog_on_confirm, Dialog_on_cancel

.section .text
.global ConfirmDialog_new
.global dlg_layout_center_buttons
.global dlg_layout_right_buttons
.global Dialog_vtbl
.global ConfirmDialog_vtbl

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
