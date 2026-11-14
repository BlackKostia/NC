# src/fs/git_status.s - Git branch & porcelain v1 status integration
.intel_syntax noprefix

.include "pal.inc"
.include "classes.inc"

.equ GIT_MAX_ENTRIES, 512
.equ GENT_SIZE,       260     # name[256] + status(1) + pad(3)
.equ GCTX_SIZE,       80      # branch[64] + count(4) + pad(4) + entries(8)
.equ GIT_BUF_SIZE,    65536

.section .rodata
git_bin:       .asciz "/usr/bin/git"
git_arg_nolck: .asciz "--no-optional-locks"
git_arg_c:     .asciz "-C"
git_arg_stat:  .asciz "status"
git_arg_porc:  .asciz "--porcelain=v1"
git_arg_z:     .asciz "-z"
git_arg_b:     .asciz "-b"
git_devnull:   .asciz "/dev/null"
git_env_path:  .asciz "PATH=/usr/bin:/bin"
git_env_lc:    .asciz "LC_ALL=C"
git_no_comm:   .asciz "No commits yet on "
git_dot_git:   .asciz "/.git"
git_empty:     .asciz ""

.section .text
.global git_refresh
.global git_free_ctx
.global git_lookup
.global git_branch

.extern mem_alloc
.extern mem_free
.extern mem_zero
.extern str_cmp
.extern str_copy
.extern str_cat
.extern str_len
.extern os_statat

# void git_free_ctx(DirModel *dm)
git_free_ctx:
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + DirModel.git_ctx]
    test rdi, rdi
    jz .Lgfc_done
    push rdi
    mov rdi, [rdi + 72]
    test rdi, rdi
    jz .Lgfc_ctx
    call mem_free
.Lgfc_ctx:
    pop rdi
    call mem_free
    mov qword ptr [rbx + DirModel.git_ctx], 0
.Lgfc_done:
    pop rbx
    ret

# int git_spawn_status(const char *dir, char *out_buf, int buf_cap) -> bytes or -1
git_spawn_status:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, 128              # [0..7]=pipefd, [8..87]=argv, [88..111]=envp, [112]=status
    mov r12, rdi              # dir
    mov r13, rsi              # out_buf
    mov r14d, edx             # buf_cap

    mov rdi, rsp
    mov esi, O_CLOEXEC
    OS_PIPE2
    test rax, rax
    js .Lgss_err

    OS_FORK
    test rax, rax
    js .Lgss_fork_err
    jnz .Lgss_parent

    # Child process
    mov edi, [rsp + 4]        # pipefd[1]
    mov esi, 1                # stdout
    OS_DUP2
    mov edi, [rsp + 0]
    OS_CLOSE
    mov edi, [rsp + 4]
    OS_CLOSE

    mov edi, AT_FDCWD
    lea rsi, [rip + git_devnull]
    mov edx, O_WRONLY
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
    js .Lgss_exec
    push rax
    mov edi, eax
    mov esi, 2                # stderr
    OS_DUP2
    pop rdi
    OS_CLOSE

.Lgss_exec:
    lea rax, [rip + git_bin];       mov [rsp + 8], rax
    lea rcx, [rip + git_arg_nolck]; mov [rsp + 16], rcx
    lea rcx, [rip + git_arg_c];     mov [rsp + 24], rcx
    mov [rsp + 32], r12
    lea rcx, [rip + git_arg_stat];  mov [rsp + 40], rcx
    lea rcx, [rip + git_arg_porc];  mov [rsp + 48], rcx
    lea rcx, [rip + git_arg_z];     mov [rsp + 56], rcx
    lea rcx, [rip + git_arg_b];     mov [rsp + 64], rcx
    mov qword ptr [rsp + 72], 0

    lea rcx, [rip + git_env_path];  mov [rsp + 88], rcx
    lea rcx, [rip + git_env_lc];    mov [rsp + 96], rcx
    mov qword ptr [rsp + 104], 0

    mov rdi, rax
    lea rsi, [rsp + 8]
    lea rdx, [rsp + 88]
    OS_EXECVE
    mov edi, 127
    OS_EXIT

