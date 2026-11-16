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

.section .bss

.align 8
g_huge_threshold: .space 8
g_stream_batch:   .space 8

.section .rodata
str_DirModel:   .asciz "DirModel"
str_dotdot:     .asciz ".."
str_slash:      .asciz "/"
str_env_huge:   .asciz "DUOP_HUGE_THRESHOLD="
str_env_batch:  .asciz "DUOP_STREAM_BATCH="

.section .text
.global DirModel_vtbl
.global DirModel_init_env
.global DirModel_new
.global alloc_initial_arrays
.global DirModel_invalidate_stats
.global reset_entry_stats
.global close_stream_resources
.global DirModel_dtor
.global DirModel_entry_name
.global g_huge_threshold
.global g_stream_batch

DirModel_vtbl:
    OBJECT_VTBL_SLOTS str_DirModel, Object_vtbl, DirModel._size, DirModel_dtor

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
    mov rdi, [rbx + DirModel.entries]; call mem_free
    mov rdi, [rbx + DirModel.order]; call mem_free
    mov rdi, [rbx + DirModel.name_pool]; call mem_free
    mov qword ptr [rbx + DirModel.entries], 0
    mov qword ptr [rbx + DirModel.order], 0
    mov qword ptr [rbx + DirModel.name_pool], 0
    mov qword ptr [rbx + DirModel.raw_cap], 0
    mov qword ptr [rbx + DirModel.name_cap], 0
    mov eax, -ENOMEM
    pop rbx
    ret

# ==============================================================================
# void DirModel_invalidate_stats(DirModel *this)
# File contents/attributes changed (watch event): drop cached stats so visible rows re-stat
# lazily; selections stay untouched.
# ==============================================================================
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
    push rbx; mov rbx, rdi
    call close_stream_resources
    mov rdi, rbx; call git_free_ctx
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
