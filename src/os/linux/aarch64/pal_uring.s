// Duop PAL: Linux AArch64 batch stat (io_uring fallback to os_statat)

.include "pal.inc"

.section .text
.global os_batch_stat
.global os_uring_shutdown
.global os_uring_atfork_reset

// int os_batch_stat(int dirfd, const char **paths, FileStat *out_stats,
//                   int32_t *out_errs, size_t count, int follow)
os_batch_stat:
    stp x29, x30, [sp, #-80]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    str x25, [sp, #64]
    mov w19, w0               // dirfd
    mov x20, x1               // paths
    mov x21, x2               // out_stats
    mov x22, x3               // out_errs
    mov x23, x4               // count
    mov w25, w5               // follow
    mov x24, #0               // i
1:
    cmp x24, x23
    b.hs 2f
    mov w0, w19
    ldr x1, [x20, x24, lsl #3]
    mov x9, #FileStat._size
    mul x9, x24, x9
    add x2, x21, x9
    mov w3, w25
    bl os_statat
    cbz x22, 3f
    str w0, [x22, x24, lsl #2]
3:
    add x24, x24, #1
    b 1b
2:
    mov w0, #0
    ldr x25, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #80
    ret

os_uring_atfork_reset:
os_uring_shutdown:
    ret
