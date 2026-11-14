# User Menu Dialog (inherits from Dialog)
# Lists custom duoprc `menu` items (or built-in defaults) and runs selected command.

.intel_syntax noprefix
.include "classes.inc"

.section .rodata
str_UserMenuDialog: .asciz "UserMenuDialog"

.global UserMenuDialog_vtbl
UserMenuDialog_vtbl:
    DIALOG_VTBL_SLOTS str_UserMenuDialog, Dialog_vtbl, UserMenuDialog._size, Dialog_dtor, UserMenuDialog_layout, UserMenuDialog_render, UserMenuDialog_on_key, UserMenuDialog_on_mouse, Widget_on_focus, Widget_hit_test, Dialog_on_confirm, Dialog_on_cancel

.section .text
.global UserMenuDialog_new

.extern Dialog_init
.extern Dialog_dtor
.extern Dialog_on_key
.extern Dialog_on_mouse
.extern Dialog_on_confirm
.extern Dialog_on_cancel
.extern Dialog_draw_frame
.extern dlg_layout_right_buttons
.extern Widget_on_focus
.extern Widget_hit_test
.extern ScreenBuffer_set_pen
.extern ScreenBuffer_draw_hline
.extern ScreenBuffer_draw_text
.extern i18n_get
.extern config_menu_count
.extern config_menu_item

# UserMenuDialog *UserMenuDialog_new(App *app)
UserMenuDialog_new:
    push rbx
    push r12
    sub rsp, 8
    mov r12, rdi
    NEW_OBJ UserMenuDialog_vtbl, UserMenuDialog._size
    test rax, rax
    jz .Lumn_fail
    mov rbx, rax
    call i18n_get
    mov rdx, [rax + LangStrings.dlg_title_usermenu]
    mov rdi, rbx
    mov rsi, r12
    mov ecx, OP_USERMENU
    call Dialog_init
    mov dword ptr [rbx + UserMenuDialog.cursor], 0
    mov dword ptr [rbx + UserMenuDialog.scroll], 0

    mov rdi, rbx
    xor esi, esi
    xor edx, edx
    mov ecx, [r12 + App.term_w]
    mov r8d, [r12 + App.term_h]
    call UserMenuDialog_layout
    mov rax, rbx
.Lumn_fail:
    add rsp, 8
    pop r12
    pop rbx
    ret

UserMenuDialog_layout:
    # Center 68x16 dialog (clamped to terminal)
    mov eax, ecx
    sub eax, 4
    cmp eax, 68
    jle .Luml_w_ok
    mov eax, 68
.Luml_w_ok:
    cmp eax, 36
    jge .Luml_w_min
    mov eax, 36
.Luml_w_min:
    mov [rdi + Widget.w], eax

    mov r9d, r8d
    sub r9d, 4
    cmp r9d, 16
    jle .Luml_h_ok
    mov r9d, 16
.Luml_h_ok:
    cmp r9d, 10
    jge .Luml_h_min
    mov r9d, 10
.Luml_h_min:
    mov [rdi + Widget.h], r9d

    sub ecx, eax
    sar ecx, 1
    mov [rdi + Widget.x], ecx
    sub r8d, r9d
    sar r8d, 1
    mov [rdi + Widget.y], r8d

    jmp dlg_layout_right_buttons

UserMenuDialog_render:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 24               # [rsp+0]=vis_rows, [rsp+4]=count, [rsp+8]=label*
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx

    call i18n_get
    mov rcx, [rax + LangStrings.dlg_btn_ok]
    mov r8, [rax + LangStrings.dlg_btn_cancel]
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call Dialog_draw_frame

    call config_menu_count
    mov [rsp + 4], eax
    mov ecx, [rbx + Widget.h]
    sub ecx, 5
    cmp ecx, 1
    jge .Lumr_vr_ok
    mov ecx, 1
.Lumr_vr_ok:
    mov [rsp + 0], ecx

    xor r14d, r14d            # row r = 0
.Lumr_loop:
    cmp r14d, [rsp + 0]
    jge .Lumr_hint
    mov r15d, [rbx + UserMenuDialog.scroll]
    add r15d, r14d
    cmp r15d, [rsp + 4]
    jae .Lumr_hint

    mov edi, r15d
    lea rsi, [rsp + 8]
    lea rdx, [rsp + 16]
    call config_menu_item
    test eax, eax
    jz .Lumr_hint

    mov esi, [r13 + Theme.text]
    mov edx, [r13 + Theme.dialog_bg]
    xor ecx, ecx
    cmp r15d, [rbx + UserMenuDialog.cursor]
    jne .Lumr_pen
    mov edx, [r13 + Theme.cursor_active_bg]
    mov ecx, ATTR_BOLD
