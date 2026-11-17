# Frozen reference oracle: the hand-written asm that src/fs/dir_model_select.c replaced (tests/test_c_dir_model_stat.py diffs against it)
# src/fs/dir_model.s - Compact 32B DirModel, zero-stat d_type scan, streaming & lazy stat — dir model select (split from dir_model.s)

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"
.equ BATCH_STAT_CHUNK, 1024
.equ CHUNK_ENTRIES_OFF, 0
.equ CHUNK_NAMES_OFF,   (BATCH_STAT_CHUNK * 8)
.equ CHUNK_STATS_OFF,   (CHUNK_NAMES_OFF + BATCH_STAT_CHUNK * 8)
.equ CHUNK_ERRS_OFF,    (CHUNK_STATS_OFF + BATCH_STAT_CHUNK * FileStat._size)
.equ CHUNK_BUF_SIZE,    (CHUNK_ERRS_OFF + BATCH_STAT_CHUNK * 4)
.extern DirModel_sort
.extern Object_dtor
.extern mem_alloc
.extern mem_realloc
.extern mem_free
.extern str_copy
.extern str_cmp
.extern str_contains_ci
.extern str_starts_with
.extern utf8_display_width
.extern os_statat
.extern os_batch_stat
.extern os_dir_read
.extern os_dir_next_ex

.section .text
.global DirModel_ensure_all_stats
.global DirModel_toggle_select
.global DirModel_select_all_toggle
.global DirModel_count_selected
.global DirModel_find_by_name

# ==============================================================================
# void DirModel_ensure_all_stats(DirModel *this)
# Batch-stats all pending entries via os_batch_stat (io_uring/fallback PAL)
# before SORT_SIZE or SORT_MTIME executes.
# ==============================================================================
DirModel_ensure_all_stats:
    cmp dword ptr [rdi + DirModel.stats_complete], 0
    jne .Leas_ret
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 24               # [rsp+0]=dirfd(d), [rsp+4]=own_fd(d), [rsp+8]=chunk_n
    mov rbx, rdi

    mov rdi, CHUNK_BUF_SIZE
    call mem_alloc
    test rax, rax
    jz .Leas_fail
    mov r12, rax              # chunk_buf

    xor ebp, ebp
    mov eax, [rbx + DirModel.load_dirfd]
    test eax, eax
    jns .Leas_got_fd
    mov edi, AT_FDCWD
    lea rsi, [rbx + DirModel.path]
    mov edx, O_RDONLY | O_DIRECTORY | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
    js .Leas_free_buf
    mov ebp, 1
.Leas_got_fd:
    mov [rsp + 0], eax
    mov [rsp + 4], ebp

    mov r13d, [rbx + DirModel.has_dotdot]
    mov r14, [rbx + DirModel.raw_count]

.Leas_outer:
    cmp r13, r14
    jae .Leas_finish
    xor r15d, r15d            # chunk_n = 0
    mov r8, [rbx + DirModel.entries]
    mov r9, [rbx + DirModel.name_pool]

.Leas_collect:
    cmp r13, r14
    jae .Leas_flush
    cmp r15, BATCH_STAT_CHUNK
    jae .Leas_flush
    mov rax, r13
    shl rax, 5
    lea r10, [r8 + rax]
    test dword ptr [r10 + FileEntry.flags], FE_STAT_READY
    jnz .Leas_c_next

    mov [r12 + CHUNK_ENTRIES_OFF + r15 * 8], r10
    mov eax, [r10 + FileEntry.name_off]
    add rax, r9
    mov [r12 + CHUNK_NAMES_OFF + r15 * 8], rax
    inc r15
.Leas_c_next:
    inc r13
    jmp .Leas_collect

.Leas_flush:
    test r15, r15
    jz .Leas_outer
    mov [rsp + 8], r15

    mov edi, [rsp + 0]
    lea rsi, [r12 + CHUNK_NAMES_OFF]
    lea rdx, [r12 + CHUNK_STATS_OFF]
    lea rcx, [r12 + CHUNK_ERRS_OFF]
    mov r8, r15
    xor r9d, r9d
    call os_batch_stat

    xor ebp, ebp
    mov r15, [rsp + 8]
