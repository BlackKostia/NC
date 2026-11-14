# src/fs/dir_model.s - Compact 32B DirModel, zero-stat d_type scan, streaming & lazy stat — dir model filter (split from dir_model.s)

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
.global DirModel_apply_filter
.global DirModel_chdir
.global DirModel_get_entry
.global mark_link_dir

# ==============================================================================
# void DirModel_apply_filter(DirModel *this)
# Instantaneously rebuilds order[] and visible dir/file counts from raw RAM pool.
# Sorts result unless model is in ls -f unsorted huge mode or still loading.
# ==============================================================================
DirModel_apply_filter:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8
    mov rbx, rdi
    call prepare_filter

    # Incremental narrowing: when the new filter extends the one that produced order[]
    # (same raw set, same hidden mode, finished load), re-filter order[] in place: the
    # result keeps its sorted order, so neither a full raw scan nor a re-sort is needed.
    cmp dword ptr [rbx + DirModel.flt_valid], 0
    je .Ldaf_full
    cmp dword ptr [rbx + DirModel.is_loading], 0
    jne .Ldaf_full
    mov rax, [rbx + DirModel.raw_count]
    cmp rax, [rbx + DirModel.flt_raw]
    jne .Ldaf_full
    mov eax, [rbx + DirModel.show_hidden]
    cmp eax, [rbx + DirModel.flt_hidden]
    jne .Ldaf_full
    lea rdi, [rbx + DirModel.filter]
    lea rsi, [rbx + DirModel.flt_applied]
    call str_starts_with
    test eax, eax
    jz .Ldaf_full

    mov dword ptr [rbx + DirModel.dir_count], 0
    mov dword ptr [rbx + DirModel.file_count], 0
    mov r12, [rbx + DirModel.count]
    xor r13d, r13d            # read index
    xor ebp, ebp              # write index
    mov r14, [rbx + DirModel.entries]
    mov r15, [rbx + DirModel.order]
.Ldaf_nar_loop:
    cmp r13, r12
    jae .Ldaf_nar_done
    mov eax, [r15 + r13 * 4]
    mov [rsp], eax
    shl rax, 5
    add rax, r14
    mov edx, [rax + FileEntry.flags]
    mov ecx, [rax + FileEntry.name_off]
    add rcx, [rbx + DirModel.name_pool]
    push rdx
    sub rsp, 8
    mov rdi, rbx
    call entry_passes_filter
    add rsp, 8
    pop rdx
    test eax, eax
    jz .Ldaf_nar_next
    mov eax, [rsp]
    mov [r15 + rbp * 4], eax
    inc rbp
    test edx, FE_IS_PARENT
    jnz .Ldaf_nar_next
    test edx, FE_IS_DIR | FE_LINK_DIR
    jz .Ldaf_nar_file
    inc dword ptr [rbx + DirModel.dir_count]
    jmp .Ldaf_nar_next
.Ldaf_nar_file:
    inc dword ptr [rbx + DirModel.file_count]
.Ldaf_nar_next:
    inc r13
    jmp .Ldaf_nar_loop
.Ldaf_nar_done:
    mov [rbx + DirModel.count], rbp
    jmp .Ldaf_remember

.Ldaf_full:
    mov qword ptr [rbx + DirModel.count], 0
    mov dword ptr [rbx + DirModel.dir_count], 0
    mov dword ptr [rbx + DirModel.file_count], 0

    mov r12, [rbx + DirModel.raw_count]
    xor r13d, r13d            # i = 0
    mov r14, [rbx + DirModel.entries]
    mov r15, [rbx + DirModel.order]

.Ldaf_loop:
    cmp r13, r12
    jae .Ldaf_after
    mov rbp, r13
    shl rbp, 5
    add rbp, r14              # &entries[i]

    mov rdi, rbx
    mov edx, [rbp + FileEntry.flags]
    mov ecx, [rbp + FileEntry.name_off]
    add rcx, [rbx + DirModel.name_pool]
    call entry_passes_filter
    test eax, eax
    jz .Ldaf_next

    mov rax, [rbx + DirModel.count]
    mov [r15 + rax * 4], r13d
    inc rax
    mov [rbx + DirModel.count], rax

    mov edx, [rbp + FileEntry.flags]
    test edx, FE_IS_PARENT
    jnz .Ldaf_next
    test edx, FE_IS_DIR | FE_LINK_DIR
    jz .Ldaf_cnt_file
    inc dword ptr [rbx + DirModel.dir_count]
    jmp .Ldaf_next
.Ldaf_cnt_file:
    inc dword ptr [rbx + DirModel.file_count]

.Ldaf_next:
    inc r13
    jmp .Ldaf_loop

.Ldaf_after:
    cmp dword ptr [rbx + DirModel.is_loading], 0
    jne .Ldaf_done
    cmp dword ptr [rbx + DirModel.is_unsorted], 0
    jne .Ldaf_done
    cmp dword ptr [rbx + DirModel.huge_mode], 0
    jne .Ldaf_done
    mov rdi, rbx
    call DirModel_sort

.Ldaf_done:
    cmp dword ptr [rbx + DirModel.is_loading], 0
    jne .Ldaf_ret
.Ldaf_remember:
    lea rdi, [rbx + DirModel.flt_applied]
    lea rsi, [rbx + DirModel.filter]
    mov edx, FILTER_MAX
    call str_copy
    mov rax, [rbx + DirModel.raw_count]
    mov [rbx + DirModel.flt_raw], rax
    mov eax, [rbx + DirModel.show_hidden]
    mov [rbx + DirModel.flt_hidden], eax
    mov dword ptr [rbx + DirModel.flt_valid], 1
