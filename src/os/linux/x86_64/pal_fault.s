# src/os/linux/x86_64/pal_fault.s - Unified SA_SIGINFO fault handler for TRY/CATCH & mmap SIGBUS
.intel_syntax noprefix

.include "pal.inc"
.include "try_using.inc"

.section .bss
.align 8
g_pf_slot_ptr:  .space 8

.section .text
.global os_fault_guard_install_slot

# SA_RESTORER trampoline (must invoke rt_sigreturn directly with untouched rsp)
pf_sig_restorer:
    mov eax, OS_SYS_rt_sigreturn
    syscall

# Fallback SIGBUS patch for truncated mmap'ed files when no TRY frame is active
pf_bus_patch:
    mov rdi, [rsi + KSIGINFO_ADDR]
    and rdi, -4096
    mov esi, 4096
    mov edx, PROT_READ | PROT_WRITE
    mov r10d, MAP_PRIVATE_ANON | MAP_FIXED
    mov r8, -1
    xor r9d, r9d
    mov eax, OS_SYS_mmap
    syscall
    ret

# void pf_fault_handler(int sig, siginfo_t *info, void *uctx)
pf_fault_handler:
    mov r8, [rip + g_pf_slot_ptr]
    test r8, r8
    jz .Lpf_no_try
    mov r9, [r8]
    test r9, r9
    jz .Lpf_no_try

    # Active TRY frame found in r9: pop it first to prevent recursive fault loops
    mov rax, [r9 + TF_PREV]
    mov [r8], rax

    # Patch ucontext_t->uc_mcontext.gregs so rt_sigreturn resumes at CATCH
    mov rax, [r9 + TF_RBX]
    mov [rdx + UC_REG_RBX], rax
    mov rax, [r9 + TF_RBP]
    mov [rdx + UC_REG_RBP], rax
    mov rax, [r9 + TF_R12]
    mov [rdx + UC_REG_R12], rax
    mov rax, [r9 + TF_R13]
    mov [rdx + UC_REG_R13], rax
    mov rax, [r9 + TF_R14]
    mov [rdx + UC_REG_R14], rax
    mov rax, [r9 + TF_R15]
    mov [rdx + UC_REG_R15], rax
    mov rax, [r9 + TF_RSP]
    mov [rdx + UC_REG_RSP], rax
    mov rax, [r9 + TF_RIP]
    mov [rdx + UC_REG_RIP], rax

    movsxd rax, edi
    mov [rdx + UC_REG_RAX], rax
    and qword ptr [rdx + UC_REG_EFL], ~0x400   # clear DF
    ret

.Lpf_no_try:
    cmp edi, SIGBUS
    je pf_bus_patch
    # Unhandled SIGSEGV/SIGFPE outside TRY: restore SIG_DFL and let faulting insn re-execute
    sub rsp, KSIGACTION_SIZE + 8
    mov qword ptr [rsp + KSIG_HANDLER], 0      # SIG_DFL
    mov qword ptr [rsp + KSIG_FLAGS], SA_RESTORER
    lea rax, [rip + pf_sig_restorer]
    mov [rsp + KSIG_RESTORER], rax
    mov qword ptr [rsp + KSIG_MASK], 0
    mov rsi, rsp
    xor edx, edx
    mov r10d, 8
    mov eax, OS_SYS_rt_sigaction
    syscall
    add rsp, KSIGACTION_SIZE + 8
    ret

# void os_fault_guard_install_slot(TryFrame **slot_ptr)
os_fault_guard_install_slot:
    mov [rip + g_pf_slot_ptr], rdi
    sub rsp, KSIGACTION_SIZE + 8
    lea rax, [rip + pf_fault_handler]
    mov [rsp + KSIG_HANDLER], rax
    mov qword ptr [rsp + KSIG_FLAGS], SA_RESTORER | SA_SIGINFO
    lea rax, [rip + pf_sig_restorer]
    mov [rsp + KSIG_RESTORER], rax
    mov qword ptr [rsp + KSIG_MASK], 0

    mov edi, SIGBUS
    mov rsi, rsp
    xor edx, edx
    mov r10d, 8
    mov eax, OS_SYS_rt_sigaction
    syscall

    mov edi, SIGSEGV
    mov rsi, rsp
    xor edx, edx
    mov r10d, 8
    mov eax, OS_SYS_rt_sigaction
    syscall

    mov edi, SIGFPE
    mov rsi, rsp
    xor edx, edx
    mov r10d, 8
    mov eax, OS_SYS_rt_sigaction
    syscall

    add rsp, KSIGACTION_SIZE + 8
    ret
