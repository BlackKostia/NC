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

.section .rodata
.Ldsr_empty: .asciz ""

.section .text
.global dir_search_run
.global ds_append_entry

.extern DirModel_cancel_load
.extern ds_match_mask
.extern ds_grep_file
.extern mem_alloc
.extern mem_realloc
.extern mem_free
.extern str_len
.extern str_copy
.extern utf8_display_width
.extern os_statat
.extern os_dir_read
.extern os_dir_next_ex

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
    call utf8_display_width
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
    add rsp, 8
    pop r14
    pop r13
    pop r12
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

# void ds_handle_dir(SearchCtx *ctx, int dirfd, const char *d_name, const char *rel_name, int depth)
ds_handle_dir:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, FileStat._size + 8
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    mov r15d, r8d

    mov rax, [rbx + SearchCtx.grep_pat]
    test rax, rax
    jz .Ldhd_name
    cmp byte ptr [rax], 0
    jne .Ldhd_rec
.Ldhd_name:
    mov rdi, r13
    mov rsi, [rbx + SearchCtx.name_mask]
    mov edx, [rbx + SearchCtx.has_glob]
    call ds_match_mask
    test eax, eax
    jz .Ldhd_rec
    mov edi, r12d
    mov rsi, r13
    mov rdx, rsp
    mov ecx, AT_SYMLINK_NOFOLLOW
    call os_statat
    test eax, eax
    js .Ldhd_rec
    mov rdi, [rbx + SearchCtx.model]
    mov rsi, r14
    mov rdx, rsp
    call ds_append_entry
    inc dword ptr [rbx + SearchCtx.hits]
.Ldhd_rec:
    cmp r15d, SEARCH_MAX_DEPTH
    jge .Ldhd_done
    mov edi, r12d
    mov rsi, r13
    mov edx, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
    js .Ldhd_done
    mov r12d, eax
    mov rdi, rbx
    mov esi, r12d
    mov rdx, r14
    lea ecx, [r15d + 1]
    call ds_walk_dir
    mov edi, r12d
    OS_CLOSE
.Ldhd_done:
    add rsp, FileStat._size + 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# void ds_handle_reg(SearchCtx *ctx, int dirfd, const char *d_name, const char *rel_name, FileStat *st_or_null)
ds_handle_reg:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, FileStat._size + 8
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    mov r15, r8
    test r15, r15
    jnz .Ldhr_chk
    mov edi, r12d
    mov rsi, r13
    mov rdx, rsp
    mov ecx, AT_SYMLINK_NOFOLLOW
    call os_statat
    test eax, eax
    js .Ldhr_done
    mov r15, rsp
.Ldhr_chk:
    mov rdi, r13
    mov rsi, [rbx + SearchCtx.name_mask]
    mov edx, [rbx + SearchCtx.has_glob]
    call ds_match_mask
    test eax, eax
    jz .Ldhr_done
    mov rax, [rbx + SearchCtx.grep_pat]
    test rax, rax
    jz .Ldhr_add
    cmp byte ptr [rax], 0
    je .Ldhr_add
    mov edi, r12d
    mov rsi, r13
    mov rdx, rax
    mov rcx, [rbx + SearchCtx.grep_len]
    mov r8, [rbx + SearchCtx.grep_buf]
    call ds_grep_file
    test eax, eax
    jz .Ldhr_done
.Ldhr_add:
    mov rdi, [rbx + SearchCtx.model]
    mov rsi, r14
    mov rdx, r15
    call ds_append_entry
    inc dword ptr [rbx + SearchCtx.hits]
.Ldhr_done:
    add rsp, FileStat._size + 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# void ds_walk_dir(SearchCtx *ctx, int dirfd, const char *rel_prefix, int depth)
ds_walk_dir:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, PATH_MAX + FileStat._size + 40
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov [rsp + 20], ecx

    mov edi, SEARCH_DENTS_SZ
    call mem_alloc
    test rax, rax
    jz .Ldwd_done
    mov r14, rax

.Ldwd_read_loop:
    cmp dword ptr [rbx + SearchCtx.hits], SEARCH_MAX_HITS
    jge .Ldwd_free
    mov edi, r12d
    mov rsi, r14
    mov edx, SEARCH_DENTS_SZ
    call os_dir_read
    test rax, rax
    jle .Ldwd_free
    mov [rsp + 8], rax
    mov qword ptr [rsp + 0], 0

.Ldwd_next:
    cmp dword ptr [rbx + SearchCtx.hits], SEARCH_MAX_HITS
    jge .Ldwd_free
    mov rdi, r14
    mov rsi, [rsp + 8]
    lea rdx, [rsp + 0]
    lea rcx, [rsp + 16]
    call os_dir_next_ex
    test rax, rax
    jz .Ldwd_read_loop
    mov r15, rax

    cmp byte ptr [r15], '.'
    jne .Ldwd_join
    cmp byte ptr [r15 + 1], 0
    je .Ldwd_next
    cmp byte ptr [r15 + 1], '.'
    jne .Ldwd_join
    cmp byte ptr [r15 + 2], 0
    je .Ldwd_next

.Ldwd_join:
    lea rdi, [rsp + 32 + FileStat._size]
    mov rsi, r13
    mov rdx, r15
    call ds_join_rel

    movzx eax, byte ptr [rsp + 16]
    cmp eax, PAL_DT_DIR
    je .Ldwd_dir
    cmp eax, PAL_DT_REG
    je .Ldwd_reg_nostat
    cmp eax, PAL_DT_UNKNOWN
    jne .Ldwd_next
    mov edi, r12d
    mov rsi, r15
    lea rdx, [rsp + 24]
    mov ecx, AT_SYMLINK_NOFOLLOW
    call os_statat
    test eax, eax
    js .Ldwd_next
    mov eax, [rsp + 24 + FileStat.mode]
    and eax, S_IFMT
    cmp eax, S_IFDIR
    je .Ldwd_dir
    cmp eax, S_IFREG
    jne .Ldwd_next
    lea r8, [rsp + 24]
    jmp .Ldwd_reg
