# src/fs/dir_fuzzy.s - Fuzzy matching scorer & recursive tree collector — dir fuzzy walk (split from dir_fuzzy.s)

.intel_syntax noprefix
.include "pal.inc"
.include "config.inc"
.include "types.inc"
.equ FUZZY_MAX_DEPTH, 8
.extern sys_open
.extern sys_close
.extern sys_write_all
.extern os_statat
.extern tmp_open_atomic
.extern tmp_commit_atomic
.extern os_dir_read
.extern os_dir_next_ex
.extern mem_alloc
.extern mem_free
.extern str_len
.extern str_copy

.section .rodata

.Ldfc_empty: .asciz ""

.section .text
.global dir_fuzzy_collect
.global fs_write_file

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
    mov edi, FUZZY_MAX_DEPTH * 8192
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
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, PATH_MAX + 64            # [0..55]=FileStat, [64..]=tmp_buf
    mov r15, rdi; mov r12, rsi; mov r13, rdx
    mov edi, AT_FDCWD; mov rsi, r15; mov rdx, rsp; xor ecx, ecx
    call os_statat
    mov r14d, 0644
    test rax, rax
    js .Lfwf_chk_enoent
    mov eax, [rsp + FileStat.mode]
    and eax, S_IFMT
    cmp eax, S_IFREG
    jne .Lfwf_err
    mov r14d, [rsp + FileStat.mode]
    and r14d, 0777
    jmp .Lfwf_open
.Lfwf_chk_enoent:
    cmp rax, -2
    jne .Lfwf_err
.Lfwf_open:
    mov rdi, r15; lea rsi, [rsp + 64]; mov edx, r14d
    call tmp_open_atomic
    test rax, rax; js .Lfwf_err
    mov ebx, eax
    mov edi, ebx; mov rsi, r12; mov rdx, r13
    call sys_write_all
    xor rcx, rcx
    test rax, rax; js .Lfwf_wr_fail
    cmp rax, r13; je .Lfwf_commit
.Lfwf_wr_fail:
    mov rcx, rax
    test rcx, rcx; js .Lfwf_commit
    mov rcx, -EIO
.Lfwf_commit:
    mov edi, ebx; lea rsi, [rsp + 64]; mov rdx, r15
    call tmp_commit_atomic
    test eax, eax; js .Lfwf_err
    xor eax, eax; jmp .Lfwf_ret
.Lfwf_err:
    mov eax, -1
.Lfwf_ret:
    add rsp, PATH_MAX + 64
    pop r15; pop r14; pop r13; pop r12; pop rbx
    ret
