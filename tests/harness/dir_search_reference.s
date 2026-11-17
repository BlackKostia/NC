# Frozen reference oracle: the hand-written asm that src/fs/dir_search*.c replaced (tests/test_c_dir_search.py diffs against it)
# src/fs/dir_search.s - Recursive directory search into DirModel virtual panel

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"
.equ SEARCH_MAX_DEPTH, 16
.equ SEARCH_MAX_HITS,  4096
.equ SEARCH_DENTS_SZ,  16384
.equ SEARCH_GREP_SZ,   32768
.struct 0
SearchCtx.model:     .space 8
SearchCtx.name_mask: .space 8
SearchCtx.grep_pat:  .space 8
SearchCtx.grep_len:  .space 8
SearchCtx.grep_buf:  .space 8
SearchCtx.hits:      .space 4
SearchCtx.has_glob:  .space 4
SearchCtx._size:

.extern DirModel_cancel_load
.extern ds_match_mask
.extern ds_grep_file
.extern mem_alloc
.extern mem_realloc
.extern mem_free
.extern mem_zero
.extern str_len
.extern str_copy
.extern utf8_display_width
.extern os_statat
.extern os_dir_read
.extern os_dir_next_ex

.section .rodata
.Ldsr_empty: .asciz ""
ds_dotdot_name: .asciz ".."

.section .text
.global ds_ensure_model_cap
.global ds_append_entry
.global ds_append_parent
.global ds_join_rel
.global dir_search_run

# int ds_ensure_model_cap(DirModel *m, size_t add_name_bytes)
ds_ensure_model_cap:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    mov rax, [rbx + DirModel.raw_count]
    cmp rax, [rbx + DirModel.raw_cap]
    jb .Ldemc_name
    mov rcx, [rbx + DirModel.raw_cap]
    shl rcx, 1
    cmp rcx, 128
    jae .Ldemc_cap_ok
    mov ecx, 128
.Ldemc_cap_ok:
    push rcx
    mov rdi, [rbx + DirModel.entries]
    mov rsi, rcx
    imul rsi, FileEntry._size
    call mem_realloc
    pop rcx
    test rax, rax
    jz .Ldemc_err
    mov [rbx + DirModel.entries], rax
    push rcx
    mov rdi, [rbx + DirModel.order]
    mov rsi, rcx
    shl rsi, 2
    call mem_realloc
    pop rcx
    test rax, rax
    jz .Ldemc_err
    mov [rbx + DirModel.order], rax
    mov [rbx + DirModel.raw_cap], rcx
.Ldemc_name:
    mov rax, [rbx + DirModel.name_used]
    add rax, r12
    cmp rax, [rbx + DirModel.name_cap]
    jbe .Ldemc_ok
    mov rcx, [rbx + DirModel.name_cap]
.Ldemc_ngrow:
    shl rcx, 1
    cmp rcx, 4096
    jae .Ldemc_nchk
    mov ecx, 4096
.Ldemc_nchk:
    cmp rcx, rax
    jb .Ldemc_ngrow
    push rcx
    mov rdi, [rbx + DirModel.name_pool]
    mov rsi, rcx
    call mem_realloc
    pop rcx
    test rax, rax
    jz .Ldemc_err
    mov [rbx + DirModel.name_pool], rax
    mov [rbx + DirModel.name_cap], rcx
.Ldemc_ok:
    xor eax, eax
    jmp .Ldemc_ret
.Ldemc_err:
    mov eax, -1
.Ldemc_ret:
    add rsp, 8
    pop r12
    pop rbx
    ret

# void ds_append_entry(DirModel *m, const char *rel_name, const FileStat *st)
ds_append_entry:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    call ds_append_entry__ds_ensure_model_cap
    call ds_append_entry__part2
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# ds_append_entry step: ds_ensure_model_cap (runs on the caller's frame)
ds_append_entry__ds_ensure_model_cap:
    lea rsp, [rsp - 8]
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, r12
    call str_len
    mov r14, rax
    mov rdi, rbx
    lea rsi, [r14 + 1]
    call ds_ensure_model_cap
    test eax, eax
.Lds_append_entry__ds_ensure_model_cap_ret:
    lea rsp, [rsp + 8]
    ret

# ds_append_entry step (runs on the caller's frame)
ds_append_entry__part2:
    lea rsp, [rsp - 8]
    js .Ldae_ret

    mov r8, [rbx + DirModel.name_used]
    mov rdi, [rbx + DirModel.name_pool]
    add rdi, r8
    mov rsi, r12
    lea rdx, [r14 + 1]
    call str_copy
    lea rax, [r8 + r14 + 1]
    mov [rbx + DirModel.name_used], rax

    mov r9, [rbx + DirModel.raw_count]
    mov r10, r9
    imul r10, FileEntry._size
    add r10, [rbx + DirModel.entries]

    mov rax, [r13 + FileStat.size]
    mov [r10 + FileEntry.size], rax
    mov rax, [r13 + FileStat.mtime]
    mov [r10 + FileEntry.mtime], rax
    mov eax, [r13 + FileStat.mode]
    mov [r10 + FileEntry.mode], eax
    mov [r10 + FileEntry.name_off], r8d
    mov [r10 + FileEntry.name_len], r14w
    mov byte ptr [r10 + FileEntry.ext_offset], 0

    mov ecx, FE_STAT_READY
    mov edx, eax
    and edx, S_IFMT
    cmp edx, S_IFDIR
    jne .Ldae_not_dir
    or ecx, FE_IS_DIR
    inc dword ptr [rbx + DirModel.dir_count]
    jmp .Ldae_flags_ok
