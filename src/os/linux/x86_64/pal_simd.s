# Duop PAL SIMD Primitives: x86-64 SSE2 baseline (every x86-64 CPU supports SSE2)
# Memory/string kernels used by src/core (memory.s, string.s), src/fs (filter) and src/tui (diff).
# Register contracts are intentionally *narrower* than the SysV ABI so they are drop-in
# replacements for the former byte-wise routines:
#   os_mem_copy_fast / os_mem_move_fast : clobber rcx, rdi, rsi, xmm0-xmm1 only
#   os_mem_set_fast                     : clobber rax, rcx, rdi, xmm0 only
#   os_mem_cmp_fast                     : clobber rax, rcx, rdx, rdi, rsi, xmm0-xmm1
#   os_str_len_fast                     : clobber rax, xmm0-xmm1 only
#   os_str_contains_ci_fast             : clobber rax, rcx, rdi, r8, r9, xmm0-xmm5
#   os_mem_mismatch16                   : clobber rax, rcx, xmm0-xmm1
# An AArch64 port supplies NEON (or scalar) versions with identical contracts.

.intel_syntax noprefix
.include "pal.inc"

.equ ERMS_MIN, 2048           # from here `rep movsb/stosb` (ERMS/FSRM) beats SSE loops

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

# void os_mem_copy_fast(void *dst, const void *src, size_t len) -- non-overlapping
os_mem_copy_fast:
    cmp rdx, 16
    jb .Lcp_small
    cmp rdx, 32
    jbe .Lcp_16_32
    cmp rdx, ERMS_MIN
    jae .Lcp_erms
    push rdx
    movdqu xmm1, [rsi + rdx - 16]     # tail (overlapping final store)
    lea rcx, [rdi + rdx - 16]
.Lcp_loop:
    movdqu xmm0, [rsi]
    movdqu [rdi], xmm0
    add rsi, 16
    add rdi, 16
    sub rdx, 16
    cmp rdx, 16
    ja .Lcp_loop
    movdqu [rcx], xmm1
    pop rdx
    ret
.Lcp_16_32:
    movdqu xmm0, [rsi]
    movdqu xmm1, [rsi + rdx - 16]
    movdqu [rdi], xmm0
    movdqu [rdi + rdx - 16], xmm1
    ret
.Lcp_erms:
    mov rcx, rdx
    rep movsb
    ret
.Lcp_small:
    cmp rdx, 8
    jb .Lcp_lt8
    movq xmm0, [rsi]
    movq xmm1, [rsi + rdx - 8]
    movq [rdi], xmm0
    movq [rdi + rdx - 8], xmm1
    ret
.Lcp_lt8:
    cmp rdx, 4
    jb .Lcp_lt4
    movd xmm0, [rsi]
    movd xmm1, [rsi + rdx - 4]
    movd [rdi], xmm0
    movd [rdi + rdx - 4], xmm1
    ret
.Lcp_lt4:
    test rdx, rdx
    jz .Lcp_ret
    movzx ecx, byte ptr [rsi]
    cmp rdx, 1
    je .Lcp_one
    push rax
    movzx eax, word ptr [rsi + rdx - 2]
    mov [rdi + rdx - 2], ax
    pop rax
.Lcp_one:
    mov [rdi], cl
.Lcp_ret:
    ret

# void os_mem_move_fast(void *dst, const void *src, size_t len) -- overlap-safe, no `std`
os_mem_move_fast:
    cmp rdi, rsi
    je .Lmv_ret
    cmp rdx, 32
    jbe .Lmv_small                    # all loads precede stores -> overlap-safe
    mov rcx, rsi
    add rcx, rdx
    cmp rdi, rcx
    jae os_mem_copy_fast              # disjoint
    cmp rdi, rsi
    jb .Lmv_fwd
    # Backward: dst > src, overlapping. Preload head, copy 16B blocks from the end.
    push rdx
    movdqu xmm1, [rsi]
    mov rcx, rdi
.Lmv_bk_loop:
    movdqu xmm0, [rsi + rdx - 16]
    movdqu [rdi + rdx - 16], xmm0
    sub rdx, 16
    cmp rdx, 16
    ja .Lmv_bk_loop
    movdqu [rcx], xmm1
    pop rdx
    ret
.Lmv_fwd:
    # dst < src: forward blocks never overwrite unread source bytes; tail preloaded
    push rdx
    movdqu xmm1, [rsi + rdx - 16]
    lea rcx, [rdi + rdx - 16]
