# Duop Compile-Time PAL Target Definitions: Linux x86-64
# Verified against Linux 7.0 / Ubuntu 24.04 x86-64 kernel ABI headers.
# Kernel syscall numbers and structs stay encapsulated here and in src/os/linux/x86_64/.

.intel_syntax noprefix

.ifndef PAL_TARGET_INCLUDED
.equ PAL_TARGET_INCLUDED, 1

# --- Linux x86-64 Kernel Syscall Numbers (private to OS PAL) ---
.equ OS_SYS_read,           0
.equ OS_SYS_write,          1
.equ OS_SYS_close,          3
.equ OS_SYS_fstat,          5
.equ OS_SYS_mmap,           9
.equ OS_SYS_munmap,         11
.equ OS_SYS_rt_sigaction,   13
.equ OS_SYS_rt_sigreturn,   15
.equ OS_SYS_ioctl,          16
.equ OS_SYS_mremap,         25
.equ OS_SYS_fork,           57
.equ OS_SYS_execve,         59
.equ OS_SYS_exit,           60
.equ OS_SYS_wait4,          61
.equ OS_SYS_getcwd,         79
.equ OS_SYS_chdir,          80
.equ OS_SYS_getdents64,     217
.equ OS_SYS_clock_gettime,  228
.equ OS_SYS_openat,         257
.equ OS_SYS_mkdirat,        258
.equ OS_SYS_newfstatat,     262
.equ OS_SYS_unlinkat,       263
.equ OS_SYS_renameat,       264
.equ OS_SYS_symlinkat,      266
.equ OS_SYS_readlinkat,     267
.equ OS_SYS_ppoll,          271

# --- Portable POSIX File Descriptors & *at Flags ---
.equ STDIN_FD,              0
.equ STDOUT_FD,             1
.equ STDERR_FD,             2
.equ AT_FDCWD,              -100
.equ AT_SYMLINK_NOFOLLOW,   0x100
.equ AT_REMOVEDIR,          0x200

# --- Portable Open Flags (Linux x86-64 values) ---
.equ O_RDONLY,              0x0
.equ O_WRONLY,              0x1
.equ O_RDWR,                0x2
.equ O_CREAT,               0x40
.equ O_EXCL,                0x80
.equ O_TRUNC,               0x200
.equ O_APPEND,              0x400
.equ O_NONBLOCK,            0x800
.equ O_DIRECTORY,           0x10000
.equ O_CLOEXEC,             0x80000

# --- Memory Mapping Flags ---
.equ PROT_READ,             0x1
.equ PROT_WRITE,            0x2
.equ PROT_RW,               0x3
.equ MAP_PRIVATE,           0x02
.equ MAP_ANONYMOUS,         0x20
.equ MAP_PRIVATE_ANON,      0x22
.equ MREMAP_MAYMOVE,        0x1

# --- POSIX File Mode Types ---
.equ S_IFMT,                0170000
.equ S_IFDIR,               0040000
.equ S_IFREG,               0100000
.equ S_IFLNK,               0120000

# --- Common Errno Values (PAL normalizes failures to -errno) ---
.equ ENOENT,                2
.equ EINTR,                 4
.equ EAGAIN,                11
.equ ENOMEM,                12
.equ EACCES,                13
.equ EEXIST,                17
.equ EXDEV,                 18
.equ ENOTDIR,               20
.equ EISDIR,                21
.equ EINVAL,                22
.equ ENOTEMPTY,             39

# --- Linux Kernel ABI Struct Offsets (only used inside src/os/linux/x86_64/) ---
.equ TCGETS,                0x5401
.equ TCSETS,                0x5402
.equ TCSETSW,               0x5403
.equ TIOCGWINSZ,            0x5413

