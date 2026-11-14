# src/fs/dir_model.s - Compact 32B DirModel, zero-stat d_type scan, streaming & lazy stat
.intel_syntax noprefix

.include "pal.inc"
.include "classes.inc"

.equ BATCH_STAT_CHUNK, 1024
.equ CHUNK_ENTRIES_OFF, 0
.equ CHUNK_NAMES_OFF,   (BATCH_STAT_CHUNK * 8)
.equ CHUNK_STATS_OFF,   (CHUNK_NAMES_OFF + BATCH_STAT_CHUNK * 8)
.equ CHUNK_ERRS_OFF,    (CHUNK_STATS_OFF + BATCH_STAT_CHUNK * FileStat._size)
.equ CHUNK_BUF_SIZE,    (CHUNK_ERRS_OFF + BATCH_STAT_CHUNK * 4)

.section .rodata
str_DirModel:   .asciz "DirModel"
str_dotdot:     .asciz ".."
str_slash:      .asciz "/"
str_env_huge:   .asciz "DUOP_HUGE_THRESHOLD="
str_env_batch:  .asciz "DUOP_STREAM_BATCH="

.section .bss
.align 8
g_huge_threshold: .space 8
g_stream_batch:   .space 8

.section .text
.global DirModel_vtbl
DirModel_vtbl:
    OBJECT_VTBL_SLOTS str_DirModel, Object_vtbl, DirModel._size, DirModel_dtor

.global DirModel_init_env
.global DirModel_new
.global DirModel_dtor
.global DirModel_reload
.global DirModel_step_load
.global DirModel_cancel_load
.global DirModel_apply_filter
.global DirModel_chdir
.global DirModel_entry_name
.global DirModel_get_entry
.global DirModel_ensure_entry_stat
.global DirModel_stat_range
.global DirModel_ensure_all_stats
.global DirModel_toggle_select
.global DirModel_select_all_toggle
.global DirModel_count_selected
.global DirModel_find_by_name

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

# ==============================================================================
# Helper: uint64_t parse_u64_dec(const char *s)
# ==============================================================================
parse_u64_dec:
    xor eax, eax
.Lpud_loop:
    movzx ecx, byte ptr [rdi]
    sub ecx, '0'
    cmp ecx, 9
    ja .Lpud_done
    imul rax, rax, 10
    add rax, rcx
    inc rdi
    jmp .Lpud_loop
.Lpud_done:
    ret

# ==============================================================================
# void DirModel_init_env(const char **envp)
# Reads DUOP_HUGE_THRESHOLD and DUOP_STREAM_BATCH overrides from environment.
# ==============================================================================
DirModel_init_env:
    mov qword ptr [rip + g_huge_threshold], HUGE_DIR_THRESHOLD
    mov qword ptr [rip + g_stream_batch], STREAM_BATCH_BUDGET
    test rdi, rdi
    jz .Ldie_ret
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
.Ldie_loop:
    mov r12, [rbx]
    test r12, r12
    jz .Ldie_done

    mov rdi, r12
    lea rsi, [rip + str_env_huge]
    call str_starts_with
    test eax, eax
    jz .Ldie_chk_batch
    lea rdi, [r12 + 20]
    call parse_u64_dec
    test rax, rax
    jz .Ldie_next
    mov [rip + g_huge_threshold], rax
    jmp .Ldie_next

.Ldie_chk_batch:
    mov rdi, r12
    lea rsi, [rip + str_env_batch]
    call str_starts_with
    test eax, eax
    jz .Ldie_next
    lea rdi, [r12 + 18]
    call parse_u64_dec
    test rax, rax
    jz .Ldie_next
    mov [rip + g_stream_batch], rax

.Ldie_next:
    add rbx, 8
    jmp .Ldie_loop
.Ldie_done:
    add rsp, 8
    pop r12
    pop rbx
.Ldie_ret:
    ret

