// src/os/linux/aarch64/pal_start.s - process entry for C-main builds (kernel stack -> duop_main)
// Stack at _start: [sp]=argc, argv[argc]=NULL, envp[]=NULL, auxv[] (pairs, AT_NULL-terminated).

.section .text
.global _start
_start:
    mov x29, #0                       // outermost frame marker
    mov x30, #0
    ldr x0, [sp]                      // argc
    add x1, sp, #8                    // argv
    add x2, x1, x0, lsl #3
    add x2, x2, #8                    // envp
    mov x3, x2
1:
    ldr x4, [x3], #8
    cbnz x4, 1b                       // x3 -> auxv
    mov x9, sp
    and x9, x9, #-16                  // AAPCS64: already 16-aligned by the kernel; make it explicit
    mov sp, x9
    bl duop_main
    bl os_exit
2:
    b 2b
