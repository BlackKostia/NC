# Frozen reference oracle: src/ui/function_bar.s (before C23 migration to src/ui/function_bar.c).
# FunctionBar Widget (Inherits from Widget)
# Bottom interactive F1..F10 action bar with hover highlights and mouse click dispatch.

.intel_syntax noprefix
.include "classes.inc"

.section .rodata
str_FunctionBar: .asciz "FunctionBar"

f_nums:
    .quad fnum_1, fnum_2, fnum_3, fnum_4, fnum_5, fnum_6, fnum_7, fnum_8, fnum_9, fnum_0

fnum_1: .asciz "1"
fnum_2: .asciz "2"
fnum_3: .asciz "3"
fnum_4: .asciz "4"
fnum_5: .asciz "5"
fnum_6: .asciz "6"
fnum_7: .asciz "7"
fnum_8: .asciz "8"
fnum_9: .asciz "9"
fnum_0: .asciz "0"

.global FunctionBar_vtbl
FunctionBar_vtbl:
    WIDGET_VTBL_SLOTS str_FunctionBar, Widget_vtbl, FunctionBar._size, Widget_dtor, FunctionBar_layout, FunctionBar_render, Widget_on_key, FunctionBar_on_mouse, Widget_on_focus, Widget_hit_test

.section .text
.global FunctionBar_new
.global FunctionBar_layout
.global FunctionBar_render
.global FunctionBar_on_mouse

# FunctionBar *FunctionBar_new(App *app)
FunctionBar_new:
    push rbx
    push r12
    mov r12, rdi

    NEW_OBJ FunctionBar_vtbl, FunctionBar._size
    test rax, rax
    jz .Lfbn_done
    mov rbx, rax

    mov rdi, rbx
    mov rsi, r12
    mov edx, 101
    call Widget_init
    mov [rbx + FunctionBar.app], r12
    mov dword ptr [rbx + FunctionBar.hovered_id], -1
    mov rax, rbx
.Lfbn_done:
    pop r12
    pop rbx
    ret

# void FunctionBar_layout(FunctionBar *this, int x, int y, int w, int h)
FunctionBar_layout:
    push rbx
    push r12
    mov rbx, rdi
    mov r12d, ecx             # w
    call Widget_layout

    mov dword ptr [rbx + FunctionBar.zone_count], 10
    xor ecx, ecx              # i = 0..9
.Lfbl_loop:
    cmp ecx, 10
    jge .Lfbl_done
    # x1 = x + (i * w) / 10, x2 = x + ((i+1) * w) / 10
    mov eax, ecx
    imul eax, r12d
    xor edx, edx
    mov r8d, 10
    div r8d
    add eax, [rbx + Widget.x]
    mov r9d, eax              # x1

    lea eax, [ecx + 1]
    imul eax, r12d
    xor edx, edx
    div r8d
    add eax, [rbx + Widget.x]
    mov r10d, eax             # x2

    imul rax, rcx, HitZone._size
    lea rax, [rbx + FunctionBar.zones + rax]
    mov [rax + HitZone.x1], r9w
    mov [rax + HitZone.x2], r10w
    mov dx, [rbx + Widget.y]
    mov [rax + HitZone.y], dx
    mov [rax + HitZone.id], cx

    inc ecx
    jmp .Lfbl_loop
.Lfbl_done:
    pop r12
    pop rbx
    ret

# void FunctionBar_render(FunctionBar *this, ScreenBuffer *scr, Theme *theme)
FunctionBar_render:
    push rbx
    push r12
    push r13
    push r14
    push r15
    call FunctionBar_render__fill_background
    xor r14d, r14d            # idx = 0..9
.Lfbr_loop:
    cmp r14d, 10
    jge .Lfbr_done
    call FunctionBar_render__btn_w
    call FunctionBar_render__draw_key_badge_digit
.Lfbr_next:
    inc r14d
    jmp .Lfbr_loop

.Lfbr_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# FunctionBar_render step: Fill background (runs on the caller's frame)
FunctionBar_render__fill_background:
    lea rsp, [rsp - 8]
    mov rbx, rdi              # this
    mov r12, rsi              # scr
    mov r13, rdx              # theme

    # Fill background
    mov rdi, r12
    mov esi, [r13 + Theme.text]
    mov edx, [r13 + Theme.header_bg]
    xor ecx, ecx
    call ScreenBuffer_set_pen

    mov rdi, r12
    mov esi, [rbx + Widget.x]
    mov edx, [rbx + Widget.y]
    mov ecx, [rbx + Widget.w]
    mov r8d, 1
    mov r9d, ' '
    call ScreenBuffer_fill_rect

.LFunctionBar_render__fill_background_ret:
    lea rsp, [rsp + 8]
    ret