.Ldaf_ret:
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

# ==============================================================================
# int DirModel_chdir(DirModel *this, const char *target)
# Lexically resolves target against this->path (no process-wide chdir/getcwd), verifies it
# is an accessible directory, donates the current listing to the LRU dir cache, then either
# restores a valid cached snapshot in O(1) or reloads. Clears the filter.
# On failure this->path and the listing stay untouched.
# ==============================================================================
DirModel_chdir:
    push rbx
    push r12
    push r13
    sub rsp, PATH_MAX + 64            # [0]=resolved path, [PATH_MAX]=FileStat
    call DirModel_chdir__path_normalize
    jz .Ldmc_toolong

    call DirModel_chdir__part2
    js .Ldmc_ret
    call DirModel_chdir__os_fstat
    js .Ldmc_ret

    call DirModel_chdir__close_stream_resources
    mov rdi, rbx
    lea rsi, [rsp + PATH_MAX]
    call dircache_fetch
    test eax, eax
    jz .Ldmc_miss
    call DirModel_chdir__reset_entry_stats
    mov rdi, rbx; call git_refresh
    jmp .Ldmc_ret

.Ldmc_miss:
    cmp qword ptr [rbx + DirModel.entries], 0
    jne .Ldmc_reload
    mov rdi, rbx
    call alloc_initial_arrays
    test eax, eax
    js .Ldmc_ret
.Ldmc_reload:
    mov rdi, rbx
    call DirModel_reload
    jmp .Ldmc_ret
.Ldmc_toolong:
    mov rax, -EINVAL
.Ldmc_ret:
    add rsp, PATH_MAX + 64
    pop r13
    pop r12
    pop rbx
    ret

# DirModel_chdir step: path_normalize (runs on the caller's frame)
DirModel_chdir__path_normalize:
    lea rsp, [rsp - 8]
    mov rbx, rdi
    mov r12, rsi

    lea rdi, [rbx + DirModel.path]
    mov rsi, r12
    lea rdx, [rsp + 16]
    mov ecx, PATH_MAX
    call path_normalize
    test rax, rax
.LDirModel_chdir__path_normalize_ret:
    lea rsp, [rsp + 8]
    ret

# DirModel_chdir step (runs on the caller's frame)
DirModel_chdir__part2:
    lea rsp, [rsp - 8]
    mov edi, AT_FDCWD
    lea rsi, [rsp + 16]
    mov edx, O_RDONLY | O_DIRECTORY | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
.LDirModel_chdir__part2_ret:
    lea rsp, [rsp + 8]
    ret

# DirModel_chdir step: os_fstat (runs on the caller's frame)
DirModel_chdir__os_fstat:
    lea rsp, [rsp - 8]
    mov r13d, eax
    mov edi, r13d
    lea rsi, [rsp + PATH_MAX + 16]
    call os_fstat
    mov r12, rax
    mov edi, r13d
    OS_CLOSE
    mov rax, r12
    test rax, rax
.LDirModel_chdir__os_fstat_ret:
    lea rsp, [rsp + 8]
    ret

# DirModel_chdir step: close_stream_resources (runs on the caller's frame)
DirModel_chdir__close_stream_resources:
    lea rsp, [rsp - 8]
    mov rdi, rbx
    call close_stream_resources
    mov rdi, rbx
    call dircache_store
    lea rdi, [rbx + DirModel.path]
    lea rsi, [rsp + 16]
    mov edx, PATH_MAX
    call str_copy
    mov byte ptr [rbx + DirModel.filter], 0

.LDirModel_chdir__close_stream_resources_ret:
    lea rsp, [rsp + 8]
    ret

# DirModel_chdir step: reset_entry_stats (runs on the caller's frame)
DirModel_chdir__reset_entry_stats:
    lea rsp, [rsp - 8]
    mov r12d, eax
    mov dword ptr [rbx + DirModel.is_loading], 0
    mov dword ptr [rbx + DirModel.load_aborted], 0
    mov dword ptr [rbx + DirModel.flt_valid], 0
    mov rdi, rbx
    call reset_entry_stats
    cmp r12d, 1
    je .Ldmc_ok
    mov dword ptr [rbx + DirModel.is_unsorted], 0
    mov rdi, rbx
    call DirModel_apply_filter
.Ldmc_ok:
.LDirModel_chdir__reset_entry_stats_ret:
    lea rsp, [rsp + 8]
    ret

# ==============================================================================
# FileEntry *DirModel_get_entry(DirModel *this, ssize_t idx)
# Maps visible index through order[] indirection to 32-byte FileEntry*.
# ==============================================================================
DirModel_get_entry:
    test rsi, rsi
    js .Ldge_null
    cmp rsi, [rdi + DirModel.count]
    jae .Ldge_null
    mov rax, [rdi + DirModel.order]
    mov eax, [rax + rsi * 4]
    shl rax, 5
    add rax, [rdi + DirModel.entries]
    ret
.Ldge_null:
    xor eax, eax
    ret

# ==============================================================================
# Helper: void mark_link_dir(DirModel *model, FileEntry *entry)
# A symlink resolved to a directory: count it as a dir once and flag FE_LINK_DIR.
# ==============================================================================
mark_link_dir:
    test dword ptr [rsi + FileEntry.flags], FE_IS_DIR | FE_LINK_DIR
    jnz .Lmld_flag
    inc dword ptr [rdi + DirModel.dir_count]
    cmp dword ptr [rdi + DirModel.file_count], 0
    je .Lmld_flag
    dec dword ptr [rdi + DirModel.file_count]
.Lmld_flag:
    or dword ptr [rsi + FileEntry.flags], FE_LINK_DIR
    ret
