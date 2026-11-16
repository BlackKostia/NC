# src/os/linux/x86_64/pal_fault.s - Unified SA_SIGINFO fault handler for TRY/CATCH & mmap SIGBUS
.intel_syntax noprefix

.include "pal.inc"
.include "try_using.inc"

.section .rodata
pf_tty_reset:
    .ascii "\x1b[?1000l\x1b[?1002l\x1b[?1006l\x1b[?1049l\x1b[?25h"
.equ pf_tty_reset_len, . - pf_tty_reset
pf_core_sigs:
    .byte SIGBUS, SIGSEGV, SIGFPE, SIGABRT, 0
pf_term_sigs:
    .byte SIGHUP, SIGQUIT, SIGILL, SIGTRAP, SIGUSR1, SIGUSR2, SIGALRM, SIGSTKFLT
    .byte SIGXCPU, SIGXFSZ, SIGVTALRM, SIGPROF, SIGIO, SIGPWR, SIGSYS, 0

.section .bss
.align 8
g_pf_slot_ptr:   .space 8
g_main_pid:      .space 4
g_try_owner_pid: .space 4
g_try_main_tid:  .space 4
.equ PF_MMAP_SLOTS, 64
g_pf_mmap_tab:   .space PF_MMAP_SLOTS * 16
.align 16
g_sig_altstack:  .space SIGSTKSZ_BUFSZ

.section .text
.global os_fault_guard_install_slot
.global os_signals_install
.global pf_sig_restorer
.global os_sig_reset_pipe
.global pf_reg_mmap
.global pf_unreg_mmap
.global pf_sigbus_fallback
.global os_parent_alive
.global os_set_pdeathsig
.global os_raise_nofile
.global os_mark_child_forked
.extern os_term_restore

# SA_RESTORER trampoline (must invoke rt_sigreturn directly with untouched rsp)
pf_sig_restorer:
    mov eax, OS_SYS_rt_sigreturn
    syscall

# void pf_reg_mmap(void *base, size_t len)
pf_reg_mmap:
    test rdi, rdi; jz .Lprm_ret
    test rsi, rsi; jz .Lprm_ret
    lea rax, [rsi + 4095]; and rax, -4096
    add rax, rdi
    lea rcx, [rip + g_pf_mmap_tab]
    xor edx, edx
    xor r9d, r9d
.Lprm_loop:
    cmp edx, PF_MMAP_SLOTS; jae .Lprm_chk_free
    mov r8, [rcx]
    cmp r8, rdi; je .Lprm_set
    test r8, r8; jnz .Lprm_next
    test r9, r9; jnz .Lprm_next
    mov r9, rcx
.Lprm_next:
    add rcx, 16; inc edx; jmp .Lprm_loop
.Lprm_chk_free:
    test r9, r9; jz .Lprm_ret
    mov rcx, r9
.Lprm_set:
    mov [rcx], rdi; mov [rcx + 8], rax
.Lprm_ret:
    ret

# void pf_unreg_mmap(void *base)
pf_unreg_mmap:
    test rdi, rdi; jz .Lpum_ret
    lea rcx, [rip + g_pf_mmap_tab]
    xor edx, edx
.Lpum_loop:
    cmp edx, PF_MMAP_SLOTS; jae .Lpum_ret
    cmp [rcx], rdi; je .Lpum_clr
    add rcx, 16; inc edx; jmp .Lpum_loop
.Lpum_clr:
    mov qword ptr [rcx], 0; mov qword ptr [rcx + 8], 0
.Lpum_ret:
    ret

# int pf_is_mmap_addr(void *addr) -> 1 if in registered file mapping, 0 otherwise
pf_is_mmap_addr:
    test rdi, rdi; jz .Lpim_no
    lea rcx, [rip + g_pf_mmap_tab]
    xor edx, edx
.Lpim_loop:
    cmp edx, PF_MMAP_SLOTS; jae .Lpim_no
    mov rax, [rcx]
    test rax, rax; jz .Lpim_next
    cmp rdi, rax; jb .Lpim_next
    cmp rdi, [rcx + 8]; jae .Lpim_next
    mov eax, 1; ret
.Lpim_next:
    add rcx, 16; inc edx; jmp .Lpim_loop
.Lpim_no:
    xor eax, eax; ret

# Fatal non-TRY terminating signals: restore TTY and re-raise SIG_DFL
pf_term_handler:
    jmp pf_fatal_default

# SIGBUS fallback: patch only registered file mappings, else default action
pf_sigbus_fallback:
    push rsi
    mov rdi, [rsi + KSIGINFO_ADDR]
    call pf_is_mmap_addr
    pop rsi
    test eax, eax
    jnz pf_bus_patch
    mov edi, SIGBUS
    jmp pf_fatal_default

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
    cmp rax, -4095
    jae .Lpbp_fatal
    ret
