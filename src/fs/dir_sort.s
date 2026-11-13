# src/fs/dir_sort.s - Modular 4-byte index Introsort & byte-skipping LSD Radix Sort
.intel_syntax noprefix

.include "pal.inc"
.include "classes.inc"

.equ RADIX_MIN_N,     64
.equ INSERTION_MIN_N, 16
.equ PREFIX_MIN_N,    512       # prefix-key radix for SORT_NAME / SORT_EXT from this size

.section .text
.global DirModel_sort

.extern DirModel_ensure_all_stats
.extern str_casecmp
.extern str_cmp
.extern mem_alloc
.extern mem_free

# ==============================================================================
# Helper: uint64_t extract_radix_key(uint32_t idx, const FileEntry *entries,
#                                    uint32_t sort_mode, uint32_t sort_desc)
# Maps signed 64-bit size/mtime to monotonic unsigned key, inverting if desc.
# ==============================================================================
extract_radix_key:
    mov eax, edi
    shl rax, 5
    cmp edx, SORT_MTIME
    je .Lerk_mtime
    mov rax, [rsi + rax + FileEntry.size]
    jmp .Lerk_norm
.Lerk_mtime:
    mov rax, [rsi + rax + FileEntry.mtime]
.Lerk_norm:
    mov r8, 0x8000000000000000
    xor rax, r8
    test ecx, ecx
    jz .Lerk_done
    not rax
.Lerk_done:
    ret

# ==============================================================================
# Helper: int cmp_indices(uint32_t idx_a, uint32_t idx_b,
#                         const FileEntry *entries, const char *name_pool,
#                         uint32_t sort_mode, uint32_t sort_desc)
# Compares two raw FileEntry indices inside the active sort partition.
# ==============================================================================
cmp_indices:
    cmp edi, esi
    jne .Lci_diff
    xor eax, eax
    ret
.Lci_diff:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov eax, edi
    shl rax, 5
    lea r12, [rdx + rax]      # entry_a
    mov eax, esi
    shl rax, 5
    lea r13, [rdx + rax]      # entry_b
    mov r14, rcx              # name_pool
    mov ebx, r8d              # sort_mode
    mov r15d, r9d             # sort_desc

    cmp ebx, SORT_SIZE
    je .Lci_size
    cmp ebx, SORT_MTIME
    je .Lci_mtime
    cmp ebx, SORT_EXT
    je .Lci_ext
    jmp .Lci_name

.Lci_size:
    mov rax, [r12 + FileEntry.size]
    mov rcx, [r13 + FileEntry.size]
    cmp rax, rcx
    je .Lci_tie_name_asc
    mov eax, -1
    mov ecx, 1
    cmovg eax, ecx
    jmp .Lci_apply_desc

.Lci_mtime:
    mov rax, [r12 + FileEntry.mtime]
    mov rcx, [r13 + FileEntry.mtime]
    cmp rax, rcx
    je .Lci_tie_name_asc
    mov eax, -1
    mov ecx, 1
    cmovg eax, ecx
    jmp .Lci_apply_desc

.Lci_ext:
    movzx eax, byte ptr [r12 + FileEntry.ext_offset]
    movzx ecx, byte ptr [r13 + FileEntry.ext_offset]
    test eax, eax
    jnz .Lci_ext_a_ok
    test ecx, ecx
    jz .Lci_tie_name_asc
    mov eax, -1
    jmp .Lci_apply_desc
.Lci_ext_a_ok:
    test ecx, ecx
    jnz .Lci_ext_both
    mov eax, 1
    jmp .Lci_apply_desc
.Lci_ext_both:
    mov edi, [r12 + FileEntry.name_off]
    add rdi, r14
    lea rdi, [rdi + rax + 1]
    mov esi, [r13 + FileEntry.name_off]
    add rsi, r14
    lea rsi, [rsi + rcx + 1]
    call str_casecmp
    test eax, eax
    jnz .Lci_apply_desc

.Lci_tie_name_asc:
    # Equal primary keys always tie-break ascending by filename for determinism
    xor r15d, r15d

.Lci_name:
    mov edi, [r12 + FileEntry.name_off]
    add rdi, r14
    mov esi, [r13 + FileEntry.name_off]
    add rsi, r14
    call str_casecmp
    test eax, eax
    jnz .Lci_apply_desc
    mov edi, [r12 + FileEntry.name_off]
    add rdi, r14
    mov esi, [r13 + FileEntry.name_off]
    add rsi, r14
    call str_cmp

