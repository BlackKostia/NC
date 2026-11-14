// Duop Platform Abstraction Layer Implementation: Linux AArch64 (ARM64)
// Encapsulates kernel structs (aarch64 stat, dirent64, termios, sigaction, pollfd, timespec, mremap).

.include "pal.inc"

.section .bss
.align 3
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
.global os_signals_install
.global os_poll_in2
.global os_pipe_cloexec
.global os_signals_worker_mode
.global os_clone_file
.global os_poll_many
.global os_set_nonblock
.global os_watch_init

// AArch64 struct stat offsets: st_dev=0(8), st_ino=8(8), st_mode=16(4), st_size=48(8), st_mtime=88(8)
kstat_to_filestat:
    ldr x9, [x0, #0]
    str x9, [x1, #FileStat.dev]
    ldr x9, [x0, #8]
    str x9, [x1, #FileStat.ino]
    ldr x9, [x0, #48]
    str x9, [x1, #FileStat.size]
    ldr x9, [x0, #88]
    str x9, [x1, #FileStat.mtime]
    ldr w9, [x0, #16]
    str w9, [x1, #FileStat.mode]
    ret

// int os_statat(int dirfd, const char *path, FileStat *out, int follow_symlinks)
os_statat:
    stp x29, x30, [sp, #-160]!
    mov x29, sp
    mov x10, x2               // out
    add x2, sp, #16           // kstat buf
    cmp w3, #0
    mov w3, #AT_SYMLINK_NOFOLLOW
    csel w3, wzr, w3, ne
    OS_SYSCALL OS_SYS_newfstatat
    cmp x0, #0
    blt 1f
    add x0, sp, #16
    mov x1, x10
    bl kstat_to_filestat
    mov w0, #0
1:
    ldp x29, x30, [sp], #160
    ret

// int os_fstat(int fd, FileStat *out)
os_fstat:
    stp x29, x30, [sp, #-160]!
    mov x29, sp
    mov x10, x1
    add x1, sp, #16
    OS_SYSCALL OS_SYS_fstat
    cmp x0, #0
    blt 1f
    add x0, sp, #16
    mov x1, x10
    bl kstat_to_filestat
    mov w0, #0
1:
    ldp x29, x30, [sp], #160
    ret

os_dir_read:
    OS_SYSCALL OS_SYS_getdents64
    ret

// linux_dirent64: d_ino(0,8), d_off(8,8), d_reclen(16,2), d_type(18,1), d_name(19)
os_dir_next_ex:
    ldr x9, [x1]
    cmp x9, x2
    b.hs 1f
    add x10, x0, x9
    ldrh w11, [x10, #16]
    add x9, x9, x11
    str x9, [x1]
    ldrb w12, [x10, #18]
    strb w12, [x3]
    add x0, x10, #19
    ret
1:
    mov x0, #0
    ret

os_dir_next:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    add x3, sp, #16
    bl os_dir_next_ex
    ldp x29, x30, [sp], #32
    ret

os_mem_remap:
    mov x3, #MREMAP_MAYMOVE
    OS_SYSCALL OS_SYS_mremap
    ret

os_poll_in:
    sub sp, sp, #32
    str w0, [sp, #0]
    mov w9, #POLLIN
    strh w9, [sp, #4]
    strh wzr, [sp, #6]
    cmp w1, #0
    b.lt 1f
    mov w9, #1000
    sdiv w10, w1, w9
    msub w11, w10, w9, w1
    movz x12, #0x4240
    movk x12, #0x000f, lsl #16
    mul x11, x11, x12
    str x10, [sp, #16]
    str x11, [sp, #24]
    add x2, sp, #16
    b 2f
1:
    mov x2, #0
2:
    mov x0, sp
    mov x1, #1
    mov x3, #0
    mov x4, #8
    OS_SYSCALL OS_SYS_ppoll
    add sp, sp, #32
    ret

os_poll_in2:
    sub sp, sp, #32
    str w0, [sp, #0]
    mov w9, #POLLIN
    strh w9, [sp, #4]
    strh wzr, [sp, #6]
    str w1, [sp, #8]
    strh w9, [sp, #12]
    strh wzr, [sp, #14]
    mov x0, sp
    mov x1, #2
    mov x2, #0
    mov x3, #0
    mov x4, #8
    OS_SYSCALL OS_SYS_ppoll
    add sp, sp, #32
    ret

os_poll_many:
    cmp w1, #0
    b.le 2f
    sub sp, sp, #64
    mov x9, #0
1:
    cmp w9, w1
    b.ge 3f
    ldr w10, [x0, x9, lsl #2]
    add x11, sp, x9, lsl #3
    str w10, [x11, #0]
    mov w12, #POLLIN
    strh w12, [x11, #4]
    strh wzr, [x11, #6]
    add x9, x9, #1
    b 1b
3:
    mov x0, sp
    mov x2, #0
    mov x3, #0
    mov x4, #8
    OS_SYSCALL OS_SYS_ppoll
    add sp, sp, #64
    ret
2:
    mov w0, #0
    ret

os_clock_ms:
    sub sp, sp, #16
    mov x0, #CLOCK_MONOTONIC
    mov x1, sp
    OS_SYSCALL OS_SYS_clock_gettime
    ldr x9, [sp, #0]
    ldr x10, [sp, #8]
    mov w11, #1000
    mul x9, x9, x11
    movz x12, #0x4240
    movk x12, #0x000f, lsl #16
    udiv x10, x10, x12
    add x0, x9, x10
    add sp, sp, #16
    ret

os_get_winsize:
    sub sp, sp, #16
    mov x9, x0
    mov x10, x1
    mov w0, #1
    mov x1, #TIOCGWINSZ
    mov x2, sp
    OS_IOCTL
    cmp x0, #0
    b.lt 1f
    ldrh w11, [sp, #0]
    ldrh w12, [sp, #2]
    str w12, [x9]
    str w11, [x10]
    mov w0, #0
1:
    add sp, sp, #16
    ret

os_term_save_and_raw:
    mov w0, #0
    mov x1, #0x5401           // TCGETS
    adrp x2, orig_termios
    add x2, x2, :lo12:orig_termios
    OS_IOCTL
    cmp x0, #0
    b.lt 1f
    adrp x9, g_raw_active
    mov w10, #1
    str w10, [x9, :lo12:g_raw_active]
1:
    ret

os_term_restore:
    adrp x9, g_raw_active
    ldr w10, [x9, :lo12:g_raw_active]
    cbz w10, 1f
    mov w0, #0
    mov x1, #0x5402           // TCSETS
    adrp x2, orig_termios
    add x2, x2, :lo12:orig_termios
    OS_IOCTL
    adrp x9, g_raw_active
    str wzr, [x9, :lo12:g_raw_active]
1:
    ret

os_signals_install:
os_signals_worker_mode:
    mov w0, #0
    ret

os_pipe_cloexec:
    mov w1, #O_CLOEXEC
    OS_SYSCALL OS_SYS_pipe2
    ret

os_clone_file:
    mov x3, x0
    mov x0, x1
    movz x1, #0x9409
    movk x1, #0x4004, lsl #16 // FICLONE
    mov x2, x3
    OS_IOCTL
    ret

os_set_nonblock:
    mov w9, w0
    mov w1, #3                // F_GETFL
    mov w2, #0
    OS_SYSCALL OS_SYS_fcntl
    cmp x0, #0
    b.lt 1f
    orr w2, w0, #O_NONBLOCK
    mov w0, w9
    mov w1, #4                // F_SETFL
    OS_SYSCALL OS_SYS_fcntl
1:
    ret

os_watch_init:
    movz w0, #0x0800
    movk w0, #0x0008, lsl #16 // IN_NONBLOCK | IN_CLOEXEC
    OS_SYSCALL OS_SYS_inotify_init1
    ret