.Lpbp_fatal:
    mov edi, SIGBUS
    jmp pf_fatal_default

# void pf_fault_handler(int sig, siginfo_t *info, void *uctx)
pf_fault_handler:
    mov r8, [rip + g_pf_slot_ptr]
    test r8, r8
    jz .Lpf_no_try
    mov r9, [r8]
    test r9, r9
    jz .Lpf_no_try

    OS_GETPID
    cmp eax, [rip + g_try_owner_pid]
    jne .Lpf_fork_chk
    OS_GETTID
    cmp eax, [rip + g_try_main_tid]
    jne .Lpf_no_try
    jmp .Lpf_do_try
.Lpf_fork_chk:
    mov r10d, eax
    OS_GETTID
    cmp eax, r10d
    jne .Lpf_no_try
.Lpf_do_try:

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
    je pf_sigbus_fallback
    jmp pf_fatal_default

# Helper: restore terminal (if raw active), set SIG_DFL, unblock & re-raise fatal signal
pf_fatal_default:
    sub rsp, KSIGACTION_SIZE + 24
    mov [rsp + KSIGACTION_SIZE + 16], rdi
    OS_GETPID
    cmp eax, [rip + g_main_pid]
    jne .Lpf_no_tty
    call os_term_restore
    test eax, eax
    jz .Lpf_no_tty
    mov edi, STDOUT_FD
    lea rsi, [rip + pf_tty_reset]
    mov edx, pf_tty_reset_len
    OS_WRITE
.Lpf_no_tty:

    mov qword ptr [rsp + KSIG_HANDLER], 0      # SIG_DFL
    mov qword ptr [rsp + KSIG_FLAGS], SA_RESTORER
    lea rax, [rip + pf_sig_restorer]
    mov [rsp + KSIG_RESTORER], rax
    mov qword ptr [rsp + KSIG_MASK], 0
    mov rdi, [rsp + KSIGACTION_SIZE + 16]
    mov rsi, rsp
    xor edx, edx
    mov r10d, 8
    mov eax, OS_SYS_rt_sigaction
    syscall

    mov ecx, [rsp + KSIGACTION_SIZE + 16]
    dec ecx
    mov eax, 1
    shl rax, cl
    mov [rsp + KSIGACTION_SIZE], rax
    mov edi, 1                                 # SIG_UNBLOCK
    lea rsi, [rsp + KSIGACTION_SIZE]
    xor edx, edx
    mov r10d, 8
    mov eax, OS_SYS_rt_sigprocmask
    syscall

    OS_GETPID
    mov r10d, eax
    OS_GETTID
    mov edi, r10d
    mov esi, eax
    mov edx, [rsp + KSIGACTION_SIZE + 16]
    mov eax, OS_SYS_tgkill
    syscall

    add rsp, KSIGACTION_SIZE + 24
    ret

# void os_fault_guard_install_slot(TryFrame **slot_ptr)
os_fault_guard_install_slot:
    mov [rip + g_pf_slot_ptr], rdi
    OS_GETPID; mov [rip + g_main_pid], eax; mov [rip + g_try_owner_pid], eax # fault-checked: getpid
    OS_GETTID; mov [rip + g_try_main_tid], eax # fault-checked: gettid
    sub rsp, KSIGACTION_SIZE + 8
    lea rax, [rip + g_sig_altstack]; mov [rsp + KSTACK_T_SP], rax
    mov qword ptr [rsp + KSTACK_T_FLAGS], 0
    mov qword ptr [rsp + KSTACK_T_SZ], SIGSTKSZ_BUFSZ
    mov rdi, rsp; xor esi, esi; mov eax, OS_SYS_sigaltstack; syscall # fault-checked: best-effort altstack
    lea rax, [rip + pf_fault_handler]; mov [rsp + KSIG_HANDLER], rax
    mov qword ptr [rsp + KSIG_FLAGS], SA_RESTORER | SA_SIGINFO | SA_ONSTACK
    lea rax, [rip + pf_sig_restorer]; mov [rsp + KSIG_RESTORER], rax
    mov qword ptr [rsp + KSIG_MASK], 0
    lea rdi, [rip + pf_core_sigs]
    mov rdx, rsp
    call pf_install_sig_table
    add rsp, KSIGACTION_SIZE + 8
    ret

# Helper: void pf_sig_set(int sig, void *sa_buf)
pf_sig_set:
    mov rsi, rdx; xor edx, edx; mov r10d, 8; mov eax, OS_SYS_rt_sigaction; syscall; ret # fault-checked: best-effort signal setup

# Helper: void pf_install_sig_table(const uint8_t *sigs, void *sa_buf)
pf_install_sig_table:
    push rbx; push r12; sub rsp, 8
    mov rbx, rdi; mov r12, rdx
.Lpist_loop:
    movzx edi, byte ptr [rbx]
    test edi, edi
    jz .Lpist_done
    mov rdx, r12
    call pf_sig_set
    inc rbx
    jmp .Lpist_loop