.Lgss_parent:
    mov rbx, rax              # child pid
    mov edi, [rsp + 4]
    OS_CLOSE

    xor r15d, r15d            # total read
    dec r14d                  # leave room for NUL
.Lgss_rd:
    cmp r15d, r14d
    jge .Lgss_rd_done
    mov edi, [rsp + 0]
    lea rsi, [r13 + r15]
    mov edx, r14d
    sub edx, r15d
    OS_READ
    cmp rax, -EINTR
    je .Lgss_rd
    test rax, rax
    jle .Lgss_rd_done
    add r15d, eax
    jmp .Lgss_rd
.Lgss_rd_done:
    mov edi, [rsp + 0]
    OS_CLOSE

.Lgss_wait:
    mov rdi, rbx
    lea rsi, [rsp + 112]
    xor edx, edx
    xor r10d, r10d
    OS_WAIT4
    cmp rax, -EINTR
    je .Lgss_wait
    cmp dword ptr [rsp + 112], 0
    jne .Lgss_err
    mov byte ptr [r13 + r15], 0
    mov eax, r15d
    jmp .Lgss_ret

.Lgss_fork_err:
    mov edi, [rsp + 0]; OS_CLOSE
    mov edi, [rsp + 4]; OS_CLOSE
.Lgss_err:
    mov eax, -1
.Lgss_ret:
    add rsp, 128
    pop r15; pop r14; pop r13; pop r12; pop rbx
    ret

# void git_parse_branch(GitCtx *ctx, const char **p_cur, const char *end)
git_parse_branch:
    mov r8, [rsi]
    cmp r8, rdx
    jae .Lgpb_done
    cmp byte ptr [r8], '#'
    jne .Lgpb_done
    cmp byte ptr [r8 + 1], '#'
    jne .Lgpb_done
    cmp byte ptr [r8 + 2], ' '
    jne .Lgpb_done
    add r8, 3
    # Check "No commits yet on "
    lea r9, [rip + git_no_comm]
    xor ecx, ecx
.Lgpb_nc:
    mov al, [r9 + rcx]
    test al, al
    jz .Lgpb_nc_hit
    cmp [r8 + rcx], al
    jne .Lgpb_copy
    inc ecx
    jmp .Lgpb_nc
.Lgpb_nc_hit:
    add r8, rcx
.Lgpb_copy:
    xor ecx, ecx
.Lgpb_cloop:
    cmp r8, rdx
    jae .Lgpb_cterm
    mov al, [r8]
    test al, al
    jz .Lgpb_skip
    cmp al, 10
    je .Lgpb_skip
    cmp al, '.'
    jne .Lgpb_put
    cmp byte ptr [r8 + 1], '.'
    je .Lgpb_skip
.Lgpb_put:
    cmp ecx, 63
    jge .Lgpb_adv
    mov [rdi + rcx], al
    inc ecx
.Lgpb_adv:
    inc r8
    jmp .Lgpb_cloop
.Lgpb_skip:
    cmp r8, rdx
    jae .Lgpb_cterm
    cmp byte ptr [r8], 0
    je .Lgpb_nul
    inc r8
    jmp .Lgpb_skip
.Lgpb_nul:
    inc r8
.Lgpb_cterm:
    mov byte ptr [rdi + rcx], 0
    mov [rsi], r8
.Lgpb_done:
    ret

# void git_parse_output(GitCtx *ctx, const char *buf, int len)
git_parse_output:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, 16               # [rsp+0] = cur ptr
    mov rbx, rdi              # ctx
    mov [rsp], rsi
    movsxd r12, edx
    add r12, rsi              # end

    mov rdi, rbx
    mov rsi, rsp
    mov rdx, r12
    call git_parse_branch