# ==============================================================================
# DirModel *DirModel_new(const char *initial_path)
# ==============================================================================
DirModel_new:
    push rbx
    push r12
    sub rsp, 8                # align: 2 pushes=16 + 8 + 8 = 32
    mov r12, rdi              # initial_path

    NEW_OBJ DirModel_vtbl, DirModel._size
    test rax, rax
    jz .Ldmn_fail
    mov rbx, rax
    mov dword ptr [rbx + DirModel.load_dirfd], -1
    mov dword ptr [rbx + DirModel.show_hidden], 1
    mov dword ptr [rbx + DirModel.sort_mode], SORT_NAME

    mov rdi, rbx
    call alloc_initial_arrays
    test eax, eax
    jnz .Ldmn_fail_free

    test r12, r12
    jnz .Ldmn_use_arg
    lea rdi, [rbx + DirModel.path]
    mov esi, PATH_MAX
    OS_GETCWD
    test rax, rax
    jns .Ldmn_reload
    lea rdi, [rbx + DirModel.path]
    lea rsi, [rip + str_slash]
    mov edx, PATH_MAX
    call str_copy
    jmp .Ldmn_reload

.Ldmn_use_arg:
    lea rdi, [rbx + DirModel.path]
    mov rsi, r12
    mov edx, PATH_MAX
    call str_copy

.Ldmn_reload:
    mov rdi, rbx
    call DirModel_reload
    mov rax, rbx
    add rsp, 8
    pop r12
    pop rbx
    ret

.Ldmn_fail_free:
    mov rdi, rbx
    call DirModel_dtor
.Ldmn_fail:
    xor eax, eax
    add rsp, 8
    pop r12
    pop rbx
    ret

# ==============================================================================
# Helper: int alloc_initial_arrays(DirModel *this) -> 0 or -ENOMEM
# entries[INITIAL_FILE_CAP] (32 B), order[INITIAL_FILE_CAP] (4 B), name_pool[INITIAL_NAME_CAP]
# ==============================================================================
alloc_initial_arrays:
    push rbx
    mov rbx, rdi
    mov edi, INITIAL_FILE_CAP * FileEntry._size
    call mem_alloc
    test rax, rax
    jz .Laia_fail
    mov [rbx + DirModel.entries], rax
    mov edi, INITIAL_FILE_CAP * 4
    call mem_alloc
    test rax, rax
    jz .Laia_fail
    mov [rbx + DirModel.order], rax
    mov qword ptr [rbx + DirModel.raw_cap], INITIAL_FILE_CAP
    mov edi, INITIAL_NAME_CAP
    call mem_alloc
    test rax, rax
    jz .Laia_fail
    mov [rbx + DirModel.name_pool], rax
    mov qword ptr [rbx + DirModel.name_cap], INITIAL_NAME_CAP
    xor eax, eax
    pop rbx
    ret
.Laia_fail:
    mov eax, -ENOMEM
    pop rbx
    ret

# ==============================================================================
# void DirModel_invalidate_stats(DirModel *this)
# File contents/attributes changed (watch event): drop cached stats so visible rows re-stat
# lazily; selections stay untouched.
# ==============================================================================
.global DirModel_invalidate_stats
DirModel_invalidate_stats:
    mov rcx, [rdi + DirModel.entries]
    mov rdx, [rdi + DirModel.raw_count]
    mov eax, [rdi + DirModel.has_dotdot]
.Ldis_loop:
    cmp rax, rdx
    jae .Ldis_done
    mov r8, rax
    shl r8, 5
    and dword ptr [rcx + r8 + FileEntry.flags], ~FE_STAT_READY
    inc rax
    jmp .Ldis_loop
.Ldis_done:
    mov qword ptr [rdi + DirModel.total_bytes], 0
    mov dword ptr [rdi + DirModel.stats_complete], 0
    ret

# ==============================================================================
# Helper: void reset_entry_stats(DirModel *this)
# After restoring a cached listing: forget cached stat data and selections so visible rows
# are lazily re-stat'ed exactly like a fresh load (file contents may change without the
# directory mtime changing).
# ==============================================================================
reset_entry_stats:
    mov rcx, [rdi + DirModel.entries]
    mov rdx, [rdi + DirModel.raw_count]
    mov eax, [rdi + DirModel.has_dotdot]
