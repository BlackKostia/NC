# StatusBar Widget (Inherits from Widget)
# Shows temporary status notifications, background task progress, active filter indicator,
# or detailed entry info.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .rodata
str_StatusBar:    .asciz "StatusBar"

StatusBar_vtbl:
    WIDGET_VTBL_SLOTS str_StatusBar, Widget_vtbl, StatusBar._size, Widget_dtor, Widget_layout, StatusBar_render, Widget_on_key, Widget_on_mouse, Widget_on_focus, Widget_hit_test

.section .text
.global StatusBar_new
.global StatusBar_set_message
.global StatusBar_vtbl

# StatusBar *StatusBar_new(App *app)
StatusBar_new:
    push rbx
    push r12
    mov r12, rdi
    NEW_OBJ StatusBar_vtbl, StatusBar._size
    test rax, rax
    jz .Lsbn_done
    mov rbx, rax
    mov rdi, rbx
    mov rsi, r12
    mov edx, 102
    call Widget_init
    mov [rbx + StatusBar.app], r12
    mov rax, rbx
.Lsbn_done:
    pop r12
    pop rbx
    ret

# void StatusBar_set_message(StatusBar *this, const char *msg, int kind, int ttl_ms)
StatusBar_set_message:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12d, edx             # kind
    mov r13d, ecx             # ttl_ms

    lea rdi, [rbx + StatusBar.msg]
    # rsi = msg
    mov edx, STATUS_MAX
    call str_copy
    mov [rbx + StatusBar.msg_kind], r12d

    call sys_clock_ms
    movsxd rcx, r13d
    add rax, rcx
    mov [rbx + StatusBar.msg_expire_ms], rax

    pop r13
    pop r12
    pop rbx
    ret