.Lci_apply_desc:
    test r15d, r15d
    jz .Lci_ret
    neg eax
.Lci_ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# ==============================================================================
# Insertion Sort on uint32_t arr[0..len-1]
# void insertion_sort_u32(uint32_t *arr, size_t len,
#                         const FileEntry *entries, const char *name_pool,
#                         uint32_t sort_mode, uint32_t sort_desc)
# ==============================================================================
insertion_sort_u32:
    cmp rsi, 2
    jb .Lins_ret
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 24               # alignment (6 pushes=48 -> +24 = 72; call=8 -> 80 = 0 mod 16)
    mov [rsp + 0], r8d        # sort_mode
    mov [rsp + 4], r9d        # sort_desc
    mov rbx, rdi              # arr
    mov rbp, rsi              # len
    mov r12, rdx              # entries
    mov r13, rcx              # name_pool

    mov r14, 1                # i = 1
.Lins_outer:
    cmp r14, rbp
    jae .Lins_done
    mov r15d, [rbx + r14 * 4] # key_idx = arr[i]
    mov [rsp + 8], r14        # save i
    lea r14, [r14 - 1]        # j = i - 1 (as signed index)
.Lins_inner:
    cmp r14, 0
    jl .Lins_place
    mov edi, [rbx + r14 * 4]
    mov esi, r15d
    mov rdx, r12
    mov rcx, r13
    mov r8d, [rsp + 0]
    mov r9d, [rsp + 4]
    call cmp_indices
    cmp eax, 0
    jle .Lins_place
    mov eax, [rbx + r14 * 4]
    mov [rbx + r14 * 4 + 4], eax
    dec r14
    jmp .Lins_inner
.Lins_place:
    mov [rbx + r14 * 4 + 4], r15d
    mov r14, [rsp + 8]
    inc r14
    jmp .Lins_outer

.Lins_done:
    add rsp, 24
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
.Lins_ret:
    ret

# ==============================================================================
# Heapsort fallback (O(N log N) worst-case depth guard for Introsort)
# void sift_down_u32(uint32_t *arr, size_t root, size_t end_n, ...ctx in struct)
# Context struct on caller stack: [0]=entries, [8]=name_pool, [16]=mode, [20]=desc
# ==============================================================================
sift_down_u32:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8                # align stack (6 pushes + 8 + 8 = 64 = 0 mod 16)
    mov rbx, rdi              # arr
    mov r12, rsi              # root
    mov r13, rdx              # n
    mov r14, rcx              # SortCtx*

.Lsd_loop:
    lea rbp, [r12 + r12 + 1]  # child = 2*root + 1
    cmp rbp, r13
    jae .Lsd_done
    mov r15, r12              # swap_idx = root

    mov edi, [rbx + r15 * 4]
    mov esi, [rbx + rbp * 4]
    mov rdx, [r14 + 0]
    mov rcx, [r14 + 8]
    mov r8d, [r14 + 16]
    mov r9d, [r14 + 20]
    call cmp_indices
    cmp eax, 0
    jge .Lsd_chk_right
    mov r15, rbp

.Lsd_chk_right:
    lea rax, [rbp + 1]
    cmp rax, r13
    jae .Lsd_maybe_swap
    mov [rsp + 0], rax
    mov edi, [rbx + r15 * 4]
    mov esi, [rbx + rax * 4]
    mov rdx, [r14 + 0]
    mov rcx, [r14 + 8]
    mov r8d, [r14 + 16]
    mov r9d, [r14 + 20]
    call cmp_indices
    cmp eax, 0
    jge .Lsd_maybe_swap
    mov r15, [rsp + 0]

.Lsd_maybe_swap:
    cmp r15, r12
    je .Lsd_done
    mov eax, [rbx + r12 * 4]
    mov edx, [rbx + r15 * 4]
    mov [rbx + r12 * 4], edx
    mov [rbx + r15 * 4], eax
    mov r12, r15
    jmp .Lsd_loop

.Lsd_done:
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

heapsort_u32:
    cmp rsi, 2
    jb .Lhs_ret
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 24               # SortCtx + alignment (4 pushes=32 + 24 + 8 = 64)
    mov [rsp + 0], rdx        # entries
    mov [rsp + 8], rcx        # name_pool
    mov [rsp + 16], r8d       # mode
    mov [rsp + 20], r9d       # desc
    mov rbx, rdi              # arr
    mov r12, rsi              # n

    mov r13, r12
    shr r13, 1
    dec r13                   # i = n/2 - 1
