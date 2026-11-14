// Duop Target-Specific PAL Definitions: Linux AArch64 (ARM64)
// Pure constants, kernel structs, and inline OS_* syscall macros (svc #0).

.ifndef PAL_TARGET_INC
.equ PAL_TARGET_INC, 1

// --- Linux AArch64 Syscall Numbers (x8) ---
.equ OS_SYS_dup3,             24
.equ OS_SYS_fcntl,            25
.equ OS_SYS_inotify_init1,    26
.equ OS_SYS_inotify_add_watch,27
.equ OS_SYS_inotify_rm_watch, 28
.equ OS_SYS_ioctl,            29
.equ OS_SYS_mkdirat,          34
.equ OS_SYS_unlinkat,         35
.equ OS_SYS_symlinkat,        36
.equ OS_SYS_linkat,           37
.equ OS_SYS_renameat2,        276
.equ OS_SYS_chdir,            49
.equ OS_SYS_fchmodat,         53
.equ OS_SYS_fchownat,         54
.equ OS_SYS_openat,           56
.equ OS_SYS_close,            57
.equ OS_SYS_pipe2,            59
.equ OS_SYS_getdents64,       61
.equ OS_SYS_lseek,            62
.equ OS_SYS_read,             63
.equ OS_SYS_write,            64
.equ OS_SYS_ppoll,            73
.equ OS_SYS_readlinkat,       78
.equ OS_SYS_newfstatat,       79
.equ OS_SYS_fstat,            80
.equ OS_SYS_exit,             93
.equ OS_SYS_exit_group,       94
.equ OS_SYS_clock_gettime,    113
.equ OS_SYS_kill,             129
.equ OS_SYS_rt_sigaction,     134
.equ OS_SYS_rt_sigprocmask,   135
.equ OS_SYS_setsid,           157
.equ OS_SYS_munmap,           215
.equ OS_SYS_mremap,           216
.equ OS_SYS_clone,            220
.equ OS_SYS_execve,           221
.equ OS_SYS_mmap,             222
.equ OS_SYS_wait4,            260
.equ OS_SYS_copy_file_range,  285
.equ OS_SYS_statx,            291
.equ OS_SYS_io_uring_setup,   425
.equ OS_SYS_io_uring_enter,   426

// --- Open/At/Mmap/Poll/Signal Constants ---
.equ AT_FDCWD,                -100
.equ AT_SYMLINK_NOFOLLOW,     0x100
.equ AT_REMOVEDIR,            0x200
.equ O_RDONLY,                0
.equ O_WRONLY,                1
.equ O_RDWR,                  2
.equ O_CREAT,                 0x40
.equ O_EXCL,                  0x80
.equ O_NOCTTY,                0x100
.equ O_TRUNC,                 0x200
.equ O_NONBLOCK,              0x800
.equ O_DIRECTORY,             0x4000
.equ O_CLOEXEC,               0x80000

.equ PROT_READ,               1
.equ PROT_WRITE,              2
.equ MAP_SHARED,              0x01
.equ MAP_PRIVATE,             0x02
.equ MAP_ANONYMOUS,           0x20
.equ MAP_SHARED_ANON,         0x21
.equ MREMAP_MAYMOVE,          1
.equ POLLIN,                  1
.equ CLOCK_MONOTONIC,         1
.equ TIOCGWINSZ,              0x5413
.equ OS_TIOCSWINSZ,           0x5414
.equ OS_TIOCSCTTY,            0x540E
.equ OS_TIOCGPTN,             0x80045430
.equ OS_TIOCSPTLCK,           0x40045431
.equ KSTAT_SIZE,              128
.equ KTERMIOS_SIZE,           60

.macro OS_SYSCALL nr
    mov x8, #\nr
    svc #0
.endm

.macro OS_READ
    OS_SYSCALL OS_SYS_read
.endm

.macro OS_WRITE
    OS_SYSCALL OS_SYS_write
.endm

.macro OS_OPENAT
    OS_SYSCALL OS_SYS_openat
.endm

.macro OS_CLOSE
    OS_SYSCALL OS_SYS_close
.endm

.macro OS_IOCTL
    OS_SYSCALL OS_SYS_ioctl
.endm

.macro OS_MMAP
    OS_SYSCALL OS_SYS_mmap
.endm

.macro OS_MUNMAP
    OS_SYSCALL OS_SYS_munmap
.endm

.macro OS_EXIT
    OS_SYSCALL OS_SYS_exit_group
.endm

.endif
