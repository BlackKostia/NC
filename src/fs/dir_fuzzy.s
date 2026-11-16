# src/fs/dir_fuzzy.s - Fuzzy matching scorer & recursive tree collector

.intel_syntax noprefix
.include "pal.inc"
.include "config.inc"
.include "types.inc"
.equ FUZZY_MAX_DEPTH, 8
.extern sys_open
.extern sys_close
.extern os_dir_read
.extern os_dir_next_ex
.extern mem_alloc
.extern mem_free
.extern str_len
.extern str_copy

.section .text
.global fuzzy_score
.global dfc_walk

# int fuzzy_score(const char *query, const char *cand, uint64_t *out_mask)
fuzzy_score:
    push rbx
    push r12
    push r13
    push r14
    xor eax, eax
    test rdx, rdx
    jz .Lfs_no_z
    mov qword ptr [rdx], 0
.Lfs_no_z:
    cmp byte ptr [rdi], 0
    je .Lfs_ret               # empty query -> score 0
    xor r8d, r8d              # score
    xor r9d, r9d              # cand idx
    xor r10d, r10d            # prev_matched = 0
    xor r11d, r11d            # mask
    mov rbx, rdi
    mov r12, rsi
.Lfs_loop:
    mov al, [rbx]
    test al, al
    jz .Lfs_done
    cmp al, 'A'
    jb .Lfs_ql
    cmp al, 'Z'
    ja .Lfs_ql
    add al, 32
.Lfs_ql:
    mov cl, [r12]
    test cl, cl
    jz .Lfs_fail
    cmp cl, 'A'
    jb .Lfs_cl
    cmp cl, 'Z'
    ja .Lfs_cl
    add cl, 32
.Lfs_cl:
    cmp al, cl
    jne .Lfs_miss
    add r8d, 2
    test r10d, r10d
    jz .Lfs_chk_bnd
    add r8d, 8                # consecutive bonus
.Lfs_chk_bnd:
    test r9d, r9d
    jz .Lfs_bnd_hit
    mov r13b, [r12 - 1]
    cmp r13b, '/'
    je .Lfs_bnd_hit
    cmp r13b, '_'
    je .Lfs_bnd_hit
    cmp r13b, '-'
    je .Lfs_bnd_hit
    cmp r13b, '.'
    je .Lfs_bnd_hit
    cmp r13b, ' '
    jne .Lfs_set_mask
.Lfs_bnd_hit:
    add r8d, 6                # word-boundary bonus
.Lfs_set_mask:
    cmp r9d, 64
    jae .Lfs_adv
    mov r14d, 1
    mov ecx, r9d
    shl r14, cl
    or r11, r14
.Lfs_adv:
    mov r10d, 1
    inc rbx
    inc r12
    inc r9d
    jmp .Lfs_loop
.Lfs_miss:
    xor r10d, r10d
    inc r12
    inc r9d
    jmp .Lfs_loop
.Lfs_done:
    mov eax, r9d
    shr eax, 2
    sub r8d, eax
    cmp r8d, 1
    jge .Lfs_ok
    mov r8d, 1
.Lfs_ok:
    test rdx, rdx
    jz .Lfs_ret_sc
    mov [rdx], r11
.Lfs_ret_sc:
    mov eax, r8d
    jmp .Lfs_ret
.Lfs_fail:
    mov eax, -1
.Lfs_ret:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Helper: void dfc_join(char *dst, const char *pfx, const char *name)
dfc_join:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rdx
    mov r13, rsi
    cmp byte ptr [r13], 0
    jne .Ldj_pfx
    mov rdi, r12
    call str_len
    cmp rax, PATH_MAX
    jae .Ldj_err
    mov rdi, rbx
    mov rsi, r12
    mov edx, PATH_MAX
    call str_copy
    xor eax, eax
    jmp .Ldj_ret
.Ldj_pfx:
    mov rdi, r13
    call str_len
    cmp rax, PATH_MAX - 2
    jae .Ldj_err
    mov rdi, rbx
    mov rsi, r13
    mov edx, PATH_MAX
    call str_copy
    test rax, rax
    jz .Ldj_need_sep
    cmp byte ptr [rbx + rax - 1], '/'
    je .Ldj_chk_rem
.Ldj_need_sep:
    cmp rax, PATH_MAX - 2
    jae .Ldj_err
    mov byte ptr [rbx + rax], '/'
    inc rax
.Ldj_chk_rem:
    mov r13, rax
    mov rdi, r12
    call str_len
    mov ecx, PATH_MAX - 1
    sub rcx, r13
    cmp rax, rcx
    ja .Ldj_err
    lea rdi, [rbx + r13]
    mov rsi, r12
    lea rdx, [rcx + 1]
    call str_copy
    xor eax, eax
    jmp .Ldj_ret
.Ldj_err:
    mov eax, -1
.Ldj_ret:
    pop r13
    pop r12
    pop rbx
    ret

# Helper: int dfc_skip_name(const char *name) -> 1 if ., .., or .git
dfc_skip_name:
    cmp byte ptr [rdi], '.'
    jne .Ldsn_no
    cmp byte ptr [rdi + 1], 0
    je .Ldsn_yes
    cmp byte ptr [rdi + 1], '.'
    jne .Ldsn_git
    cmp byte ptr [rdi + 2], 0
    je .Ldsn_yes
