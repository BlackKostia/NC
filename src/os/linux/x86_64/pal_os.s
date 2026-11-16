# Duop Platform Abstraction Layer Implementation: Linux x86-64
# Encapsulates kernel structs (stat, dirent64, termios, sigaction, pollfd, timespec, mremap)

.intel_syntax noprefix
.include "pal.inc"

.section .bss
.align 8
orig_termios:
    .space KTERMIOS_SIZE
raw_termios:
    .space KTERMIOS_SIZE
g_raw_active:
    .space 4

.section .text
.global os_statat
.global os_fstat
.global os_dir_read
.global os_dir_next
.global os_dir_next_ex
.global os_mem_remap
.global os_poll_in
.global os_clock_ms
.global os_get_winsize
.global os_term_save_and_raw
.global os_term_restore
.global os_poll_in2
.global os_pipe_cloexec
.global os_signals_worker_mode
.global os_clone_file
.global os_poll_many
.global os_set_nonblock
.extern pf_reg_mmap
.extern pf_unreg_mmap
.extern pf_sigbus_fallback

# Helper: void copy_kstat_to_filestat(const struct stat *kstat [rsi], FileStat *out [rdi])
copy_kstat_to_filestat:
    mov rax, [rsi + KSTAT_DEV]
    mov [rdi + FileStat.dev], rax
    mov rax, [rsi + KSTAT_INO]
    mov [rdi + FileStat.ino], rax
    mov rax, [rsi + KSTAT_ST_SIZE]
    mov [rdi + FileStat.size], rax
    mov rax, [rsi + KSTAT_MTIME]
    mov [rdi + FileStat.mtime], rax
    mov eax, [rsi + KSTAT_MODE]
    mov [rdi + FileStat.mode], eax
    mov eax, [rsi + KSTAT_MTIME_NSEC]
    mov [rdi + FileStat.mtime_nsec], eax
    mov rax, [rsi + KSTAT_NLINK]
    mov [rdi + FileStat.nlink], rax
    mov eax, [rsi + KSTAT_UID]
    mov [rdi + FileStat.uid], eax
    mov eax, [rsi + KSTAT_GID]
    mov [rdi + FileStat.gid], eax
    ret

# int os_statat(int dirfd, const char *path, FileStat *out, int follow_symlinks)
# Returns 0 on success or -errno on failure.
os_statat:
    push rbx
    sub rsp, 160
    mov rbx, rdx              # FileStat *out
    mov rdx, rsp              # &kstat
    xor r10d, r10d
    test ecx, ecx
    jnz .Losa_call
    mov r10d, AT_SYMLINK_NOFOLLOW
.Losa_call:
    mov eax, OS_SYS_newfstatat
    syscall
    test rax, rax
    js .Losa_done
    mov rdi, rbx
    mov rsi, rsp
    call copy_kstat_to_filestat
    xor eax, eax
.Losa_done:
    add rsp, 160
    pop rbx
    ret

# int os_fstat(int fd, FileStat *out)
# Returns 0 on success or -errno on failure.
os_fstat:
    push rbx
    sub rsp, 160
    mov rbx, rsi              # FileStat *out
    mov rsi, rsp              # &kstat
    mov eax, OS_SYS_fstat
    syscall
    test rax, rax
    js .Lofs_done
    mov rdi, rbx
    mov rsi, rsp
    call copy_kstat_to_filestat
    xor eax, eax
.Lofs_done:
    add rsp, 160
    pop rbx
    ret

# ssize_t os_dir_read(int dirfd, void *buf, size_t cap)
os_dir_read:
    mov eax, OS_SYS_getdents64
    syscall
    ret

# const char *os_dir_next(void *buf, size_t bytes, size_t *pos_ptr)
# Advances *pos_ptr and returns d_name pointer, or NULL when batch exhausted.
os_dir_next:
    xor ecx, ecx
