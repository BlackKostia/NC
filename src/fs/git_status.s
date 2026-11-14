# src/fs/git_status.s - Git branch & porcelain v1 status integration

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"
.equ GIT_MAX_ENTRIES, 512
.equ GENT_SIZE,       260     # name[256] + status(1) + pad(3)
.equ GCTX_SIZE,       80      # branch[64] + count(4) + pad(4) + entries(8)
.equ GIT_BUF_SIZE,    65536
.extern mem_alloc
.extern mem_free
.extern mem_zero
.extern str_cmp
.extern str_copy
.extern str_cat
.extern str_len
.extern os_statat

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

.section .text
.global git_free_ctx
.global git_spawn_status
.global git_parse_branch

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
    call git_spawn_status__dir
    js .Lgss_err

    OS_FORK
    test rax, rax
    js .Lgss_fork_err
    call git_spawn_status__child_process
    call git_spawn_status__total_read
.Lgss_wait:
    call git_spawn_status__part4
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

# git_spawn_status step: dir (runs on the caller's frame)
git_spawn_status__dir:
    lea rsp, [rsp - 8]
    mov r12, rdi              # dir
    mov r13, rsi              # out_buf
    mov r14d, edx             # buf_cap

    lea rdi, [rsp + 16]
    mov esi, O_CLOEXEC
    OS_PIPE2
    test rax, rax
.Lgit_spawn_status__dir_ret:
    lea rsp, [rsp + 8]
    ret

# git_spawn_status step: Child process (runs on the caller's frame)
git_spawn_status__child_process:
    lea rsp, [rsp - 8]
    jnz .Lgss_parent

    # Child process
    mov edi, [rsp + 4 + 16]  # pipefd[1]
    mov esi, 1                # stdout
    OS_DUP2
    mov edi, [rsp + 0 + 16]
    OS_CLOSE
    mov edi, [rsp + 4 + 16]
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
    lea rax, [rip + git_bin]; mov [rsp + 8 + 16], rax
    lea rcx, [rip + git_arg_nolck]; mov [rsp + 16 + 16], rcx
    lea rcx, [rip + git_arg_c]; mov [rsp + 24 + 16], rcx
    mov [rsp + 32 + 16], r12
    lea rcx, [rip + git_arg_stat]; mov [rsp + 40 + 16], rcx
    lea rcx, [rip + git_arg_porc]; mov [rsp + 48 + 16], rcx
    lea rcx, [rip + git_arg_z]; mov [rsp + 56 + 16], rcx
    lea rcx, [rip + git_arg_b]; mov [rsp + 64 + 16], rcx
    mov qword ptr [rsp + 72 + 16], 0

    lea rcx, [rip + git_env_path]; mov [rsp + 88 + 16], rcx
    lea rcx, [rip + git_env_lc]; mov [rsp + 96 + 16], rcx
    mov qword ptr [rsp + 104 + 16], 0

    mov rdi, rax
    lea rsi, [rsp + 8 + 16]
    lea rdx, [rsp + 88 + 16]
    OS_EXECVE
    mov edi, 127
    OS_EXIT

.Lgss_parent:
    mov rbx, rax              # child pid
    mov edi, [rsp + 4 + 16]
    OS_CLOSE

.Lgit_spawn_status__child_process_ret:
    lea rsp, [rsp + 8]
    ret

# git_spawn_status step: total read (runs on the caller's frame)
git_spawn_status__total_read:
    lea rsp, [rsp - 8]
    xor r15d, r15d            # total read
    dec r14d                  # leave room for NUL
.Lgss_rd:
    cmp r15d, r14d
    jge .Lgss_rd_done
    mov edi, [rsp + 0 + 16]
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
    mov edi, [rsp + 0 + 16]
    OS_CLOSE

.Lgit_spawn_status__total_read_ret:
    lea rsp, [rsp + 8]
    ret

# git_spawn_status step (runs on the caller's frame)
git_spawn_status__part4:
    lea rsp, [rsp - 8]
    mov rdi, rbx
    lea rsi, [rsp + 112 + 16]
    xor edx, edx
    xor r10d, r10d
    OS_WAIT4
    cmp rax, -EINTR
.Lgit_spawn_status__part4_ret:
    lea rsp, [rsp + 8]
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
