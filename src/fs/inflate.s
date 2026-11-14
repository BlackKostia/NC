# src/fs/inflate.s - Compact RFC 1951 DEFLATE & zlib decompressor

.intel_syntax noprefix
.equ INF_TREE_SZ, 704         # counts[16](32) + offsets[16](32) + symbols[320](640)
.equ INF_STATE_SZ, 64         # [0]=src [8]=src_end [16]=bitbuf [24]=bitcnt [32]=dst [40]=dst_start [48]=dst_end
.extern mem_alloc
.extern mem_free
.extern mem_zero

.section .rodata
.align 2
inf_len_base:
    .word 3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31
    .word 35,43,51,59,67,83,99,115,131,163,195,227,258
inf_len_ext:
    .byte 0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0
inf_dist_base:
    .word 1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193
    .word 257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577
inf_dist_ext:
    .byte 0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13
inf_cl_order:
    .byte 16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15

.section .text
.global inf_bits
.global inf_block_stored
.global inf_block_huff
.global inf_build_fixed
.global inf_load_dyn

# uint32_t inf_bits(InfState *st, int nbits)
inf_bits:
    mov rax, [rdi + 16]       # bitbuf
    mov ecx, [rdi + 24]       # bitcnt
.Lib_fill:
    cmp ecx, esi
    jge .Lib_take
    mov r8, [rdi]
    cmp r8, [rdi + 8]
    jae .Lib_eof
    movzx r9d, byte ptr [r8]
    inc r8
    mov [rdi], r8
    shl r9, cl
    or rax, r9
    add ecx, 8
    jmp .Lib_fill
.Lib_eof:
    # Pad with zeros if past EOF
    mov ecx, esi
.Lib_take:
    mov [rdi + 16], rax
    mov r8d, 1
    push rcx
    mov ecx, esi
    shl r8, cl
    dec r8
    and r8, rax               # result
    shr rax, cl
    pop rcx
    sub ecx, esi
    mov [rdi + 16], rax
    mov [rdi + 24], ecx
    mov eax, r8d
    ret

# void inf_align(InfState *st)
inf_align:
    mov ecx, [rdi + 24]
    and ecx, 7
    jz .Lia_done
    mov rax, [rdi + 16]
    shr rax, cl
    mov [rdi + 16], rax
    sub [rdi + 24], ecx
.Lia_done:
    ret

# int inf_build_tree(const uint8_t *lens, int n_syms, void *tree)
inf_build_tree:
    push rbx
    push r12
    mov rbx, rdx              # tree
    mov r12d, esi             # n_syms
    mov r8, rdi               # lens
    # Zero counts[16] & offsets[16] (64 bytes)
    xor ecx, ecx
.Libt_z:
    mov qword ptr [rbx + rcx*8], 0
    inc ecx
    cmp ecx, 8
    jl .Libt_z
    # Count bit lengths
    xor ecx, ecx
.Libt_cnt:
    cmp ecx, r12d
    jge .Libt_off
    movzx eax, byte ptr [r8 + rcx]
    cmp eax, 15
    ja .Libt_next_c
    inc word ptr [rbx + rax*2]
.Libt_next_c:
    inc ecx
    jmp .Libt_cnt
.Libt_off:
    mov word ptr [rbx], 0     # counts[0] = 0
    xor eax, eax              # sum = 0
    mov ecx, 1
.Libt_off_loop:
    cmp ecx, 16
    jge .Libt_fill
    mov [rbx + 32 + rcx*2], ax
    movzx edx, word ptr [rbx + rcx*2]
    add eax, edx
    inc ecx
    jmp .Libt_off_loop
.Libt_fill:
    xor ecx, ecx
.Libt_fill_loop:
    cmp ecx, r12d
    jge .Libt_ok
    movzx eax, byte ptr [r8 + rcx]
    test eax, eax
    jz .Libt_fill_next
    movzx edx, word ptr [rbx + 32 + rax*2]
    inc word ptr [rbx + 32 + rax*2]
    cmp edx, 320
    jae .Libt_fill_next
    mov [rbx + 64 + rdx*2], cx
.Libt_fill_next:
    inc ecx
    jmp .Libt_fill_loop
.Libt_ok:
    xor eax, eax
    pop r12
    pop rbx
    ret

# int inf_decode(InfState *st, void *tree) -> symbol or -1
inf_decode:
    push rbx
    push r12
    push r13
    mov rbx, rdi              # st
    mov r12, rsi              # tree
    xor r13d, r13d            # code = 0
    xor edx, edx              # first = 0
    xor r8d, r8d              # index = 0
    mov r9d, 1                # len = 1
