// Duop PAL: AArch64 NEON SIMD memory & string fast-paths

.include "pal.inc"

.section .text
.global os_mem_copy_fast
.global os_mem_move_fast
.global os_mem_set_fast
.global os_mem_cmp_fast
.global os_str_len_fast
.global os_str_contains_ci_fast
.global os_mem_mismatch16
.global os_mem_find_byte
.global os_mem_count_byte

os_mem_copy_fast:
    mov x9, x0
1:
    cmp x2, #16
    b.lt 2f
    ldr q0, [x1], #16
    str q0, [x0], #16
    sub x2, x2, #16
    b 1b
2:
    cbz x2, 3f
    ldrb w10, [x1], #1
    strb w10, [x0], #1
    sub x2, x2, #1
    b 2b
3:
    mov x0, x9
    ret

os_mem_move_fast:
    cmp x0, x1
    b.ls os_mem_copy_fast
    add x9, x1, x2
    cmp x0, x9
    b.hs os_mem_copy_fast
    add x10, x0, x2
1:
    cbz x2, 2f
    ldrb w11, [x9, #-1]!
    strb w11, [x10, #-1]!
    sub x2, x2, #1
    b 1b
2:
    ret

os_mem_set_fast:
    mov x9, x0
    dup v0.16b, w1
1:
    cmp x2, #16
    b.lt 2f
    str q0, [x0], #16
    sub x2, x2, #16
    b 1b
2:
    cbz x2, 3f
    strb w1, [x0], #1
    sub x2, x2, #1
    b 2b
3:
    mov x0, x9
    ret

os_mem_cmp_fast:
1:
    cbz x2, 2f
    ldrb w9, [x0], #1
    ldrb w10, [x1], #1
    cmp w9, w10
    b.ne 3f
    sub x2, x2, #1
    b 1b
2:
    mov w0, #0
    ret
3:
    sub w0, w9, w10
    ret

os_str_len_fast:
    mov x9, x0
1:
    ldrb w10, [x9]
    cbz w10, 2f
    add x9, x9, #1
    b 1b
2:
    sub x0, x9, x0
    ret

// int os_str_contains_ci_fast(const char *hay, const char *needle_lc, size_t nlen)
// needle_lc is already ASCII-lowercased; hay is NUL-terminated and folded A-Z -> a-z while comparing.
os_str_contains_ci_fast:
    cbz x2, 8f
1:
    ldrb w9, [x0]
    cbz w9, 9f                        // haystack exhausted before a full match
    mov x10, #0                       // j
2:
    cmp x10, x2
    b.hs 8f                           // all nlen bytes matched
    ldrb w11, [x0, x10]
    cbz w11, 9f                       // no later start can fit either
    sub w12, w11, #'A'
    cmp w12, #25
    b.hi 3f
    add w11, w11, #32                 // fold A-Z
3:
    ldrb w12, [x1, x10]
    cmp w11, w12
    b.ne 4f
    add x10, x10, #1
    b 2b
4:
    add x0, x0, #1
    b 1b
8:
    mov w0, #1
    ret
9:
    mov w0, #0
    ret

// size_t os_mem_mismatch16(const void *a, const void *b, size_t n16): first differing 16-byte block, or n16
os_mem_mismatch16:
    mov x3, #0
1:
    cmp x3, x2
    b.hs 2f
    ldr q0, [x0, x3, lsl #4]
    ldr q1, [x1, x3, lsl #4]
    cmeq v0.16b, v0.16b, v1.16b
    uminv b0, v0.16b
    umov w9, v0.b[0]
    cmp w9, #0xff
    b.ne 2f
    add x3, x3, #1
    b 1b
2:
    mov x0, x3
    ret

// size_t os_mem_find_byte(const void *p, size_t len, int byte) -> index or len
os_mem_find_byte:
    mov x9, #0
    and w2, w2, #0xff
1:
    cmp x9, x1
    b.hs 2f
    ldrb w10, [x0, x9]
    cmp w10, w2
    b.eq 2f
    add x9, x9, #1
    b 1b
2:
    mov x0, x9
    ret

// size_t os_mem_count_byte(const void *p, size_t len, int byte)
os_mem_count_byte:
    mov x9, #0
    and w2, w2, #0xff
1:
    cbz x1, 2f
    ldrb w10, [x0], #1
    cmp w10, w2
    cinc x9, x9, eq
    sub x1, x1, #1
    b 1b
2:
    mov x0, x9
    ret
