// src/os/linux/aarch64/pal_sys_proc.s - C-callable raw syscall wrappers: process control
// AAPCS64 args x0-x5 are already the syscall registers; returns -errno in x0.
.include "pal.inc"

.macro PAL_SYS name, nr
.section .text.\name, "ax", @progbits
.global \name
\name:
    mov x8, #\nr
    svc #0
    ret
.endm

PAL_SYS os_execve, OS_SYS_execve
PAL_SYS os_wait4, OS_SYS_wait4
PAL_SYS os_kill, OS_SYS_kill
PAL_SYS os_exit, OS_SYS_exit_group
PAL_SYS os_getpid, OS_SYS_getpid
PAL_SYS os_getppid, OS_SYS_getppid
PAL_SYS os_gettid, OS_SYS_gettid
PAL_SYS os_setsid, OS_SYS_setsid
PAL_SYS os_getuid, OS_SYS_getuid
PAL_SYS os_prctl, OS_SYS_prctl
PAL_SYS os_prlimit64, OS_SYS_prlimit64
PAL_SYS os_tgkill, OS_SYS_tgkill

.section .text.os_fork, "ax", @progbits
.global os_fork
os_fork:                          // pid_t os_fork(void): clone(SIGCHLD) -- no fork on arm64
    mov x0, #SIGCHLD
    mov x1, #0
    mov x2, #0
    mov x3, #0
    mov x4, #0
    mov x8, #OS_SYS_clone
    svc #0
    ret
