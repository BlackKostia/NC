# Frozen reference oracle: the hand-written asm that src/fs/inflate.c replaced (tests/test_c_inflate.py diffs against it)
# src/fs/inflate.s - Compact RFC 1951 DEFLATE & zlib decompressor — inflate api (split from inflate.s)

.intel_syntax noprefix
.equ INF_TREE_SZ, 704         # counts[16](32) + offsets[16](32) + symbols[320](640)
.equ INF_STATE_SZ, 64         # [0]=src [8]=src_end [16]=bitbuf [24]=bitcnt [32]=dst [40]=dst_start [48]=dst_end
.extern mem_alloc
.extern mem_free
.extern mem_zero

.section .text
.global inflate_raw
.global inflate_zlib

# int64_t inflate_raw(const void *src, uint64_t src_len, void *dst, uint64_t dst_cap)
inflate_raw:
    push rbx; push r12; push r13; push r14
    sub rsp, INF_STATE_SZ + INF_TREE_SZ * 2 + 8
    mov [rsp], rdi
    lea rax, [rdi + rsi]
    mov [rsp + 8], rax
    mov qword ptr [rsp + 16], 0
    mov dword ptr [rsp + 24], 0
    mov [rsp + 32], rdx
    mov [rsp + 40], rdx
    lea rax, [rdx + rcx]
    mov [rsp + 48], rax
    lea r12, [rsp + INF_STATE_SZ]
    lea r13, [rsp + INF_STATE_SZ + INF_TREE_SZ]

.Lir_blk:
    mov rdi, rsp; mov esi, 1; call inf_bits; mov r14d, eax
    mov rdi, rsp; mov esi, 2; call inf_bits
    cmp eax, 0; je .Lir_stored
    cmp eax, 1; je .Lir_fixed
    cmp eax, 2; je .Lir_dyn
    jmp .Lir_err
.Lir_stored:
    mov rdi, rsp; call inf_block_stored; jmp .Lir_chk
.Lir_fixed:
    mov rdi, r12; mov rsi, r13; call inf_build_fixed
    mov rdi, rsp; mov rsi, r12; mov rdx, r13; call inf_block_huff; jmp .Lir_chk
.Lir_dyn:
    mov rdi, rsp; mov rsi, r12; mov rdx, r13; call inf_load_dyn
    test eax, eax; js .Lir_err
    mov rdi, rsp; mov rsi, r12; mov rdx, r13; call inf_block_huff
.Lir_chk:
    test eax, eax; js .Lir_err
    test r14d, r14d; jz .Lir_blk
    mov rax, [rsp + 32]; sub rax, [rsp + 40]; jmp .Lir_ret
.Lir_err:
    mov rax, -1
.Lir_ret:
    add rsp, INF_STATE_SZ + INF_TREE_SZ * 2 + 8
    pop r14; pop r13; pop r12; pop rbx; ret

# int64_t inflate_zlib(const void *src, uint64_t src_len, void *dst, uint64_t dst_cap)
inflate_zlib:
    cmp rsi, 6; jb .Liz_err
    movzx eax, byte ptr [rdi]
    and eax, 0x0F
    cmp eax, 8; jne .Liz_err
    movzx eax, byte ptr [rdi + 1]
    add rdi, 2; sub rsi, 2
    test eax, 0x20
    jz .Liz_go
    cmp rsi, 4; jb .Liz_err
    add rdi, 4; sub rsi, 4
.Liz_go:
    jmp inflate_raw
.Liz_err:
    mov rax, -1; ret