.Lgpo_loop:
    mov r13, [rsp]
    lea rax, [r13 + 4]
    cmp rax, r12
    jae .Lgpo_done
    movzx r14d, byte ptr [r13]      # X
    movzx r15d, byte ptr [r13 + 1]  # Y
    # Pick display char in r14d
    cmp r14d, '?'
    je .Lgpo_st_ok
    cmp r15d, ' '
    je .Lgpo_st_ok
    test r15d, r15d
    jz .Lgpo_st_ok
    mov r14d, r15d
.Lgpo_st_ok:
    mov r8, r13
    add r8, 3                 # path start
    # Advance r13 to past NUL
    mov r13, r8
.Lgpo_nul1:
    cmp r13, r12
    jae .Lgpo_save_cur
    cmp byte ptr [r13], 0
    je .Lgpo_got_nul1
    inc r13
    jmp .Lgpo_nul1
.Lgpo_got_nul1:
    inc r13
    # If R or C, skip second NUL-terminated path
    mov al, [r8 - 3]
    cmp al, 'R'
    je .Lgpo_skip2
    cmp al, 'C'
    jne .Lgpo_save_cur
.Lgpo_skip2:
    cmp r13, r12
    jae .Lgpo_save_cur
    cmp byte ptr [r13], 0
    je .Lgpo_got_nul2
    inc r13
    jmp .Lgpo_skip2
.Lgpo_got_nul2:
    inc r13
.Lgpo_save_cur:
    mov [rsp], r13

    mov eax, [rbx + 64]
    cmp eax, GIT_MAX_ENTRIES
    jge .Lgpo_loop
    imul rax, GENT_SIZE
    add rax, [rbx + 72]
    # Copy up to first '/' or NUL (max 255)
    xor ecx, ecx
.Lgpo_cp:
    cmp ecx, 255
    jge .Lgpo_cp_end
    mov dl, [r8 + rcx]
    test dl, dl
    jz .Lgpo_cp_end
    cmp dl, '/'
    je .Lgpo_cp_end
    mov [rax + rcx], dl
    inc ecx
    jmp .Lgpo_cp
.Lgpo_cp_end:
    mov byte ptr [rax + rcx], 0
    mov [rax + 256], r14b
    inc dword ptr [rbx + 64]
    jmp .Lgpo_loop
.Lgpo_done:
    add rsp, 16
    pop r15; pop r14; pop r13; pop r12; pop rbx
    ret

# int git_has_repo(const char *dir) -> 1 if .git found in dir or ancestor, 0 else
git_has_repo:
    push rbx; push r12
    sub rsp, PATH_MAX * 2 + FileStat._size
    mov rbx, rsp              # cur dir
    lea r12, [rsp + PATH_MAX] # probe buf
    mov rsi, rdi; mov rdi, rbx; mov edx, PATH_MAX; call str_copy
.Lghr_loop:
    mov rdi, r12; mov rsi, rbx; mov edx, PATH_MAX; call str_copy
    mov rdi, r12; call str_len
    cmp rax, 1; jne .Lghr_cat
    cmp byte ptr [r12], '/'; jne .Lghr_cat
    mov byte ptr [r12], 0     # avoid "//.git"
.Lghr_cat:
    mov rdi, r12; lea rsi, [rip + git_dot_git]; mov edx, PATH_MAX; call str_cat
    mov edi, AT_FDCWD; mov rsi, r12; lea rdx, [rsp + PATH_MAX * 2]; xor ecx, ecx
    call os_statat
    test rax, rax
    jz .Lghr_yes
    mov rdi, rbx; call str_len
    cmp rax, 1; jle .Lghr_no
    dec rax
.Lghr_strip:
    test rax, rax; jz .Lghr_no
    cmp byte ptr [rbx + rax], '/'; je .Lghr_cut
    dec rax; jmp .Lghr_strip
.Lghr_cut:
    test rax, rax; jz .Lghr_root
    mov byte ptr [rbx + rax], 0
    jmp .Lghr_loop
.Lghr_root:
    mov byte ptr [rbx + 1], 0
    jmp .Lghr_loop
.Lghr_yes:
    mov eax, 1; jmp .Lghr_ret