.Lid_loop:
    cmp r9d, 15
    jg .Lid_fail
    push rdx
    push r8
    push r9
    mov rdi, rbx
    mov esi, 1
    call inf_bits
    pop r9
    pop r8
    pop rdx
    shl r13d, 1
    or r13d, eax
    movzx ecx, word ptr [r12 + r9*2]  # count = counts[len]
    mov eax, r13d
    sub eax, edx              # code - first
    cmp eax, ecx
    jl .Lid_found
    add edx, ecx
    shl edx, 1
    add r8d, ecx
    inc r9d
    jmp .Lid_loop
.Lid_found:
    add eax, r8d
    cmp eax, 320
    jae .Lid_fail
    movzx eax, word ptr [r12 + 64 + rax*2]
    pop r13
    pop r12
    pop rbx
    ret
.Lid_fail:
    mov eax, -1
    pop r13
    pop r12
    pop rbx
    ret

# int inf_block_stored(InfState *st)
inf_block_stored:
    push rbx
    mov rbx, rdi
    call inf_align
    mov rdi, rbx; mov esi, 16; call inf_bits
    push rax                  # len
    mov rdi, rbx; mov esi, 16; call inf_bits
    pop rcx                   # len
    not eax
    and eax, 0xFFFF
    cmp eax, ecx
    jne .Libs_err
    mov r8, [rbx + 32]        # dst
    lea r9, [r8 + rcx]
    cmp r9, [rbx + 48]        # dst_end
    ja .Libs_err
    mov rsi, [rbx]            # src
    lea r10, [rsi + rcx]
    cmp r10, [rbx + 8]
    ja .Libs_err
    mov [rbx], r10
    mov [rbx + 32], r9
    test rcx, rcx
    jz .Libs_ok
.Libs_cp:
    mov al, [rsi]
    mov [r8], al
    inc rsi; inc r8; dec rcx
    jnz .Libs_cp
.Libs_ok:
    xor eax, eax
    pop rbx
    ret
.Libs_err:
    mov eax, -1
    pop rbx
    ret

# int inf_block_huff(InfState *st, void *lit_tree, void *dist_tree)
inf_block_huff:
    push rbx; push r12; push r13; push r14; push r15
    mov rbx, rdi; mov r12, rsi; mov r13, rdx
.Libh_loop:
    mov rdi, rbx; mov rsi, r12; call inf_decode
    cmp eax, 0; jl .Libh_err
    cmp eax, 256; je .Libh_ok
    jg .Libh_match
    mov r8, [rbx + 32]
    cmp r8, [rbx + 48]; jae .Libh_err
    mov [r8], al
    inc qword ptr [rbx + 32]
    jmp .Libh_loop
.Libh_match:
    sub eax, 257
    cmp eax, 29; jae .Libh_err
    lea r9, [rip + inf_len_base]
    movzx r14d, word ptr [r9 + rax*2]
    lea r9, [rip + inf_len_ext]
    movzx esi, byte ptr [r9 + rax]
    test esi, esi; jz .Libh_dist
    mov rdi, rbx; call inf_bits
    add r14d, eax             # length
.Libh_dist:
    mov rdi, rbx; mov rsi, r13; call inf_decode
    cmp eax, 0; jl .Libh_err
    cmp eax, 30; jae .Libh_err
    lea r9, [rip + inf_dist_base]
    movzx r15d, word ptr [r9 + rax*2]
    lea r9, [rip + inf_dist_ext]
    movzx esi, byte ptr [r9 + rax]
    test esi, esi; jz .Libh_copy
    mov rdi, rbx; call inf_bits
    add r15d, eax             # distance
.Libh_copy:
    mov r8, [rbx + 32]        # dst
    mov r9, r8; sub r9, r15
    cmp r9, [rbx + 40]; jb .Libh_err
    lea r10, [r8 + r14]
    cmp r10, [rbx + 48]; ja .Libh_err
    mov [rbx + 32], r10
.Libh_cp:
    mov al, [r9]; mov [r8], al
    inc r9; inc r8; dec r14d; jnz .Libh_cp
    jmp .Libh_loop
.Libh_ok:
    xor eax, eax; jmp .Libh_ret
.Libh_err:
    mov eax, -1
.Libh_ret:
    pop r15; pop r14; pop r13; pop r12; pop rbx; ret