.Lres_loop:
    cmp rax, rdx
    jae .Lres_done
    mov r8, rax
    shl r8, 5
    and dword ptr [rcx + r8 + FileEntry.flags], ~(FE_STAT_READY | FE_SELECTED)
    inc rax
    jmp .Lres_loop
.Lres_done:
    mov qword ptr [rdi + DirModel.total_bytes], 0
    mov dword ptr [rdi + DirModel.stats_complete], 0
    ret

# ==============================================================================
# Helper: void close_stream_resources(DirModel *this)
# ==============================================================================
close_stream_resources:
    push rbx
    mov rbx, rdi
    mov edi, [rbx + DirModel.load_dirfd]
    test edi, edi
    js .Lcsr_buf
    OS_CLOSE
    mov dword ptr [rbx + DirModel.load_dirfd], -1
.Lcsr_buf:
    mov rdi, [rbx + DirModel.load_buf]
    test rdi, rdi
    jz .Lcsr_done
    call mem_free
    mov qword ptr [rbx + DirModel.load_buf], 0
.Lcsr_done:
    mov qword ptr [rbx + DirModel.load_pos], 0
    mov qword ptr [rbx + DirModel.load_bytes], 0
    pop rbx
    ret

# ==============================================================================
# void DirModel_dtor(DirModel *this)
# ==============================================================================
DirModel_dtor:
    push rbx
    mov rbx, rdi
    call close_stream_resources
    mov rdi, [rbx + DirModel.name_pool]
    call mem_free
    mov rdi, [rbx + DirModel.order]
    call mem_free
    mov rdi, [rbx + DirModel.entries]
    call mem_free
    mov rdi, rbx
    call Object_dtor
    pop rbx
    ret

# ==============================================================================
# const char *DirModel_entry_name(const DirModel *this, const FileEntry *entry)
# Returns pointer inside contiguous name_pool (or NULL if args NULL).
# ==============================================================================
DirModel_entry_name:
    test rdi, rdi
    jz .Lden_null
    test rsi, rsi
    jz .Lden_null
    mov eax, [rsi + FileEntry.name_off]
    add rax, [rdi + DirModel.name_pool]
    ret
.Lden_null:
    xor eax, eax
    ret

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
    shl r13, 1                # new_cap = raw_cap * 2
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
.Lec_grow_pool:
    shl r13, 1
    cmp r13, rax
    jb .Lec_grow_pool

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
# Helper: void prepare_filter(DirModel *this)
# Lowercases DirModel.filter once into flt_lc so per-entry matching is a pure SIMD scan.
# ==============================================================================
prepare_filter:
    xor ecx, ecx
.Lpf_loop:
    movzx eax, byte ptr [rdi + DirModel.filter + rcx]
    cmp eax, 'A'
    jb .Lpf_store
    cmp eax, 'Z'
    ja .Lpf_store
    add eax, 32
.Lpf_store:
    mov [rdi + DirModel.flt_lc + rcx], al
    test eax, eax
    jz .Lpf_done
    inc ecx
    cmp ecx, FILTER_MAX - 1
    jb .Lpf_loop
    mov byte ptr [rdi + DirModel.flt_lc + rcx], 0
.Lpf_done:
    mov [rdi + DirModel.flt_lc_len], ecx
    ret

# ==============================================================================
# Helper: int entry_passes_filter(const DirModel *this, uint32_t flags, const char *name)
# Requires prepare_filter() to have run for the current DirModel.filter.
# ==============================================================================
entry_passes_filter:
    test edx, FE_IS_PARENT
    jnz .Lepf_yes
    test edx, FE_IS_HIDDEN
    jz .Lepf_chk_str
    cmp dword ptr [rdi + DirModel.show_hidden], 0
    je .Lepf_no
.Lepf_chk_str:
    mov edx, [rdi + DirModel.flt_lc_len]
    test edx, edx
    jz .Lepf_yes
    lea rsi, [rdi + DirModel.flt_lc]
    mov rdi, rcx              # name
    jmp os_str_contains_ci_fast
