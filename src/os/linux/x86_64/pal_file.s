# src/os/linux/x86_64/pal_file.s - PAL: file mappings (SIGBUS-safe), in-kernel copy, inotify directory watch
# Split from pal_os.s (lean budget); kernel details stay inside src/os/.
.intel_syntax noprefix
.include "pal.inc"

.extern pf_reg_mmap
.extern pf_unreg_mmap
.extern pf_sigbus_fallback
.extern pf_sig_restorer

.section .text
.global os_copy_file_range
.global os_mmap_file_ro
.global os_munmap
.global os_sigbus_guard_install
.global os_watch_init
.global os_watch_add
.global os_watch_rm
.global os_watch_read
.global os_watch_next

# ssize_t os_copy_file_range(int src_fd, int dst_fd, size_t len) -- in-kernel copy at file offsets
os_copy_file_range:
    mov r8, rdx               # len
    mov edx, esi              # fd_out
    xor esi, esi              # off_in  = NULL (advance file position)
    xor r10d, r10d            # off_out = NULL
    xor r9d, r9d              # flags   = 0
    mov eax, OS_SYS_copy_file_range
    syscall
    ret

# void *os_mmap_file_ro(int fd, size_t len) -> mapping or 0
os_mmap_file_ro:
    push rsi
    mov r8d, edi              # fd
    xor edi, edi
    mov edx, PROT_READ
    mov r10d, MAP_PRIVATE
    xor r9d, r9d
    mov eax, OS_SYS_mmap
    syscall
    pop rsi
    cmp rax, -4095
    jae .Lomf_fail
    push rax; mov rdi, rax
    call pf_reg_mmap
    pop rax; ret
.Lomf_fail:
    xor eax, eax
    ret

# void os_munmap(void *addr, size_t len)
os_munmap:
    test rdi, rdi
    jz .Lomu_ret
    push rdi; push rsi; sub rsp, 8
    call pf_unreg_mmap
    add rsp, 8; pop rsi; pop rdi
    mov eax, OS_SYS_munmap
    syscall
.Lomu_ret:
    ret


# int os_watch_init(void) -> inotify fd (IN_NONBLOCK | IN_CLOEXEC)
os_watch_init:
    mov edi, O_NONBLOCK | O_CLOEXEC
    mov eax, OS_SYS_inotify_init1
    syscall
    ret

# int os_watch_add(int fd, const char *path, uint32_t mask)
os_watch_add:
    mov eax, OS_SYS_inotify_add_watch
    syscall
    ret

# int os_watch_rm(int fd, int wd)
os_watch_rm:
    mov eax, OS_SYS_inotify_rm_watch
    syscall
    ret

# ssize_t os_watch_read(int fd, void *buf, size_t cap)
os_watch_read:
    mov eax, OS_SYS_read
    syscall
    ret

# int os_watch_next(const void *buf, size_t len, size_t *pos, int *wd, uint32_t *mask)
os_watch_next:
    mov rax, [rdx]
    lea r9, [rax + KINOTIFY_HDR]
    cmp r9, rsi
    ja .Lown_end
    lea r9, [rdi + rax]
    mov r10d, [r9 + 0]
    mov [rcx], r10d                   # wd
    mov r10d, [r9 + 4]
    mov [r8], r10d                    # mask
    mov r10d, [r9 + 12]               # name len
    lea rax, [rax + r10 + KINOTIFY_HDR]
    mov [rdx], rax
    mov eax, 1
    ret
.Lown_end:
    xor eax, eax
    ret


# SIGBUS guard (SA_SIGINFO): delegate to pf_sigbus_fallback (patches only registered file mappings).
sig_bus_patch:
    jmp pf_sigbus_fallback

# void os_sigbus_guard_install(void)
os_sigbus_guard_install:
    sub rsp, KSIGACTION_SIZE + 8
    lea rax, [rip + sig_bus_patch]
    mov [rsp + KSIG_HANDLER], rax
    mov qword ptr [rsp + KSIG_FLAGS], SA_RESTORER | SA_SIGINFO | SA_ONSTACK
    lea rax, [rip + pf_sig_restorer]
    mov [rsp + KSIG_RESTORER], rax
    mov qword ptr [rsp + KSIG_MASK], 0
    mov edi, SIGBUS
    mov rsi, rsp
    xor edx, edx
    mov r10d, 8
    mov eax, OS_SYS_rt_sigaction
    syscall
    add rsp, KSIGACTION_SIZE + 8
    ret
