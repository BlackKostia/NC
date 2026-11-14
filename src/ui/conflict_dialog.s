# Duop File Conflict Dialog ([ Overwrite ] / [ Skip ] / [ Rename ] / [ For all ])
# Pure x86-64 GAS, zero .data, strict OOP vtable subclass of Dialog.

.intel_syntax noprefix
.include "classes.inc"

.section .rodata
str_ConflictDialog: .asciz "ConflictDialog"
str_chk_off:        .asciz "[ ] "
str_chk_on:         .asciz "[x] "
str_btn_lp:         .asciz " "
str_btn_rp:         .asciz " "

.align 8
.global ConflictDialog_vtbl
ConflictDialog_vtbl:
    DIALOG_VTBL_SLOTS str_ConflictDialog, Dialog_vtbl, ConflictDialog._size, Dialog_dtor, ConflictDialog_layout, ConflictDialog_render, ConflictDialog_on_key, ConflictDialog_on_mouse, Widget_on_focus, Widget_hit_test, Dialog_on_confirm, Dialog_on_cancel

.section .text
.global ConflictDialog_new

# ConflictDialog *ConflictDialog_new(App *app, const char *name, uint64_t src_sz, uint64_t dst_sz)
ConflictDialog_new:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi              # app
    mov r13, rsi              # name
    mov r14, rdx              # src_sz
    mov r15, rcx              # dst_sz

    NEW_OBJ ConflictDialog_vtbl, ConflictDialog._size
    mov rbx, rax
    call i18n_get
    mov rdx, [rax + LangStrings.dlg_title_conflict]
    mov rdi, rbx
    mov rsi, r12
    mov ecx, OP_CONFLICT
    call Dialog_init

    mov dword ptr [rbx + ConflictDialog.action], CONFLICT_ACT_OVERWRITE
    mov dword ptr [rbx + ConflictDialog.for_all], 0
    mov [rbx + ConflictDialog.src_size], r14
    mov [rbx + ConflictDialog.dst_size], r15
    mov dword ptr [rbx + Dialog.focus_btn], 0
    mov dword ptr [rbx + Dialog.btn_count], 3

    lea rdi, [rbx + ConflictDialog.name]
    mov rsi, r13
    mov edx, NAME_MAX
    call str_copy

    mov rdi, rbx
    xor esi, esi
    xor edx, edx
    mov ecx, [r12 + App.term_w]
    mov r8d, [r12 + App.term_h]
    call ConflictDialog_layout

    mov rax, rbx
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

ConflictDialog_layout:
    mov eax, ecx
    sub eax, 4
    cmp eax, 68
    jle .Lcdl_w_ok
    mov eax, 68
.Lcdl_w_ok:
    cmp eax, 44
    jge .Lcdl_w_min
    mov eax, 44
.Lcdl_w_min:
    mov [rdi + Widget.w], eax
    mov edx, 11
    mov [rdi + Widget.h], edx
    sub ecx, eax
    sar ecx, 1
    mov [rdi + Widget.x], ecx
    sub r8d, edx
    sar r8d, 1
    mov [rdi + Widget.y], r8d
    ret

# Helper: void cfl_draw_buttons(ConflictDialog *dlg, ScreenBuffer *scr, Theme *theme, LangStrings *lang)
cfl_draw_buttons:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rax, [rcx + LangStrings.cfl_btn_overwrite]
    mov [rsp], rax
    mov rax, [rcx + LangStrings.cfl_btn_skip]
    mov [rsp + 8], rax
    mov rax, [rcx + LangStrings.cfl_btn_rename]
    mov [rsp + 16], rax

    xor r14d, r14d
    mov r15d, [rbx + Widget.x]
    add r15d, 3
    mov dword ptr [rbx + Dialog.btn_count], 3

.Lcdb_loop:
    cmp r14d, 3
    jge .Lcdb_done
    cmp r14d, [rbx + Dialog.focus_btn]
    jne .Lcdb_norm
    mov esi, [r13 + Theme.accent_fg]
    mov edx, [r13 + Theme.accent]
    mov ecx, ATTR_BOLD
    jmp .Lcdb_pen