.Lepf_yes:
    mov eax, 1
    ret
.Lepf_no:
    xor eax, eax
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

    mov edi, AT_FDCWD
    lea rsi, [rbx + DirModel.path]
    mov edx, O_RDONLY | O_DIRECTORY | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
    js .Ldmr_err
    mov [rbx + DirModel.load_dirfd], eax
    # Stamp the listing (dev/ino/mtime) for LRU dir-cache validation
    mov edi, eax
    mov rsi, rsp
    call os_fstat
    xor ecx, ecx
    test rax, rax
    js .Ldmr_stamp
    mov rcx, [rsp + FileStat.ino]
    mov rax, [rsp + FileStat.dev]
    mov [rbx + DirModel.dir_dev], rax
    mov rax, [rsp + FileStat.mtime]
    mov [rbx + DirModel.dir_mtime], rax
    mov eax, [rsp + FileStat.mtime_nsec]
    mov [rbx + DirModel.dir_mtime_ns], eax
.Ldmr_stamp:
    mov [rbx + DirModel.dir_ino], rcx

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
    mov rdx, [rbx + DirModel.name_pool]
    mov byte ptr [rdx + 0], '.'
    mov byte ptr [rdx + 1], '.'
    mov byte ptr [rdx + 2], 0
    mov qword ptr [rbx + DirModel.name_used], 3

    # Populate entries[0]
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

.Ldmr_first_batch:
    mov rdi, rbx
    xor esi, esi              # default g_stream_batch budget
    call DirModel_step_load
    test rax, rax
    js .Ldmr_err
    # If streaming continues after first batch, hide premature sort indicator until EOF
    cmp dword ptr [rbx + DirModel.is_loading], 0
    je .Ldmr_ok
    mov dword ptr [rbx + DirModel.is_unsorted], 1
.Ldmr_ok:
    xor eax, eax
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

# ==============================================================================
# int DirModel_step_load(DirModel *this, size_t max_entries)
# Reads and appends up to max_entries (or g_stream_batch if 0) using d_type only.
# Returns 1 if more entries may follow, 0 on EOF/done, or -errno on read error.
# ==============================================================================
DirModel_step_load:
    cmp dword ptr [rdi + DirModel.is_loading], 0
    jne .Ldsl_active
    xor eax, eax
    ret
.Ldsl_active:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 40               # align: 6 pushes=48 + 40 + 8 = 96 = 0 mod 16
    # Stack frame:
    # [rsp + 0]  = budget
    # [rsp + 8]  = added
    # [rsp + 16] = d_name ptr
    # [rsp + 24] = name_len (qword)
    # [rsp + 32] = ext_off (byte), d_type (byte at +33), disp_w (byte at +34)
    mov rbx, rdi
    mov dword ptr [rbx + DirModel.flt_valid], 0
    push rsi
    sub rsp, 8
    call prepare_filter
    add rsp, 8
    pop rsi
    test rsi, rsi
    jnz .Ldsl_got_budget
    mov rsi, [rip + g_stream_batch]
    test rsi, rsi
    jnz .Ldsl_got_budget
    mov rsi, STREAM_BATCH_BUDGET
.Ldsl_got_budget:
    mov [rsp + 0], rsi
    mov qword ptr [rsp + 8], 0

.Ldsl_loop:
    mov rax, [rsp + 8]
    cmp rax, [rsp + 0]
    jae .Ldsl_more

    # Refill 1 MiB getdents64 buffer when exhausted
    mov rax, [rbx + DirModel.load_pos]
    cmp rax, [rbx + DirModel.load_bytes]
    jb .Ldsl_next_dentry

    mov edi, [rbx + DirModel.load_dirfd]
    mov rsi, [rbx + DirModel.load_buf]
    mov edx, DIRENTS_BUF_SIZE
    call os_dir_read
    test rax, rax
    js .Ldsl_read_err
    jz .Ldsl_eof
    mov [rbx + DirModel.load_bytes], rax
    mov qword ptr [rbx + DirModel.load_pos], 0

