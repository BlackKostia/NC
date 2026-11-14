# "Open as" dialog shown by F3 on an image: [ Image ] [ Hex ] [ Text ] (i / h / t, arrows +
# Enter, mouse; Esc cancels). The choice is read by the app from ViewAsDialog.choice.

.intel_syntax noprefix
.include "classes.inc"

.section .rodata
str_ViewAsDialog: .asciz "ViewAsDialog"
str_vas_pad:      .asciz " "

.align 8
ViewAsDialog_vtbl:
    DIALOG_VTBL_SLOTS str_ViewAsDialog, Dialog_vtbl, ViewAsDialog._size, Dialog_dtor, ViewAsDialog_layout, ViewAsDialog_render, ViewAsDialog_on_key, ViewAsDialog_on_mouse, Widget_on_focus, Widget_hit_test, Dialog_on_confirm, Dialog_on_cancel

.section .text
.global ViewAsDialog_new
.global ViewAsDialog_vtbl

# ViewAsDialog *ViewAsDialog_new(App *app, const char *path, int fmt)
ViewAsDialog_new:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    mov r12, rdi
    mov r13, rsi
    mov r14d, edx
    NEW_OBJ ViewAsDialog_vtbl, ViewAsDialog._size
    test rax, rax
    jz .Lvan_ret
    mov rbx, rax
    call i18n_get
    mov rdx, [rax + LangStrings.dlg_title_viewas]
    mov rdi, rbx
    mov rsi, r12
    mov ecx, OP_VIEWAS
    call Dialog_init
    mov [rbx + ViewAsDialog.fmt], r14d
    mov dword ptr [rbx + ViewAsDialog.choice], PV_MODE_IMAGE
    mov dword ptr [rbx + Dialog.focus_btn], 0
    mov dword ptr [rbx + Dialog.btn_count], 3
    lea rdi, [rbx + ViewAsDialog.path]
    mov rsi, r13
    mov edx, PATH_MAX
    call str_copy
    mov rdi, rbx
    xor esi, esi
    xor edx, edx
    mov ecx, [r12 + App.term_w]
    mov r8d, [r12 + App.term_h]
    call ViewAsDialog_layout
    mov rax, rbx
.Lvan_ret:
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# void ViewAsDialog_layout(ViewAsDialog *this, int x, int y, int w, int h) -- centred, 9 rows
ViewAsDialog_layout:
    mov eax, ecx
    sub eax, 4
    cmp eax, 60
    jle 1f
    mov eax, 60
1:  cmp eax, 44
    jge 2f
    mov eax, 44
2:  mov [rdi + Widget.w], eax
    mov dword ptr [rdi + Widget.h], 9
    sub ecx, eax
    sar ecx, 1
    mov [rdi + Widget.x], ecx
    sub r8d, 9
    sar r8d, 1
    mov [rdi + Widget.y], r8d
    ret

# void ViewAsDialog_render(ViewAsDialog *this, ScreenBuffer *scr)
ViewAsDialog_render:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    mov rax, [rbx + Dialog.app]
    mov r13, [rax + App.theme]
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    xor ecx, ecx
    xor r8d, r8d
    call Dialog_draw_frame
    lea rdi, [rbx + ViewAsDialog.path]
    call path_basename
    mov r14, rax
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
    mov rcx, r14
    mov r8d, [rbx + Widget.w]
    sub r8d, 6
    call ScreenBuffer_draw_text
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call vas_buttons
    mov rdi, r12
    mov esi, [r13 + Theme.muted]
    mov edx, [r13 + Theme.dialog_bg]
    xor ecx, ecx
    call ScreenBuffer_set_pen
    call i18n_get
    mov rcx, [rax + LangStrings.vas_hint]
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 3
    mov edx, [rbx + Widget.y]
    add edx, 6
    mov r8d, [rbx + Widget.w]
    sub r8d, 6
    call ScreenBuffer_draw_text
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: void vas_buttons(ViewAsDialog *d, ScreenBuffer *scr, Theme *theme) -- row y + 4, hit zones
vas_buttons:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r15d, [rbx + Widget.x]
    add r15d, 3
    xor r14d, r14d
.Lvb_loop:
    cmp r14d, 3
    jge .Lvb_done
    call i18n_get
    mov rcx, [rax + LangStrings.vas_image + r14 * 8]
    mov [rsp], rcx
    mov rdi, r12
    mov esi, [r13 + Theme.text]
    mov edx, [r13 + Theme.surface_alt]
    xor ecx, ecx
    cmp r14d, [rbx + Dialog.focus_btn]
    jne 1f
    mov esi, [r13 + Theme.accent_fg]
    mov edx, [r13 + Theme.accent]
    mov ecx, ATTR_BOLD
