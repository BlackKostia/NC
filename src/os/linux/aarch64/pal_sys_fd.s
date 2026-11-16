// src/os/linux/aarch64/pal_sys_fd.s - C-callable raw syscall wrappers: descriptors & I/O
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

PAL_SYS os_read, OS_SYS_read
PAL_SYS os_write, OS_SYS_write
PAL_SYS os_close, OS_SYS_close
PAL_SYS os_fsync, OS_SYS_fsync
PAL_SYS os_lseek, OS_SYS_lseek
PAL_SYS os_ioctl, OS_SYS_ioctl
PAL_SYS os_fcntl, OS_SYS_fcntl
PAL_SYS os_pipe2, OS_SYS_pipe2
PAL_SYS os_ftruncate, OS_SYS_ftruncate
PAL_SYS os_openat, OS_SYS_openat

.section .text.os_dup2, "ax", @progbits
.global os_dup2
os_dup2:                          // int os_dup2(int oldfd, int newfd): dup3(old, new, 0)
    mov x2, #0
    mov x8, #OS_SYS_dup3
    svc #0
    ret
