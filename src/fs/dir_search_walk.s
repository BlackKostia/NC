# src/fs/dir_search.s - Recursive directory search into DirModel virtual panel — dir search walk (split from dir_search.s)

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
.extern str_len
.extern str_copy
.extern utf8_display_width
.extern os_statat
.extern os_dir_read
.extern os_dir_next_ex

.section .text
.global ds_walk_dir

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
    xor ecx, ecx                      # OS_STAT_NOFOLLOW
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
    xor ecx, ecx                      # OS_STAT_NOFOLLOW
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
    call ds_walk_dir__part1
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
    call ds_walk_dir__os_dir_next_ex
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
    call ds_walk_dir__ds_join_rel
    je .Ldwd_dir
    cmp eax, PAL_DT_REG
    je .Ldwd_reg_nostat
    cmp eax, PAL_DT_UNKNOWN
    jne .Ldwd_next
    call ds_walk_dir__os_statat
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
    call ds_walk_dir__ds_handle_dir
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

# ds_walk_dir step (runs on the caller's frame)
ds_walk_dir__part1:
    lea rsp, [rsp - 8]
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov [rsp + 20 + 16], ecx

    mov edi, SEARCH_DENTS_SZ
    call mem_alloc
    test rax, rax
.Lds_walk_dir__part1_ret:
    lea rsp, [rsp + 8]
    ret

# ds_walk_dir step: os_dir_next_ex (runs on the caller's frame)
ds_walk_dir__os_dir_next_ex:
    lea rsp, [rsp - 8]
    mov rdi, r14
    mov rsi, [rsp + 8 + 16]
    lea rdx, [rsp + 0 + 16]
    lea rcx, [rsp + 16 + 16]
    call os_dir_next_ex
    test rax, rax
.Lds_walk_dir__os_dir_next_ex_ret:
    lea rsp, [rsp + 8]
    ret

# ds_walk_dir step: ds_join_rel (runs on the caller's frame)
ds_walk_dir__ds_join_rel:
    lea rsp, [rsp - 8]
    lea rdi, [rsp + 32 + FileStat._size + 16]
    mov rsi, r13
    mov rdx, r15
    call ds_join_rel

    movzx eax, byte ptr [rsp + 16 + 16]
    cmp eax, PAL_DT_DIR
.Lds_walk_dir__ds_join_rel_ret:
    lea rsp, [rsp + 8]
    ret

# ds_walk_dir step: os_statat (runs on the caller's frame)
ds_walk_dir__os_statat:
    lea rsp, [rsp - 8]
    mov edi, r12d
    mov rsi, r15
    lea rdx, [rsp + 24 + 16]
    mov ecx, AT_SYMLINK_NOFOLLOW
    call os_statat
    test eax, eax
.Lds_walk_dir__os_statat_ret:
    lea rsp, [rsp + 8]
    ret

# ds_walk_dir step: ds_handle_dir (runs on the caller's frame)
ds_walk_dir__ds_handle_dir:
    lea rsp, [rsp - 8]
    mov rdi, rbx
    mov esi, r12d
    mov rdx, r15
    lea rcx, [rsp + 32 + FileStat._size + 16]
    mov r8d, [rsp + 20 + 16]
    call ds_handle_dir
.Lds_walk_dir__ds_handle_dir_ret:
    lea rsp, [rsp + 8]
    ret