# const char *os_dir_next_ex(void *buf, size_t bytes, size_t *pos_ptr, uint8_t *out_type)
# Same as os_dir_next, additionally writing normalized PAL_DT_* to *out_type when non-NULL.
os_dir_next_ex:
.Lodn_loop:
    mov r8, [rdx]
    cmp r8, rsi
    jae .Lodn_eof
    lea r9, [rdi + r8]
    movzx r11d, word ptr [r9 + KDIRENT_RECLEN]
    test r11d, r11d
    jz .Lodn_eof
    lea r10, [r8 + r11]
    mov [rdx], r10
    cmp qword ptr [r9 + KDIRENT_INO], 0
    je .Lodn_loop
    test rcx, rcx
    jz .Lodn_name
    movzx r10d, byte ptr [r9 + KDIRENT_TYPE]
    mov [rcx], r10b
.Lodn_name:
    lea rax, [r9 + KDIRENT_NAME]
    ret
.Lodn_eof:
    test rcx, rcx
    jz .Lodn_zero
    mov byte ptr [rcx], 0
.Lodn_zero:
    xor eax, eax
    ret

# void *os_mem_remap(void *old_base, size_t old_mapped, size_t new_mapped)
# Returns new mapped base pointer on success, or 0 on failure.
os_mem_remap:
    mov r10d, MREMAP_MAYMOVE
    xor r8d, r8d
    mov eax, OS_SYS_mremap
    syscall
    cmp rax, -4095
    jae .Lomr_fail
    ret
.Lomr_fail:
    xor eax, eax
    ret

# int os_poll_in(int fd, int timeout_ms)
# Uses Linux ppoll (timeout_ms < 0 waits indefinitely). Returns >0 ready, 0 timeout, or -errno.
os_poll_in:
    sub rsp, 40               # [rsp+0..7]=pollfd, [rsp+16..31]=timespec (entry rsp%16==8 -> aligned!)
    mov dword ptr [rsp + POLLFD_FD], edi
    mov word ptr [rsp + POLLFD_EVENTS], POLLIN
    mov word ptr [rsp + POLLFD_REVENTS], 0

    xor edx, edx              # NULL timespec if timeout_ms < 0
    test esi, esi
    js .Lopi_call
    movsxd rax, esi
    cqo
    mov ecx, 1000
    idiv rcx
    imul rdx, rdx, 1000000
    mov [rsp + 16 + TIMESPEC_SEC], rax
    mov [rsp + 16 + TIMESPEC_NSEC], rdx
    lea rdx, [rsp + 16]

.Lopi_call:
    mov rdi, rsp
    mov esi, 1
    xor r10d, r10d
    mov r8d, 8
    mov eax, OS_SYS_ppoll
    syscall
    add rsp, 40
    ret

# int os_poll_in2(int fd0, int fd1, int timeout_ms)
# ppoll on two descriptors (fd1 < 0 is ignored by the kernel). POLLHUP/POLLERR count as ready.
# Returns bitmask (bit0 = fd0, bit1 = fd1), 0 on timeout, or -errno.
os_poll_in2:
    sub rsp, 40               # [0..7]=pollfd0, [8..15]=pollfd1, [16..31]=timespec
    mov dword ptr [rsp + POLLFD_FD], edi
    mov word ptr [rsp + POLLFD_EVENTS], POLLIN
    mov word ptr [rsp + POLLFD_REVENTS], 0
    mov dword ptr [rsp + 8 + POLLFD_FD], esi
    mov word ptr [rsp + 8 + POLLFD_EVENTS], POLLIN
    mov word ptr [rsp + 8 + POLLFD_REVENTS], 0

    xor r9d, r9d              # NULL timespec if timeout_ms < 0
    test edx, edx
    js .Lopi2_call
    movsxd rax, edx
    cqo
    mov ecx, 1000
    idiv rcx
    imul rdx, rdx, 1000000
    mov [rsp + 16 + TIMESPEC_SEC], rax
    mov [rsp + 16 + TIMESPEC_NSEC], rdx
    lea r9, [rsp + 16]

