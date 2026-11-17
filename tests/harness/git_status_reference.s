# Frozen reference oracle: the hand-written asm that src/fs/git_status.c replaced (tests/test_c_git_status.py diffs against it)
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
.extern os_clock_ms
.extern os_poll_in
.extern env_getenv
.extern g_envp

.section .rodata
git_bin:       .asciz "/usr/bin/git"
git_bin_usr:   .asciz "/usr/local/bin/git"
git_bin_bin:   .asciz "/bin/git"
git_name:      .asciz "git"
git_path_key:  .asciz "PATH"
git_arg_nolck: .asciz "--no-optional-locks"
git_arg_cflag: .asciz "-c"
git_arg_nofsm: .asciz "core.fsmonitor=false"            # a repository's fsmonitor hook would run code
git_arg_c:     .asciz "-C"
git_arg_stat:  .asciz "status"
git_arg_porc:  .asciz "--porcelain=v1"
git_arg_nosub: .asciz "--ignore-submodules=all"         # nested repositories are never inspected
git_arg_z:     .asciz "-z"
git_arg_b:     .asciz "-b"
git_devnull:   .asciz "/dev/null"
git_env_path:  .asciz "PATH=/usr/bin:/bin"
git_env_lc:    .asciz "LC_ALL=C"
git_no_comm:   .asciz "No commits yet on "

.section .bss
.align 4
g_git_off: .space 4            # 1 after a git run exceeded its deadline: git integration stays off

.section .text
.global git_free_ctx
.global git_spawn_status
.global git_parse_branch
.equ GIT_TIMEOUT_MS, 2500      # a stuck git (dead mount, huge repo) must never freeze the UI

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
    sub rsp, 144              # [0..7]=pipefd, [8..103]=argv, [104..127]=envp, [128]=status, [136]=deadline
    cmp dword ptr [rip + g_git_off], 0
    jne .Lgss_err
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
    cmp dword ptr [rsp + 128], 0
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
    add rsp, 144
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
    mov edx, O_RDWR
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
    js .Lgss_exec
    push rax
    mov edi, eax
    mov esi, 2                # stderr
    OS_DUP2
    mov edi, [rsp]
    xor esi, esi              # stdin: the helper must never read the user's keystrokes
    OS_DUP2
    pop rdi
    OS_CLOSE

.Lgss_exec:
    lea rax, [rip + git_name]; mov [rsp + 8 + 16], rax
    lea rcx, [rip + git_arg_nolck]; mov [rsp + 16 + 16], rcx
    lea rcx, [rip + git_arg_cflag]; mov [rsp + 24 + 16], rcx
    lea rcx, [rip + git_arg_nofsm]; mov [rsp + 32 + 16], rcx
    lea rcx, [rip + git_arg_c]; mov [rsp + 40 + 16], rcx
    mov [rsp + 48 + 16], r12
    lea rcx, [rip + git_arg_stat]; mov [rsp + 56 + 16], rcx
    lea rcx, [rip + git_arg_porc]; mov [rsp + 64 + 16], rcx
    lea rcx, [rip + git_arg_nosub]; mov [rsp + 72 + 16], rcx
    lea rcx, [rip + git_arg_z]; mov [rsp + 80 + 16], rcx
    lea rcx, [rip + git_arg_b]; mov [rsp + 88 + 16], rcx
    mov qword ptr [rsp + 96 + 16], 0

    lea rcx, [rip + git_env_path]; mov [rsp + 104 + 16], rcx
    lea rcx, [rip + git_env_lc]; mov [rsp + 112 + 16], rcx
    mov qword ptr [rsp + 120 + 16], 0

    call os_sig_reset_pipe
    call os_mark_child_forked
    lea rdi, [rsp + 8 + 16]
    lea rsi, [rsp + 104 + 16]
    call git_exec_from_path
    mov edi, 127
    OS_EXIT

.Lgss_parent:
    mov rbx, rax              # child pid
    mov edi, [rsp + 4 + 16]
    OS_CLOSE

.Lgit_spawn_status__child_process_ret:
    lea rsp, [rsp + 8]
    ret

# void git_exec_from_path(char **argv, char **envp) -> tries PATH entries, then fallbacks
git_exec_from_path:
    sub rsp, PATH_MAX + 8
    mov r12, rdi; mov r13, rsi
    mov rdi, [rip + g_envp]
    lea rsi, [rip + git_path_key]
    call env_getenv
    test rax, rax; jz .Lgep_fb
    mov r14, rax
.Lgep_next:
    cmp byte ptr [r14], 0; je .Lgep_fb
    xor ecx, ecx
.Lgep_cp:
    mov al, [r14]
    test al, al; jz .Lgep_sep
    cmp al, ':'; je .Lgep_sep
    cmp ecx, PATH_MAX - 8; jge .Lgep_skip
    mov [rsp + rcx], al; inc ecx
.Lgep_skip:
    inc r14; jmp .Lgep_cp
.Lgep_sep:
    cmp byte ptr [r14], ':'; jne .Lgep_sfx
    inc r14
.Lgep_sfx:
    test ecx, ecx; jz .Lgep_next
    mov byte ptr [rsp + rcx], '/'
    mov dword ptr [rsp + rcx + 1], 0x00746967  # "git\0"
    mov rdi, rsp; mov rsi, r12; mov rdx, r13
    OS_EXECVE
    jmp .Lgep_next
.Lgep_fb:
    lea rdi, [rip + git_bin]; mov rsi, r12; mov rdx, r13; OS_EXECVE
    lea rdi, [rip + git_bin_usr]; mov rsi, r12; mov rdx, r13; OS_EXECVE
    lea rdi, [rip + git_bin_bin]; mov rsi, r12; mov rdx, r13; OS_EXECVE
    add rsp, PATH_MAX + 8
    ret

# git_spawn_status step: total read (runs on the caller's frame)
git_spawn_status__total_read:
    lea rsp, [rsp - 8]
    xor r15d, r15d            # total read
    dec r14d                  # leave room for NUL
    call os_clock_ms
    add rax, GIT_TIMEOUT_MS
    mov [rsp + 136 + 16], rax # deadline
.Lgss_rd:
    cmp r15d, r14d
    jge .Lgss_rd_done
    call os_clock_ms
    mov rsi, [rsp + 136 + 16]
    sub rsi, rax              # ms left
    jle .Lgss_late
    mov edi, [rsp + 0 + 16]
    call os_poll_in
    cmp rax, -EINTR
    je .Lgss_rd
    test rax, rax
    jz .Lgss_late             # nothing readable before the deadline
    js .Lgss_rd_done
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
.Lgss_late:
    mov dword ptr [rip + g_git_off], 1   # too slow once: leave git alone for the rest of the session
    mov rdi, rbx
    mov esi, SIGKILL
    OS_KILL
    xor r15d, r15d            # drop partial output
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
    lea rsi, [rsp + 128 + 16]
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