.Lhs_heapify:
    cmp r13, 0
    jl .Lhs_pop
    mov rdi, rbx
    mov rsi, r13
    mov rdx, r12
    mov rcx, rsp
    call sift_down_u32
    dec r13
    jmp .Lhs_heapify

.Lhs_pop:
    mov r13, r12
    dec r13                   # end = n - 1
.Lhs_pop_loop:
    cmp r13, 0
    jle .Lhs_done
    mov eax, [rbx]
    mov edx, [rbx + r13 * 4]
    mov [rbx], edx
    mov [rbx + r13 * 4], eax
    mov rdi, rbx
    xor esi, esi
    mov rdx, r13
    mov rcx, rsp
    call sift_down_u32
    dec r13
    jmp .Lhs_pop_loop

.Lhs_done:
    add rsp, 24
    pop r14
    pop r13
    pop r12
    pop rbx
.Lhs_ret:
    ret

# ==============================================================================
# Introsort Loop: median-of-3 + Hoare partition + heapsort guard + insertion
# void introsort_loop(uint32_t *arr, size_t len, size_t depth, const SortCtx *ctx)
# ==============================================================================
introsort_loop:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 24               # align: 6 pushes=48 + 24 + 8 = 80 = 0 mod 16
    mov rbx, rdi              # arr
    mov r12, rsi              # len
    mov r13, rdx              # depth
    mov r14, rcx              # SortCtx*

.Lisl_while:
    cmp r12, INSERTION_MIN_N
    jbe .Lisl_small
    test r13, r13
    jz .Lisl_heap
    dec r13

    # Median-of-3 across 0, mid, len-1 ensuring arr[0] <= arr[mid] <= arr[len-1]
    mov r15, r12
    shr r15, 1                # mid
    lea rbp, [r12 - 1]        # hi = len - 1

    # if arr[0] > arr[mid]: swap(0, mid)
    mov edi, [rbx]
    mov esi, [rbx + r15 * 4]
    mov rdx, [r14 + 0]
    mov rcx, [r14 + 8]
    mov r8d, [r14 + 16]
    mov r9d, [r14 + 20]
    call cmp_indices
    cmp eax, 0
    jle .Lisl_m1
    mov eax, [rbx]
    mov edx, [rbx + r15 * 4]
    mov [rbx], edx
    mov [rbx + r15 * 4], eax
.Lisl_m1:
    # if arr[0] > arr[hi]: swap(0, hi)
    mov edi, [rbx]
    mov esi, [rbx + rbp * 4]
    mov rdx, [r14 + 0]
    mov rcx, [r14 + 8]
    mov r8d, [r14 + 16]
    mov r9d, [r14 + 20]
    call cmp_indices
    cmp eax, 0
    jle .Lisl_m2
    mov eax, [rbx]
    mov edx, [rbx + rbp * 4]
    mov [rbx], edx
    mov [rbx + rbp * 4], eax
.Lisl_m2:
    # if arr[mid] > arr[hi]: swap(mid, hi)
    mov edi, [rbx + r15 * 4]
    mov esi, [rbx + rbp * 4]
    mov rdx, [r14 + 0]
    mov rcx, [r14 + 8]
    mov r8d, [r14 + 16]
    mov r9d, [r14 + 20]
    call cmp_indices
    cmp eax, 0
    jle .Lisl_m3
    mov eax, [rbx + r15 * 4]
    mov edx, [rbx + rbp * 4]
    mov [rbx + r15 * 4], edx
    mov [rbx + rbp * 4], eax
.Lisl_m3:
    # Hoare partition using pivot_idx = arr[mid] (guaranteed arr[0] <= pivot <= arr[hi])
    mov eax, [rbx + r15 * 4]
    mov [rsp + 0], eax        # pivot_idx (dword)
    xor r15d, r15d
    dec r15                   # i = -1
    mov rbp, r12              # j = len

.Lisl_part:
.Lisl_inc_i:
    inc r15
    mov edi, [rbx + r15 * 4]
    mov esi, [rsp + 0]
    mov rdx, [r14 + 0]
    mov rcx, [r14 + 8]
    mov r8d, [r14 + 16]
    mov r9d, [r14 + 20]
    call cmp_indices
    cmp eax, 0
    jl .Lisl_inc_i