.Lmv_fw_loop:
    movdqu xmm0, [rsi]
    movdqu [rdi], xmm0
    add rsi, 16
    add rdi, 16
    sub rdx, 16
    cmp rdx, 16
    ja .Lmv_fw_loop
    movdqu [rcx], xmm1
    pop rdx
    ret
.Lmv_small:
    cmp rdx, 16
    jae .Lcp_16_32
    jmp .Lcp_small
.Lmv_ret:
    ret

# void os_mem_set_fast(void *dst, int byte, size_t len)
os_mem_set_fast:
    movzx eax, sil
    cmp rdx, 16
    jb .Lst_small
    cmp rdx, ERMS_MIN
    jae .Lst_erms
    push rdx
    imul eax, eax, 0x01010101
    movd xmm0, eax
    pshufd xmm0, xmm0, 0
    lea rcx, [rdi + rdx - 16]
.Lst_loop:
    movdqu [rdi], xmm0
    add rdi, 16
    sub rdx, 16
    cmp rdx, 16
    ja .Lst_loop
    movdqu [rcx], xmm0
    pop rdx
    ret
.Lst_erms:
    mov rcx, rdx
    rep stosb
    ret
.Lst_small:
    mov rcx, rdx
    rep stosb
    ret

# int os_mem_cmp_fast(const void *a, const void *b, size_t len)
os_mem_cmp_fast:
.Lmc_blk:
    cmp rdx, 16
    jb .Lmc_tail
    movdqu xmm0, [rdi]
    movdqu xmm1, [rsi]
    pcmpeqb xmm0, xmm1
    pmovmskb eax, xmm0
    cmp eax, 0xFFFF
    jne .Lmc_diff
    add rdi, 16
    add rsi, 16
    sub rdx, 16
    jmp .Lmc_blk
.Lmc_diff:
    not eax
    bsf ecx, eax
    movzx eax, byte ptr [rdi + rcx]
    movzx edx, byte ptr [rsi + rcx]
    sub eax, edx
    ret
.Lmc_tail:
    test rdx, rdx
    jz .Lmc_eq
    movzx eax, byte ptr [rdi]
    movzx ecx, byte ptr [rsi]
    sub eax, ecx
    jnz .Lmc_ret
    inc rdi
    inc rsi
    dec rdx
    jmp .Lmc_tail
.Lmc_eq:
    xor eax, eax
.Lmc_ret:
    ret

# size_t os_str_len_fast(const char *s) -- aligned 16B scans never cross a page boundary
os_str_len_fast:
    push rcx
    push rdx
    mov rax, rdi
    and rax, -16
    pxor xmm0, xmm0
    movdqa xmm1, [rax]
    pcmpeqb xmm1, xmm0
    pmovmskb edx, xmm1
    mov ecx, edi
    and ecx, 15
    shr edx, cl
    test edx, edx
    jnz .Lsl_first
.Lsl_loop:
    add rax, 16
    movdqa xmm1, [rax]
    pcmpeqb xmm1, xmm0
    pmovmskb edx, xmm1
    test edx, edx
    jz .Lsl_loop
    bsf edx, edx
    add rax, rdx
    sub rax, rdi
    pop rdx
    pop rcx
    ret
.Lsl_first:
    bsf eax, edx
    pop rdx
    pop rcx
    ret

# int os_str_contains_ci_fast(const char *hay, const char *needle_lc, size_t nlen)
# needle_lc must already be ASCII-lowercased. Candidate first bytes (both cases) are found
# 16 at a time with pcmpeqb; only candidates are verified byte-wise.
os_str_contains_ci_fast:
    test rdx, rdx
    jz .Lci_yes_fast
    push rbx
    push r10
    push r11
    movzx eax, byte ptr [rsi]
    mov ecx, eax
    cmp eax, 'a'
    jb .Lci_nocase
    cmp eax, 'z'
    ja .Lci_nocase
    sub ecx, 32
.Lci_nocase:
    imul eax, eax, 0x01010101
    movd xmm1, eax
    pshufd xmm1, xmm1, 0
    imul ecx, ecx, 0x01010101
    movd xmm2, ecx
    pshufd xmm2, xmm2, 0
    pxor xmm0, xmm0
    mov r8, rdi
    and r8, -16
    mov ecx, edi
    and ecx, 15
    mov r11d, -1
    shl r11d, cl
