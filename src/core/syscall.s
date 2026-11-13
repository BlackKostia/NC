# Terminal Raw Mode, Signal Handlers, Clock, Environment, and Subprocess Helpers

.intel_syntax noprefix
.include "linux_sys.inc"

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
orig_termios:
    .space KTERMIOS_SIZE
raw_termios:
    .space KTERMIOS_SIZE
g_raw_active:
    .space 4
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
    mov rax, SYS_write
    syscall
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
    mov rax, SYS_read
    syscall
    cmp rax, -EINTR
    je .Lsrr_loop
    pop r13
    pop r12
    pop rbx
    ret

# int64_t sys_clock_ms(void)
# Returns CLOCK_MONOTONIC in milliseconds
sys_clock_ms:
    sub rsp, 16
    mov edi, CLOCK_MONOTONIC
    mov rsi, rsp
    mov rax, SYS_clock_gettime
    syscall
    mov rax, [rsp + TIMESPEC_SEC]
    imul rax, rax, 1000
    mov rcx, [rsp + TIMESPEC_NSEC]
    mov r8, 1000000
    push rax
    mov rax, rcx
    xor edx, edx
    div r8
    pop rcx
    add rax, rcx
    add rsp, 16
    ret

# void sys_get_winsize(int *cols, int *rows)
sys_get_winsize:
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    sub rsp, 16

    mov edi, STDOUT_FD
    mov esi, TIOCGWINSZ
    mov rdx, rsp
    mov rax, SYS_ioctl
    syscall
    test rax, rax
    jns .Lgw_ok

    # Try STDIN_FD as fallback
    mov edi, STDIN_FD
    mov esi, TIOCGWINSZ
    mov rdx, rsp
    mov rax, SYS_ioctl
    syscall
    test rax, rax
    js .Lgw_default

.Lgw_ok:
    movzx eax, word ptr [rsp + WINSIZE_COL]
    movzx ecx, word ptr [rsp + WINSIZE_ROW]
    test eax, eax
    jz .Lgw_default
    test ecx, ecx
    jz .Lgw_default
    mov [rbx], eax
    mov [r12], ecx
    jmp .Lgw_done

.Lgw_default:
    mov dword ptr [rbx], 80
    mov dword ptr [r12], 24
.Lgw_done:
    add rsp, 16
    pop r12
    pop rbx
    ret

# int term_enter_raw(void)
term_enter_raw:
    push rbx
    cmp dword ptr [rip + g_raw_active], 1
    je .Lter_seq

    # Save original termios
    mov edi, STDIN_FD
    mov esi, TCGETS
    lea rdx, [rip + orig_termios]
    mov rax, SYS_ioctl
    syscall
    test rax, rax
    js .Lter_seq              # proceed with ANSI even if non-tty

    # Copy orig_termios -> raw_termios
    lea rdi, [rip + raw_termios]
    lea rsi, [rip + orig_termios]
    mov edx, KTERMIOS_SIZE
    call mem_copy

    # Modify raw_termios flags
    lea rbx, [rip + raw_termios]
    mov eax, [rbx + KTERMIOS_IFLAG]
    and eax, ~(IXON | ICRNL | BRKINT | INPCK | ISTRIP)
    mov [rbx + KTERMIOS_IFLAG], eax

    mov eax, [rbx + KTERMIOS_OFLAG]
    and eax, ~OPOST
    mov [rbx + KTERMIOS_OFLAG], eax

    mov eax, [rbx + KTERMIOS_CFLAG]
    or eax, CS8
    mov [rbx + KTERMIOS_CFLAG], eax

    mov eax, [rbx + KTERMIOS_LFLAG]
    and eax, ~(ICANON | ECHO | ISIG | IEXTEN)
    mov [rbx + KTERMIOS_LFLAG], eax

    mov byte ptr [rbx + KTERMIOS_VMIN], 1
    mov byte ptr [rbx + KTERMIOS_VTIME], 0

    mov edi, STDIN_FD
    mov esi, TCSETSW
    mov rdx, rbx
    mov rax, SYS_ioctl
    syscall

    mov dword ptr [rip + g_raw_active], 1

.Lter_seq:
    mov edi, STDOUT_FD
    lea rsi, [rip + seq_term_enter]
    mov edx, seq_term_enter_len
    call sys_write_all

    xor eax, eax
    pop rbx
    ret

# void term_exit_raw(void)
term_exit_raw:
    mov edi, STDOUT_FD
    lea rsi, [rip + seq_term_exit]
    mov edx, seq_term_exit_len
    call sys_write_all

    cmp dword ptr [rip + g_raw_active], 0
    je .Ltxr_done

    mov edi, STDIN_FD
    mov esi, TCSETSW
    lea rdx, [rip + orig_termios]
    mov rax, SYS_ioctl
    syscall
    mov dword ptr [rip + g_raw_active], 0
.Ltxr_done:
    ret

# Signal trampoline for rt_sigaction SA_RESTORER
.align 16
sig_restorer:
    mov rax, SYS_rt_sigreturn
    syscall

on_sigwinch:
    mov dword ptr [rip + g_sigwinch], 1
    ret

on_sigterm:
    mov dword ptr [rip + g_sigterm], 1
    ret

# void signals_install(void)
signals_install:
    sub rsp, KSIGACTION_SIZE

    # SIGWINCH (no SA_RESTART so poll wakes immediately on resize)
    lea rax, [rip + on_sigwinch]
    mov [rsp + KSIG_HANDLER], rax
    mov qword ptr [rsp + KSIG_FLAGS], SA_RESTORER
    lea rax, [rip + sig_restorer]
    mov [rsp + KSIG_RESTORER], rax
    mov qword ptr [rsp + KSIG_MASK], 0

    mov edi, SIGWINCH
    mov rsi, rsp
    xor edx, edx
    mov r10d, 8
    mov rax, SYS_rt_sigaction
    syscall

    # SIGINT
    lea rax, [rip + on_sigterm]
    mov [rsp + KSIG_HANDLER], rax
    mov edi, SIGINT
    mov rsi, rsp
    xor edx, edx
    mov r10d, 8
    mov rax, SYS_rt_sigaction
    syscall

    # SIGTERM
    mov edi, SIGTERM
    mov rsi, rsp
    xor edx, edx
    mov r10d, 8
    mov rax, SYS_rt_sigaction
    syscall

    add rsp, KSIGACTION_SIZE
    ret

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

    mov rax, SYS_fork
    syscall
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
    mov rax, SYS_execve
    syscall

    mov edi, 127
    mov rax, SYS_exit
    syscall

.Lexec_parent:
    mov rbx, rax              # child pid
    sub rsp, 16               # status slot
.Lexec_wait:
    mov rdi, rbx
    mov rsi, rsp
    xor edx, edx
    xor r10d, r10d
    mov rax, SYS_wait4
    syscall
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
