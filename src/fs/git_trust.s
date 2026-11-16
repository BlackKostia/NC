# src/fs/git_trust.s - may `git status` run in this repository? (code-execution guard)
#
# `git status` runs programs named by the repository's own configuration: filter drivers
# (filter.<name>.clean / .process), anything an [include] pulls in, core.fsmonitor (overridden on the
# command line by the caller). A repository that arrives from elsewhere (archive, shared disk,
# download) must not run code just because somebody browsed it, so git_repo_trusted() only accepts
# a plain <repo>/.git directory whose local config is a readable regular file, free of NUL bytes,
# not larger than 32 KiB and naming no filter / include section. Everything unreadable or
# unexpected counts as untrusted; a missing config file is fine (it cannot name a program).

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.equ GT_CFG_MAX,   32768
.equ GT_FRAME,     PATH_MAX + FileStat._size + 16

.section .rodata
gt_cfg:          .asciz "/config"
gt_word_filter:  .asciz "filter"
gt_word_include: .asciz "include"

.section .text
.global git_repo_trusted

.extern os_statat
.extern os_fstat
.extern str_copy
.extern str_cat
.extern str_len
.extern str_contains_ci
.extern sys_read_retry
.extern mem_alloc
.extern mem_free

# int gt_read_config(int fd, char *buf) -> bytes read (<= GT_CFG_MAX + 1), or -errno
gt_read_config:
    push rbx; push r12; push r13
    mov ebx, edi
    mov r12, rsi
    xor r13d, r13d
.Lgrc_loop:
    cmp r13d, GT_CFG_MAX + 1; jae .Lgrc_done
    mov edi, ebx
    lea rsi, [r12 + r13]
    mov edx, GT_CFG_MAX + 1
    sub edx, r13d
    call sys_read_retry
    test rax, rax; js .Lgrc_ret
    jz .Lgrc_done
    add r13d, eax
    jmp .Lgrc_loop
.Lgrc_done:
    mov eax, r13d
.Lgrc_ret:
    pop r13; pop r12; pop rbx
    ret

# int gt_config_clean(char *buf, int len) -> 1 when the text is NUL free and names no filter/include
gt_config_clean:
    push rbx; push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12d, esi
    mov byte ptr [rbx + r12], 0
    mov rdi, rbx
    call str_len
    cmp eax, r12d; jne .Lgcc_no                       # embedded NUL: git may parse more than we do
    mov rdi, rbx; lea rsi, [rip + gt_word_filter]
    call str_contains_ci
    test eax, eax; jnz .Lgcc_no
    mov rdi, rbx; lea rsi, [rip + gt_word_include]
    call str_contains_ci
    test eax, eax; jnz .Lgcc_no
    mov eax, 1
    jmp .Lgcc_ret
.Lgcc_no:
    xor eax, eax
.Lgcc_ret:
    add rsp, 8
    pop r12; pop rbx
    ret

# int gt_config_fd_ok(int fd, char *statbuf) -> 1 when fd is a regular file
gt_config_fd_ok:
    push rbx
    mov rbx, rsi
    call os_fstat
    test rax, rax; js .Lgfo_no
    mov eax, [rbx + FileStat.mode]
    and eax, S_IFMT
    cmp eax, S_IFREG
    sete al
    movzx eax, al
    jmp .Lgfo_ret
.Lgfo_no:
    xor eax, eax
.Lgfo_ret:
    pop rbx
    ret

# int git_repo_trusted(const char *dotgit) -- dotgit = "<worktree>/.git"; 1 = trusted, 0 = refuse
git_repo_trusted:
    push rbx; push r12; push r13; push r14
    sub rsp, GT_FRAME                                 # [0..PATH_MAX) config path, then a FileStat
    mov rbx, rdi
    call str_len
    cmp rax, PATH_MAX - 16; jae .Lgrt_no              # "/config" must fit without truncation
    mov edi, AT_FDCWD; mov rsi, rbx; lea rdx, [rsp + PATH_MAX]; xor ecx, ecx
    call os_statat                                    # no-follow: a symlinked .git is not trusted
    test rax, rax; js .Lgrt_no
    mov eax, [rsp + PATH_MAX + FileStat.mode]
    and eax, S_IFMT
    cmp eax, S_IFDIR; jne .Lgrt_no
    mov rdi, rsp; mov rsi, rbx; mov edx, PATH_MAX
    call str_copy
    mov rdi, rsp; lea rsi, [rip + gt_cfg]; mov edx, PATH_MAX
    call str_cat
    mov edi, AT_FDCWD; mov rsi, rsp
    mov edx, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    cmp rax, -ENOENT; je .Lgrt_yes                    # no local config: nothing can name a program
    test rax, rax; js .Lgrt_no
    mov r12d, eax
    mov edi, r12d; lea rsi, [rsp + PATH_MAX]
    call gt_config_fd_ok
    test eax, eax; jz .Lgrt_close_no
    mov edi, GT_CFG_MAX + 2
    call mem_alloc
    test rax, rax; jz .Lgrt_close_no
    mov r13, rax
    mov edi, r12d; mov rsi, r13
    call gt_read_config
    mov r14d, eax
    mov edi, r12d
    OS_CLOSE
    test r14d, r14d; js .Lgrt_free_no
    cmp r14d, GT_CFG_MAX; ja .Lgrt_free_no            # too large to vet
    mov rdi, r13; mov esi, r14d
    call gt_config_clean
    mov r14d, eax
    mov rdi, r13
    call mem_free
    mov eax, r14d
    jmp .Lgrt_ret
.Lgrt_free_no:
    mov rdi, r13
    call mem_free
    jmp .Lgrt_no
.Lgrt_close_no:
    mov edi, r12d
    OS_CLOSE
.Lgrt_no:
    xor eax, eax
    jmp .Lgrt_ret
.Lgrt_yes:
    mov eax, 1
.Lgrt_ret:
    add rsp, GT_FRAME
    pop r14; pop r13; pop r12; pop rbx
    ret