.Lisl_dec_j:
    dec rbp
    mov edi, [rsp + 0]
    mov esi, [rbx + rbp * 4]
    mov rdx, [r14 + 0]
    mov rcx, [r14 + 8]
    mov r8d, [r14 + 16]
    mov r9d, [r14 + 20]
    call cmp_indices
    cmp eax, 0
    jl .Lisl_dec_j

    cmp r15, rbp
    jge .Lisl_part_done
    mov eax, [rbx + r15 * 4]
    mov edx, [rbx + rbp * 4]
    mov [rbx + r15 * 4], edx
    mov [rbx + rbp * 4], eax
    jmp .Lisl_part

.Lisl_part_done:
    # Left partition [0 .. j], length = j + 1
    # Right partition [j+1 .. len-1], length = len - (j + 1)
    lea rax, [rbp + 1]        # left_len
    mov rdx, r12
    sub rdx, rax              # right_len
    mov [rsp + 8], rax        # save left_len
    mov [rsp + 16], rdx       # save right_len

    cmp rax, rdx
    jb .Lisl_recurse_left

    # Right side is smaller -> recurse right, tail-loop left
    lea rdi, [rbx + rax * 4]
    mov rsi, rdx
    mov rdx, r13
    mov rcx, r14
    call introsort_loop
    mov r12, [rsp + 8]
    jmp .Lisl_while

.Lisl_recurse_left:
    mov rdi, rbx
    mov rsi, rax
    mov rdx, r13
    mov rcx, r14
    call introsort_loop
    mov rax, [rsp + 8]
    lea rbx, [rbx + rax * 4]
    mov r12, [rsp + 16]
    jmp .Lisl_while

.Lisl_heap:
    mov rdi, rbx
    mov rsi, r12
    mov rdx, [r14 + 0]
    mov rcx, [r14 + 8]
    mov r8d, [r14 + 16]
    mov r9d, [r14 + 20]
    call heapsort_u32
    jmp .Lisl_exit

.Lisl_small:
    mov rdi, rbx
    mov rsi, r12
    mov rdx, [r14 + 0]
    mov rcx, [r14 + 8]
    mov r8d, [r14 + 16]
    mov r9d, [r14 + 20]
    call insertion_sort_u32

.Lisl_exit:
    add rsp, 24
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

# ==============================================================================
# Entry for Introsort on slice
# void introsort_u32(uint32_t *arr, size_t len, const FileEntry *entries,
#                    const char *name_pool, uint32_t mode, uint32_t desc)
# ==============================================================================
introsort_u32:
    cmp rsi, 2
    jb .Lis_ret
    sub rsp, 24               # SortCtx (stack becomes 0 mod 16 before call)
    mov [rsp + 0], rdx        # entries
    mov [rsp + 8], rcx        # name_pool
    mov [rsp + 16], r8d       # mode
    mov [rsp + 20], r9d       # desc
    bsr rax, rsi
    shl rax, 1                # depth = 2 * floor(log2(len))
    mov rdx, rax
    mov rcx, rsp
    call introsort_loop
    add rsp, 24
.Lis_ret:
    ret

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

# ==============================================================================
# Prefix-key LSD radix sort for SORT_NAME / SORT_EXT
# void prefix_sort_u32(uint32_t *arr, size_t len, const FileEntry *entries,
#                      const char *name_pool, uint32_t mode, uint32_t desc)
# Builds compact 16-byte {key, idx} records (one sequential pass touching name_pool),
# radix-sorts them by key with byte-lane skipping, then introsorts only equal-key runs.
# ==============================================================================
prefix_sort_u32:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 2048 + 72
    # Frame at [rsp + 2048]: +0 arr, +8 len, +16 entries, +24 pool, +32 mode, +36 desc,
    #                        +40 recs (2*len*16), +48 diff mask
    mov [rsp + 2048 + 0], rdi
    mov [rsp + 2048 + 8], rsi
    mov [rsp + 2048 + 16], rdx
    mov [rsp + 2048 + 24], rcx
    mov [rsp + 2048 + 32], r8d
    mov [rsp + 2048 + 36], r9d
    mov rdi, rsi
    shl rdi, 5                        # 2 record arrays of 16 B
    call mem_alloc
    test rax, rax
    jz .Lps_fallback
    mov [rsp + 2048 + 40], rax

    # Build records + diff mask
    mov rbx, rax                      # src recs
    mov r12, [rsp + 2048 + 8]         # len
    xor r13d, r13d                    # i
    xor r14d, r14d                    # diff mask
