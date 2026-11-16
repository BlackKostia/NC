// Duop PAL: Linux AArch64 PTY master/slave spawn, resize, and I/O helpers

.include "pal.inc"

.section .rodata
ptmx_path: .asciz "/dev/ptmx"
pts_pfx:   .asciz "/dev/pts/"
sh_path:   .asciz "/bin/sh"

.section .text
.global os_pty_spawn
.global os_pty_resize
.global os_pty_read
.global os_pty_write
.global os_pty_close
.global os_get_winsize_px
.global os_poll_out
.extern os_sig_reset_pipe

pty_format_pts_path:
    mov w9, w0
    mov x10, x1
    adrp x11, pts_pfx
    add x11, x11, :lo12:pts_pfx
1:
    ldrb w12, [x11], #1
    cbz w12, 2f
    strb w12, [x10], #1
    b 1b
2:
    sub sp, sp, #32
    add x13, sp, #31
    strb wzr, [x13]
    mov w14, #10
3:
    udiv w15, w9, w14
    msub w12, w15, w14, w9
    add w12, w12, #'0'
    sub x13, x13, #1
    strb w12, [x13]
    mov w9, w15
    cbnz w9, 3b
4:
    ldrb w12, [x13], #1
    strb w12, [x10], #1
    cbnz w12, 4b
    add sp, sp, #32
    ret

pty_exec_child:
    sub sp, sp, #32
    mov x19, x1               // pts_path
    mov x20, x2               // cwd
    mov x21, x3               // envp
    OS_CLOSE
    OS_SYSCALL OS_SYS_setsid
    mov w0, #AT_FDCWD
    mov x1, x19
    mov w2, #O_RDWR
    mov w3, #0
    OS_OPENAT
    cmp x0, #0
    b.lt 2f
    mov w22, w0
    mov w0, w22
    mov x1, #OS_TIOCSCTTY
    mov x2, #0
    OS_IOCTL
    mov w0, w22; mov w1, #0; mov w2, #0; OS_SYSCALL OS_SYS_dup3
    mov w0, w22; mov w1, #1; mov w2, #0; OS_SYSCALL OS_SYS_dup3
    mov w0, w22; mov w1, #2; mov w2, #0; OS_SYSCALL OS_SYS_dup3
    cmp w22, #2
    b.le 1f
    mov w0, w22
    OS_CLOSE
1:
    cbz x20, 3f
    mov x0, x20
    OS_SYSCALL OS_SYS_chdir
3:
    bl os_sig_reset_pipe
    adrp x0, sh_path
    add x0, x0, :lo12:sh_path
    str x0, [sp, #0]
    str xzr, [sp, #8]
    mov x1, sp
    mov x2, x21
    OS_SYSCALL OS_SYS_execve
2:
    mov w0, #127
    OS_EXIT

// int os_pty_spawn(int *out_master_fd, int *out_pid, const char *cwd, char **envp, int cols, int rows)
os_pty_spawn:
    stp x29, x30, [sp, #-112]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    mov x19, x0               // out_master_fd
    mov x20, x1               // out_pid
    mov x21, x2               // cwd
    mov x22, x3               // envp
    mov w23, w4               // cols
    mov w24, w5               // rows

    mov w0, #AT_FDCWD
    adrp x1, ptmx_path
    add x1, x1, :lo12:ptmx_path
    movz w2, #0x0902
    movk w2, #0x0008, lsl #16 // O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC
    mov w3, #0
    OS_OPENAT
    cmp x0, #0
    b.lt 9f
    mov w25, w0               // master_fd

    str wzr, [sp, #64]
    mov w0, w25
    movz x1, #0x5431
    movk x1, #0x4004, lsl #16
    add x2, sp, #64
    OS_IOCTL
    cmp x0, #0
    b.lt 8f

    str wzr, [sp, #68]
    mov w0, w25
    movz x1, #0x5430
    movk x1, #0x8004, lsl #16
    add x2, sp, #68
    OS_IOCTL
    cmp x0, #0
    b.lt 8f

    ldr w0, [sp, #68]
    add x1, sp, #72
    bl pty_format_pts_path

    mov w0, w25
    mov w1, w23
    mov w2, w24
    bl os_pty_resize

    mov x0, #17               // SIGCHLD
    mov x1, #0; mov x2, #0; mov x3, #0; mov x4, #0
    OS_SYSCALL OS_SYS_clone
    cmp x0, #0
    b.lt 8f
    cbnz x0, 1f

    mov w0, w25
    add x1, sp, #72
    mov x2, x21
    mov x3, x22
    bl pty_exec_child
1:
    str w25, [x19]
    str w0, [x20]
    mov w0, #0
    b 9f
8:
    mov w9, w0
    mov w0, w25
    OS_CLOSE
    mov w0, w9
9:
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #112
    ret

os_pty_resize:
    sub sp, sp, #16
    strh w2, [sp, #0]
    strh w1, [sp, #2]
    str wzr, [sp, #4]
    mov x1, #OS_TIOCSWINSZ
    mov x2, sp
    OS_IOCTL
    add sp, sp, #16
    ret

os_pty_read:
    OS_READ
    ret

os_pty_write:
    OS_WRITE
    ret

os_pty_close:
    OS_CLOSE
    ret

// void os_get_winsize_px(int *xpix, int *ypix) -- terminal size in pixels (0, 0 when not reported)
os_get_winsize_px:
    sub sp, sp, #16
    mov x9, x0
    mov x10, x1
    str wzr, [x9]
    str wzr, [x10]
    mov w0, #1
    mov x1, #TIOCGWINSZ
    mov x2, sp
    OS_IOCTL
    cmp x0, #0
    b.lt 1f
    ldrh w11, [sp, #4]
    ldrh w12, [sp, #6]
    str w11, [x9]
    str w12, [x10]
1:
    add sp, sp, #16
    ret

os_poll_out:
    mov w0, #1
    ret
