# Calls img_alloc with garbage in the upper half of rdx (the System V ABI leaves the upper 32 bits of an int argument undefined):
# the frozen asm multiplied the full rdx, the C version uses the int.
.intel_syntax noprefix
.section .text
.global ic_ref_alloc_hi
.global ic_c_alloc_hi
ic_ref_alloc_hi:
    mov eax, edx
    movabs rdx, 0x0000000100000000
    or rdx, rax
    jmp ref_img_alloc
ic_c_alloc_hi:
    mov eax, edx
    movabs rdx, 0x0000000100000000
    or rdx, rax
    jmp img_alloc