.Lumr_pen:
    mov rdi, r12
    call ScreenBuffer_set_pen

    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 2
    mov edx, [rbx + Widget.y]
    add edx, 2
    add edx, r14d
    mov ecx, [rbx + Widget.w]
    sub ecx, 4
    mov r8d, ' '
    call ScreenBuffer_draw_hline

    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 3
    mov edx, [rbx + Widget.y]
    add edx, 2
    add edx, r14d
    mov rcx, [rsp + 8]
    mov r8d, [rbx + Widget.w]
    sub r8d, 6
    call ScreenBuffer_draw_text

    inc r14d
    jmp .Lumr_loop

.Lumr_hint:
    mov rdi, r12
    mov esi, [r13 + Theme.muted]
    mov edx, [r13 + Theme.dialog_bg]
    xor ecx, ecx
    call ScreenBuffer_set_pen
    call i18n_get
    mov rcx, [rax + LangStrings.um_hint]
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 2
    mov edx, [rbx + Widget.y]
    add edx, [rbx + Widget.h]
    sub edx, 2
    mov r8d, [rbx + Widget.w]
    sub r8d, 26
    cmp r8d, 8
    jge .Lumr_hd
    mov r8d, 8
.Lumr_hd:
    call ScreenBuffer_draw_text

    add rsp, 24
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

UserMenuDialog_on_key:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    mov eax, [r12 + Event.key]

    cmp eax, KEY_UP;   je .Lumk_up
    cmp eax, 'k';      je .Lumk_up
    cmp eax, KEY_DOWN; je .Lumk_dn
    cmp eax, 'j';      je .Lumk_dn
    cmp eax, KEY_ENTER; je .Lumk_ok
    cmp eax, KEY_ESC;  je .Lumk_esc
    cmp eax, 'q';      je .Lumk_esc

    mov rdi, rbx
    mov rsi, r12
    call Dialog_on_key
    jmp .Lumk_done

.Lumk_up:
    mov eax, [rbx + UserMenuDialog.cursor]
    test eax, eax
    jle .Lumk_done
    dec eax
    mov [rbx + UserMenuDialog.cursor], eax
    cmp eax, [rbx + UserMenuDialog.scroll]
    jge .Lumk_redraw
    mov [rbx + UserMenuDialog.scroll], eax
    jmp .Lumk_redraw

.Lumk_dn:
    call config_menu_count
    mov ecx, [rbx + UserMenuDialog.cursor]
    inc ecx
    cmp ecx, eax
    jae .Lumk_done
    mov [rbx + UserMenuDialog.cursor], ecx
    mov edx, [rbx + Widget.h]
    sub edx, 5
    cmp edx, 1
    jge .Lumk_vh
    mov edx, 1
.Lumk_vh:
    mov eax, [rbx + UserMenuDialog.scroll]
    add eax, edx
    cmp ecx, eax
    jl .Lumk_redraw
    sub ecx, edx
    inc ecx
    mov [rbx + UserMenuDialog.scroll], ecx

.Lumk_redraw:
    mov rax, [rbx + Dialog.app]
    mov dword ptr [rax + App.need_redraw], 1
    jmp .Lumk_done

.Lumk_ok:
    mov rdi, rbx
    call Dialog_on_confirm
    jmp .Lumk_done

.Lumk_esc:
    mov rdi, rbx
    call Dialog_on_cancel

.Lumk_done:
    add rsp, 8
    pop r12
    pop rbx
    ret

UserMenuDialog_on_mouse:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    cmp dword ptr [r12 + Event.mouse_kind], MACT_PRESS
    jne .Lumm_base
    cmp dword ptr [r12 + Event.mouse_btn], MOUSE_LEFT
    jne .Lumm_base

    mov eax, [r12 + Event.mouse_y]
    mov ecx, [rbx + Widget.y]
    add ecx, 2
    cmp eax, ecx
    jl .Lumm_base
    mov edx, [rbx + Widget.y]
    add edx, [rbx + Widget.h]
    sub edx, 3
    cmp eax, edx
    jge .Lumm_base

    sub eax, ecx
    add eax, [rbx + UserMenuDialog.scroll]
    push rax
    call config_menu_count
    pop rcx
    cmp ecx, eax
    jae .Lumm_base
    mov [rbx + UserMenuDialog.cursor], ecx
    mov rdi, rbx
    call Dialog_on_confirm
    jmp .Lumm_done

.Lumm_base:
    mov rdi, rbx
    mov rsi, r12
    call Dialog_on_mouse
.Lumm_done:
    add rsp, 8
    pop r12
    pop rbx
    ret
