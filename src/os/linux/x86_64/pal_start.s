# src/os/linux/x86_64/pal_start.s - process entry for C-main builds (kernel stack -> duop_main)
# Stack at _start: [rsp]=argc, argv[argc]=NULL, envp[]=NULL, auxv[] (pairs, AT_NULL-terminated).
.intel_syntax noprefix

.section .text
.global _start
_start:
    xor ebp, ebp                      # outermost frame marker for unwinders/debuggers
    mov rdi, [rsp]                    # argc
    lea rsi, [rsp + 8]                # argv
    lea rdx, [rsi + rdi * 8 + 8]      # envp
    mov rcx, rdx
.Lps_env:
    add rcx, 8
    cmp qword ptr [rcx - 8], 0
    jne .Lps_env                      # rcx -> auxv
    and rsp, -16                      # SysV: 16-byte aligned at the call
    call duop_main
    mov edi, eax
    call os_exit
.Lps_hang:
    jmp .Lps_hang                     # os_exit never returns
