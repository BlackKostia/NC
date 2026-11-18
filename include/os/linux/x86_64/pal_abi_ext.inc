# Duop Extended Linux x86-64 Kernel ABI Constants (included by pal_target.inc)
# Kept modular to stay strictly within the 400-line header budget.
.intel_syntax noprefix

.ifndef PAL_ABI_EXT_INCLUDED
.equ PAL_ABI_EXT_INCLUDED, 1

.equ OS_SYS_getppid,         110
.equ OS_SYS_lseek,           8
.equ OS_SYS_ftruncate,       77
.equ OS_SYS_exit_group,      231
.equ SIGCHLD,                17
.equ OS_SYS_sigaltstack,     131
.equ OS_SYS_prctl,           157
.equ OS_SYS_gettid,          186
.equ OS_SYS_tgkill,          234
.equ OS_SYS_prlimit64,       302

.equ PR_SET_PDEATHSIG,       1
.equ SIGHUP,                 1
.equ SIGQUIT,                3
.equ SIGILL,                 4
.equ SIGTRAP,                5
.equ SIGUSR1,                10
.equ SIGUSR2,                12
.equ SIGALRM,                14
.equ SIGSTKFLT,              16
.equ SIGXCPU,                24
.equ SIGXFSZ,                25
.equ SIGVTALRM,              26
.equ SIGPROF,                27
.equ SIGIO,                  29
.equ SIGPWR,                 30
.equ SIGSYS,                 31

.equ SA_ONSTACK,             0x08000000
.equ SS_DISABLE,             2
.equ SIGSTKSZ_BUFSZ,         16384
.equ KSTACK_T_SIZE,          24
.equ KSTACK_T_SP,            0
.equ KSTACK_T_FLAGS,         8
.equ KSTACK_T_SZ,            16

.equ F_SETFD,                2
.equ FD_CLOEXEC,             1
.equ POLLERR,                0x0008
.equ POLLHUP,                0x0010
.equ POLLNVAL,               0x0020
.equ RLIMIT_NOFILE,          7
.equ S_IFIFO,                0010000

.equ KSTATX_NLINK,           16
.equ KSTATX_UID,             20
.equ KSTATX_GID,             24

.macro OS_GETTID
    mov eax, OS_SYS_gettid
    syscall
.endm

.macro OS_GETPPID
    mov eax, OS_SYS_getppid
    syscall
.endm


# pty / session (moved from pal_target.inc: header budget)
.equ OS_SYS_setsid, 112
.equ OS_TIOCSPTLCK, 0x40045431
.equ OS_TIOCGPTN,   0x80045430
.equ OS_TIOCSCTTY,  0x540E
.equ OS_TIOCSWINSZ, 0x5414
.endif