# FunctionBar_render step: btn_w (runs on the caller's frame)
FunctionBar_render__btn_w:
    lea rsp, [rsp - 8]
    imul rax, r14, HitZone._size
    lea r15, [rbx + FunctionBar.zones + rax]
    movsx esi, word ptr [r15 + HitZone.x1]
    movsx ecx, word ptr [r15 + HitZone.x2]
    sub ecx, esi              # btn_w
    cmp ecx, 3
.LFunctionBar_render__btn_w_ret:
    lea rsp, [rsp + 8]
    ret

# FunctionBar_render step: Draw key badge digit (runs on the caller's frame)
FunctionBar_render__draw_key_badge_digit:
    lea rsp, [rsp - 8]
    jl .LFunctionBar_render__draw_key_badge_digit_ret

    push rsi
    push rcx

    # Draw key badge digit ("1".."0")
    mov rdi, r12
    mov esi, [r13 + Theme.accent_fg]
    mov edx, [r13 + Theme.accent]
    cmp r14d, [rbx + FunctionBar.hovered_id]
    jne .Lfbr_num_pen
    mov edx, [r13 + Theme.dir_fg]
.Lfbr_num_pen:
    mov ecx, ATTR_BOLD
    call ScreenBuffer_set_pen

    mov rdi, r12
    mov esi, [rsp + 8]        # x1
    mov edx, [rbx + Widget.y]
    lea rax, [rip + f_nums]
    mov rcx, [rax + r14*8]
    mov r8d, 2
    call ScreenBuffer_draw_text

    # Draw label pill
    mov eax, [rsp]            # btn_w
    sub eax, 2                # space after key badge (leave 1 col gap on right if >= 4)
    cmp eax, 1
    jle .Lfbr_pop_next
    mov ecx, eax
    cmp ecx, 3
    jl .Lfbr_lbl_w_ok
    dec ecx                   # 1-col breathing gap between pills
.Lfbr_lbl_w_ok:
    push rcx

    mov rdi, r12
    mov esi, [r13 + Theme.badge_fg]
    mov edx, [r13 + Theme.badge_bg]
    xor ecx, ecx
    cmp r14d, [rbx + FunctionBar.hovered_id]
    jne .Lfbr_lbl_pen
    mov edx, [r13 + Theme.badge_hover_bg]
    mov ecx, ATTR_BOLD
.Lfbr_lbl_pen:
    call ScreenBuffer_set_pen

    call i18n_get
    mov rcx, [rax + LangStrings.f_labels + r14*8]
    mov rdi, r12
    mov esi, [rsp + 16]       # x1
    inc esi
    mov edx, [rbx + Widget.y]
    mov r8d, [rsp]            # label_w
    call ScreenBuffer_draw_text_pad

    pop rcx
.Lfbr_pop_next:
    pop rcx
    pop rsi
.LFunctionBar_render__draw_key_badge_digit_ret:
    lea rsp, [rsp + 8]
    ret

# int FunctionBar_on_mouse(FunctionBar *this, Event *evt)
FunctionBar_on_mouse:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi

    mov r8d, [r12 + Event.mouse_x]
    mov r9d, [r12 + Event.mouse_y]
    mov r13d, -1

    xor ecx, ecx
.Lfbm_find:
    cmp ecx, [rbx + FunctionBar.zone_count]
    jge .Lfbm_found
    imul rax, rcx, HitZone._size
    lea r10, [rbx + FunctionBar.zones + rax]
    movsx edx, word ptr [r10 + HitZone.y]
    cmp r9d, edx
    jne .Lfbm_fnext
    movsx edx, word ptr [r10 + HitZone.x1]
    cmp r8d, edx
    jl .Lfbm_fnext
    movsx edx, word ptr [r10 + HitZone.x2]
    cmp r8d, edx
    jge .Lfbm_fnext
    movsx r13d, word ptr [r10 + HitZone.id]
    jmp .Lfbm_found
.Lfbm_fnext:
    inc ecx
    jmp .Lfbm_find

.Lfbm_found:
    mov eax, [r12 + Event.mouse_kind]
    cmp eax, MACT_MOVE
    je .Lfbm_hover
    cmp eax, MACT_PRESS
    je .Lfbm_press
    xor eax, eax
    jmp .Lfbm_ret

.Lfbm_hover:
    cmp r13d, [rbx + FunctionBar.hovered_id]
    je .Lfbm_ret0
    mov [rbx + FunctionBar.hovered_id], r13d
    mov rax, [rbx + FunctionBar.app]
    mov dword ptr [rax + App.need_redraw], 1
.Lfbm_ret0:
    xor eax, eax
    jmp .Lfbm_ret

.Lfbm_press:
    cmp dword ptr [r12 + Event.mouse_btn], MOUSE_LEFT
    jne .Lfbm_ret0
    cmp r13d, -1
    je .Lfbm_ret0
    mov rdi, [rbx + FunctionBar.app]
    mov esi, r13d
    call App_dispatch_f_action
    mov eax, 1

.Lfbm_ret:
    pop r13
    pop r12
    pop rbx
    ret
