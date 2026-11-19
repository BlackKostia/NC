# Frozen reference oracle: the hand-written asm that src/ui/dialog.c replaced (tests/test_c_dialog_base.py diffs against it)
# Modal Dialog Class Hierarchy (Dialog -> ConfirmDialog, InputDialog, HelpDialog; ViewerDialog: viewer_dialog.s)
# Demonstrates OOP inheritance, virtual rendering, keyboard & mouse hit-testing, and UTF-8 input.

.intel_syntax noprefix
.include "classes.inc"
.equ HELP_LINE_COUNT, 22

.section .text
.global Dialog_init
.global Dialog_dtor
.global Dialog_layout
.global Dialog_on_confirm
.global Dialog_on_cancel
.global Dialog_draw_frame
.global Dialog_render
.global Dialog_on_key
.global Dialog_on_mouse

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

# Helper: draw dialog frame, title badge, and clickable buttons
# void Dialog_draw_frame(Dialog *this, ScreenBuffer *scr, Theme *theme, const char *b0_lbl, const char *b1_lbl)
Dialog_draw_frame:
    push rbx
    push r12
    push r13
    push r14
    push r15
    call Dialog_draw_frame__this
    # Box + interior fill
    call Dialog_draw_frame__box_interior_fill
    # Title pill on top border
    call Dialog_draw_frame__title_pill_top_border
    # Draw buttons stored in Dialog.btns[0..btn_count-1]
    call Dialog_draw_frame__draw_buttons_stored_dialog
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Dialog_draw_frame step: this (runs on the caller's frame)
Dialog_draw_frame__this:
    lea rsp, [rsp - 8]
    mov rbx, rdi              # this
    mov r12, rsi              # scr
    mov r13, rdx              # theme
    mov r14, rcx              # b0_lbl
    mov r15, r8               # b1_lbl

.LDialog_draw_frame__this_ret:
    lea rsp, [rsp + 8]
    ret

# Dialog_draw_frame step: Box interior fill (runs on the caller's frame)
Dialog_draw_frame__box_interior_fill:
    lea rsp, [rsp - 8]
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

.LDialog_draw_frame__box_interior_fill_ret:
    lea rsp, [rsp + 8]
    ret

# Dialog_draw_frame step: Title pill on top border (runs on the caller's frame)
Dialog_draw_frame__title_pill_top_border:
    lea rsp, [rsp - 8]
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

.LDialog_draw_frame__title_pill_top_border_ret:
    lea rsp, [rsp + 8]
    ret

# Dialog_draw_frame step: Draw buttons stored in Dialog btns (runs on the caller's frame)
Dialog_draw_frame__draw_buttons_stored_dialog:
    lea rsp, [rsp - 8]
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
.LDialog_draw_frame__draw_buttons_stored_dialog_ret:
    lea rsp, [rsp + 8]
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
