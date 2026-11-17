# Frozen reference oracle: the hand-written asm that src/fs/dir_sort.c + dir_sort_radix.c replaced (tests/test_c_dir_sort.py diffs against it)
# src/fs/dir_sort.s - Modular 4-byte index Introsort & byte-skipping LSD Radix Sort

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
.global extract_radix_key
.global cmp_indices
.global insertion_sort_u32
.global heapsort_u32

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
