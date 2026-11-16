# src/os/linux/x86_64/pal_time.s - Linux x86-64 wall clock (seconds since the Unix epoch)
.intel_syntax noprefix
.include "pal.inc"

.equ CLOCK_REALTIME, 0

.section .text
.global os_time_sec

# int64_t os_time_sec(void) -- CLOCK_REALTIME seconds; 0 when the clock cannot be read
os_time_sec:
    sub rsp, 24               # timespec; entry rsp%16==8, so calls/syscalls see an aligned stack
    mov edi, CLOCK_REALTIME
    mov rsi, rsp
    mov eax, OS_SYS_clock_gettime
    syscall
    test rax, rax
    jnz .Lots_fail
    mov rax, [rsp]
    jmp .Lots_ret
.Lots_fail:
    xor eax, eax
.Lots_ret:
    add rsp, 24
    ret
