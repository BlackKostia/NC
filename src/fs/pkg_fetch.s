# src/fs/pkg_fetch.s - Fork+exec curl/wget helper for Duop Package Manager
.intel_syntax noprefix
.include "pal.inc"

.section .rodata
pf_curl1:   .asciz "/usr/bin/curl"
pf_curl2:   .asciz "/bin/curl"
pf_curl_a1: .asciz "-fsSL"
pf_curl_a2: .asciz "-o"
pf_wget1:   .asciz "/usr/bin/wget"
pf_wget2:   .asciz "/bin/wget"
pf_wget_a1: .asciz "-q"
pf_wget_a2: .asciz "-O"

.section .text
.global pkg_fetch_url

# int pkg_fetch_url(char **envp, const char *url, const char *dest_path) -> 0 ok, -1 err
pkg_fetch_url:
    push rbx; push r12; push r13; push r14
    sub rsp, 56
    mov rbx, rdi                      # envp
    mov r12, rsi                      # url
    mov r13, rdx                      # dest_path
    OS_FORK
    test rax, rax
    js .Lpf_err
    jz .Lpf_child
    mov r14, rax                      # child pid
.Lpf_wait:
    mov rdi, r14
    lea rsi, [rsp + 48]               # status
    xor edx, edx
    xor r10d, r10d
    OS_WAIT4
    cmp rax, -EINTR
    je .Lpf_wait
    test rax, rax
    js .Lpf_err
    mov eax, [rsp + 48]
    test eax, eax
    jnz .Lpf_err
    xor eax, eax
    jmp .Lpf_ret
.Lpf_child:
    # argv = { curl, -fsSL, -o, dest_path, url, NULL }
    lea rax, [rip + pf_curl1];  mov [rsp], rax
    lea rax, [rip + pf_curl_a1]; mov [rsp + 8], rax
    lea rax, [rip + pf_curl_a2]; mov [rsp + 16], rax
    mov [rsp + 24], r13
    mov [rsp + 32], r12
    mov qword ptr [rsp + 40], 0
    lea rdi, [rip + pf_curl1]; mov rsi, rsp; mov rdx, rbx; OS_EXECVE
    lea rdi, [rip + pf_curl2]; mov rsi, rsp; mov rdx, rbx; OS_EXECVE
    # fallback wget -q -O dest_path url
    lea rax, [rip + pf_wget1];  mov [rsp], rax
    lea rax, [rip + pf_wget_a1]; mov [rsp + 8], rax
    lea rax, [rip + pf_wget_a2]; mov [rsp + 16], rax
    lea rdi, [rip + pf_wget1]; mov rsi, rsp; mov rdx, rbx; OS_EXECVE
    lea rdi, [rip + pf_wget2]; mov rsi, rsp; mov rdx, rbx; OS_EXECVE
    mov edi, 127
    OS_EXIT
.Lpf_err:
    mov eax, -1
.Lpf_ret:
    add rsp, 56
    pop r14; pop r13; pop r12; pop rbx; ret