.equ KTERMIOS_SIZE,         64
.equ KTERMIOS_IFLAG,        0
.equ KTERMIOS_OFLAG,        4
.equ KTERMIOS_CFLAG,        8
.equ KTERMIOS_LFLAG,        12
.equ KTERMIOS_VTIME,        22
.equ KTERMIOS_VMIN,         23

.equ ICANON,                0x0002
.equ ECHO,                  0x0008
.equ ISIG,                  0x0001
.equ IEXTEN,                0x8000
.equ IXON,                  0x0400
.equ ICRNL,                 0x0100
.equ BRKINT,                0x0002
.equ INPCK,                 0x0010
.equ ISTRIP,                0x0020
.equ OPOST,                 0x0001
.equ CS8,                   0x0030

.equ WINSIZE_ROW,           0
.equ WINSIZE_COL,           2

.equ KSIGACTION_SIZE,       32
.equ KSIG_HANDLER,          0
.equ KSIG_FLAGS,            8
.equ KSIG_RESTORER,         16
.equ KSIG_MASK,             24
.equ SA_RESTORER,           0x04000000
.equ SIGINT,                2
.equ SIGTERM,               15
.equ SIGWINCH,              28

.equ POLLFD_FD,             0
.equ POLLFD_EVENTS,         4
.equ POLLFD_REVENTS,        6
.equ POLLIN,                0x0001

.equ CLOCK_MONOTONIC,       1
.equ TIMESPEC_SEC,          0
.equ TIMESPEC_NSEC,         8

.equ KSTAT_SIZE,            144
.equ KSTAT_DEV,             0
.equ KSTAT_INO,             8
.equ KSTAT_MODE,            24
.equ KSTAT_ST_SIZE,         48
.equ KSTAT_MTIME,           88

.equ KDIRENT_INO,           0
.equ KDIRENT_RECLEN,        16
.equ KDIRENT_NAME,          19

# ==============================================================================
# Zero-Overhead Inline Syscall PAL Macros (Linux x86-64)
# Convention: register arguments follow Linux/POSIX syscall ABI (rdi, rsi, rdx, r10);
# return value in rax >= 0 on success or -errno < 0 on failure.
# ==============================================================================

.macro OS_READ
    mov eax, OS_SYS_read
    syscall
.endm

.macro OS_WRITE
    mov eax, OS_SYS_write
    syscall
.endm

.macro OS_OPENAT
    mov eax, OS_SYS_openat
    syscall
.endm

.macro OS_CLOSE
    mov eax, OS_SYS_close
    syscall
.endm

.macro OS_MKDIRAT
    mov eax, OS_SYS_mkdirat
    syscall
.endm

.macro OS_UNLINKAT
    mov eax, OS_SYS_unlinkat
    syscall
.endm

.macro OS_RENAMEAT
    mov eax, OS_SYS_renameat
    syscall
.endm

.macro OS_SYMLINKAT
    mov eax, OS_SYS_symlinkat
    syscall
.endm

.macro OS_READLINKAT
    mov eax, OS_SYS_readlinkat
    syscall
.endm

.macro OS_GETCWD
    mov eax, OS_SYS_getcwd
    syscall
.endm

.macro OS_CHDIR
    mov eax, OS_SYS_chdir
    syscall
.endm

# Allocate anonymous private pages: rdi=addr(0), rsi=length, rdx=prot
.macro OS_MMAP_ANON
    mov r10d, MAP_PRIVATE_ANON
    mov r8, -1
    xor r9d, r9d
    mov eax, OS_SYS_mmap
    syscall
.endm

.macro OS_MUNMAP
    mov eax, OS_SYS_munmap
    syscall
.endm

.macro OS_FORK
    mov eax, OS_SYS_fork
    syscall
.endm

.macro OS_EXECVE
    mov eax, OS_SYS_execve
    syscall
.endm

.macro OS_WAIT4
    mov eax, OS_SYS_wait4
    syscall
.endm

.macro OS_EXIT
    mov eax, OS_SYS_exit
    syscall
.endm

.endif
