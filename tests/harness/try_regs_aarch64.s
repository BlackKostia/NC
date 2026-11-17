// int try_regs_probe(TryFrame *f, volatile char *bad): every callee-saved register holds a known value when os_try_begin runs,
// is clobbered, and a fault on *bad must hand the known values back when os_try_begin "returns" the second time (signal in w0).
.text
.global try_regs_probe
try_regs_probe:
    stp x29, x30, [sp, #-128]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    stp x27, x28, [sp, #80]
    str x1, [sp, #96]
    mov x19, #0x1901
    mov x20, #0x2002
    mov x21, #0x2103
    mov x22, #0x2204
    mov x23, #0x2305
    mov x24, #0x2406
    mov x25, #0x2507
    mov x26, #0x2608
    mov x27, #0x2709
    mov x28, #0x280a
    bl os_try_begin
    cbnz w0, 2f
    mov x19, #0xbad
    mov x20, #0xbad
    mov x21, #0xbad
    mov x22, #0xbad
    mov x23, #0xbad
    mov x24, #0xbad
    mov x25, #0xbad
    mov x26, #0xbad
    mov x27, #0xbad
    mov x28, #0xbad
    ldr x9, [sp, #96]
    mov w10, #1
    strb w10, [x9]
    mov w0, #-2
    b 9f
2:  mov x9, #0x1901
    cmp x19, x9
    b.ne 8f
    mov x9, #0x2002
    cmp x20, x9
    b.ne 8f
    mov x9, #0x2103
    cmp x21, x9
    b.ne 8f
    mov x9, #0x2204
    cmp x22, x9
    b.ne 8f
    mov x9, #0x2305
    cmp x23, x9
    b.ne 8f
    mov x9, #0x2406
    cmp x24, x9
    b.ne 8f
    mov x9, #0x2507
    cmp x25, x9
    b.ne 8f
    mov x9, #0x2608
    cmp x26, x9
    b.ne 8f
    mov x9, #0x2709
    cmp x27, x9
    b.ne 8f
    mov x9, #0x280a
    cmp x28, x9
    b.ne 8f
    ldr x9, [sp, #96]                       // sp is the value at the call: the spill slot is intact
    cbz x9, 8f
    b 9f
8:  mov w0, #-1
9:  ldp x19, x20, [sp, #16]
    ldp x21, x22, [sp, #32]
    ldp x23, x24, [sp, #48]
    ldp x25, x26, [sp, #64]
    ldp x27, x28, [sp, #80]
    ldp x29, x30, [sp], #128
    ret
