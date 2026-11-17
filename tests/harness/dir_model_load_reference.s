# Frozen reference oracle: the hand-written asm that src/fs/dir_model_load.c + dir_model_stream.c replaced (tests/test_c_dir_model_load.py diffs against it)
# src/fs/dir_model.s - Compact 32B DirModel, zero-stat d_type scan, streaming & lazy stat — dir model load (split from dir_model.s)

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
.global ensure_capacity
.global finish_load_internal
.global DirModel_reload

# ==============================================================================
# Helper: int ensure_capacity(DirModel *this, size_t need_name_bytes)
# Grows entries[], order[], and name_pool via mem_realloc (os_mem_remap).
# Returns 0 on success, -ENOMEM on allocation failure.
# ==============================================================================
ensure_capacity:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi              # need_name_bytes

    mov rax, [rbx + DirModel.raw_count]
    cmp rax, [rbx + DirModel.raw_cap]
    jb .Lec_check_pool

    mov r13, [rbx + DirModel.raw_cap]
    test r13, r13
    jnz 1f
    mov r13d, INITIAL_FILE_CAP / 2
1:  shl r13, 1                # new_cap = raw_cap * 2
    mov rdi, [rbx + DirModel.entries]
    mov rsi, r13
    shl rsi, 5                # new_cap * 32
    call mem_realloc
    test rax, rax
    jz .Lec_nomem
    mov [rbx + DirModel.entries], rax

    mov rdi, [rbx + DirModel.order]
    lea rsi, [r13 * 4]
    call mem_realloc
    test rax, rax
    jz .Lec_nomem
    mov [rbx + DirModel.order], rax
    mov [rbx + DirModel.raw_cap], r13

.Lec_check_pool:
    mov rax, [rbx + DirModel.name_used]
    add rax, r12
    cmp rax, [rbx + DirModel.name_cap]
    jbe .Lec_ok

    mov r13, [rbx + DirModel.name_cap]
    test r13, r13
    jnz .Lec_grow_pool
    mov r13d, INITIAL_NAME_CAP
    cmp r13, rax
    jae .Lec_alloc_pool
.Lec_grow_pool:
    shl r13, 1
    cmp r13, rax
    jb .Lec_grow_pool
.Lec_alloc_pool:

    mov rdi, [rbx + DirModel.name_pool]
    mov rsi, r13
    call mem_realloc
    test rax, rax
    jz .Lec_nomem
    mov [rbx + DirModel.name_pool], rax
    mov [rbx + DirModel.name_cap], r13

.Lec_ok:
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    ret
.Lec_nomem:
    mov eax, -12              # -ENOMEM
    pop r13
    pop r12
    pop rbx
    ret

# ==============================================================================
# Helper: void finish_load_internal(DirModel *this, int canceled)
# Closes load resources and finalizes initial sort (unless huge_mode).
# ==============================================================================
finish_load_internal:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12d, esi             # canceled

    call close_stream_resources
    mov dword ptr [rbx + DirModel.is_loading], 0
    test r12d, r12d
    jz .Lfli_chk_huge
    mov dword ptr [rbx + DirModel.load_aborted], 1
    jmp .Lfli_done

.Lfli_chk_huge:
    cmp dword ptr [rbx + DirModel.huge_mode], 0
    jne .Lfli_keep_fs_order
    mov rdi, rbx
    call DirModel_sort        # clears is_unsorted = 0
    jmp .Lfli_done

.Lfli_keep_fs_order:
    mov dword ptr [rbx + DirModel.is_unsorted], 1

.Lfli_done:
    add rsp, 8
    pop r12
    pop rbx
    ret

# ==============================================================================
# int DirModel_reload(DirModel *this)
# Resets DirModel, opens directory, adds synthetic "..", reads first batch.
# Returns 0 on success (is_loading=1 if more batches pending), or -errno.
# ==============================================================================
DirModel_reload:
    push rbx
    push r12
    sub rsp, 56               # [rsp] = FileStat of the directory
    call DirModel_reload__close_stream_resources
    call DirModel_reload__part2
    js .Ldmr_err
    call DirModel_reload__stamp_listing_lru_dir
    mov rdi, DIRENTS_BUF_SIZE
    call mem_alloc
    test rax, rax
    jz .Ldmr_nomem
    mov [rbx + DirModel.load_buf], rax
    mov dword ptr [rbx + DirModel.is_loading], 1

    # Add synthetic ".." entry unless path == "/"
    cmp byte ptr [rbx + DirModel.path], '/'
    jne .Ldmr_add_parent
    cmp byte ptr [rbx + DirModel.path + 1], 0
    je .Ldmr_first_batch

.Ldmr_add_parent:
    mov rdi, rbx
    mov esi, 3
    call ensure_capacity
    test eax, eax
    js .Ldmr_fail_alloc

    # Write "..\0" at name_pool[0..2]
    call DirModel_reload__write_name_pool
    # Populate entries[0]
    call DirModel_reload__populate_entries
.Ldmr_first_batch:
    call DirModel_reload__streaming_continues_after_first
.Ldmr_err:
    add rsp, 56
    pop r12
    pop rbx
    ret

.Ldmr_nomem:
    mov eax, -12
.Ldmr_fail_alloc:
    push rax
    mov rdi, rbx
    call close_stream_resources
    mov dword ptr [rbx + DirModel.is_loading], 0
    pop rax
    add rsp, 56
    pop r12
    pop rbx
    ret

