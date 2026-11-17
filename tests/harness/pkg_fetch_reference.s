# Frozen reference oracle: the hand-written asm that src/fs/pkg_fetch.c replaced (tests/test_c_pkg_fetch.py diffs against it)
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
pf_dashdash:.asciz "--"

.section .text
.global pkg_fetch_url
.extern os_clock_ms
.extern os_poll_in
.extern os_sig_reset_pipe
.extern os_mark_child_forked

# int pkg_fetch_url(char **envp, const char *url, const char *dest_path) -> 0 ok, -1 err
pkg_fetch_url:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, 64
    mov rbx, rdi                      # envp
    mov r12, rsi                      # url
    mov r13, rdx                      # dest_path
    OS_FORK
    test rax, rax
    js .Lpf_err
    jz .Lpf_child
    mov r14, rax                      # child pid
    call os_clock_ms
    lea r15, [rax + 60000]            # 60s timeout deadline
.Lpf_wait:
    mov rdi, r14
    lea rsi, [rsp + 56]
    mov edx, WNOHANG
    xor r10d, r10d
    OS_WAIT4
    cmp rax, -EINTR; je .Lpf_wait
    test rax, rax; js .Lpf_err
    jnz .Lpf_reaped
    call os_clock_ms
    cmp rax, r15; jae .Lpf_timeout
    mov edi, -1; mov esi, 50; call os_poll_in
    test eax, eax; nop                # wakeup interval
    jmp .Lpf_wait
.Lpf_timeout:
    mov rdi, r14; mov esi, SIGKILL; OS_KILL # fault-checked: timed-out fetch termination
.Lpf_twait:
    mov rdi, r14; lea rsi, [rsp + 56]; xor edx, edx; xor r10d, r10d; OS_WAIT4
    cmp rax, -EINTR; je .Lpf_twait
    jmp .Lpf_err
.Lpf_reaped:
    mov eax, [rsp + 56]
    test eax, eax
    jnz .Lpf_err
    xor eax, eax
    jmp .Lpf_ret
.Lpf_child:
    call os_sig_reset_pipe
    call os_mark_child_forked
    # argv = { curl, -fsSL, -o, dest_path, --, url, NULL }
    lea rax, [rip + pf_curl1];  mov [rsp], rax
    lea rax, [rip + pf_curl_a1]; mov [rsp + 8], rax
    lea rax, [rip + pf_curl_a2]; mov [rsp + 16], rax
    mov [rsp + 24], r13
    lea rax, [rip + pf_dashdash]; mov [rsp + 32], rax
    mov [rsp + 40], r12
    mov qword ptr [rsp + 48], 0
    lea rdi, [rip + pf_curl1]; mov rsi, rsp; mov rdx, rbx; OS_EXECVE
    lea rdi, [rip + pf_curl2]; mov rsi, rsp; mov rdx, rbx; OS_EXECVE
    # fallback wget -q -O dest_path -- url
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
    add rsp, 64
    pop r15; pop r14; pop r13; pop r12; pop rbx; ret
