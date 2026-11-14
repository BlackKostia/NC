# src/fs/dir_fuzzy.s - Fuzzy matching scorer & recursive tree collector
.intel_syntax noprefix

.include "pal.inc"
.include "config.inc"
.include "types.inc"

.equ FUZZY_MAX_DEPTH, 8

.section .text
.global fuzzy_score
.global dir_fuzzy_collect
.global fs_write_file

.extern sys_open
.extern sys_close
.extern os_dir_read
.extern os_dir_next_ex
.extern mem_alloc
.extern mem_free
.extern str_len
.extern str_copy

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
    mov rbx, rdi
    mov r12, rdx
    cmp byte ptr [rsi], 0
    jne .Ldj_pfx
    mov rsi, r12
    mov edx, PATH_MAX
    call str_copy
    pop r12
    pop rbx
    ret
.Ldj_pfx:
    mov edx, PATH_MAX
    call str_copy
    cmp rax, PATH_MAX - 2
    jae .Ldj_done
    cmp byte ptr [rbx + rax - 1], '/'
    je .Ldj_app
    mov byte ptr [rbx + rax], '/'
    inc rax
.Ldj_app:
    lea rdi, [rbx + rax]
    mov rsi, r12
    mov edx, PATH_MAX / 2
    call str_copy
.Ldj_done:
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

    mov edi, AT_FDCWD
    mov rsi, r12
    mov edx, O_RDONLY | O_DIRECTORY | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
    js .Ldw_ret
    mov [rsp + PATH_MAX * 2], eax

.Ldw_read:
    mov edi, [rsp + PATH_MAX * 2]
    mov rsi, [rbx + 32]
    mov edx, 32768
    call os_dir_read
    test rax, rax
    jle .Ldw_close
    mov [rsp + PATH_MAX * 2 + 8], rax
    mov qword ptr [rsp + PATH_MAX * 2 + 16], 0

.Ldw_ent:
    mov eax, [rbx + 24]
    cmp eax, [rbx + 28]
    jge .Ldw_close
    mov rdi, [rbx + 32]
    mov rsi, [rsp + PATH_MAX * 2 + 8]
    lea rdx, [rsp + PATH_MAX * 2 + 16]
    lea rcx, [rsp + PATH_MAX * 2 + 24]
    lea r8, [rsp + PATH_MAX * 2 + 32]
    call os_dir_next_ex
    test rax, rax
    jz .Ldw_read
    mov r15, rax
    mov rdi, r15
    call dfc_skip_name
    test eax, eax
    jnz .Ldw_ent

    lea rdi, [rsp + PATH_MAX]
    mov rsi, r13
    mov rdx, r15
    call dfc_join

    mov rdi, rbx
    lea rsi, [rsp + PATH_MAX]
    mov edx, [rsp + PATH_MAX * 2 + 24]
    call dfc_push_item

    cmp dword ptr [rsp + PATH_MAX * 2 + 24], PAL_DT_DIR
    jne .Ldw_ent
    mov rdi, rsp
    mov rsi, r12
    mov rdx, r15
    call dfc_join
    mov rdi, rbx
    mov rsi, rsp
    lea rdx, [rsp + PATH_MAX]
    lea ecx, [r14d + 1]
    call dfc_walk
    jmp .Ldw_ent

.Ldw_close:
    mov edi, [rsp + PATH_MAX * 2]
    OS_CLOSE
.Ldw_ret:
    add rsp, PATH_MAX * 2 + 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# int dir_fuzzy_collect(const char *root, char *pool, int pool_cap, void *items, int max_items)
dir_fuzzy_collect:
    push rbx
    sub rsp, 48
    mov rbx, rdi
    mov [rsp], rsi
    mov dword ptr [rsp + 8], 0
    mov [rsp + 12], edx
    mov [rsp + 16], rcx
    mov dword ptr [rsp + 24], 0
    mov [rsp + 28], r8d
    mov edi, 32768
    call mem_alloc
    test rax, rax
    jz .Ldfc_fail
    mov [rsp + 32], rax
    mov rdi, rsp
    mov rsi, rbx
    lea rdx, [rip + .Ldfc_empty]
    xor ecx, ecx
    call dfc_walk
    mov rdi, [rsp + 32]
    call mem_free
    mov eax, [rsp + 24]
    jmp .Ldfc_ret
.Ldfc_fail:
    xor eax, eax
.Ldfc_ret:
    add rsp, 48
    pop rbx
    ret

# int fs_write_file(const char *path, const void *buf, uint64_t len) -> 0 ok, -1 err
fs_write_file:
    push rbx; push r12; push r13
    mov r12, rsi; mov r13, rdx
    mov rsi, rdi; mov edi, AT_FDCWD
    mov edx, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC
    mov r10d, 0644; OS_OPENAT
    test rax, rax; js .Lfwf_err
    mov ebx, eax
    mov rdi, rbx; mov rsi, r12; mov rdx, r13
    OS_WRITE
    push rax
    mov edi, ebx; OS_CLOSE
    pop rax
    test rax, rax; js .Lfwf_err
    xor eax, eax; jmp .Lfwf_ret
.Lfwf_err:
    mov eax, -1
.Lfwf_ret:
    pop r13; pop r12; pop rbx
    ret

.section .rodata
.Ldfc_empty: .asciz ""
