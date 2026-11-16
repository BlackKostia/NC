# Filesystem Operations: copy a symbolic link (split from file_ops_copy_at.s)

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .text
.global copy_link_at

# Internal: int copy_link_at(int sdir, const char *sname, int ddir, const char *dname)
copy_link_at:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi
    mov r13, rsi
    mov r14d, edx
    mov r15, rcx
    mov edi, PATH_MAX
    call mem_alloc
    test rax, rax
    jz .Lcla_nomem
    mov rbx, rax
    mov edi, r12d
    mov rsi, r13
    mov rdx, rbx
    mov r10d, PATH_MAX - 1
    OS_READLINKAT
    test rax, rax
    js .Lcla_free
    mov byte ptr [rbx + rax], 0
    mov rdi, rbx
    mov esi, r14d
    mov rdx, r15
    OS_SYMLINKAT
.Lcla_free:
    mov r12, rax
    mov rdi, rbx
    call mem_free
    mov rax, r12
    test rax, rax
    js .Lcla_ret
    call fs_progress_item
    xor eax, eax
    jmp .Lcla_ret
.Lcla_nomem:
    mov rax, -ENOMEM
.Lcla_ret:
    pop r15
    pop r14
    pop r13
    pop r12; pop rbx; ret
