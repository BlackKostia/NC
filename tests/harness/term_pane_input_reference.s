# Frozen reference oracle: the hand-written asm that src/ui/term_pane_input.c replaced (tests/test_c_ui_leaf1.py diffs against it)
# Embedded Bottom PTY Terminal Pane (Ctrl+`) — term pane input (split from term_pane.s)

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"
.equ TERM_COLS, 160
.equ TERM_ROWS, 48
.equ TERM_BUF_SZ, (TERM_COLS * TERM_ROWS)

.section .text
.global term_on_key
.global term_shutdown

# int term_on_key(App *app, Event *evt) -> 1 if consumed
term_on_key:
    push rbx; push r12
    sub rsp, 24
    mov rbx, rdi; mov r12, rsi
    cmp dword ptr [rip + g_term_visible], 0
    je .Ltok_zero
    cmp dword ptr [r12 + Event.mods], MOD_CTRL
    jne .Ltok_send
    cmp dword ptr [r12 + Event.key], '`'
    jne .Ltok_send
    mov rdi, rbx; call term_toggle
    mov eax, 2; jmp .Ltok_ret

.Ltok_send:
    mov eax, [rip + g_term_fd]
    test eax, eax; js .Ltok_one
    mov rdi, r12; mov rsi, rsp
    call term_key_encode
    test eax, eax; js .Ltok_zero
    jz .Ltok_one
    mov edx, eax
    mov edi, [rip + g_term_fd]; mov rsi, rsp
    call os_pty_write
.Ltok_one:
    mov eax, 1; jmp .Ltok_ret
.Ltok_zero:
    xor eax, eax
.Ltok_ret:
    add rsp, 24; pop r12; pop rbx; ret

term_shutdown:
    cmp dword ptr [rip + g_term_inited], 0; je .Lts_done
    mov edi, [rip + g_term_fd]
    test edi, edi; js .Lts_done
    call os_pty_close
    mov dword ptr [rip + g_term_fd], -1
.Lts_done:
    ret
