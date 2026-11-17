# Frozen reference oracle: the hand-written asm that src/fs/dir_sort.c + dir_sort_radix.c replaced (tests/test_c_dir_sort.py diffs against it)
# src/fs/dir_sort.s - Modular 4-byte index Introsort & byte-skipping LSD Radix Sort — dir sort radix (split from dir_sort.s)

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"
.equ RADIX_MIN_N,     64
.equ INSERTION_MIN_N, 16
.equ PREFIX_MIN_N,    512       # prefix-key radix for SORT_NAME / SORT_EXT from this size
.extern DirModel_ensure_all_stats
.extern str_casecmp
.extern str_cmp
.extern mem_alloc
.extern mem_free

.section .text
.global radix_sort_u32
.global make_prefix_key

# ==============================================================================
# 64-bit LSD Radix Sort with byte-skipping + equal-key Introsort tie-break
# void radix_sort_u32(uint32_t *arr, size_t len, const FileEntry *entries,
#                     const char *name_pool, uint32_t mode, uint32_t desc)
# ==============================================================================
radix_sort_u32:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 2048 + 72        # 256*8 histogram on stack + 72B frame (6 pushes=48 + 2120 + 8 = 2176 = 0 mod 16)
    # Frame at [rsp + 2048]:
    # +0  = arr
    # +8  = len
    # +16 = entries
    # +24 = name_pool
    # +32 = sort_mode (dword), +36 = sort_desc (dword)
    # +40 = scratch ptr
    # +48 = diff_mask
    # +56 = parity (qword)
    mov [rsp + 2048 + 0], rdi
    mov [rsp + 2048 + 8], rsi
    mov [rsp + 2048 + 16], rdx
    mov [rsp + 2048 + 24], rcx
    mov [rsp + 2048 + 32], r8d
    mov [rsp + 2048 + 36], r9d

    lea rdi, [rsi * 4]
    call mem_alloc
    test rax, rax
    jz .Lrs_fallback_intro
    mov [rsp + 2048 + 40], rax

    # Pass 0: compute diff_mask over keys to skip constant byte lanes
    mov rbx, [rsp + 2048 + 0]     # arr
    mov r12, [rsp + 2048 + 8]     # len
    mov r13, [rsp + 2048 + 16]    # entries
    mov r14d, [rsp + 2048 + 32]   # mode
    mov r15d, [rsp + 2048 + 36]   # desc

    mov edi, [rbx]
    mov rsi, r13
    mov edx, r14d
    mov ecx, r15d
    call extract_radix_key
    mov rbp, rax                  # first_key
    xor r10d, r10d                # diff_mask = 0
    mov r11, 1
.Lrs_diff_loop:
    cmp r11, r12
    jae .Lrs_diff_done
    mov eax, [rbx + r11 * 4]
    shl rax, 5
    cmp r14d, SORT_MTIME
    je .Lrs_d_mtime
    mov rax, [r13 + rax + FileEntry.size]
    jmp .Lrs_d_norm
.Lrs_d_mtime:
    mov rax, [r13 + rax + FileEntry.mtime]
.Lrs_d_norm:
    mov r8, 0x8000000000000000
    xor rax, r8
    test r15d, r15d
    jz .Lrs_d_xor
    not rax
.Lrs_d_xor:
    xor rax, rbp
    or r10, rax
    inc r11
    jmp .Lrs_diff_loop

.Lrs_diff_done:
    mov [rsp + 2048 + 48], r10
    mov rbp, [rsp + 2048 + 40]    # dst = scratch
    # rbx = src (starts at arr)
    mov qword ptr [rsp + 2048 + 56], 0
    xor ecx, ecx                  # bit shift = 0, 8, ..., 56

.Lrs_byte_pass:
    cmp ecx, 64
    jae .Lrs_passes_done
    mov rax, [rsp + 2048 + 48]
    shr rax, cl
    test al, 0xff
    jz .Lrs_next_byte

    # Zero histogram [rsp .. rsp + 2047]
    push rcx
    xor eax, eax
    mov ecx, 256
    mov rdi, rsp
    add rdi, 8
    rep stosq
    pop rcx

    # Count occurrences in src
    xor r11d, r11d
.Lrs_hist_loop:
    cmp r11, r12
    jae .Lrs_prefix
    mov eax, [rbx + r11 * 4]
    shl rax, 5
    cmp r14d, SORT_MTIME
    je .Lrs_h_mtime
    mov rax, [r13 + rax + FileEntry.size]
    jmp .Lrs_h_norm
.Lrs_h_mtime:
    mov rax, [r13 + rax + FileEntry.mtime]
.Lrs_h_norm:
    mov r8, 0x8000000000000000
    xor rax, r8
    test r15d, r15d
    jz .Lrs_h_inc
    not rax
.Lrs_h_inc:
    shr rax, cl
    movzx eax, al
    inc qword ptr [rsp + rax * 8]
    inc r11
    jmp .Lrs_hist_loop

.Lrs_prefix:
    xor r8d, r8d                  # running prefix sum
    xor r9d, r9d
.Lrs_pfx_loop:
    mov rax, [rsp + r9 * 8]
    mov [rsp + r9 * 8], r8
    add r8, rax
    inc r9d
    cmp r9d, 256
    jb .Lrs_pfx_loop

    # Scatter src -> dst
    xor r11d, r11d
