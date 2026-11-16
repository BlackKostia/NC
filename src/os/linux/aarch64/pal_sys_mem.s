// src/os/linux/aarch64/pal_sys_mem.s - C-callable raw syscall wrappers: memory & signals
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

PAL_SYS os_mmap, OS_SYS_mmap
PAL_SYS os_sigaltstack, OS_SYS_sigaltstack
PAL_SYS os_rt_sigaction, OS_SYS_rt_sigaction
PAL_SYS os_rt_sigprocmask, OS_SYS_rt_sigprocmask
