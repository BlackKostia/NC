// src/os/linux/aarch64/pal_file.s - PAL: file mappings (SIGBUS-safe), in-kernel copy, inotify directory watch
// Split from pal_os.s (lean budget); kernel details stay inside src/os/.
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

// int os_watch_init(void) -> inotify fd (IN_NONBLOCK | IN_CLOEXEC)
os_watch_init:
    movz w0, #0x0800
    movk w0, #0x0008, lsl #16 // IN_NONBLOCK | IN_CLOEXEC
    OS_SYSCALL OS_SYS_inotify_init1
    ret

// int os_watch_add(int fd, const char *path, uint32_t mask)
os_watch_add:
    OS_SYSCALL OS_SYS_inotify_add_watch
    ret

// int os_watch_rm(int fd, int wd)
os_watch_rm:
    OS_SYSCALL OS_SYS_inotify_rm_watch
    ret

// ssize_t os_watch_read(int fd, void *buf, size_t cap)
os_watch_read:
    OS_SYSCALL OS_SYS_read
    ret

// int os_watch_next(const void *buf, size_t len, size_t *pos, int *wd, uint32_t *mask) -> 1/0
os_watch_next:
    ldr x5, [x2]
    add x6, x5, #KINOTIFY_HDR
    cmp x6, x1
    b.hi 1f
    add x7, x0, x5
    ldr w8, [x7, #0]
    str w8, [x3]                      // wd
    ldr w8, [x7, #4]
    str w8, [x4]                      // mask
    ldr w8, [x7, #12]                 // name length
    add x5, x5, x8
    add x5, x5, #KINOTIFY_HDR
    str x5, [x2]
    mov w0, #1
    ret
1:
    mov w0, #0
    ret

// ssize_t os_copy_file_range(int src_fd, int dst_fd, size_t len) -- in-kernel copy at file offsets
os_copy_file_range:
    mov x4, x2                        // len
    mov w2, w1                        // fd_out
    mov x1, #0                        // off_in  = NULL
    mov x3, #0                        // off_out = NULL
    mov x5, #0                        // flags
    OS_SYSCALL OS_SYS_copy_file_range
    ret

// void *os_mmap_file_ro(int fd, size_t len) -> mapping or 0 (registered for SIGBUS recovery)
os_mmap_file_ro:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov x19, x1
    mov w4, w0
    mov x0, #0
    mov x2, #PROT_READ
    mov x3, #MAP_PRIVATE
    mov x5, #0
    OS_MMAP
    cmn x0, #4095
    b.hs 1f
    mov x20, x0
    mov x1, x19
    bl pf_reg_mmap
    mov x0, x20
    b 2f
1:
    mov x0, #0
2:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// void os_munmap(void *addr, size_t len)
os_munmap:
    cbz x0, 1f
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x0, x1, [sp, #16]
    bl pf_unreg_mmap
    ldp x0, x1, [sp, #16]
    ldp x29, x30, [sp], #32
    OS_MUNMAP
1:
    ret

sig_bus_patch:
    b pf_sigbus_fallback

// void os_sigbus_guard_install(void)
os_sigbus_guard_install:
    sub sp, sp, #48
    adrp x9, sig_bus_patch; add x9, x9, :lo12:sig_bus_patch
    str x9, [sp, #KSIG_HANDLER]
    mov x9, #(SA_RESTORER | SA_ONSTACK)
    orr x9, x9, #SA_SIGINFO
    str x9, [sp, #KSIG_FLAGS]
    adrp x9, pf_sig_restorer; add x9, x9, :lo12:pf_sig_restorer
    str x9, [sp, #KSIG_RESTORER]
    str xzr, [sp, #KSIG_MASK]
    mov w0, #SIGBUS
    mov x1, sp
    mov x2, #0
    mov x3, #8
    OS_SYSCALL OS_SYS_rt_sigaction
    add sp, sp, #48
    ret