.Lrs_scat_loop:
    cmp r11, r12
    jae .Lrs_pass_swap
    mov r9d, [rbx + r11 * 4]
    mov eax, r9d
    shl rax, 5
    cmp r14d, SORT_MTIME
    je .Lrs_s_mtime
    mov rax, [r13 + rax + FileEntry.size]
    jmp .Lrs_s_norm
.Lrs_s_mtime:
    mov rax, [r13 + rax + FileEntry.mtime]
.Lrs_s_norm:
    mov r8, 0x8000000000000000
    xor rax, r8
    test r15d, r15d
    jz .Lrs_s_put
    not rax
.Lrs_s_put:
    shr rax, cl
    movzx eax, al
    mov rdx, [rsp + rax * 8]
    mov [rbp + rdx * 4], r9d
    inc qword ptr [rsp + rax * 8]
    inc r11
    jmp .Lrs_scat_loop

.Lrs_pass_swap:
    xchg rbx, rbp
    xor qword ptr [rsp + 2048 + 56], 1

.Lrs_next_byte:
    add ecx, 8
    jmp .Lrs_byte_pass

.Lrs_passes_done:
    # Copy back to original arr if final output landed in scratch
    cmp qword ptr [rsp + 2048 + 56], 0
    je .Lrs_free_scratch
    mov rdi, [rsp + 2048 + 0]     # arr
    mov rsi, rbx                  # scratch
    mov rcx, r12
    rep movsd

.Lrs_free_scratch:
    mov rdi, [rsp + 2048 + 40]
    call mem_free

    # Tie-break runs with equal size/mtime keys using SORT_NAME Introsort
    mov rbx, [rsp + 2048 + 0]     # arr
    xor r12d, r12d                # i = 0
    mov r13, [rsp + 2048 + 8]     # len
.Lrs_tie_loop:
    cmp r12, r13
    jae .Lrs_exit
    mov edi, [rbx + r12 * 4]
    mov rsi, [rsp + 2048 + 16]
    mov edx, [rsp + 2048 + 32]
    mov ecx, [rsp + 2048 + 36]
    call extract_radix_key
    mov rbp, rax                  # run key
    lea r14, [r12 + 1]            # j = i + 1
.Lrs_tie_scan:
    cmp r14, r13
    jae .Lrs_tie_run
    mov edi, [rbx + r14 * 4]
    mov rsi, [rsp + 2048 + 16]
    mov edx, [rsp + 2048 + 32]
    mov ecx, [rsp + 2048 + 36]
    call extract_radix_key
    cmp rax, rbp
    jne .Lrs_tie_run
    inc r14
    jmp .Lrs_tie_scan

.Lrs_tie_run:
    mov rax, r14
    sub rax, r12
    cmp rax, 2
    jb .Lrs_tie_next
    lea rdi, [rbx + r12 * 4]
    mov rsi, rax
    mov rdx, [rsp + 2048 + 16]
    mov rcx, [rsp + 2048 + 24]
    mov r8d, SORT_NAME
    xor r9d, r9d
    call introsort_u32
.Lrs_tie_next:
    mov r12, r14
    jmp .Lrs_tie_loop

.Lrs_fallback_intro:
    mov rdi, [rsp + 2048 + 0]
    mov rsi, [rsp + 2048 + 8]
    mov rdx, [rsp + 2048 + 16]
    mov rcx, [rsp + 2048 + 24]
    mov r8d, [rsp + 2048 + 32]
    mov r9d, [rsp + 2048 + 36]
    call introsort_u32

.Lrs_exit:
    add rsp, 2048 + 72
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

# ==============================================================================
# Helper: uint64_t make_prefix_key(uint32_t idx, const FileEntry *entries,
#                                  const char *name_pool, uint32_t mode, uint32_t desc)
# Order-preserving 64-bit key consistent with cmp_indices:
#   SORT_NAME: first 8 ASCII-folded bytes, big-endian, NUL padded.
#   SORT_EXT : bit63 = has extension, bits 55..0 = first 7 folded bytes of the extension.
# Different keys => cmp_indices agrees with key order; equal keys are tie-broken later.
# ==============================================================================
make_prefix_key:
    mov eax, edi
    shl rax, 5
    add rsi, rax                      # entry
    mov eax, [rsi + FileEntry.name_off]
    add rdx, rax                      # name
    xor r10d, r10d                    # key
    mov r11d, 8                       # bytes to take
    cmp ecx, SORT_EXT
    jne .Lmpk_take
    movzx eax, byte ptr [rsi + FileEntry.ext_offset]
    test eax, eax
    jz .Lmpk_desc                     # no extension: key 0
    lea rdx, [rdx + rax + 1]
    mov r10d, 1                       # has-ext flag, shifted into bit 63 below
    mov r11d, 7
.Lmpk_take:
    xor ecx, ecx                      # taken
.Lmpk_loop:
    cmp ecx, r11d
    jae .Lmpk_desc
    movzx eax, byte ptr [rdx]
    test eax, eax
    jz .Lmpk_pad
    cmp eax, 'A'
    jb .Lmpk_put
    cmp eax, 'Z'
    ja .Lmpk_put
    add eax, 32
.Lmpk_put:
    shl r10, 8
    or r10, rax
    inc rdx
    inc ecx
    jmp .Lmpk_loop
.Lmpk_pad:
    shl r10, 8
    inc ecx
    cmp ecx, r11d
    jb .Lmpk_pad
.Lmpk_desc:
    mov rax, r10
    test r8d, r8d
    jz .Lmpk_ret
    not rax
.Lmpk_ret:
    ret
