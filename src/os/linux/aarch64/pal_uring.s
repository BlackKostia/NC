// Duop PAL: Linux AArch64 batch stat (io_uring fallback to os_statat)

.include "pal.inc"

.section .text
.global os_batch_stat
.global os_uring_shutdown

// int os_batch_stat(int dirfd, const char **paths, FileStat *out_stats, int count, int follow)
os_batch_stat:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    mov w19, w0               // dirfd
    mov x20, x1               // paths
    mov x21, x2               // out_stats
    mov w22, w3               // count
    mov w23, w4               // follow
    mov w24, #0               // i
1:
    cmp w24, w22
    b.ge 2f
    mov w0, w19
    ldr x1, [x20, x24, lsl #3]
    mov x9, #FileStat._size
    mul x9, x24, x9
    add x2, x21, x9
    mov w3, w23
    bl os_statat
    add w24, w24, #1
    b 1b
2:
    mov w0, w24
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret

os_uring_shutdown:
    ret