.Lghr_no:
    xor eax, eax
.Lghr_ret:
    add rsp, PATH_MAX * 2 + FileStat._size
    pop r12; pop rbx
    ret

# void git_refresh(DirModel *dm)
git_refresh:
    push rbx; push r12; push r13
    mov rbx, rdi
    cmp dword ptr [rbx + DirModel.virtual_mode], 0
    jne .Lgr_done
    lea rdi, [rbx + DirModel.path]
    call git_has_repo
    test eax, eax
    jz .Lgr_clear

    mov r12, [rbx + DirModel.git_ctx]
    test r12, r12
    jnz .Lgr_have_ctx
    mov edi, GCTX_SIZE
    call mem_alloc
    test rax, rax
    jz .Lgr_done
    mov r12, rax
    mov rdi, r12; mov esi, GCTX_SIZE; call mem_zero
    mov edi, GIT_MAX_ENTRIES * GENT_SIZE
    call mem_alloc
    test rax, rax
    jz .Lgr_free_ctx
    mov [r12 + 72], rax
    mov [rbx + DirModel.git_ctx], r12
.Lgr_have_ctx:
    mov byte ptr [r12], 0
    mov dword ptr [r12 + 64], 0

    mov edi, GIT_BUF_SIZE
    call mem_alloc
    test rax, rax
    jz .Lgr_done
    mov r13, rax

    lea rdi, [rbx + DirModel.path]
    mov rsi, r13
    mov edx, GIT_BUF_SIZE
    call git_spawn_status
    test eax, eax
    jle .Lgr_free_buf

    mov rdi, r12
    mov rsi, r13
    mov edx, eax
    call git_parse_output

.Lgr_free_buf:
    mov rdi, r13
    call mem_free
    jmp .Lgr_done
.Lgr_free_ctx:
    mov rdi, r12
    call mem_free
    jmp .Lgr_done
.Lgr_clear:
    mov r12, [rbx + DirModel.git_ctx]
    test r12, r12; jz .Lgr_done
    mov byte ptr [r12], 0
    mov dword ptr [r12 + 64], 0
.Lgr_done:
    xor eax, eax
    pop r13; pop r12; pop rbx
    ret

# int git_lookup(DirModel *dm, const char *name) -> status char or 0
git_lookup:
    test rdi, rdi; jz .Lgl_zero
    test rsi, rsi; jz .Lgl_zero
    cmp dword ptr [rdi + DirModel.virtual_mode], 0
    jne .Lgl_zero
    mov rcx, [rdi + DirModel.git_ctx]
    test rcx, rcx; jz .Lgl_zero
    mov edx, [rcx + 64]
    test edx, edx; jz .Lgl_zero

    push rbx; push r12; push r13; push r14
    mov r12, [rcx + 72]
    mov r13d, edx
    mov r14, rsi
    xor ebx, ebx
.Lgl_loop:
    cmp ebx, r13d; jge .Lgl_nf
    imul rax, rbx, GENT_SIZE
    add rax, r12
    mov rdi, rax; mov rsi, r14
    push rax
    call str_cmp
    pop rcx
    test eax, eax
    jz .Lgl_hit
    inc ebx; jmp .Lgl_loop
.Lgl_hit:
    movzx eax, byte ptr [rcx + 256]
    pop r14; pop r13; pop r12; pop rbx
    ret
.Lgl_nf:
    pop r14; pop r13; pop r12; pop rbx
.Lgl_zero:
    xor eax, eax
    ret

# const char *git_branch(DirModel *dm) -> branch string or ""
git_branch:
    test rdi, rdi; jz .Lgb_empty
    cmp dword ptr [rdi + DirModel.virtual_mode], 0
    jne .Lgb_empty
    mov rax, [rdi + DirModel.git_ctx]
    test rax, rax; jz .Lgb_empty
    cmp byte ptr [rax], 0; je .Lgb_empty
    ret
.Lgb_empty:
    lea rax, [rip + git_empty]
    ret