.Ldwd_reg_nostat:
    xor r8d, r8d
.Ldwd_reg:
    mov rdi, rbx
    mov esi, r12d
    mov rdx, r15
    lea rcx, [rsp + 32 + FileStat._size]
    call ds_handle_reg
    jmp .Ldwd_next
.Ldwd_dir:
    mov rdi, rbx
    mov esi, r12d
    mov rdx, r15
    lea rcx, [rsp + 32 + FileStat._size]
    mov r8d, [rsp + 20]
    call ds_handle_dir
    jmp .Ldwd_next

.Ldwd_free:
    mov rdi, r14
    call mem_free
.Ldwd_done:
    add rsp, PATH_MAX + FileStat._size + 40
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

# void ds_reset_model(DirModel *m, const char *root_path)
ds_reset_model:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    call DirModel_cancel_load
    mov dword ptr [rbx + DirModel.flt_valid], 0
    mov dword ptr [rbx + DirModel.is_loading], 0
    mov dword ptr [rbx + DirModel.load_aborted], 0
    mov dword ptr [rbx + DirModel.huge_mode], 0
    mov dword ptr [rbx + DirModel.is_unsorted], 0
    mov dword ptr [rbx + DirModel.stats_complete], 1
    mov dword ptr [rbx + DirModel.virtual_mode], 1
    mov qword ptr [rbx + DirModel.count], 0
    mov qword ptr [rbx + DirModel.raw_count], 0
    mov qword ptr [rbx + DirModel.name_used], 0
    mov qword ptr [rbx + DirModel.total_bytes], 0
    mov dword ptr [rbx + DirModel.dir_count], 0
    mov dword ptr [rbx + DirModel.file_count], 0
    mov dword ptr [rbx + DirModel.has_dotdot], 0

    cmp byte ptr [r12], '/'
    jne .Ldrm_dotdot
    cmp byte ptr [r12 + 1], 0
    je .Ldrm_done
.Ldrm_dotdot:
    mov rdi, rbx
    mov esi, 3
    call ds_ensure_model_cap
    test eax, eax
    js .Ldrm_done
    mov rdx, [rbx + DirModel.name_pool]
    mov byte ptr [rdx + 0], '.'
    mov byte ptr [rdx + 1], '.'
    mov byte ptr [rdx + 2], 0
    mov qword ptr [rbx + DirModel.name_used], 3
    mov rax, [rbx + DirModel.entries]
    mov qword ptr [rax + FileEntry.size], 0
    mov qword ptr [rax + FileEntry.mtime], 0
    mov dword ptr [rax + FileEntry.mode], S_IFDIR | 0755
    mov dword ptr [rax + FileEntry.flags], FE_IS_DIR | FE_IS_PARENT | FE_STAT_READY
    mov dword ptr [rax + FileEntry.name_off], 0
    mov word ptr [rax + FileEntry.name_len], 2
    mov byte ptr [rax + FileEntry.disp_width], 2
    mov byte ptr [rax + FileEntry.ext_offset], 0
    mov rcx, [rbx + DirModel.order]
    mov dword ptr [rcx], 0
    mov qword ptr [rbx + DirModel.raw_count], 1
    mov qword ptr [rbx + DirModel.count], 1
    mov dword ptr [rbx + DirModel.has_dotdot], 1
.Ldrm_done:
    add rsp, 8
    pop r12
    pop rbx
    ret

# int dir_search_run(DirModel *m, const char *root_path, const char *mask, const char *grep)
dir_search_run:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, SearchCtx._size + 8
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx

    call ds_reset_model

    mov [rsp + SearchCtx.model], rbx
    mov [rsp + SearchCtx.name_mask], r13
    mov [rsp + SearchCtx.grep_pat], r14
    mov dword ptr [rsp + SearchCtx.hits], 0
    mov dword ptr [rsp + SearchCtx.has_glob], 0
    mov qword ptr [rsp + SearchCtx.grep_len], 0
    mov qword ptr [rsp + SearchCtx.grep_buf], 0

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
    mov dword ptr [rsp + SearchCtx.has_glob], 1

.Ldsr_chk_grep:
    test r14, r14
    jz .Ldsr_open_root
    cmp byte ptr [r14], 0
    je .Ldsr_open_root
    mov rdi, r14
    call str_len
    mov [rsp + SearchCtx.grep_len], rax
    mov edi, SEARCH_GREP_SZ
    call mem_alloc
    mov [rsp + SearchCtx.grep_buf], rax

.Ldsr_open_root:
    mov edi, AT_FDCWD
    mov rsi, r12
    mov edx, O_RDONLY | O_DIRECTORY | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
    js .Ldsr_free_grep
    mov r13d, eax
    mov rdi, rsp
    mov esi, r13d
    lea rdx, [rip + .Ldsr_empty]
    xor ecx, ecx
    call ds_walk_dir
    mov edi, r13d
    OS_CLOSE
    mov eax, [rsp + SearchCtx.hits]

.Ldsr_free_grep:
    push rax
    mov rdi, [rsp + 8 + SearchCtx.grep_buf]
    test rdi, rdi
    jz .Ldsr_no_gbuf
    call mem_free
.Ldsr_no_gbuf:
    pop rax
    add rsp, SearchCtx._size + 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