.Ldsl_next_dentry:
    mov rdi, [rbx + DirModel.load_buf]
    mov rsi, [rbx + DirModel.load_bytes]
    lea rdx, [rbx + DirModel.load_pos]
    lea rcx, [rsp + 33]       # &d_type (byte)
    call os_dir_next_ex
    test rax, rax
    jz .Ldsl_loop
    mov r12, rax              # d_name

    # Skip "." and ".."
    cmp byte ptr [r12], '.'
    jne .Ldsl_scan_name
    cmp byte ptr [r12 + 1], 0
    je .Ldsl_loop
    cmp byte ptr [r12 + 1], '.'
    jne .Ldsl_scan_name
    cmp byte ptr [r12 + 2], 0
    je .Ldsl_loop

.Ldsl_scan_name:
    # Inline scan: compute name_len, last_dot, ASCII vs UTF-8
    xor ecx, ecx              # len = 0
    xor edx, edx              # last_dot = 0
    xor r8d, r8d              # high_bit_or = 0
.Ldsl_scan_loop:
    movzx eax, byte ptr [r12 + rcx]
    test eax, eax
    jz .Ldsl_scan_done
    or r8d, eax
    cmp eax, '.'
    jne .Ldsl_scan_next
    test rcx, rcx
    jz .Ldsl_scan_next
    mov edx, ecx
.Ldsl_scan_next:
    inc rcx
    jmp .Ldsl_scan_loop

.Ldsl_scan_done:
    mov [rsp + 16], r12
    mov [rsp + 24], rcx       # name_len
    cmp edx, 255
    jbe .Ldsl_ext_ok
    xor edx, edx
.Ldsl_ext_ok:
    mov [rsp + 32], dl        # ext_offset

    # ASCII fast-path display width vs utf8_display_width
    test r8d, 0x80
    jz .Ldsl_ascii_w
    mov rdi, r12
    call utf8_display_width
    cmp rax, 255
    jbe .Ldsl_w_ok
    mov eax, 255
    jmp .Ldsl_w_ok
.Ldsl_ascii_w:
    mov rax, [rsp + 24]
    cmp rax, 255
    jbe .Ldsl_w_ok
    mov eax, 255
.Ldsl_w_ok:
    mov [rsp + 34], al        # disp_width

    # Ensure array + name_pool capacity for name_len + 1
    mov rdi, rbx
    mov rsi, [rsp + 24]
    inc rsi
    call ensure_capacity
    test eax, eax
    js .Ldsl_read_err

    # Copy name_len + 1 bytes into name_pool + name_used
    mov r13, [rbx + DirModel.name_used]       # name_off
    mov rdi, [rbx + DirModel.name_pool]
    add rdi, r13
    mov rsi, [rsp + 16]
    mov rcx, [rsp + 24]
    inc rcx
    rep movsb
    mov rax, [rsp + 24]
    lea r14, [r13 + rax + 1]
    mov [rbx + DirModel.name_used], r14

    # Derive zero-stat flags & fallback mode purely from d_type
    xor r10d, r10d
    mov r12, [rsp + 16]
    cmp byte ptr [r12], '.'
    jne .Ldsl_dt
    or r10d, FE_IS_HIDDEN
.Ldsl_dt:
    movzx eax, byte ptr [rsp + 33]
    cmp eax, PAL_DT_DIR
    je .Ldsl_dt_dir
    cmp eax, PAL_DT_LNK
    je .Ldsl_dt_lnk
    cmp eax, PAL_DT_UNKNOWN
    je .Ldsl_dt_unk
    mov r11d, S_IFREG | 0644
    jmp .Ldsl_fill_fe
.Ldsl_dt_dir:
    or r10d, FE_IS_DIR
    mov r11d, S_IFDIR | 0755
    jmp .Ldsl_fill_fe
.Ldsl_dt_lnk:
    or r10d, FE_IS_LINK
    mov r11d, S_IFLNK | 0777
    jmp .Ldsl_fill_fe
.Ldsl_dt_unk:
    or r10d, FE_DT_UNKNOWN
    xor r11d, r11d

