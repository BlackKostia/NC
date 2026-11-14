# src/fs/dir_sort.s - Modular 4-byte index Introsort & byte-skipping LSD Radix Sort — dir sort prefix (split from dir_sort.s)

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
.global DirModel_sort

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
    call DirModel_sort__ensure_all_stats
    call DirModel_sort__two_pointer_partition
    mov dword ptr [rbx + DirModel.is_unsorted], 0
    add rsp, 16
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

# DirModel_sort step: ensure_all_stats (runs on the caller's frame)
DirModel_sort__ensure_all_stats:
    lea rsp, [rsp - 8]
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
.LDirModel_sort__ensure_all_stats_ret:
    lea rsp, [rsp + 8]
    ret

# DirModel_sort step: Two pointer partition (runs on the caller's frame)
DirModel_sort__two_pointer_partition:
    lea rsp, [rsp - 8]
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
.LDirModel_sort__two_pointer_partition_ret:
    lea rsp, [rsp + 8]
    ret
