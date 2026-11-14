# src/os/linux/x86_64/pal_thread.s - Linux x86-64 zero-libc worker thread primitives
.intel_syntax noprefix
.include "pal.inc"

.equ CLONE_THREAD_FLAGS, 0x01210F00 # VM|FS|FILES|SIGHAND|THREAD|CHILD_CLEARTID|CHILD_SETTID
.equ FUTEX_WAIT,         0

.section .text
.global os_thread_spawn
.global os_thread_join

# int os_thread_spawn(void (*fn)(void *), void *arg, void *stack_top, int *ctid_out)
# rdi=fn, rsi=arg, rdx=stack_top, rcx=ctid_out
os_thread_spawn:
    mov dword ptr [rcx], 1
    sub rdx, 16
    mov [rdx], rdi                    # [stack_top - 16] = fn
    mov [rdx + 8], rsi                # [stack_top - 8]  = arg
    mov r10, rcx                      # child_tid
    mov rsi, rdx                      # child stack
    mov rdi, CLONE_THREAD_FLAGS
    xor edx, edx                      # parent_tid = NULL
    xor r8d, r8d                      # tls = 0
    mov eax, OS_SYS_clone
    syscall
    test rax, rax
    jz .Lchild_entry
    jns .Lparent_ok
    mov dword ptr [r10], 0
.Lparent_ok:
    ret
.Lchild_entry:
    pop rax                           # fn
    pop rdi                           # arg
    call rax
    xor edi, edi
    mov eax, OS_SYS_exit
    syscall

# void os_thread_join(int *ctid)
os_thread_join:
    push rbx
    mov rbx, rdi
.Ljoin_loop:
    mov edx, [rbx]
    test edx, edx
    jz .Ljoin_done
    mov rdi, rbx
    xor esi, esi                      # FUTEX_WAIT
    xor r10d, r10d
    xor r8d, r8d
    xor r9d, r9d
    mov eax, OS_SYS_futex
    syscall
    jmp .Ljoin_loop
.Ljoin_done:
    pop rbx
    ret