.Leas_apply:
    cmp rbp, r15
    jae .Leas_links
    mov rsi, [r12 + CHUNK_ENTRIES_OFF + rbp * 8]
    cmp dword ptr [r12 + CHUNK_ERRS_OFF + rbp * 4], 0
    jne .Leas_err_item
    mov rdi, rbx
    imul rdx, rbp, FileStat._size
    lea rdx, [r12 + CHUNK_STATS_OFF + rdx]
    mov ecx, -2                       # defer symlink targets to one batched pass
    call apply_stat_to_entry
    jmp .Leas_a_next
.Leas_err_item:
    or dword ptr [rsi + FileEntry.flags], FE_STAT_READY
.Leas_a_next:
    inc rbp
    jmp .Leas_apply

.Leas_links:
    # Second pass: compact this chunk's symlinks in place and resolve all targets with
    # one follow=1 batch (io_uring) instead of one synchronous stat per link.
    xor ebp, ebp                      # read index
    xor r15d, r15d                    # write index
    mov rcx, [rsp + 8]
.Leas_lk_scan:
    cmp rbp, rcx
    jae .Leas_lk_go
    cmp dword ptr [r12 + CHUNK_ERRS_OFF + rbp * 4], 0
    jne .Leas_lk_next
    imul rax, rbp, FileStat._size
    mov eax, [r12 + CHUNK_STATS_OFF + rax + FileStat.mode]
    and eax, S_IFMT
    cmp eax, S_IFLNK
    jne .Leas_lk_next
    mov rax, [r12 + CHUNK_ENTRIES_OFF + rbp * 8]
    mov [r12 + CHUNK_ENTRIES_OFF + r15 * 8], rax
    mov rax, [r12 + CHUNK_NAMES_OFF + rbp * 8]
    mov [r12 + CHUNK_NAMES_OFF + r15 * 8], rax
    inc r15
.Leas_lk_next:
    inc rbp
    jmp .Leas_lk_scan
.Leas_lk_go:
    test r15, r15
    jz .Leas_outer
    mov [rsp + 16], r15
    mov edi, [rsp + 0]
    lea rsi, [r12 + CHUNK_NAMES_OFF]
    lea rdx, [r12 + CHUNK_STATS_OFF]
    lea rcx, [r12 + CHUNK_ERRS_OFF]
    mov r8, r15
    mov r9d, 1                        # follow
    call os_batch_stat
    xor ebp, ebp
.Leas_lk_apply:
    cmp rbp, [rsp + 16]
    jae .Leas_outer
    cmp dword ptr [r12 + CHUNK_ERRS_OFF + rbp * 4], 0
    jne .Leas_lk_anext
    imul rax, rbp, FileStat._size
    mov eax, [r12 + CHUNK_STATS_OFF + rax + FileStat.mode]
    and eax, S_IFMT
    cmp eax, S_IFDIR
    jne .Leas_lk_anext
    mov rdi, rbx
    mov rsi, [r12 + CHUNK_ENTRIES_OFF + rbp * 8]
    call mark_link_dir
.Leas_lk_anext:
    inc rbp
    jmp .Leas_lk_apply

.Leas_finish:
    mov dword ptr [rbx + DirModel.stats_complete], 1
    cmp dword ptr [rsp + 4], 0
    je .Leas_free_buf
    mov edi, [rsp + 0]
    OS_CLOSE
.Leas_free_buf:
    mov rdi, r12
    call mem_free
.Leas_fail:
    add rsp, 24
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
.Leas_ret:
    ret