.Ldsl_fill_fe:
    mov r14, [rbx + DirModel.raw_count]
    mov r15, r14
    shl r15, 5
    add r15, [rbx + DirModel.entries]
    mov qword ptr [r15 + FileEntry.size], 0
    mov qword ptr [r15 + FileEntry.mtime], 0
    mov [r15 + FileEntry.mode], r11d
    mov [r15 + FileEntry.flags], r10d
    mov [r15 + FileEntry.name_off], r13d
    mov ax, [rsp + 24]
    mov [r15 + FileEntry.name_len], ax
    mov al, [rsp + 34]
    mov [r15 + FileEntry.disp_width], al
    mov al, [rsp + 32]
    mov [r15 + FileEntry.ext_offset], al

    inc qword ptr [rbx + DirModel.raw_count]
    inc qword ptr [rsp + 8]

    # Trigger ls -f huge mode once raw_count reaches g_huge_threshold
    mov rax, [rip + g_huge_threshold]
    test rax, rax
    jnz .Ldsl_chk_huge
    mov eax, HUGE_DIR_THRESHOLD
.Ldsl_chk_huge:
    cmp [rbx + DirModel.raw_count], rax
    jb .Ldsl_chk_vis
    mov dword ptr [rbx + DirModel.huge_mode], 1
    mov dword ptr [rbx + DirModel.is_unsorted], 1

.Ldsl_chk_vis:
    # Filter incrementally so Frame 1 shows matched rows immediately
    mov rdi, rbx
    mov edx, [r15 + FileEntry.flags]
    mov rcx, [rbx + DirModel.name_pool]
    add rcx, r13
    call entry_passes_filter
    test eax, eax
    jz .Ldsl_loop

    mov rdi, [rbx + DirModel.order]
    mov rax, [rbx + DirModel.count]
    mov [rdi + rax * 4], r14d
    inc rax
    mov [rbx + DirModel.count], rax

    test dword ptr [r15 + FileEntry.flags], FE_IS_DIR | FE_LINK_DIR
    jz .Ldsl_inc_file
    inc dword ptr [rbx + DirModel.dir_count]
    jmp .Ldsl_loop
.Ldsl_inc_file:
    inc dword ptr [rbx + DirModel.file_count]
    jmp .Ldsl_loop

.Ldsl_eof:
    mov rdi, rbx
    xor esi, esi
    call finish_load_internal
    xor eax, eax
    jmp .Ldsl_exit

.Ldsl_read_err:
    push rax
    mov rdi, rbx
    xor esi, esi
    call finish_load_internal
    pop rax
    jmp .Ldsl_exit

.Ldsl_more:
    mov eax, 1

.Ldsl_exit:
    add rsp, 40
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

# ==============================================================================
# void DirModel_cancel_load(DirModel *this)
# Cancels active directory streaming (Esc), preserving already loaded entries.
# ==============================================================================
DirModel_cancel_load:
    cmp dword ptr [rdi + DirModel.is_loading], 0
    je .Ldcl_ret
    mov esi, 1
    jmp finish_load_internal
.Ldcl_ret:
    ret

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
    mov rbx, rdi
    mov r12, rsi

    lea rdi, [rbx + DirModel.path]
    mov rsi, r12
    mov rdx, rsp
    mov ecx, PATH_MAX
    call path_normalize
    test rax, rax
    jz .Ldmc_toolong

    mov edi, AT_FDCWD
    mov rsi, rsp
    mov edx, O_RDONLY | O_DIRECTORY | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
    js .Ldmc_ret
    mov r13d, eax
    mov edi, r13d
    lea rsi, [rsp + PATH_MAX]
    call os_fstat
    mov r12, rax
    mov edi, r13d
    OS_CLOSE
    mov rax, r12
    test rax, rax
    js .Ldmc_ret

    mov rdi, rbx
    call close_stream_resources
    mov rdi, rbx
    call dircache_store
    lea rdi, [rbx + DirModel.path]
    mov rsi, rsp
    mov edx, PATH_MAX
    call str_copy
    mov byte ptr [rbx + DirModel.filter], 0

    mov rdi, rbx
    lea rsi, [rsp + PATH_MAX]
    call dircache_fetch
    test eax, eax
    jz .Ldmc_miss
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
    xor eax, eax
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

