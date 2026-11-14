# src/fs/dir_fuzzy.s - Fuzzy matching scorer & recursive tree collector — dir fuzzy walk (split from dir_fuzzy.s)

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