.Lps_build:
    cmp r13, r12
    jae .Lps_built
    mov rax, [rsp + 2048 + 0]
    mov edi, [rax + r13 * 4]
    mov r15d, edi
    mov rsi, [rsp + 2048 + 16]
    mov rdx, [rsp + 2048 + 24]
    mov ecx, [rsp + 2048 + 32]
    mov r8d, [rsp + 2048 + 36]
    call make_prefix_key
    mov rcx, r13
    shl rcx, 4
    mov [rbx + rcx], rax
    mov [rbx + rcx + 8], r15d
    xor rax, [rbx]                    # vs first key
    or r14, rax
    inc r13
    jmp .Lps_build
.Lps_built:
    mov [rsp + 2048 + 48], r14
    mov rbp, r12
    shl rbp, 4
    add rbp, rbx                      # dst recs
    xor ecx, ecx                      # shift
.Lps_pass:
    cmp ecx, 64
    jae .Lps_passes_done
    mov rax, [rsp + 2048 + 48]
    shr rax, cl
    test al, 0xff
    jz .Lps_next_byte

    push rcx
    xor eax, eax
    mov ecx, 256
    lea rdi, [rsp + 8]
    rep stosq
    pop rcx

    xor r11d, r11d
.Lps_hist:
    cmp r11, r12
    jae .Lps_prefix
    mov rax, r11
    shl rax, 4
    mov rax, [rbx + rax]
    shr rax, cl
    movzx eax, al
    inc qword ptr [rsp + rax * 8]
    inc r11
    jmp .Lps_hist
.Lps_prefix:
    xor r8d, r8d
    xor r9d, r9d
.Lps_pfx:
    mov rax, [rsp + r9 * 8]
    mov [rsp + r9 * 8], r8
    add r8, rax
    inc r9d
    cmp r9d, 256
    jb .Lps_pfx

    xor r11d, r11d
.Lps_scat:
    cmp r11, r12
    jae .Lps_swap
    mov r9, r11
    shl r9, 4
    mov r10, [rbx + r9]               # key
    mov r9d, [rbx + r9 + 8]           # idx
    mov rax, r10
    shr rax, cl
    movzx eax, al
    mov rdx, [rsp + rax * 8]
    inc qword ptr [rsp + rax * 8]
    shl rdx, 4
    mov [rbp + rdx], r10
    mov [rbp + rdx + 8], r9d
    inc r11
    jmp .Lps_scat
.Lps_swap:
    xchg rbx, rbp
.Lps_next_byte:
    add ecx, 8
    jmp .Lps_pass

.Lps_passes_done:
    # Write sorted indices back
    mov rdi, [rsp + 2048 + 0]
    xor r11d, r11d
.Lps_wb:
    cmp r11, r12
    jae .Lps_ties
    mov rax, r11
    shl rax, 4
    mov eax, [rbx + rax + 8]
    mov [rdi + r11 * 4], eax
    inc r11
    jmp .Lps_wb

    # Introsort only runs of equal prefix keys (full comparator)
.Lps_ties:
    xor r13d, r13d                    # i
.Lps_tie_loop:
    cmp r13, r12
    jae .Lps_free
    mov rax, r13
    shl rax, 4
    mov rbp, [rbx + rax]              # run key
    lea r14, [r13 + 1]
.Lps_tie_scan:
    cmp r14, r12
    jae .Lps_tie_run
    mov rax, r14
    shl rax, 4
    cmp [rbx + rax], rbp
    jne .Lps_tie_run
    inc r14
    jmp .Lps_tie_scan
.Lps_tie_run:
    mov rax, r14
    sub rax, r13
    cmp rax, 2
    jb .Lps_tie_next
    mov rdi, [rsp + 2048 + 0]
    lea rdi, [rdi + r13 * 4]
    mov rsi, rax
    mov rdx, [rsp + 2048 + 16]
    mov rcx, [rsp + 2048 + 24]
    mov r8d, [rsp + 2048 + 32]
    mov r9d, [rsp + 2048 + 36]
    call introsort_u32
.Lps_tie_next:
    mov r13, r14
    jmp .Lps_tie_loop

.Lps_free:
    mov rdi, [rsp + 2048 + 40]
    call mem_free
    jmp .Lps_exit

