// src/os/linux/aarch64/pal_thread.s - Linux AArch64 worker thread primitives
.include "pal.inc"

.equ CLONE_THREAD_FLAGS, 0x01210F00
.equ OS_SYS_futex,       98

.section .text
.global os_thread_spawn
.global os_thread_join

// int os_thread_spawn(void (*fn)(void *), void *arg, void *stack_top, int *ctid_out)
os_thread_spawn:
    mov w4, #1
    str w4, [x3]
    sub x2, x2, #16
    stp x0, x1, [x2]
    mov x1, x2
    ldr x0, =CLONE_THREAD_FLAGS
    mov x2, #0
    mov x4, x3
    mov x3, #0
    OS_SYSCALL OS_SYS_clone
    cbz x0, .Lchild_entry
    cmp x0, #0
    b.ge .Lparent_ok
    str wzr, [x4]
.Lparent_ok:
    ret
.Lchild_entry:
    ldp x9, x0, [sp], #16
    blr x9
    mov x0, #0
    OS_SYSCALL OS_SYS_exit

// void os_thread_join(int *ctid)
os_thread_join:
    mov x9, x0
.Ljoin_loop:
    ldr w2, [x9]
    cbz w2, .Ljoin_done
    mov x0, x9
    mov x1, #0
    mov x3, #0
    mov x4, #0
    mov x5, #0
    OS_SYSCALL OS_SYS_futex
    b .Ljoin_loop
.Ljoin_done:
    ret