# ==============================================================================
# Helper: void apply_stat_to_entry(DirModel *model, FileEntry *entry,
#                                  const FileStat *st, int dirfd)
# Populates size/mtime/mode/flags cleanly and marks FE_STAT_READY.
# ==============================================================================
apply_stat_to_entry:
    push rbx
    push r12
    push r13
    sub rsp, FileStat._size + 8   # aligned stack + tmp FileStat
    mov rbx, rdi              # model
    mov r12, rsi              # entry
    mov r13, rdx              # st
    mov [rsp + FileStat._size], ecx  # dirfd

    mov r8d, [r12 + FileEntry.flags]
    test r8d, FE_STAT_READY
    jnz .Lase_done

    mov rax, [r13 + FileStat.size]
    mov [r12 + FileEntry.size], rax
    mov rax, [r13 + FileStat.mtime]
    mov [r12 + FileEntry.mtime], rax
    mov eax, [r13 + FileStat.mode]
    mov [r12 + FileEntry.mode], eax

    and r8d, ~(FE_DT_UNKNOWN | FE_IS_EXEC)
    mov r9d, eax
    and r9d, S_IFMT
    cmp r9d, S_IFDIR
    je .Lase_dir
    cmp r9d, S_IFLNK
    je .Lase_lnk

    # Regular or special non-dir file
    test eax, 0111
    jz .Lase_non_dir_cnt
    or r8d, FE_IS_EXEC
.Lase_non_dir_cnt:
    mov rax, [r13 + FileStat.size]
    add [rbx + DirModel.total_bytes], rax
    jmp .Lase_commit

.Lase_dir:
    test dword ptr [r12 + FileEntry.flags], FE_IS_DIR | FE_LINK_DIR
    jnz .Lase_commit
    or r8d, FE_IS_DIR
    inc dword ptr [rbx + DirModel.dir_count]
    cmp dword ptr [rbx + DirModel.file_count], 0
    je .Lase_commit
    dec dword ptr [rbx + DirModel.file_count]
    jmp .Lase_commit

.Lase_lnk:
    or r8d, FE_IS_LINK | FE_STAT_READY
    mov [r12 + FileEntry.flags], r8d
    cmp dword ptr [rsp + FileStat._size], -2
    je .Lase_done                     # batch caller resolves link targets via io_uring
    mov edi, [rsp + FileStat._size]
    mov esi, [r12 + FileEntry.name_off]
    add rsi, [rbx + DirModel.name_pool]
    mov rdx, rsp
    mov ecx, 1                # follow symlink to check FE_LINK_DIR
    call os_statat
    test rax, rax
    js .Lase_done
    mov eax, [rsp + FileStat.mode]
    and eax, S_IFMT
    cmp eax, S_IFDIR
    jne .Lase_done
    mov rdi, rbx
    mov rsi, r12
    call mark_link_dir
    jmp .Lase_done

.Lase_commit:
    or r8d, FE_STAT_READY
    mov [r12 + FileEntry.flags], r8d

.Lase_done:
    add rsp, FileStat._size + 8
    pop r13
    pop r12
    pop rbx
    ret

# ==============================================================================
# void DirModel_ensure_entry_stat(DirModel *this, FileEntry *entry)
# Lazy-stats a single FileEntry if FE_STAT_READY is not yet set.
# ==============================================================================
DirModel_ensure_entry_stat:
    test rdi, rdi
    jz .Lees_ret
    test rsi, rsi
    jz .Lees_ret
    test dword ptr [rsi + FileEntry.flags], FE_STAT_READY
    jnz .Lees_ret

    push rbx
    push r12
    push r13
    sub rsp, FileStat._size + 8
    mov rbx, rdi
    mov r12, rsi

    mov edi, AT_FDCWD
    lea rsi, [rbx + DirModel.path]
    mov edx, O_RDONLY | O_DIRECTORY | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
    js .Lees_mark_err
    mov r13d, eax

    mov edi, r13d
    mov esi, [r12 + FileEntry.name_off]
    add rsi, [rbx + DirModel.name_pool]
    mov rdx, rsp
    xor ecx, ecx
    call os_statat
    test rax, rax
    js .Lees_close_err
    mov rdi, rbx
    mov rsi, r12
    mov rdx, rsp
    mov ecx, r13d
    call apply_stat_to_entry
    jmp .Lees_close

