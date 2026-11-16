# Duop PAL: Linux x86-64 PTY master/slave spawn and resize helpers

.intel_syntax noprefix
.include "pal.inc"

.equ OS_SYS_fork,   57
.equ OS_SYS_execve, 59
.equ OS_SYS_chdir,  80
.equ O_NOCTTY,      0x100
.global os_poll_out

.macro OS_IOCTL
    mov eax, OS_SYS_ioctl
    syscall
.endm

.section .rodata
ptmx_path: .asciz "/dev/ptmx"
pts_pfx:   .asciz "/dev/pts/"
sh_path:   .asciz "/bin/sh"

.section .text
.global os_pty_spawn
.global os_pty_resize
.global os_pty_read
.global os_pty_write
.global os_pty_close
.global os_get_winsize_px

# void pty_format_pts_path(int num, char *out)
pty_format_pts_path:
    mov r8d, edi
    mov rdi, rsi
    lea rsi, [rip + pts_pfx]
    mov ecx, 9
    rep movsb
    sub rsp, 32
    lea r9, [rsp + 31]
    mov byte ptr [r9], 0
    mov eax, r8d
    mov ecx, 10
.Lpfpp_dec:
    xor edx, edx
    div ecx
    add dl, '0'
    dec r9
    mov [r9], dl
    test eax, eax
    jnz .Lpfpp_dec
.Lpfpp_cp:
    mov al, [r9]
    mov [rdi], al
    inc r9; inc rdi
    test al, al
    jnz .Lpfpp_cp
    add rsp, 32
    ret

# void pty_exec_child(int master_fd, const char *pts_path, const char *cwd, char **envp) __noreturn
pty_exec_child:
    push r12; push r13; push r14
    sub rsp, 32
    mov r12, rsi              # pts_path
    mov r13, rdx              # cwd
    mov r14, rcx              # envp
    OS_CLOSE
    OS_SETSID
    mov edi, AT_FDCWD
    mov rsi, r12
    mov edx, O_RDWR
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
    js .Lpec_exit
    mov ebx, eax
    mov edi, ebx; mov esi, OS_TIOCSCTTY; xor edx, edx; OS_IOCTL
    mov edi, ebx; xor esi, esi; OS_DUP2
    mov edi, ebx; mov esi, 1;   OS_DUP2
    mov edi, ebx; mov esi, 2;   OS_DUP2
    cmp ebx, 2; jle .Lpec_chdir
    mov edi, ebx; OS_CLOSE
.Lpec_chdir:
    test r13, r13; jz .Lpec_exec
    mov rdi, r13; mov eax, OS_SYS_chdir; syscall
.Lpec_exec:
    call os_sig_reset_pipe
    lea rax, [rip + sh_path]
    mov [rsp], rax
    mov qword ptr [rsp + 8], 0
    mov rdi, rax; mov rsi, rsp; mov rdx, r14
    mov eax, OS_SYS_execve; syscall
.Lpec_exit:
    mov edi, 127; OS_EXIT

# int os_pty_spawn(int *out_master_fd, int *out_pid, const char *cwd, char **envp, int cols, int rows)
os_pty_spawn:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, 96
    mov r12, rdi; mov r13, rsi; mov r14, rdx; mov r15, rcx
    mov [rsp + 0], r8d; mov [rsp + 4], r9d

    mov edi, AT_FDCWD; lea rsi, [rip + ptmx_path]
    mov edx, O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC; xor r10d, r10d
    OS_OPENAT
    test rax, rax; js .Lops_ret
    mov ebx, eax

    mov dword ptr [rsp + 8], 0
    mov edi, ebx; mov esi, OS_TIOCSPTLCK; lea rdx, [rsp + 8]; OS_IOCTL
    test rax, rax; js .Lops_close_err

    mov dword ptr [rsp + 12], 0
    mov edi, ebx; mov esi, OS_TIOCGPTN; lea rdx, [rsp + 12]; OS_IOCTL
    test rax, rax; js .Lops_close_err

    mov edi, [rsp + 12]; lea rsi, [rsp + 16]
    call pty_format_pts_path

    mov edi, ebx; mov esi, [rsp + 0]; mov edx, [rsp + 4]
    call os_pty_resize

    mov eax, OS_SYS_fork; syscall
    test rax, rax; js .Lops_close_err
    jnz .Lops_parent

    mov edi, ebx; lea rsi, [rsp + 16]; mov rdx, r14; mov rcx, r15
    call pty_exec_child

.Lops_parent:
    mov [r12], ebx; mov [r13], eax; xor eax, eax; jmp .Lops_ret
.Lops_close_err:
    push rax; mov edi, ebx; OS_CLOSE; pop rax
.Lops_ret:
    add rsp, 96; pop r15; pop r14; pop r13; pop r12; pop rbx; ret

# void os_pty_resize(int master_fd, int cols, int rows)
os_pty_resize:
    sub rsp, 16
    mov [rsp + 0], dx         # ws_row
    mov [rsp + 2], si         # ws_col
    mov dword ptr [rsp + 4], 0
    mov esi, OS_TIOCSWINSZ; mov rdx, rsp; OS_IOCTL
    add rsp, 16; ret

# long os_pty_read(int fd, void *buf, long len)
os_pty_read:
    OS_READ
    ret

# long os_pty_write(int fd, const void *buf, long len)
os_pty_write:
    OS_WRITE
    ret

# void os_pty_close(int fd)
os_pty_close:
    OS_CLOSE
    ret

# void os_get_winsize_px(int *xpix, int *ypix) -- terminal size in pixels (0, 0 when not reported)
os_get_winsize_px:
    mov r8, rdi
    mov r9, rsi
    mov dword ptr [r8], 0
    mov dword ptr [r9], 0
    sub rsp, 16
    mov edi, STDOUT_FD
    mov esi, TIOCGWINSZ
    mov rdx, rsp
    OS_IOCTL
    test rax, rax
    js 1f
    movzx eax, word ptr [rsp + 4]     # ws_xpixel
    mov [r8], eax
    movzx eax, word ptr [rsp + 6]     # ws_ypixel
    mov [r9], eax
1:  add rsp, 16
    ret

# int os_poll_out(int fd, int timeout_ms)
os_poll_out:
    sub rsp, 40
    mov dword ptr [rsp + POLLFD_FD], edi
    mov word ptr [rsp + POLLFD_EVENTS], POLLOUT
    mov word ptr [rsp + POLLFD_REVENTS], 0
    xor edx, edx
    test esi, esi; js .Lopo_call
    movsxd rax, esi; cqo; mov ecx, 1000; idiv rcx; imul rdx, rdx, 1000000
    mov [rsp + 16 + TIMESPEC_SEC], rax; mov [rsp + 16 + TIMESPEC_NSEC], rdx
    lea rdx, [rsp + 16]
.Lopo_call:
    mov rdi, rsp; mov esi, 1; xor r10d, r10d; mov r8d, 8
    mov eax, OS_SYS_ppoll; syscall
    add rsp, 40
    ret