.Lcdb_norm:
    mov esi, [r13 + Theme.text]
    mov edx, [r13 + Theme.surface_alt]
    xor ecx, ecx
.Lcdb_pen:
    mov rdi, r12
    call ScreenBuffer_set_pen

    mov rdi, [rsp + r14*8]
    call utf8_display_width
    lea ecx, [eax + 2]
    mov [rsp + 24], ecx

    imul rdx, r14, HitZone._size
    lea r8, [rbx + Dialog.btns + rdx]
    mov word ptr [r8 + HitZone.x1], r15w
    mov eax, [rbx + Widget.y]
    add eax, 6
    mov word ptr [r8 + HitZone.y], ax
    lea eax, [r15d + ecx]
    mov word ptr [r8 + HitZone.x2], ax
    mov word ptr [r8 + HitZone.id], r14w

    mov rdi, r12
    mov esi, r15d
    mov edx, [rbx + Widget.y]
    add edx, 6
    lea rcx, [rip + str_btn_lp]
    mov r8d, 2
    call ScreenBuffer_draw_text

    mov rdi, r12
    lea esi, [r15d + 1]
    mov edx, [rbx + Widget.y]
    add edx, 6
    mov rcx, [rsp + r14*8]
    mov r8d, 24
    call ScreenBuffer_draw_text

    mov eax, [rsp + 24]
    mov rdi, r12
    lea esi, [r15d + eax - 1]
    mov edx, [rbx + Widget.y]
    add edx, 6
    lea rcx, [rip + str_btn_rp]
    mov r8d, 2
    call ScreenBuffer_draw_text

    add r15d, [rsp + 24]
    add r15d, 2
    inc r14d
    jmp .Lcdb_loop

.Lcdb_done:
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

ConflictDialog_render:
    push rbx
    push r12
    push r13
    push r14
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

    mov rdi, r12
    mov esi, [r13 + Theme.text]
    mov edx, [r13 + Theme.surface]
    mov ecx, ATTR_BOLD
    call ScreenBuffer_set_pen
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 3
    mov edx, [rbx + Widget.y]
    add edx, 2
    lea rcx, [rbx + ConflictDialog.name]
    mov r8d, [rbx + Widget.w]
    sub r8d, 6
    call ScreenBuffer_draw_text

    mov rdi, r12
    mov esi, [r13 + Theme.accent]
    mov edx, [r13 + Theme.surface]
    xor ecx, ecx
    call ScreenBuffer_set_pen

    lea rcx, [rip + str_chk_off]
    cmp dword ptr [rbx + ConflictDialog.for_all], 0
    je .Lcdr_chk
    lea rcx, [rip + str_chk_on]
.Lcdr_chk:
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 3
    mov edx, [rbx + Widget.y]
    add edx, 4
    mov r8d, 6
    call ScreenBuffer_draw_text

    call i18n_get
    mov r14, rax
    mov rcx, [r14 + LangStrings.cfl_lbl_forall]
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 7
    mov edx, [rbx + Widget.y]
    add edx, 4
    mov r8d, 24
    call ScreenBuffer_draw_text

    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov rcx, r14
    call cfl_draw_buttons

    mov rdi, r12
    mov esi, [r13 + Theme.muted]
    mov edx, [r13 + Theme.surface]
    xor ecx, ecx
    call ScreenBuffer_set_pen
    mov rcx, [r14 + LangStrings.cfl_hint]
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 3
    mov edx, [rbx + Widget.y]
    add edx, 8
    mov r8d, [rbx + Widget.w]
    sub r8d, 6
    call ScreenBuffer_draw_text

    pop r14
    pop r13
    pop r12
    pop rbx
    ret

