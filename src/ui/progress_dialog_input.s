# ProgressDialog (Inherits from Dialog) — progress dialog input (split from progress_dialog.s)

.intel_syntax noprefix
.include "classes.inc"
.equ PD_W_MAX,  66
.equ PD_W_MIN,  44
.equ PD_H,      9
.equ PD_BTNS,   3
.equ PD_BUF,    192

.section .text
.global ProgressDialog_on_key
.global ProgressDialog_on_mouse

# int ProgressDialog_on_key(ProgressDialog *this, Event *evt)
ProgressDialog_on_key:
    push rbx
    mov rbx, rdi
    mov eax, [rsi + Event.key]
    mov ecx, [rsi + Event.mods]
    test ecx, MOD_ALT
    jz .Lpdk_plain
    cmp eax, 'j';    je .Lpdk_hide
    cmp eax, 'J';    je .Lpdk_hide
    cmp eax, 0x043E; je .Lpdk_hide   # Cyrillic 'о' (Alt+J on Ukrainian layout)
    cmp eax, 0x041E; je .Lpdk_hide   # Cyrillic 'О'
    jmp .Lpdk_swallow
.Lpdk_plain:
    test ecx, MOD_CTRL
    jnz .Lpdk_swallow
    cmp eax, KEY_ESC;   je .Lpdk_hide
    cmp eax, KEY_TAB;   je .Lpdk_next
    cmp eax, KEY_RIGHT; je .Lpdk_next
    cmp eax, KEY_BTAB;  je .Lpdk_prev
    cmp eax, KEY_LEFT;  je .Lpdk_prev
    cmp eax, KEY_ENTER; je .Lpdk_enter
    cmp eax, ' ';       je .Lpdk_pause
    cmp eax, 'p';       je .Lpdk_pause
    cmp eax, 'P';       je .Lpdk_pause
    cmp eax, 0x0437;    je .Lpdk_pause   # 'з' (P key, Ukrainian layout)
    cmp eax, 0x0417;    je .Lpdk_pause   # 'З'
    cmp eax, 'b';       je .Lpdk_hide
    cmp eax, 'B';       je .Lpdk_hide
    cmp eax, 0x0438;    je .Lpdk_hide    # 'и' (B key)
    cmp eax, 0x0418;    je .Lpdk_hide    # 'И'
    cmp eax, 'c';       je .Lpdk_cancel
    cmp eax, 'C';       je .Lpdk_cancel
    cmp eax, 0x0441;    je .Lpdk_cancel  # 'с' (C key)
    cmp eax, 0x0421;    je .Lpdk_cancel  # 'С'
    jmp .Lpdk_swallow

.Lpdk_next:
    mov eax, [rbx + Dialog.focus_btn]
    inc eax
    jmp .Lpdk_focus
.Lpdk_prev:
    mov eax, [rbx + Dialog.focus_btn]
    add eax, PD_BTNS - 1
.Lpdk_focus:
    xor edx, edx
    mov ecx, PD_BTNS
    div ecx
    mov [rbx + Dialog.focus_btn], edx
    mov rax, [rbx + Dialog.app]
    mov dword ptr [rax + App.need_redraw], 1
    jmp .Lpdk_swallow
.Lpdk_enter:
    mov esi, [rbx + Dialog.focus_btn]
    jmp .Lpdk_act
.Lpdk_pause:
    xor esi, esi
    jmp .Lpdk_act
.Lpdk_hide:
    mov esi, 1
    jmp .Lpdk_act
.Lpdk_cancel:
    mov esi, 2
.Lpdk_act:
    mov rdi, rbx
    call pd_activate
.Lpdk_swallow:
    mov eax, 1
    pop rbx
    ret

# int ProgressDialog_on_mouse(ProgressDialog *this, Event *evt)
ProgressDialog_on_mouse:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r8d, [r12 + Event.mouse_x]
    mov r9d, [r12 + Event.mouse_y]
    mov r13d, -1
    xor ecx, ecx
.Lpdm_find:
    cmp ecx, [rbx + Dialog.btn_count]
    jge .Lpdm_found
    imul rax, rcx, HitZone._size
    lea r10, [rbx + Dialog.btns + rax]
    movsx edx, word ptr [r10 + HitZone.y]
    cmp r9d, edx
    jne .Lpdm_next
    movsx edx, word ptr [r10 + HitZone.x1]
    cmp r8d, edx
    jl .Lpdm_next
    movsx edx, word ptr [r10 + HitZone.x2]
    cmp r8d, edx
    jge .Lpdm_next
    movsx r13d, word ptr [r10 + HitZone.id]
    jmp .Lpdm_found
.Lpdm_next:
    inc ecx
    jmp .Lpdm_find
.Lpdm_found:
    mov eax, [r12 + Event.mouse_kind]
    cmp eax, MACT_MOVE
    je .Lpdm_hover
    cmp eax, MACT_PRESS
    jne .Lpdm_swallow
    cmp dword ptr [r12 + Event.mouse_btn], MOUSE_LEFT
    jne .Lpdm_swallow
    test r13d, r13d
    js .Lpdm_swallow
    mov rdi, rbx
    mov esi, r13d
    call pd_activate
    jmp .Lpdm_swallow
.Lpdm_hover:
    cmp r13d, [rbx + Dialog.hovered_btn]
    je .Lpdm_swallow
    mov [rbx + Dialog.hovered_btn], r13d
    mov rax, [rbx + Dialog.app]
    mov dword ptr [rax + App.need_redraw], 1
.Lpdm_swallow:
    mov eax, 1
    pop r13
    pop r12
    pop rbx
    ret
