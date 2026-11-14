# src/fs/dir_sort.s - Modular 4-byte index Introsort & byte-skipping LSD Radix Sort — dir sort intro (split from dir_sort.s)

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
.global introsort_u32

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
