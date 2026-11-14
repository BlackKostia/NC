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

os_str_contains_ci_fast:
    ldrb w9, [x1]
    cbz w9, 4f
1:
    ldrb w10, [x0]
    cbz w10, 5f
    mov x11, x0
    mov x12, x1
2:
    ldrb w13, [x12], #1
    cbz w13, 4f
    ldrb w14, [x11], #1
    cbz w14, 5f
    orr w13, w13, #0x20
    orr w14, w14, #0x20
    cmp w13, w14
    b.eq 2b
    add x0, x0, #1
    b 1b
4:
    mov w0, #1
    ret
5:
    mov w0, #0
    ret

os_mem_mismatch16:
    ldr q0, [x0]
    ldr q1, [x1]
    cmeq v0.16b, v0.16b, v1.16b
    uminv b2, v0.16b
    umov w9, v2.b[0]
    cmp w9, #0xff
    cset w0, ne
    ret

os_mem_find_byte:
    mov x9, #0
1:
    cmp x9, x2
    b.hs 2f
    ldrb w10, [x0, x9]
    cmp w10, w1
    b.eq 3f
    add x9, x9, #1
    b 1b
2:
    mov x0, #-1
    ret
3:
    mov x0, x9
    ret

os_mem_count_byte:
    mov x9, #0
1:
    cbz x2, 2f
    ldrb w10, [x0], #1
    cmp w10, w1
    cinc x9, x9, eq
    sub x2, x2, #1
    b 1b
2:
    mov x0, x9
    ret