.Lopi2_call:
    mov rdi, rsp
    mov esi, 2
    mov rdx, r9
    xor r10d, r10d
    mov r8d, 8
    mov eax, OS_SYS_ppoll
    syscall
    test rax, rax
    jle .Lopi2_done
    xor eax, eax
    cmp word ptr [rsp + POLLFD_REVENTS], 0
    je .Lopi2_chk1
    or eax, 1
.Lopi2_chk1:
    cmp word ptr [rsp + 8 + POLLFD_REVENTS], 0
    je .Lopi2_done
    or eax, 2
.Lopi2_done:
    add rsp, 40
    ret

# int os_clone_file(int src_fd, int dst_fd) -- ioctl(dst, FICLONE, src): whole-file CoW reflink
os_clone_file:
    mov edx, edi
    mov edi, esi
    mov esi, FICLONE
    mov eax, OS_SYS_ioctl
    syscall
    ret

# int os_poll_many(const int *fds, int n, int timeout_ms) -> ready bitmask / 0 / -errno
os_poll_many:
    push rbx
    sub rsp, 96                       # [0..63] = 8 pollfds, [64..79] = timespec
    mov r8, rdi
    mov r9d, esi
    cmp r9d, 8
    jbe .Lopm_n_ok
    mov r9d, 8
.Lopm_n_ok:
    xor ecx, ecx
.Lopm_fill:
    cmp ecx, r9d
    jae .Lopm_ts
    mov eax, [r8 + rcx * 4]
    mov [rsp + rcx * 8 + POLLFD_FD], eax
    mov word ptr [rsp + rcx * 8 + POLLFD_EVENTS], POLLIN
    mov word ptr [rsp + rcx * 8 + POLLFD_REVENTS], 0
    inc ecx
    jmp .Lopm_fill
.Lopm_ts:
    xor ebx, ebx                      # NULL timespec (infinite) if timeout < 0
    test edx, edx
    js .Lopm_call
    movsxd rax, edx
    cqo
    mov ecx, 1000
    idiv rcx
    imul rdx, rdx, 1000000
    mov [rsp + 64 + TIMESPEC_SEC], rax
    mov [rsp + 64 + TIMESPEC_NSEC], rdx
    lea rbx, [rsp + 64]
.Lopm_call:
    mov rdi, rsp
    mov esi, r9d
    mov rdx, rbx
    xor r10d, r10d
    mov r8d, 8
    mov eax, OS_SYS_ppoll
    syscall
    test rax, rax
    jle .Lopm_ret
    xor eax, eax
    xor ecx, ecx
.Lopm_mask:
    cmp ecx, r9d
    jae .Lopm_ret
    cmp word ptr [rsp + rcx * 8 + POLLFD_REVENTS], 0
    je .Lopm_next
    bts eax, ecx
.Lopm_next:
    inc ecx
    jmp .Lopm_mask
.Lopm_ret:
    add rsp, 96
    pop rbx
    ret

# int os_set_nonblock(int fd)
os_set_nonblock:
    push rdi
    mov esi, F_GETFL
    mov eax, OS_SYS_fcntl
    syscall
    pop rdi
    test rax, rax
    js .Losn_ret
    or eax, O_NONBLOCK
    mov edx, eax
    mov esi, F_SETFL
    mov eax, OS_SYS_fcntl
    syscall
.Losn_ret:
    ret

# int os_pipe_cloexec(int fds[2])
os_pipe_cloexec:
    mov esi, O_CLOEXEC
    mov eax, OS_SYS_pipe2
    syscall
    ret

# int64_t os_clock_ms(void)
os_clock_ms:
    sub rsp, 24               # 16-byte aligned
    mov edi, CLOCK_MONOTONIC
    mov rsi, rsp
    mov eax, OS_SYS_clock_gettime
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
    add rsp, 24
    ret

# void os_get_winsize(int *cols, int *rows)
os_get_winsize:
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    sub rsp, 16

    mov edi, STDOUT_FD
    mov esi, TIOCGWINSZ
    mov rdx, rsp
    mov eax, OS_SYS_ioctl
    syscall
    test rax, rax
    jns .Logw_ok

    mov edi, STDIN_FD
    mov esi, TIOCGWINSZ
    mov rdx, rsp
    mov eax, OS_SYS_ioctl
    syscall
    test rax, rax
    js .Logw_default