.Ldae_not_dir:
    inc dword ptr [rbx + DirModel.file_count]
    mov rax, [r13 + FileStat.size]
    add [rbx + DirModel.total_bytes], rax
    test dword ptr [r13 + FileStat.mode], 0111
    jz .Ldae_flags_ok
    or ecx, FE_IS_EXEC
.Ldae_flags_ok:
    mov [r10 + FileEntry.flags], ecx
    mov rdi, r12
    push r9                           # utf8_display_width -> utf8_decode/_char_width clobber r8-r10
    push r10
    call utf8_display_width
    pop r10
    pop r9
    cmp eax, 255
    jbe .Ldae_dw_ok
    mov eax, 255
.Ldae_dw_ok:
    mov [r10 + FileEntry.disp_width], al

    mov rdx, [rbx + DirModel.order]
    mov rcx, [rbx + DirModel.count]
    mov [rdx + rcx*4], r9d
    inc qword ptr [rbx + DirModel.raw_count]
    inc qword ptr [rbx + DirModel.count]
.Ldae_ret:
.Lds_append_entry__part2_ret:
    lea rsp, [rsp + 8]
    ret

# int ds_append_parent(DirModel *m) -> 0, or < 0 when the entry could not be added
# Appends ".." as the newest entry the way the real directory loader does: FE_IS_PARENT (never
# hidden by the live filter, never selectable), has_dotdot = 1 (sort keeps it first), not a dir.
ds_append_parent:
    push rbx
    sub rsp, FileStat._size + 8
    mov rbx, rdi
    mov rdi, rsp
    mov esi, FileStat._size
    call mem_zero
    mov dword ptr [rsp + FileStat.mode], S_IFDIR | 0755
    mov rdi, rbx
    lea rsi, [rip + ds_dotdot_name]
    mov rdx, rsp
    call ds_append_entry
    test eax, eax
    js .Ldsp_ret
    mov rcx, [rbx + DirModel.raw_count]
    dec rcx
    imul rcx, FileEntry._size
    add rcx, [rbx + DirModel.entries]
    or dword ptr [rcx + FileEntry.flags], FE_IS_PARENT
    mov dword ptr [rbx + DirModel.has_dotdot], 1
    dec dword ptr [rbx + DirModel.dir_count]
    xor eax, eax
.Ldsp_ret:
    add rsp, FileStat._size + 8
    pop rbx
    ret

# void ds_join_rel(char *dst, const char *prefix, const char *name)
ds_join_rel:
    cmp byte ptr [rsi], 0
    jne .Ldjr_pref
    mov rsi, rdx
    mov edx, PATH_MAX
    jmp str_copy
.Ldjr_pref:
    push rdi
    push rdx
    sub rsp, 8
    mov edx, PATH_MAX - 2
    call str_copy
    pop r8
    pop rdx
    pop rdi
    add rdi, rax
    mov byte ptr [rdi], '/'
    inc rdi
    mov rsi, rdx
    mov edx, 256
    jmp str_copy

# int dir_search_run(DirModel *m, const char *root_path, const char *mask, const char *grep)
dir_search_run:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, SearchCtx._size + 8
    call dir_search_run__ds_reset_model
.Ldsr_free_grep:
    call dir_search_run__part2
    add rsp, SearchCtx._size + 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# dir_search_run step: ds_reset_model (runs on the caller's frame)
dir_search_run__ds_reset_model:
    lea rsp, [rsp - 8]
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx

    call ds_reset_model

    mov [rsp + SearchCtx.model + 16], rbx
    mov [rsp + SearchCtx.name_mask + 16], r13
    mov [rsp + SearchCtx.grep_pat + 16], r14
    mov dword ptr [rsp + SearchCtx.hits + 16], 0
    mov dword ptr [rsp + SearchCtx.has_glob + 16], 0
    mov qword ptr [rsp + SearchCtx.grep_len + 16], 0
    mov qword ptr [rsp + SearchCtx.grep_buf + 16], 0

    test r13, r13
    jz .Ldsr_chk_grep
.Ldsr_scan_mask:
    mov al, [r13]
    test al, al
    jz .Ldsr_chk_grep
    cmp al, '*'
    je .Ldsr_is_glob
    cmp al, '?'
    je .Ldsr_is_glob
    inc r13
    jmp .Ldsr_scan_mask
.Ldsr_is_glob:
    mov dword ptr [rsp + SearchCtx.has_glob + 16], 1

.Ldsr_chk_grep:
    test r14, r14
    jz .Ldsr_open_root
    cmp byte ptr [r14], 0
    je .Ldsr_open_root
    mov rdi, r14
    call str_len
    mov [rsp + SearchCtx.grep_len + 16], rax
    mov edi, SEARCH_GREP_SZ
    call mem_alloc
    mov [rsp + SearchCtx.grep_buf + 16], rax

.Ldsr_open_root:
    mov edi, AT_FDCWD
    mov rsi, r12
    mov edx, O_RDONLY | O_DIRECTORY | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
    js .Ldir_search_run__ds_reset_model_ret
    mov r13d, eax
    lea rdi, [rsp + 16]
    mov esi, r13d
    lea rdx, [rip + .Ldsr_empty]
    xor ecx, ecx
    call ds_walk_dir
    mov edi, r13d
    OS_CLOSE
    mov eax, [rsp + SearchCtx.hits + 16]

.Ldir_search_run__ds_reset_model_ret:
    lea rsp, [rsp + 8]
    ret

# dir_search_run step (runs on the caller's frame)
dir_search_run__part2:
    lea rsp, [rsp - 8]
    push rax
    mov rdi, [rsp + 8 + SearchCtx.grep_buf + 16]
    test rdi, rdi
    jz .Ldsr_no_gbuf
    call mem_free
.Ldsr_no_gbuf:
    pop rax
.Ldir_search_run__part2_ret:
    lea rsp, [rsp + 8]
    ret
