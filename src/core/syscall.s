# Terminal Raw Mode, Signal Handlers, Clock, Environment, and Subprocess Helpers
# Kernel ABI details live in src/os/$(OS)/$(ARCH)/pal_os.s and include/os/$(OS)/$(ARCH)/pal_target.inc

.intel_syntax noprefix
.include "pal.inc"

.section .rodata
seq_term_enter:
    .ascii "\x1b[?1049h\x1b[?25l\x1b[?1000h\x1b[?1002h\x1b[?1003h\x1b[?1006h"
.equ seq_term_enter_len, . - seq_term_enter

seq_term_exit:
    .ascii "\x1b[?1006l\x1b[?1003l\x1b[?1002l\x1b[?1000l\x1b[?25h\x1b[0m\x1b[?1049l"
.equ seq_term_exit_len, . - seq_term_exit

str_bin_sh:
    .asciz "/bin/sh"
str_dash_c:
    .asciz "-c"

.section .bss
.align 8
.global g_sigwinch
g_sigwinch:
    .space 4
.global g_sigterm
g_sigterm:
    .space 4

.section .text
.global sys_write_all
.global sys_read_retry
.global sys_clock_ms
.global sys_get_winsize
.global term_enter_raw
.global term_exit_raw
.global signals_install
.global env_getenv
.global sys_exec_sh_arg

# ssize_t sys_write_all(int fd, const void *buf, size_t len)
sys_write_all:
    push rbx
    push r12
    push r13
    push r14
    mov ebx, edi              # fd
    mov r12, rsi              # buf
    mov r13, rdx              # remaining
    xor r14d, r14d            # written total
.Lswa_loop:
    test r13, r13
    jz .Lswa_ok
    mov edi, ebx
    mov rsi, r12
    mov rdx, r13
    OS_WRITE
    cmp rax, -EINTR
    je .Lswa_loop
    test rax, rax
    js .Lswa_err
    jz .Lswa_ok
    add r12, rax
    sub r13, rax
    add r14, rax
    jmp .Lswa_loop
.Lswa_ok:
    mov rax, r14
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.Lswa_err:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# ssize_t sys_read_retry(int fd, void *buf, size_t len)
sys_read_retry:
    push rbx
    push r12
    push r13
    mov ebx, edi
    mov r12, rsi
    mov r13, rdx
.Lsrr_loop:
    mov edi, ebx
    mov rsi, r12
    mov rdx, r13
    OS_READ
    cmp rax, -EINTR
    je .Lsrr_loop
    pop r13
    pop r12
    pop rbx
    ret

# int64_t sys_clock_ms(void)
sys_clock_ms:
    jmp os_clock_ms

# void sys_get_winsize(int *cols, int *rows)
sys_get_winsize:
    jmp os_get_winsize

# int term_enter_raw(void)
term_enter_raw:
    sub rsp, 8
    call os_term_save_and_raw
    mov edi, STDOUT_FD
    lea rsi, [rip + seq_term_enter]
    mov edx, seq_term_enter_len
    call sys_write_all
    xor eax, eax
    add rsp, 8
    ret

# void term_exit_raw(void)
term_exit_raw:
    sub rsp, 8
    mov edi, STDOUT_FD
    lea rsi, [rip + seq_term_exit]
    mov edx, seq_term_exit_len
    call sys_write_all
    call os_term_restore
    add rsp, 8
    ret

on_sigwinch:
    mov dword ptr [rip + g_sigwinch], 1
    ret

on_sigterm:
    mov dword ptr [rip + g_sigterm], 1
    ret

# void signals_install(void)
signals_install:
    lea rdi, [rip + on_sigwinch]
    lea rsi, [rip + on_sigterm]
    jmp os_signals_install

# const char *env_getenv(char **envp, const char *name)
# rdi = envp, rsi = name (without '=') -> rax = value ptr or 0
env_getenv:
    push rbx
    push r12
    push r13
    mov rbx, rdi              # envp
    mov r12, rsi              # name
    test rbx, rbx
    jz .Leg_miss
    mov rdi, r12
    call str_len
    mov r13, rax              # name_len
.Leg_loop:
    mov rcx, [rbx]
    test rcx, rcx
    jz .Leg_miss
    mov rdi, rcx
    mov rsi, r12
    call str_starts_with
    test eax, eax
    jz .Leg_next
    mov rcx, [rbx]
    cmp byte ptr [rcx + r13], '='
    jne .Leg_next
    lea rax, [rcx + r13 + 1]
    pop r13
    pop r12
    pop rbx
    ret
.Leg_next:
    add rbx, 8
    jmp .Leg_loop
.Leg_miss:
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    ret

# int sys_exec_sh_arg(const char *sh_script, const char *arg1_or_null, char **envp)
# Exits raw mode, runs `/bin/sh -c <sh_script> sh [arg1]`, waits, re-enters raw mode.
sys_exec_sh_arg:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rdi              # script
    mov r13, rsi              # arg1 (or NULL)
    mov r14, rdx              # envp

    call term_exit_raw

    OS_FORK
    test rax, rax
    js .Lexec_parent_restore
    jnz .Lexec_parent

    # Child process: build argv on stack
    # ["/bin/sh", "-c", sh_script, "sh", arg1, NULL]
    sub rsp, 48
    lea rax, [rip + str_bin_sh]
    mov [rsp + 0], rax
    lea rcx, [rip + str_dash_c]
    mov [rsp + 8], rcx
    mov [rsp + 16], r12
    lea rcx, [rip + str_bin_sh + 5]  # "sh"
    mov [rsp + 24], rcx
    mov [rsp + 32], r13
    mov qword ptr [rsp + 40], 0

    mov rdi, rax              # "/bin/sh"
    mov rsi, rsp              # argv
    mov rdx, r14              # envp
    OS_EXECVE

    mov edi, 127
    OS_EXIT

.Lexec_parent:
    mov rbx, rax              # child pid
    sub rsp, 16               # status slot
.Lexec_wait:
    mov rdi, rbx
    mov rsi, rsp
    xor edx, edx
    xor r10d, r10d
    OS_WAIT4
    cmp rax, -EINTR
    je .Lexec_wait
    mov eax, [rsp]
    add rsp, 16

.Lexec_parent_restore:
    push rax
    call term_enter_raw
    pop rax
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