# ==============================================================================
# void DirModel_toggle_select(DirModel *this, ssize_t idx)
# ==============================================================================
DirModel_toggle_select:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    call DirModel_get_entry
    test rax, rax
    jz .Ldts_ret
    test dword ptr [rax + FileEntry.flags], FE_IS_PARENT
    jnz .Ldts_ret
    mov r12, rax
    mov rdi, rbx
    mov rsi, r12
    call DirModel_ensure_entry_stat
    xor dword ptr [r12 + FileEntry.flags], FE_SELECTED
.Ldts_ret:
    add rsp, 8
    pop r12
    pop rbx
    ret

# ==============================================================================
# void DirModel_select_all_toggle(DirModel *this)
# ==============================================================================
DirModel_select_all_toggle:
    mov rcx, [rdi + DirModel.count]
    mov rdx, [rdi + DirModel.entries]
    mov r11, [rdi + DirModel.order]
    xor r8d, r8d              # any_selected = 0
    xor r9d, r9d              # i = 0
.Lsa_scan:
    cmp r9, rcx
    jae .Lsa_apply
    mov eax, [r11 + r9 * 4]
    shl rax, 5
    mov r10d, [rdx + rax + FileEntry.flags]
    test r10d, FE_IS_PARENT
    jnz .Lsa_next1
    test r10d, FE_SELECTED
    jz .Lsa_next1
    mov r8d, 1
    jmp .Lsa_apply
.Lsa_next1:
    inc r9
    jmp .Lsa_scan

.Lsa_apply:
    xor r9d, r9d
.Lsa_loop:
    cmp r9, rcx
    jae .Lsa_done
    mov eax, [r11 + r9 * 4]
    shl rax, 5
    lea r10, [rdx + rax]
    test dword ptr [r10 + FileEntry.flags], FE_IS_PARENT
    jnz .Lsa_next2
    test r8d, r8d
    jnz .Lsa_clear
    or dword ptr [r10 + FileEntry.flags], FE_SELECTED
    jmp .Lsa_next2
.Lsa_clear:
    and dword ptr [r10 + FileEntry.flags], ~FE_SELECTED
.Lsa_next2:
    inc r9
    jmp .Lsa_loop
.Lsa_done:
    ret

# ==============================================================================
# size_t DirModel_count_selected(DirModel *this, int64_t *out_bytes)
# ==============================================================================
DirModel_count_selected:
    mov rcx, [rdi + DirModel.count]
    mov rdx, [rdi + DirModel.entries]
    mov r11, [rdi + DirModel.order]
    xor eax, eax
    xor r8d, r8d
    xor r9d, r9d
.Lcs_loop:
    cmp r9, rcx
    jae .Lcs_done
    mov r10d, [r11 + r9 * 4]
    shl r10, 5
    lea r10, [rdx + r10]
    test dword ptr [r10 + FileEntry.flags], FE_SELECTED
    jz .Lcs_next
    inc rax
    add r8, [r10 + FileEntry.size]
.Lcs_next:
    inc r9
    jmp .Lcs_loop
.Lcs_done:
    test rsi, rsi
    jz .Lcs_ret
    mov [rsi], r8
.Lcs_ret:
    ret

# ==============================================================================
# ssize_t DirModel_find_by_name(DirModel *this, const char *name)
# Searches visible order[] entries matching name; returns view index or -1.
# ==============================================================================
DirModel_find_by_name:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    mov r12, rsi
    xor r13d, r13d
    mov r14, [rbx + DirModel.count]
    mov r15, [rbx + DirModel.name_pool]

.Ldfbn_loop:
    cmp r13, r14
    jae .Ldfbn_nf
    mov rax, [rbx + DirModel.order]
    mov eax, [rax + r13 * 4]
    shl rax, 5
    add rax, [rbx + DirModel.entries]
    mov edi, [rax + FileEntry.name_off]
    add rdi, r15
    mov rsi, r12
    call str_cmp
    test eax, eax
    je .Ldfbn_found
    inc r13
    jmp .Ldfbn_loop

.Ldfbn_found:
    mov rax, r13
    jmp .Ldfbn_ret
.Ldfbn_nf:
    mov rax, -1
.Ldfbn_ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