# DirModel_reload step: close_stream_resources (runs on the caller's frame)
DirModel_reload__close_stream_resources:
    lea rsp, [rsp - 8]
    mov rbx, rdi

    call close_stream_resources
    mov dword ptr [rbx + DirModel.flt_valid], 0
    mov dword ptr [rbx + DirModel.is_loading], 0
    mov dword ptr [rbx + DirModel.load_aborted], 0
    mov dword ptr [rbx + DirModel.huge_mode], 0
    mov dword ptr [rbx + DirModel.is_unsorted], 0
    mov dword ptr [rbx + DirModel.stats_complete], 0
    mov qword ptr [rbx + DirModel.count], 0
    mov qword ptr [rbx + DirModel.raw_count], 0
    mov qword ptr [rbx + DirModel.name_used], 0
    mov qword ptr [rbx + DirModel.total_bytes], 0
    mov dword ptr [rbx + DirModel.dir_count], 0
    mov dword ptr [rbx + DirModel.file_count], 0
    mov dword ptr [rbx + DirModel.has_dotdot], 0

.LDirModel_reload__close_stream_resources_ret:
    lea rsp, [rsp + 8]
    ret

# DirModel_reload step (runs on the caller's frame)
DirModel_reload__part2:
    lea rsp, [rsp - 8]
    mov edi, AT_FDCWD
    lea rsi, [rbx + DirModel.path]
    mov edx, O_RDONLY | O_DIRECTORY | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
.LDirModel_reload__part2_ret:
    lea rsp, [rsp + 8]
    ret

# DirModel_reload step: Stamp the listing for LRU dir cache validation (runs on the caller's frame)
DirModel_reload__stamp_listing_lru_dir:
    lea rsp, [rsp - 8]
    mov [rbx + DirModel.load_dirfd], eax
    # Stamp the listing (dev/ino/mtime) for LRU dir-cache validation
    mov edi, eax
    lea rsi, [rsp + 16]
    call os_fstat
    xor ecx, ecx
    test rax, rax
    js .Ldmr_stamp
    mov rcx, [rsp + FileStat.ino + 16]
    mov rax, [rsp + FileStat.dev + 16]
    mov [rbx + DirModel.dir_dev], rax
    mov rax, [rsp + FileStat.mtime + 16]
    mov [rbx + DirModel.dir_mtime], rax
    mov eax, [rsp + FileStat.mtime_nsec + 16]
    mov [rbx + DirModel.dir_mtime_ns], eax
.Ldmr_stamp:
    mov [rbx + DirModel.dir_ino], rcx

.LDirModel_reload__stamp_listing_lru_dir_ret:
    lea rsp, [rsp + 8]
    ret

# DirModel_reload step: Write at name_pool (runs on the caller's frame)
DirModel_reload__write_name_pool:
    lea rsp, [rsp - 8]
    mov rdx, [rbx + DirModel.name_pool]
    mov byte ptr [rdx + 0], '.'
    mov byte ptr [rdx + 1], '.'
    mov byte ptr [rdx + 2], 0
    mov qword ptr [rbx + DirModel.name_used], 3

.LDirModel_reload__write_name_pool_ret:
    lea rsp, [rsp + 8]
    ret

# DirModel_reload step: Populate entries (runs on the caller's frame)
DirModel_reload__populate_entries:
    lea rsp, [rsp - 8]
    mov r12, [rbx + DirModel.entries]
    mov qword ptr [r12 + FileEntry.size], 0
    mov qword ptr [r12 + FileEntry.mtime], 0
    mov dword ptr [r12 + FileEntry.mode], S_IFDIR | 0755
    mov dword ptr [r12 + FileEntry.flags], FE_IS_DIR | FE_IS_PARENT | FE_STAT_READY
    mov dword ptr [r12 + FileEntry.name_off], 0
    mov word ptr [r12 + FileEntry.name_len], 2
    mov byte ptr [r12 + FileEntry.disp_width], 2
    mov byte ptr [r12 + FileEntry.ext_offset], 0

    mov rax, [rbx + DirModel.order]
    mov dword ptr [rax], 0
    mov qword ptr [rbx + DirModel.raw_count], 1
    mov qword ptr [rbx + DirModel.count], 1
    mov dword ptr [rbx + DirModel.has_dotdot], 1

.LDirModel_reload__populate_entries_ret:
    lea rsp, [rsp + 8]
    ret

# DirModel_reload step: If streaming continues after first batch hide premature sort indicator until EOF (runs on the caller's frame)
DirModel_reload__streaming_continues_after_first:
    lea rsp, [rsp - 8]
    mov rdi, rbx
    xor esi, esi              # default g_stream_batch budget
    call DirModel_step_load
    test rax, rax
    js .LDirModel_reload__streaming_continues_after_first_ret
    # If streaming continues after first batch, hide premature sort indicator until EOF
    cmp dword ptr [rbx + DirModel.is_loading], 0
    je .Ldmr_ok
    mov dword ptr [rbx + DirModel.is_unsorted], 1
.Ldmr_ok:
    mov rdi, rbx; call git_refresh
.LDirModel_reload__streaming_continues_after_first_ret:
    lea rsp, [rsp + 8]
    ret