.Lci_block:
    movdqa xmm3, [r8]
    movdqa xmm4, xmm3
    pcmpeqb xmm4, xmm0
    pmovmskb r9d, xmm4
    movdqa xmm4, xmm3
    pcmpeqb xmm4, xmm1
    movdqa xmm5, xmm3
    pcmpeqb xmm5, xmm2
    por xmm4, xmm5
    pmovmskb ebx, xmm4
    and r9d, r11d
    and ebx, r11d
    test r9d, r9d
    jz .Lci_cands
    mov eax, r9d
    neg eax
    and eax, r9d
    dec eax
    and ebx, eax                      # candidates strictly before the terminator
.Lci_cands:
    test ebx, ebx
    jz .Lci_next
    bsf eax, ebx
    btr ebx, eax
    lea r10, [r8 + rax]
    mov ecx, 1
.Lci_verify:
    cmp rcx, rdx
    jae .Lci_yes
    movzx eax, byte ptr [r10 + rcx]
    test eax, eax
    jz .Lci_no                        # haystack ends: no later candidate can fit either
    cmp eax, 'A'
    jb .Lci_fold
    cmp eax, 'Z'
    ja .Lci_fold
    add eax, 32
.Lci_fold:
    cmp al, byte ptr [rsi + rcx]
    jne .Lci_cands
    inc rcx
    jmp .Lci_verify
.Lci_next:
    test r9d, r9d
    jnz .Lci_no
    add r8, 16
    mov r11d, -1
    jmp .Lci_block
.Lci_yes:
    mov eax, 1
    jmp .Lci_ret
.Lci_no:
    xor eax, eax
.Lci_ret:
    pop r11
    pop r10
    pop rbx
    ret
.Lci_yes_fast:
    mov eax, 1
    ret

# size_t os_mem_find_byte(const void *p, size_t len, int byte) -> index or len
# Clobbers rax, rcx, r8, r9, xmm0-xmm1.
os_mem_find_byte:
    movzx eax, dl
    imul eax, eax, 0x01010101
    movd xmm1, eax
    pshufd xmm1, xmm1, 0
    xor eax, eax                      # index
.Lfb_blk:
    lea r8, [rax + 16]
    cmp r8, rsi
    ja .Lfb_tail
    movdqu xmm0, [rdi + rax]
    pcmpeqb xmm0, xmm1
    pmovmskb ecx, xmm0
    test ecx, ecx
    jnz .Lfb_hit
    mov rax, r8
    jmp .Lfb_blk
.Lfb_hit:
    bsf ecx, ecx
    add rax, rcx
    ret
.Lfb_tail:
    cmp rax, rsi
    jae .Lfb_none
    cmp byte ptr [rdi + rax], dl
    je .Lfb_ret
    inc rax
    jmp .Lfb_tail
.Lfb_none:
    mov rax, rsi
.Lfb_ret:
    ret

# size_t os_mem_count_byte(const void *p, size_t len, int byte)
# Clobbers rax, rcx, r8, r9, r10, xmm0-xmm1.
os_mem_count_byte:
    movzx eax, dl
    imul eax, eax, 0x01010101
    movd xmm1, eax
    pshufd xmm1, xmm1, 0
    xor eax, eax                      # count
    xor r8d, r8d                      # index
.Lcb_blk:
    lea r9, [r8 + 16]
    cmp r9, rsi
    ja .Lcb_tail
    movdqu xmm0, [rdi + r8]
    pcmpeqb xmm0, xmm1
    pmovmskb ecx, xmm0
.Lcb_pop:                             # baseline x86-64 has no POPCNT: clear lowest set bit
    test ecx, ecx
    jz .Lcb_adv
    lea r10d, [rcx - 1]
    and ecx, r10d
    inc rax
    jmp .Lcb_pop
.Lcb_adv:
    mov r8, r9
    jmp .Lcb_blk
.Lcb_tail:
    cmp r8, rsi
    jae .Lcb_ret
    cmp byte ptr [rdi + r8], dl
    jne .Lcb_next
    inc rax
.Lcb_next:
    inc r8
    jmp .Lcb_tail
.Lcb_ret:
    ret

# size_t os_mem_mismatch16(const void *a, const void *b, size_t n16)
# Index of the first 16-byte block that differs, or n16 when all blocks are equal.
os_mem_mismatch16:
    xor eax, eax
.Lmm_loop:
    cmp rax, rdx
    jae .Lmm_done
    mov rcx, rax
    shl rcx, 4
    movdqu xmm0, [rdi + rcx]
    movdqu xmm1, [rsi + rcx]
    pcmpeqb xmm0, xmm1
    pmovmskb ecx, xmm0
    cmp ecx, 0xFFFF
    jne .Lmm_done
    inc rax
    jmp .Lmm_loop
.Lmm_done:
    ret
