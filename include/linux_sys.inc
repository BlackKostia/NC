# Linux x86-64 System Call Numbers, Kernel Struct Offsets, and Constants
# Verified against Linux 7.0 / Ubuntu 24.04 x86-64 kernel headers

.intel_syntax noprefix

# --- Syscall Numbers ---
.equ SYS_read,            0
.equ SYS_write,           1
.equ SYS_open,            2
.equ SYS_close,           3
.equ SYS_stat,            4
.equ SYS_fstat,           5
.equ SYS_lstat,           6
.equ SYS_poll,            7
.equ SYS_lseek,           8
.equ SYS_mmap,            9
.equ SYS_mprotect,        10
.equ SYS_munmap,          11
.equ SYS_brk,             12
.equ SYS_rt_sigaction,    13
.equ SYS_rt_sigprocmask,  14
.equ SYS_rt_sigreturn,    15
.equ SYS_ioctl,           16
.equ SYS_mremap,          25
.equ SYS_fork,            57
.equ SYS_execve,          59
.equ SYS_exit,            60
.equ SYS_wait4,           61
.equ SYS_getcwd,          79
.equ SYS_chdir,           80
.equ SYS_getdents64,      217
.equ SYS_clock_gettime,   228
.equ SYS_openat,          257
.equ SYS_mkdirat,         258
.equ SYS_newfstatat,      262
.equ SYS_unlinkat,        263
.equ SYS_symlinkat,       266
.equ SYS_readlinkat,      267
.equ SYS_fchmodat,        268
.equ SYS_renameat2,       316

# --- File Descriptors & *at Constants ---
.equ STDIN_FD,            0
.equ STDOUT_FD,           1
.equ STDERR_FD,           2
.equ AT_FDCWD,            -100
.equ AT_SYMLINK_NOFOLLOW, 0x100
.equ AT_REMOVEDIR,        0x200

# --- open / openat Flags ---
.equ O_RDONLY,            0x0
.equ O_WRONLY,            0x1
.equ O_RDWR,              0x2
.equ O_CREAT,             0x40
.equ O_EXCL,              0x80
.equ O_TRUNC,             0x200
.equ O_APPEND,            0x400
.equ O_NONBLOCK,          0x800
.equ O_DIRECTORY,         0x10000
.equ O_CLOEXEC,           0x80000

# --- mmap / mremap ---
.equ PROT_READ,           0x1
.equ PROT_WRITE,          0x2
.equ PROT_RW,             0x3
.equ MAP_PRIVATE,         0x02
.equ MAP_ANONYMOUS,       0x20
.equ MAP_PRIVATE_ANON,    0x22
.equ MREMAP_MAYMOVE,      0x1

# --- ioctl & Kernel termios ---
.equ TCGETS,              0x5401
.equ TCSETS,              0x5402
.equ TCSETSW,             0x5403
.equ TIOCGWINSZ,          0x5413

# Kernel struct termios (36 bytes; we allocate 64 for safety)
.equ KTERMIOS_SIZE,       64
.equ KTERMIOS_IFLAG,      0
.equ KTERMIOS_OFLAG,      4
.equ KTERMIOS_CFLAG,      8
.equ KTERMIOS_LFLAG,      12
.equ KTERMIOS_LINE,       16
.equ KTERMIOS_CC,         17
.equ KTERMIOS_VTIME,      22   # c_cc[5]
.equ KTERMIOS_VMIN,       23   # c_cc[6]

# termios flags
.equ ICANON,              0x0002
.equ ECHO,                0x0008
.equ ISIG,                0x0001
.equ IEXTEN,              0x8000
.equ IXON,                0x0400
.equ ICRNL,               0x0100
.equ BRKINT,              0x0002
.equ INPCK,               0x0010
.equ ISTRIP,              0x0020
.equ OPOST,               0x0001
.equ CS8,                 0x0030

# struct winsize (8 bytes)
.equ WINSIZE_ROW,         0
.equ WINSIZE_COL,         2

# --- Kernel sigaction (32 bytes) ---
.equ KSIGACTION_SIZE,     32
.equ KSIG_HANDLER,        0
.equ KSIG_FLAGS,          8
.equ KSIG_RESTORER,       16
.equ KSIG_MASK,           24
.equ SA_RESTORER,         0x04000000
.equ SA_RESTART,          0x10000000
.equ SIGINT,              2
.equ SIGTERM,             15
.equ SIGWINCH,            28

# --- pollfd ---
.equ POLLFD_FD,           0
.equ POLLFD_EVENTS,       4
.equ POLLFD_REVENTS,      6
.equ POLLIN,              0x0001

# --- clock_gettime ---
.equ CLOCK_REALTIME,      0
.equ CLOCK_MONOTONIC,     1
.equ TIMESPEC_SEC,        0
.equ TIMESPEC_NSEC,       8

# --- struct stat (144 bytes) ---
.equ STAT_SIZE,           144
.equ STAT_INO,            8
.equ STAT_MODE,           24
.equ STAT_UID,            28
.equ STAT_GID,            32
.equ STAT_ST_SIZE,        48
.equ STAT_MTIME,          88

.equ S_IFMT,              0170000
.equ S_IFDIR,             0040000
.equ S_IFREG,             0100000
.equ S_IFLNK,             0120000

# --- struct dirent64 ---
.equ DIRENT_INO,          0
.equ DIRENT_OFF,          8
.equ DIRENT_RECLEN,       16
.equ DIRENT_TYPE,         18
.equ DIRENT_NAME,         19

.equ DT_UNKNOWN,          0
.equ DT_DIR,              4
.equ DT_REG,              8
.equ DT_LNK,              10

# --- Common Errno (positive values; syscall returns -errno) ---
.equ ENOENT,              2
.equ EINTR,               4
.equ EAGAIN,              11
.equ EACCES,              13
.equ EEXIST,              17
.equ EXDEV,               18
.equ ENOTDIR,             20
.equ EISDIR,              21
.equ ENOTEMPTY,           39
