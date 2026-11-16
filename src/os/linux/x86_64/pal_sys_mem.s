# src/os/linux/x86_64/pal_sys_mem.s - C-callable raw syscall wrappers: memory & signals
# SysV args -> syscall regs (rcx -> r10); returns -errno in rax (no errno global, no runtime OS checks).
.intel_syntax noprefix
.include "pal.inc"

.macro PAL_SYS name, nr
.section .text.\name, "ax", @progbits
.global \name
\name:
    mov r10, rcx
    mov eax, \nr
    syscall
    ret
.endm

PAL_SYS os_mmap, OS_SYS_mmap
PAL_SYS os_sigaltstack, OS_SYS_sigaltstack
PAL_SYS os_rt_sigaction, OS_SYS_rt_sigaction
PAL_SYS os_rt_sigprocmask, OS_SYS_rt_sigprocmask