ConflictDialog_on_key:
    push rbx
    mov rbx, rdi
    mov eax, [rsi + Event.key]

    cmp eax, KEY_ESC;   je .Lcd_cancel
    cmp eax, 'a';       je .Lcd_forall
    cmp eax, 'A';       je .Lcd_forall
    cmp eax, 'o';       je .Lcd_over
    cmp eax, 'O';       je .Lcd_over
    cmp eax, 's';       je .Lcd_skip
    cmp eax, 'S';       je .Lcd_skip
    cmp eax, 'r';       je .Lcd_ren
    cmp eax, 'R';       je .Lcd_ren
    cmp eax, KEY_LEFT;  je .Lcd_left
    cmp eax, KEY_RIGHT; je .Lcd_right
    cmp eax, KEY_TAB;   je .Lcd_right
    cmp eax, KEY_ENTER; je .Lcd_enter
    xor eax, eax
    pop rbx
    ret

.Lcd_forall:
    xor dword ptr [rbx + ConflictDialog.for_all], 1
    mov rax, [rbx + Dialog.app]
    mov dword ptr [rax + App.need_redraw], 1
    mov eax, 1
    pop rbx
    ret

.Lcd_left:
    mov eax, [rbx + Dialog.focus_btn]
    dec eax
    jns .Lcd_set_f
    mov eax, 2
    jmp .Lcd_set_f

.Lcd_right:
    mov eax, [rbx + Dialog.focus_btn]
    inc eax
    cmp eax, 3
    jl .Lcd_set_f
    xor eax, eax
.Lcd_set_f:
    mov [rbx + Dialog.focus_btn], eax
    mov rax, [rbx + Dialog.app]
    mov dword ptr [rax + App.need_redraw], 1
    mov eax, 1
    pop rbx
    ret

.Lcd_enter:
    mov eax, [rbx + Dialog.focus_btn]
    inc eax
    mov [rbx + ConflictDialog.action], eax
    jmp .Lcd_ok

.Lcd_over:
    mov dword ptr [rbx + ConflictDialog.action], CONFLICT_ACT_OVERWRITE
    jmp .Lcd_ok
.Lcd_skip:
    mov dword ptr [rbx + ConflictDialog.action], CONFLICT_ACT_SKIP
    jmp .Lcd_ok
.Lcd_ren:
    mov dword ptr [rbx + ConflictDialog.action], CONFLICT_ACT_RENAME
.Lcd_ok:
    mov rdi, rbx
    call Dialog_on_confirm
    mov eax, 1
    pop rbx
    ret

.Lcd_cancel:
    mov rdi, rbx
    call Dialog_on_cancel
    mov eax, 1
    pop rbx
    ret

ConflictDialog_on_mouse:
    push rbx
    mov rbx, rdi
    cmp dword ptr [rsi + Event.mouse_kind], MACT_PRESS
    jne .Lcdm_none
    mov r8d, [rsi + Event.mouse_x]
    mov r9d, [rsi + Event.mouse_y]

    mov eax, [rbx + Widget.y]
    add eax, 4
    cmp r9d, eax
    jne .Lcdm_btns
    xor dword ptr [rbx + ConflictDialog.for_all], 1
    mov rax, [rbx + Dialog.app]
    mov dword ptr [rax + App.need_redraw], 1
    mov eax, 1
    pop rbx
    ret

.Lcdm_btns:
    xor ecx, ecx
.Lcdm_bloop:
    cmp ecx, 3
    jge .Lcdm_none
    imul rdx, rcx, HitZone._size
    lea r10, [rbx + Dialog.btns + rdx]
    movsx eax, word ptr [r10 + HitZone.y]
    cmp r9d, eax
    jne .Lcdm_bnext
    movsx eax, word ptr [r10 + HitZone.x1]
    cmp r8d, eax
    jl .Lcdm_bnext
    movsx eax, word ptr [r10 + HitZone.x2]
    cmp r8d, eax
    jge .Lcdm_bnext
    movsx eax, word ptr [r10 + HitZone.id]
    inc eax
    mov [rbx + ConflictDialog.action], eax
    mov rdi, rbx
    call Dialog_on_confirm
    mov eax, 1
    pop rbx
    ret
.Lcdm_bnext:
    inc ecx
    jmp .Lcdm_bloop
.Lcdm_none:
    xor eax, eax
    pop rbx
    ret