.Ldsn_git:
    cmp byte ptr [rdi + 1], 'g'
    jne .Ldsn_no
    cmp byte ptr [rdi + 2], 'i'
    jne .Ldsn_no
    cmp byte ptr [rdi + 3], 't'
    jne .Ldsn_no
    cmp byte ptr [rdi + 4], 0
    je .Ldsn_yes
.Ldsn_no:
    xor eax, eax
    ret
.Ldsn_yes:
    mov eax, 1
    ret

# Helper: void dfc_push_item(ctx *ctx, const char *rel, int dtype)
dfc_push_item:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov rdi, r12
    call str_len
    lea rcx, [rax + 1]
    mov eax, [rbx + 8]
    lea edx, [rax + rcx]
    cmp edx, [rbx + 12]
    ja .Ldpi_done
    mov r8, [rbx]
    add r8, rax
    mov [rbx + 8], edx
    mov rdi, r8
    mov rsi, r12
    mov rdx, rcx
    push r8
    call str_copy
    pop r8
    mov eax, [rbx + 24]
    inc dword ptr [rbx + 24]
    shl rax, 4
    add rax, [rbx + 16]
    mov [rax], r8
    xor edx, edx
    cmp r13d, PAL_DT_DIR
    sete dl
    mov [rax + 8], edx
    mov dword ptr [rax + 12], 0
.Ldpi_done:
    pop r13
    pop r12
    pop rbx
    ret

# Internal recursive walker:
# void dfc_walk(ctx *ctx, const char *dir_abs, const char *rel_pfx, int depth)
dfc_walk:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, PATH_MAX * 2 + 48
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14d, ecx
    cmp r14d, FUZZY_MAX_DEPTH
    jge .Ldw_ret
    mov eax, [rbx + 24]
    cmp eax, [rbx + 28]
    jge .Ldw_ret

    call dfc_walk__part1
    call dfc_walk__d_type_byte
.Ldw_ret:
    add rsp, PATH_MAX * 2 + 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# dfc_walk step (runs on the caller's frame)
dfc_walk__part1:
    lea rsp, [rsp - 8]
    mov edi, AT_FDCWD
    mov rsi, r12
    mov edx, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
.Ldfc_walk__part1_ret:
    lea rsp, [rsp + 8]
    ret

# dfc_walk step: d_type is byte (runs on the caller's frame)
dfc_walk__d_type_byte:
    lea rsp, [rsp - 8]
    js .Ldfc_walk__d_type_byte_ret
    mov [rsp + PATH_MAX * 2 + 16], eax

.Ldw_read:
    mov edi, [rsp + PATH_MAX * 2 + 16]
    mov eax, r14d
    shl eax, 13
    mov rsi, [rbx + 32]
    add rsi, rax
    mov edx, 8192
    call os_dir_read
    test rax, rax
    jle .Ldw_close
    mov [rsp + PATH_MAX * 2 + 8 + 16], rax
    mov qword ptr [rsp + PATH_MAX * 2 + 16 + 16], 0

.Ldw_ent:
    mov eax, [rbx + 24]
    cmp eax, [rbx + 28]
    jge .Ldw_close
    mov eax, r14d
    shl eax, 13
    mov rdi, [rbx + 32]
    add rdi, rax
    mov rsi, [rsp + PATH_MAX * 2 + 8 + 16]
    lea rdx, [rsp + PATH_MAX * 2 + 16 + 16]
    lea rcx, [rsp + PATH_MAX * 2 + 24 + 16]
    lea r8, [rsp + PATH_MAX * 2 + 32 + 16]
    call os_dir_next_ex
    test rax, rax
    jz .Ldw_read
    mov r15, rax
    mov rdi, r15
    call dfc_skip_name
    test eax, eax
    jnz .Ldw_ent

    lea rdi, [rsp + PATH_MAX + 16]
    mov rsi, r13
    mov rdx, r15
    call dfc_join
    test eax, eax
    js .Ldw_ent

    mov rdi, rbx
    lea rsi, [rsp + PATH_MAX + 16]
    movzx edx, byte ptr [rsp + PATH_MAX * 2 + 24 + 16]  # d_type is a byte
    call dfc_push_item

    cmp byte ptr [rsp + PATH_MAX * 2 + 24 + 16], PAL_DT_DIR
    jne .Ldw_ent
    lea rdi, [rsp + 16]
    mov rsi, r12
    mov rdx, r15
    call dfc_join
    test eax, eax
    js .Ldw_ent
    mov rdi, rbx
    lea rsi, [rsp + 16]
    lea rdx, [rsp + PATH_MAX + 16]
    lea ecx, [r14d + 1]
    call dfc_walk
    jmp .Ldw_ent

.Ldw_close:
    mov edi, [rsp + PATH_MAX * 2 + 16]
    OS_CLOSE
.Ldfc_walk__d_type_byte_ret:
    lea rsp, [rsp + 8]
    ret