# void inf_build_fixed(void *lit_tree, void *dist_tree)
inf_build_fixed:
    push rbx; push r12; sub rsp, 336
    mov rbx, rdi; mov r12, rsi
    xor ecx, ecx
.Libf_l1:
    cmp ecx, 144; jge .Libf_l2
    mov byte ptr [rsp + rcx], 8; inc ecx; jmp .Libf_l1
.Libf_l2:
    cmp ecx, 256; jge .Libf_l3
    mov byte ptr [rsp + rcx], 9; inc ecx; jmp .Libf_l2
.Libf_l3:
    cmp ecx, 280; jge .Libf_l4
    mov byte ptr [rsp + rcx], 7; inc ecx; jmp .Libf_l3
.Libf_l4:
    cmp ecx, 288; jge .Libf_bt1
    mov byte ptr [rsp + rcx], 8; inc ecx; jmp .Libf_l4
.Libf_bt1:
    mov rdi, rsp; mov esi, 288; mov rdx, rbx; call inf_build_tree
    xor ecx, ecx
.Libf_d:
    mov byte ptr [rsp + rcx], 5; inc ecx; cmp ecx, 32; jl .Libf_d
    mov rdi, rsp; mov esi, 32; mov rdx, r12; call inf_build_tree
    add rsp, 336; pop r12; pop rbx; ret

# int inf_load_dyn(InfState *st, void *lit_tree, void *dist_tree)
inf_load_dyn:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, 352              # [0..319]=lengths(320), [320]=hlit, [324]=hdist, [328]=hclen
    mov rbx, rdi; mov r12, rsi; mov r13, rdx
    mov rdi, rbx; mov esi, 5; call inf_bits; add eax, 257; mov [rsp + 320], eax
    mov rdi, rbx; mov esi, 5; call inf_bits; add eax, 1;   mov [rsp + 324], eax
    mov rdi, rbx; mov esi, 4; call inf_bits; add eax, 4;   mov [rsp + 328], eax
    xor ecx, ecx
.Lild_z:
    mov byte ptr [rsp + rcx], 0; inc ecx; cmp ecx, 19; jl .Lild_z
    xor r14d, r14d
    lea r15, [rip + inf_cl_order]
.Lild_cl:
    cmp r14d, [rsp + 328]; jge .Lild_cl_bt
    mov rdi, rbx; mov esi, 3; call inf_bits
    movzx ecx, byte ptr [r15 + r14]
    mov [rsp + rcx], al
    inc r14d; jmp .Lild_cl
.Lild_cl_bt:
    # Build CL tree in lit_tree temporarily
    mov rdi, rsp; mov esi, 19; mov rdx, r12; call inf_build_tree
    mov r14d, [rsp + 320]; add r14d, [rsp + 324]  # total codes
    xor r15d, r15d
.Lild_codes:
    cmp r15d, r14d; jge .Lild_build
    mov rdi, rbx; mov rsi, r12; call inf_decode
    cmp eax, 0; jl .Lild_err
    cmp eax, 16; jge .Lild_rep
    mov [rsp + r15], al; inc r15d; jmp .Lild_codes
.Lild_rep:
    cmp eax, 16; jne .Lild_r17
    test r15d, r15d; jz .Lild_err
    mov rdi, rbx; mov esi, 2; call inf_bits; add eax, 3
    movzx ecx, byte ptr [rsp + r15 - 1]
    jmp .Lild_fill
.Lild_r17:
    cmp eax, 17; jne .Lild_r18
    mov rdi, rbx; mov esi, 3; call inf_bits; add eax, 3
    xor ecx, ecx; jmp .Lild_fill
.Lild_r18:
    mov rdi, rbx; mov esi, 7; call inf_bits; add eax, 11
    xor ecx, ecx
.Lild_fill:
    lea edx, [r15d + eax]
    cmp edx, r14d; ja .Lild_err
.Lild_floop:
    mov [rsp + r15], cl; inc r15d; dec eax; jnz .Lild_floop
    jmp .Lild_codes
.Lild_build:
    mov rdi, rsp; mov esi, [rsp + 320]; mov rdx, r12; call inf_build_tree
    mov eax, [rsp + 320]; lea rdi, [rsp + rax]
    mov esi, [rsp + 324]; mov rdx, r13; call inf_build_tree
    xor eax, eax; jmp .Lild_ret
.Lild_err:
    mov eax, -1
.Lild_ret:
    add rsp, 352; pop r15; pop r14; pop r13; pop r12; pop rbx; ret