1:  call ScreenBuffer_set_pen
    mov rdi, [rsp]
    call utf8_display_width
    lea ecx, [eax + 2]                # " label "
    mov [rsp + 8], ecx
    imul rdx, r14, HitZone._size
    lea r8, [rbx + Dialog.btns + rdx]
    mov [r8 + HitZone.x1], r15w
    lea eax, [r15d + ecx]
    mov [r8 + HitZone.x2], ax
    mov eax, [rbx + Widget.y]
    add eax, 4
    mov [r8 + HitZone.y], ax
    mov [r8 + HitZone.id], r14w
    mov rdi, r12
    mov esi, r15d
    mov edx, eax
    lea rcx, [rip + str_vas_pad]
    mov r8d, 1
    call ScreenBuffer_draw_text
    mov rdi, r12
    lea esi, [r15d + 1]
    mov edx, [rbx + Widget.y]
    add edx, 4
    mov rcx, [rsp]
    mov r8d, 24
    call ScreenBuffer_draw_text
    mov eax, [rsp + 8]
    mov rdi, r12
    lea esi, [r15d + eax - 1]
    mov edx, [rbx + Widget.y]
    add edx, 4
    lea rcx, [rip + str_vas_pad]
    mov r8d, 1
    call ScreenBuffer_draw_text
    add r15d, [rsp + 8]
    add r15d, 2
    inc r14d
    jmp .Lvb_loop
.Lvb_done:
    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# int ViewAsDialog_on_key(ViewAsDialog *this, Event *evt)
ViewAsDialog_on_key:
    push rbx
    mov rbx, rdi
    mov eax, [rsi + Event.lat]
    cmp eax, KEY_ESC;   je .Lvk_cancel
    or eax, 0x20                      # i / h / t, any case
    mov ecx, PV_MODE_IMAGE
    cmp eax, 'i';       je .Lvk_pick
    mov ecx, PV_MODE_HEX
    cmp eax, 'h';       je .Lvk_pick
    mov ecx, PV_MODE_TEXT
    cmp eax, 't';       je .Lvk_pick
    mov eax, [rsi + Event.key]
    mov ecx, -1
    cmp eax, KEY_LEFT;  je .Lvk_move
    mov ecx, 1
    cmp eax, KEY_RIGHT; je .Lvk_move
    cmp eax, KEY_TAB;   je .Lvk_move
    cmp eax, KEY_ENTER; je .Lvk_enter
    xor eax, eax
    pop rbx
    ret
.Lvk_move:
    mov eax, [rbx + Dialog.focus_btn]
    add eax, ecx
    add eax, 3
    xor edx, edx
    mov ecx, 3
    div ecx
    mov [rbx + Dialog.focus_btn], edx
    mov rax, [rbx + Dialog.app]
    mov dword ptr [rax + App.need_redraw], 1
    mov eax, 1
    pop rbx
    ret
.Lvk_enter:
    mov ecx, [rbx + Dialog.focus_btn]
    inc ecx                           # button 0..2 -> PV_MODE_IMAGE..TEXT
.Lvk_pick:
    mov [rbx + ViewAsDialog.choice], ecx
    mov rdi, rbx
    call Dialog_on_confirm
    mov eax, 1
    pop rbx
    ret
.Lvk_cancel:
    mov rdi, rbx
    call Dialog_on_cancel
    mov eax, 1
    pop rbx
    ret

# int ViewAsDialog_on_mouse(ViewAsDialog *this, Event *evt) -- click on a button picks it
ViewAsDialog_on_mouse:
    cmp dword ptr [rsi + Event.mouse_kind], MACT_PRESS
    jne .Lvm_none
    mov r8d, [rsi + Event.mouse_x]
    mov r9d, [rsi + Event.mouse_y]
    xor ecx, ecx
.Lvm_loop:
    cmp ecx, 3
    jge .Lvm_none
    imul rdx, rcx, HitZone._size
    lea r10, [rdi + Dialog.btns + rdx]
    movsx eax, word ptr [r10 + HitZone.y]
    cmp r9d, eax
    jne .Lvm_next
    movsx eax, word ptr [r10 + HitZone.x1]
    cmp r8d, eax
    jl .Lvm_next
    movsx eax, word ptr [r10 + HitZone.x2]
    cmp r8d, eax
    jge .Lvm_next
    inc ecx
    mov [rdi + ViewAsDialog.choice], ecx
    push rdi
    call Dialog_on_confirm
    pop rdi
    mov eax, 1
    ret
.Lvm_next:
    inc ecx
    jmp .Lvm_loop
.Lvm_none:
    xor eax, eax
    ret
