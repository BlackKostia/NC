// src/os/linux/aarch64/pal_time.s - Linux AArch64 wall clock (seconds since the Unix epoch)
.include "pal.inc"

.equ CLOCK_REALTIME, 0

.section .text
.global os_time_sec

// int64_t os_time_sec(void) -- CLOCK_REALTIME seconds; 0 when the clock cannot be read
os_time_sec:
    sub sp, sp, #16
    mov x0, #CLOCK_REALTIME
    mov x1, sp
    OS_SYSCALL OS_SYS_clock_gettime
    cmp x0, #0
    b.ne 1f
    ldr x0, [sp, #0]
    b 2f
1:  mov x0, #0
2:  add sp, sp, #16
    ret