.Lees_close_err:
    or dword ptr [r12 + FileEntry.flags], FE_STAT_READY
.Lees_close:
    mov edi, r13d
    OS_CLOSE
    jmp .Lees_done

.Lees_mark_err:
    or dword ptr [r12 + FileEntry.flags], FE_STAT_READY
.Lees_done:
    add rsp, FileStat._size + 8
    pop r13
    pop r12
    pop rbx
.Lees_ret:
    ret

# ==============================================================================
# void DirModel_stat_range(DirModel *this, size_t view_start, size_t view_len)
# Lazy-stats only visible viewport rows in FilePane_render lacking FE_STAT_READY.
# ==============================================================================
DirModel_stat_range:
    cmp qword ptr [rdi + DirModel.count], 0
    je .Ldsr_ret
    test rdx, rdx
    jz .Ldsr_ret

    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, FileStat._size + 16
    mov rbx, rdi
    mov r12, rsi              # idx = view_start
    lea r13, [rsi + rdx]      # end = view_start + view_len
    mov rax, [rbx + DirModel.count]
    cmp r13, rax
    cmova r13, rax
    cmp r12, r13
    jae .Ldsr_done

    # Quick check if any entry in [r12 .. r13) actually needs stat
    mov rax, [rbx + DirModel.order]
    mov rcx, [rbx + DirModel.entries]
    mov r8, r12
.Ldsr_scan_need:
    cmp r8, r13
    jae .Ldsr_done            # all visible rows already cached!
    mov edx, [rax + r8 * 4]
    shl rdx, 5
    test dword ptr [rcx + rdx + FileEntry.flags], FE_STAT_READY
    jz .Ldsr_open_dir
    inc r8
    jmp .Ldsr_scan_need

.Ldsr_open_dir:
    # Reuse open load_dirfd while streaming, otherwise open path once
    xor r15d, r15d            # own_fd = 0
    mov r14d, [rbx + DirModel.load_dirfd]
    test r14d, r14d
    jns .Ldsr_loop
    mov edi, AT_FDCWD
    lea rsi, [rbx + DirModel.path]
    mov edx, O_RDONLY | O_DIRECTORY | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
    js .Ldsr_done
    mov r14d, eax
    mov r15d, 1               # own_fd = 1

.Ldsr_loop:
    cmp r12, r13
    jae .Ldsr_close_if_own
    mov rax, [rbx + DirModel.order]
    mov eax, [rax + r12 * 4]
    shl rax, 5
    add rax, [rbx + DirModel.entries]
    mov rbp, rax
    test dword ptr [rbp + FileEntry.flags], FE_STAT_READY
    jnz .Ldsr_next

    mov edi, r14d
    mov esi, [rbp + FileEntry.name_off]
    add rsi, [rbx + DirModel.name_pool]
    mov rdx, rsp
    xor ecx, ecx
    call os_statat
    test rax, rax
    js .Ldsr_stat_fail
    mov rdi, rbx
    mov rsi, rbp
    mov rdx, rsp
    mov ecx, r14d
    call apply_stat_to_entry
    jmp .Ldsr_next

.Ldsr_stat_fail:
    or dword ptr [rbp + FileEntry.flags], FE_STAT_READY

.Ldsr_next:
    inc r12
    jmp .Ldsr_loop

.Ldsr_close_if_own:
    test r15d, r15d
    jz .Ldsr_done
    mov edi, r14d
    OS_CLOSE

.Ldsr_done:
    add rsp, FileStat._size + 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
.Ldsr_ret:
    ret

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