.Logw_ok:
    movzx eax, word ptr [rsp + WINSIZE_COL]
    movzx ecx, word ptr [rsp + WINSIZE_ROW]
    test eax, eax
    jz .Logw_default
    test ecx, ecx
    jz .Logw_default
    mov [rbx], eax
    mov [r12], ecx
    jmp .Logw_done

.Logw_default:
    mov dword ptr [rbx], 80
    mov dword ptr [r12], 24
.Logw_done:
    add rsp, 16
    pop r12
    pop rbx
    ret

# void os_term_save_and_raw(void)
os_term_save_and_raw:
    push rbx
    cmp dword ptr [rip + g_raw_active], 1
    je .Lotsr_done

.Lotsr_get:
    mov edi, STDIN_FD; mov esi, TCGETS; lea rdx, [rip + orig_termios]
    mov eax, OS_SYS_ioctl; syscall
    cmp rax, -EINTR; je .Lotsr_get
    test rax, rax; js .Lotsr_done

    lea rdi, [rip + raw_termios]
    lea rsi, [rip + orig_termios]
    mov edx, KTERMIOS_SIZE
    call mem_copy

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

.Lotsr_set:
    mov edi, STDIN_FD; mov esi, TCSETSW; mov rdx, rbx
    mov eax, OS_SYS_ioctl; syscall
    cmp rax, -EINTR; je .Lotsr_set
    test rax, rax; js .Lotsr_done
    mov dword ptr [rip + g_raw_active], 1
.Lotsr_done:
    pop rbx
    ret

# void os_term_restore(void)
os_term_restore:
    xor eax, eax
    cmp dword ptr [rip + g_raw_active], 0; je .Lotr_done
.Lotr_retry:
    mov edi, STDIN_FD; mov esi, TCSETSW; lea rdx, [rip + orig_termios]
    mov eax, OS_SYS_ioctl; syscall
    cmp rax, -EINTR; je .Lotr_retry
    mov dword ptr [rip + g_raw_active], 0; mov eax, 1
.Lotr_done:
    ret

.align 16
sig_restorer:
    mov eax, OS_SYS_rt_sigreturn
    syscall

# No-op handler: its only purpose is to make blocking syscalls return -EINTR
sig_noop:
    ret

# void os_signals_worker_mode(void)
# Background worker policy: SIGWINCH/SIGINT ignored (never interrupt I/O), SIGTERM -> no-op
# handler without SA_RESTART so a parent cancel request breaks blocking open()/read() with -EINTR.
os_signals_worker_mode:
    mov dword ptr [rip + g_raw_active], 0
    sub rsp, KSIGACTION_SIZE + 8
    mov qword ptr [rsp + KSIG_HANDLER], KSIG_IGN
    mov qword ptr [rsp + KSIG_FLAGS], SA_RESTORER
    lea rax, [rip + sig_restorer]
    mov [rsp + KSIG_RESTORER], rax
    mov qword ptr [rsp + KSIG_MASK], 0

    mov edi, SIGWINCH; mov rsi, rsp; xor edx, edx; mov r10d, 8; mov eax, OS_SYS_rt_sigaction; syscall # fault-checked: best-effort signal policy
    mov edi, SIGINT;   mov rsi, rsp; xor edx, edx; mov r10d, 8; mov eax, OS_SYS_rt_sigaction; syscall # fault-checked: best-effort signal policy
    mov edi, SIGXFSZ;  mov rsi, rsp; xor edx, edx; mov r10d, 8; mov eax, OS_SYS_rt_sigaction; syscall # fault-checked: return -EFBIG on write

    lea rax, [rip + sig_noop]
    mov [rsp + KSIG_HANDLER], rax
    mov edi, SIGTERM;  mov rsi, rsp; xor edx, edx; mov r10d, 8; mov eax, OS_SYS_rt_sigaction; syscall # fault-checked: EINTR cancel handler

    add rsp, KSIGACTION_SIZE + 8
    ret