.Lps_fallback:
    mov rdi, [rsp + 2048 + 0]
    mov rsi, [rsp + 2048 + 8]
    mov rdx, [rsp + 2048 + 16]
    mov rcx, [rsp + 2048 + 24]
    mov r8d, [rsp + 2048 + 32]
    mov r9d, [rsp + 2048 + 36]
    call introsort_u32
.Lps_exit:
    add rsp, 2048 + 72
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

# ==============================================================================
# Helper: void sort_half(uint32_t *arr, size_t len, const DirModel *model)
# ==============================================================================
sort_half:
    cmp rsi, 2
    jb .Lsh_ret
    mov eax, [rdx + DirModel.sort_mode]
    mov r9d, [rdx + DirModel.sort_desc]
    mov rcx, [rdx + DirModel.name_pool]
    mov rdx, [rdx + DirModel.entries]
    mov r8d, eax
    cmp eax, SORT_SIZE
    je .Lsh_check_radix
    cmp eax, SORT_MTIME
    je .Lsh_check_radix
    cmp rsi, PREFIX_MIN_N
    jae prefix_sort_u32               # SORT_NAME / SORT_EXT
    jmp introsort_u32
.Lsh_check_radix:
    cmp rsi, RADIX_MIN_N
    jae .Lsh_radix
.Lsh_intro:
    jmp introsort_u32
.Lsh_radix:
    jmp radix_sort_u32
.Lsh_ret:
    ret

# ==============================================================================
# Public: void DirModel_sort(DirModel *this)
# Partitions order[has_dotdot..count-1] into [dirs][files] and sorts each half.
# ==============================================================================
DirModel_sort:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    sub rsp, 16               # align stack: 5 pushes=40 + 16 + 8 = 64 = 0 mod 16
    mov rbx, rdi

    mov eax, [rbx + DirModel.sort_mode]
    cmp eax, SORT_SIZE
    je .Ldms_need_stats
    cmp eax, SORT_MTIME
    jne .Ldms_stats_ok
.Ldms_need_stats:
    cmp dword ptr [rbx + DirModel.stats_complete], 0
    jne .Ldms_stats_ok
    mov rdi, rbx
    call DirModel_ensure_all_stats

.Ldms_stats_ok:
    mov r12, [rbx + DirModel.order]
    mov r13, [rbx + DirModel.entries]
    mov ecx, [rbx + DirModel.has_dotdot]
    mov rax, [rbx + DirModel.count]
    sub rax, rcx
    cmp rax, 2
    jb .Ldms_sorted_flag

    lea r12, [r12 + rcx * 4]  # slice start after ".."
    mov r14, rax              # total_n

    # Two-pointer O(N) partition: [dirs][files]
    xor r8d, r8d              # lo = 0
    lea r9, [r14 - 1]         # hi = total_n - 1
.Ldms_part_loop:
    cmp r8, r9
    jg .Ldms_part_done
.Ldms_adv_lo:
    cmp r8, r9
    jg .Ldms_part_done
    mov eax, [r12 + r8 * 4]
    shl rax, 5
    test dword ptr [r13 + rax + FileEntry.flags], FE_IS_DIR | FE_LINK_DIR
    jz .Ldms_adv_hi
    inc r8
    jmp .Ldms_adv_lo
.Ldms_adv_hi:
    cmp r8, r9
    jge .Ldms_part_done
    mov eax, [r12 + r9 * 4]
    shl rax, 5
    test dword ptr [r13 + rax + FileEntry.flags], FE_IS_DIR | FE_LINK_DIR
    jnz .Ldms_do_swap
    dec r9
    jmp .Ldms_adv_hi
.Ldms_do_swap:
    mov eax, [r12 + r8 * 4]
    mov edx, [r12 + r9 * 4]
    mov [r12 + r8 * 4], edx
    mov [r12 + r9 * 4], eax
    inc r8
    dec r9
    jmp .Ldms_part_loop

.Ldms_part_done:
    # r8 = dir_count inside sortable slice
    mov rbp, r8
    mov rdi, r12
    mov rsi, rbp
    mov rdx, rbx
    call sort_half

    lea rdi, [r12 + rbp * 4]
    mov rsi, r14
    sub rsi, rbp
    mov rdx, rbx
    call sort_half

.Ldms_sorted_flag:
    mov dword ptr [rbx + DirModel.is_unsorted], 0
    add rsp, 16
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret
