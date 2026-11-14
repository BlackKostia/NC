# Duop File Conflict Dialog ([ Overwrite ] / [ Skip ] / [ Rename ] / [ For all ]) — conflict dialog input (split from conflict_dialog.s)

.intel_syntax noprefix
.include "classes.inc"

.section .text
.global ConflictDialog_on_key
.global ConflictDialog_on_mouse

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