.Lpist_done:
    add rsp, 8; pop r12; pop rbx; ret

# void os_sig_reset_pipe(void) - restore SIG_DFL for SIGPIPE in forked children
os_sig_reset_pipe:
    sub rsp, KSIGACTION_SIZE + 8
    mov qword ptr [rsp + KSIG_HANDLER], 0
    mov qword ptr [rsp + KSIG_FLAGS], SA_RESTORER
    lea rax, [rip + pf_sig_restorer]
    mov [rsp + KSIG_RESTORER], rax
    mov qword ptr [rsp + KSIG_MASK], 0
    mov edi, SIGPIPE
    mov rdx, rsp
    call pf_sig_set
    add rsp, KSIGACTION_SIZE + 8
    ret

# void os_signals_install(void (*on_winch)(void), void (*on_int)(void), void (*on_term)(void))
os_signals_install:
    sub rsp, KSIGACTION_SIZE + 16
    mov [rsp + KSIGACTION_SIZE], rsi; mov [rsp + KSIGACTION_SIZE + 8], rdx
    mov [rsp + KSIG_HANDLER], rdi; mov qword ptr [rsp + KSIG_FLAGS], SA_RESTORER
    lea rax, [rip + pf_sig_restorer]; mov [rsp + KSIG_RESTORER], rax; mov qword ptr [rsp + KSIG_MASK], 0
    mov edi, SIGWINCH; mov rdx, rsp; call pf_sig_set
    mov rax, [rsp + KSIGACTION_SIZE]; mov [rsp + KSIG_HANDLER], rax
    mov edi, SIGINT;   mov rdx, rsp; call pf_sig_set
    mov rax, [rsp + KSIGACTION_SIZE + 8]; mov [rsp + KSIG_HANDLER], rax
    mov edi, SIGTERM;  mov rdx, rsp; call pf_sig_set
    mov qword ptr [rsp + KSIG_HANDLER], KSIG_IGN
    mov edi, SIGPIPE;  mov rdx, rsp; call pf_sig_set
    lea rax, [rip + pf_term_handler]; mov [rsp + KSIG_HANDLER], rax
    mov qword ptr [rsp + KSIG_FLAGS], SA_RESTORER | SA_ONSTACK
    lea rdi, [rip + pf_term_sigs]; mov rdx, rsp; call pf_install_sig_table
    add rsp, KSIGACTION_SIZE + 16
    ret

# void os_mark_child_forked(void) - reset child TRY owner and clear inherited slot
os_mark_child_forked:
    OS_GETPID
    mov [rip + g_try_owner_pid], eax
    OS_GETTID
    mov [rip + g_try_main_tid], eax
    mov rax, [rip + g_pf_slot_ptr]
    test rax, rax
    jz .Lomcf_done
    mov qword ptr [rax], 0
.Lomcf_done:
    ret

# int os_parent_alive(int expected_ppid) -> 1 if getppid() == expected_ppid, else 0
os_parent_alive:
    OS_GETPPID
    cmp eax, edi
    sete al
    movzx eax, al
    ret

# int os_set_pdeathsig(int expected_ppid, int sig) -> 1 alive, 0 if parent died in race
os_set_pdeathsig:
    push rbx
    mov ebx, edi
    test ebx, ebx
    jle .Lospd_dead
    mov edi, PR_SET_PDEATHSIG; xor edx, edx; xor r10d, r10d; xor r8d, r8d
    mov eax, OS_SYS_prctl; syscall # fault-checked: verify parent via os_parent_alive below
    test rax, rax
    js .Lospd_chk
.Lospd_chk:
    mov edi, ebx
    call os_parent_alive
    pop rbx
    ret
.Lospd_dead:
    xor eax, eax
    pop rbx
    ret

# int os_raise_nofile(uint64_t want) -> 0 on success or -errno
os_raise_nofile:
    push rbx
    sub rsp, 16
    mov rbx, rdi
    xor edi, edi
    mov esi, RLIMIT_NOFILE
    xor edx, edx
    mov r10, rsp
    mov eax, OS_SYS_prlimit64
    syscall
    test rax, rax
    js .Lorn_ret
    mov rax, [rsp]
    mov rcx, [rsp + 8]
    cmp rax, rbx
    jae .Lorn_ok
    cmp rbx, rcx
    cmova rbx, rcx
    cmp rbx, rax
    jbe .Lorn_ok
    mov [rsp], rbx
    xor edi, edi
    mov esi, RLIMIT_NOFILE
    mov rdx, rsp
    xor r10d, r10d
    mov eax, OS_SYS_prlimit64
    syscall
    test rax, rax
    js .Lorn_ret
.Lorn_ok:
    xor eax, eax
.Lorn_ret:
    add rsp, 16
    pop rbx
    ret
