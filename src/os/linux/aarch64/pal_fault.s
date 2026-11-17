// Duop PAL: Linux AArch64 Fault/Signal/Process Lifecycle Guard
.include "pal.inc"

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
.align 4
g_pf_slot_ptr:   .space 8
g_main_pid:      .space 4
g_try_owner_pid: .space 4
g_try_main_tid:  .space 4
.equ PF_MMAP_SLOTS, 64
.align 4
g_pf_mmap_tab:   .space PF_MMAP_SLOTS * 16
.align 4
g_sig_altstack:  .space SIGSTKSZ_BUFSZ

.section .text
.global os_fault_guard_install_slot
.global os_try_begin
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

pf_sig_restorer:
    OS_SYSCALL OS_SYS_rt_sigreturn

// void pf_reg_mmap(void *base, size_t len): remember a file mapping (SIGBUS recovery range)
pf_reg_mmap:
    cbz x0, 9f
    cbz x1, 9f
    add x1, x1, #4095
    and x1, x1, #-4096
    add x1, x1, x0                    // end
    adrp x2, g_pf_mmap_tab
    add x2, x2, :lo12:g_pf_mmap_tab
    mov w3, #0
    mov x4, #0                        // first free slot
1:
    cmp w3, #PF_MMAP_SLOTS
    b.hs 4f
    ldr x5, [x2]
    cmp x5, x0
    b.eq 5f
    cbnz x5, 2f
    cbnz x4, 2f
    mov x4, x2
2:
    add x2, x2, #16
    add w3, w3, #1
    b 1b
4:
    cbz x4, 9f
    mov x2, x4
5:
    stp x0, x1, [x2]
9:
    ret

// void pf_unreg_mmap(void *base)
pf_unreg_mmap:
    cbz x0, 9f
    adrp x2, g_pf_mmap_tab
    add x2, x2, :lo12:g_pf_mmap_tab
    mov w3, #0
1:
    cmp w3, #PF_MMAP_SLOTS
    b.hs 9f
    ldr x5, [x2]
    cmp x5, x0
    b.eq 2f
    add x2, x2, #16
    add w3, w3, #1
    b 1b
2:
    stp xzr, xzr, [x2]
9:
    ret

// int pf_is_mmap_addr(void *addr) -> 1 if inside a registered file mapping
pf_is_mmap_addr:
    cbz x0, 8f
    adrp x2, g_pf_mmap_tab
    add x2, x2, :lo12:g_pf_mmap_tab
    mov w3, #0
1:
    cmp w3, #PF_MMAP_SLOTS
    b.hs 8f
    ldp x4, x5, [x2]
    cbz x4, 2f
    cmp x0, x4
    b.lo 2f
    cmp x0, x5
    b.hs 2f
    mov w0, #1
    ret
2:
    add x2, x2, #16
    add w3, w3, #1
    b 1b
8:
    mov w0, #0
    ret

pf_sig_set:
    mov x1, x2
    mov x2, #0
    mov x3, #8
    OS_SYSCALL OS_SYS_rt_sigaction
    ret

pf_fatal_default:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    str w0, [sp, #16]
    OS_GETPID
    adrp x9, g_main_pid
    ldr w10, [x9, :lo12:g_main_pid]
    cmp w0, w10
    b.ne 1f
    bl os_term_restore
    cbz w0, 1f
    mov w0, #1
    adrp x1, pf_tty_reset
    add x1, x1, :lo12:pf_tty_reset
    mov w2, #pf_tty_reset_len
    OS_WRITE /* # fault-checked */
1:
    add x2, sp, #24
    str xzr, [x2, #KSIG_HANDLER]
    mov x9, #SA_RESTORER
    str x9, [x2, #KSIG_FLAGS]
    adrp x9, pf_sig_restorer
    add x9, x9, :lo12:pf_sig_restorer
    str x9, [x2, #KSIG_RESTORER]
    str xzr, [x2, #KSIG_MASK]
    ldr w0, [sp, #16]
    bl pf_sig_set
    OS_GETPID
    str w0, [sp, #20]
    OS_GETTID
    mov w1, w0
    ldr w0, [sp, #20]
    ldr w2, [sp, #16]
    OS_SYSCALL OS_SYS_tgkill
    ldp x29, x30, [sp], #64
    ret

// SIGBUS (SA_SIGINFO: x1 = siginfo): map a zero page over a truncated registered file mapping
pf_sigbus_fallback:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x1, [sp, #16]
    ldr x0, [x1, #KSIGINFO_ADDR]
    bl pf_is_mmap_addr
    cbz w0, 1f
    ldr x1, [sp, #16]
    ldr x0, [x1, #KSIGINFO_ADDR]
    and x0, x0, #-4096
    mov x1, #4096
    mov x2, #(PROT_READ | PROT_WRITE)
    mov x3, #(MAP_PRIVATE_ANON | MAP_FIXED)
    mov x4, #-1
    mov x5, #0
    OS_MMAP
    cmn x0, #4095
    b.hs 1f
    ldp x29, x30, [sp], #32
    ret
1:
    mov w0, #SIGBUS
    bl pf_fatal_default
    ldp x29, x30, [sp], #32
    ret

pf_term_handler:
    b pf_fatal_default

// int os_try_begin(TryFrame *f): setjmp-like. Saves x19..x30, sp and the return address in the TRY frame, links it into the chain behind
// g_pf_slot_ptr and returns 0. The fault handler below resumes here a second time (sp restored, pc = the return address, x0 = signal).
os_try_begin:
    stp x19, x20, [x0, #TF_X19]
    stp x21, x22, [x0, #TF_X19 + 16]
    stp x23, x24, [x0, #TF_X19 + 32]
    stp x25, x26, [x0, #TF_X19 + 48]
    stp x27, x28, [x0, #TF_X19 + 64]
    stp x29, x30, [x0, #TF_X19 + 80]
    mov x9, sp
    str x9, [x0, #TF_SP]
    str x30, [x0, #TF_PC]
    adrp x9, g_pf_slot_ptr
    ldr x9, [x9, :lo12:g_pf_slot_ptr]
    mov x10, #0
    cbz x9, 1f
    ldr x10, [x9]
    str x0, [x9]
1:  str x10, [x0, #TF_PREV]
    mov w0, #0
    ret

// void pf_fault_handler(int sig, siginfo_t *info, void *uctx): with an active TRY frame (main thread of this process only) patch the
// interrupted context so that rt_sigreturn resumes at the frame's os_try_begin; otherwise SIGBUS on a registered mapping is
// mapped over with a zero page and everything else is fatal.
pf_fault_handler:
    adrp x8, g_pf_slot_ptr
    ldr x8, [x8, :lo12:g_pf_slot_ptr]
    cbz x8, pf_no_try
    ldr x9, [x8]
    cbz x9, pf_no_try
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x0, x1, [sp, #16]
    str x2, [sp, #32]
    str x8, [sp, #40]
    OS_GETPID
    mov w10, w0
    adrp x9, g_try_owner_pid
    ldr w11, [x9, :lo12:g_try_owner_pid]
    cmp w10, w11
    b.ne 1f
    OS_GETTID
    adrp x9, g_try_main_tid
    ldr w11, [x9, :lo12:g_try_main_tid]
    cmp w0, w11
    b.ne 3f
    b 2f
1:  OS_GETTID                               // forked child: its main thread has tid == pid
    cmp w0, w10
    b.ne 3f
2:  ldr x8, [sp, #40]
    ldr x9, [x8]
    ldr x2, [sp, #32]
    ldr x10, [x9, #TF_PREV]                 // pop the frame first: a fault in the catch path must not loop
    str x10, [x8]
    ldp x10, x11, [x9, #TF_X19]
    stp x10, x11, [x2, #KUC_X19]
    ldp x10, x11, [x9, #TF_X19 + 16]
    stp x10, x11, [x2, #KUC_X19 + 16]
    ldp x10, x11, [x9, #TF_X19 + 32]
    stp x10, x11, [x2, #KUC_X19 + 32]
    ldp x10, x11, [x9, #TF_X19 + 48]
    stp x10, x11, [x2, #KUC_X19 + 48]
    ldp x10, x11, [x9, #TF_X19 + 64]
    stp x10, x11, [x2, #KUC_X19 + 64]
    ldp x10, x11, [x9, #TF_X19 + 80]
    stp x10, x11, [x2, #KUC_X19 + 80]
    ldr x10, [x9, #TF_SP]
    str x10, [x2, #KUC_SP]
    ldr x10, [x9, #TF_PC]
    str x10, [x2, #KUC_PC]
    ldrsw x10, [sp, #16]                    // x0 of the resumed os_try_begin = the signal number
    str x10, [x2, #KUC_RET]
    ldp x29, x30, [sp], #64
    ret
3:  ldp x0, x1, [sp, #16]
    ldp x29, x30, [sp], #64
pf_no_try:
    cmp w0, #SIGBUS
    b.eq pf_sigbus_fallback
    b pf_fatal_default

pf_install_sig_table:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov x19, x0
    mov x20, x2
1:
    ldrb w0, [x19], #1
    cbz w0, 2f
    mov x2, x20
    bl pf_sig_set
    b 1b
2:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

os_fault_guard_install_slot:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    adrp x9, g_pf_slot_ptr
    str x0, [x9, :lo12:g_pf_slot_ptr]
    OS_GETPID
    adrp x9, g_main_pid
    str w0, [x9, :lo12:g_main_pid]
    adrp x9, g_try_owner_pid
    str w0, [x9, :lo12:g_try_owner_pid]
    OS_GETTID
    adrp x9, g_try_main_tid
    str w0, [x9, :lo12:g_try_main_tid]

    add x0, sp, #16
    adrp x9, g_sig_altstack
    add x9, x9, :lo12:g_sig_altstack
    str x9, [x0, #KSTACK_T_SP]
    str xzr, [x0, #KSTACK_T_FLAGS]
    mov x9, #SIGSTKSZ_BUFSZ
    str x9, [x0, #KSTACK_T_SZ]
    mov x1, #0
    OS_SYSCALL OS_SYS_sigaltstack

    add x2, sp, #16
    adrp x9, pf_fault_handler
    add x9, x9, :lo12:pf_fault_handler
    str x9, [x2, #KSIG_HANDLER]
    movz x9, #(SA_RESTORER | SA_SIGINFO | SA_ONSTACK) & 0xFFFF
    movk x9, #((SA_RESTORER | SA_SIGINFO | SA_ONSTACK) >> 16), lsl #16
    str x9, [x2, #KSIG_FLAGS]
    adrp x9, pf_sig_restorer
    add x9, x9, :lo12:pf_sig_restorer
    str x9, [x2, #KSIG_RESTORER]
    str xzr, [x2, #KSIG_MASK]

    adrp x0, pf_core_sigs
    add x0, x0, :lo12:pf_core_sigs
    add x2, sp, #16
    bl pf_install_sig_table
    ldp x29, x30, [sp], #64
    ret

os_sig_reset_pipe:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    add x2, sp, #16
    str xzr, [x2, #KSIG_HANDLER]
    mov x9, #SA_RESTORER
    str x9, [x2, #KSIG_FLAGS]
    adrp x9, pf_sig_restorer
    add x9, x9, :lo12:pf_sig_restorer
    str x9, [x2, #KSIG_RESTORER]
    str xzr, [x2, #KSIG_MASK]
    mov w0, #SIGPIPE
    bl pf_sig_set
    ldp x29, x30, [sp], #48
    ret

os_signals_install:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    stp x1, x2, [sp, #16]
    add x2, sp, #32
    str x0, [x2, #KSIG_HANDLER]
    mov x9, #SA_RESTORER
    str x9, [x2, #KSIG_FLAGS]
    adrp x9, pf_sig_restorer
    add x9, x9, :lo12:pf_sig_restorer
    str x9, [x2, #KSIG_RESTORER]
    str xzr, [x2, #KSIG_MASK]
    mov w0, #SIGWINCH; add x2, sp, #32; bl pf_sig_set
    ldr x9, [sp, #16]; str x9, [sp, #32 + KSIG_HANDLER]
    mov w0, #SIGINT;   add x2, sp, #32; bl pf_sig_set
    ldr x9, [sp, #24]; str x9, [sp, #32 + KSIG_HANDLER]
    mov w0, #SIGTERM;  add x2, sp, #32; bl pf_sig_set
    mov x9, #KSIG_IGN;  str x9, [sp, #32 + KSIG_HANDLER]
    mov w0, #SIGPIPE;  add x2, sp, #32; bl pf_sig_set
    adrp x9, pf_term_handler; add x9, x9, :lo12:pf_term_handler
    str x9, [sp, #32 + KSIG_HANDLER]
    movz x9, #((SA_RESTORER | SA_ONSTACK) >> 16), lsl #16
    str x9, [sp, #32 + KSIG_FLAGS]
    adrp x0, pf_term_sigs; add x0, x0, :lo12:pf_term_sigs
    add x2, sp, #32
    bl pf_install_sig_table
    ldp x29, x30, [sp], #64
    ret

os_mark_child_forked:
    OS_GETPID
    adrp x9, g_try_owner_pid
    str w0, [x9, :lo12:g_try_owner_pid]
    OS_GETTID
    adrp x9, g_try_main_tid
    str w0, [x9, :lo12:g_try_main_tid]
    adrp x9, g_pf_slot_ptr
    ldr x10, [x9, :lo12:g_pf_slot_ptr]
    cbz x10, 1f
    str xzr, [x10]
1:
    ret

os_parent_alive:
    mov w9, w0
    OS_GETPPID
    cmp w0, w9
    cset w0, eq
    ret

os_set_pdeathsig:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    cmp w0, #0
    b.le 1f
    str w0, [sp, #16]
    mov w0, #PR_SET_PDEATHSIG
    mov x2, #0
    mov x3, #0
    mov x4, #0
    OS_SYSCALL OS_SYS_prctl /* # fault-checked: verified via os_parent_alive */
    cmp x0, #0
    ldr w0, [sp, #16]
    bl os_parent_alive
    b 2f
1:
    mov w0, #0
2:
    ldp x29, x30, [sp], #32
    ret

os_raise_nofile:
    sub sp, sp, #16
    mov x9, x0
    mov x0, #0
    mov x1, #RLIMIT_NOFILE
    mov x2, #0
    mov x3, sp
    OS_SYSCALL OS_SYS_prlimit64
    cmp x0, #0
    b.lt 1f
    ldr x10, [sp, #0]
    ldr x11, [sp, #8]
    cmp x10, x9
    b.hs 2f
    cmp x9, x11
    csel x9, x9, x11, lo
    cmp x9, x10
    b.ls 2f
    str x9, [sp, #0]
    mov x0, #0
    mov x1, #RLIMIT_NOFILE
    mov x2, sp
    mov x3, #0
    OS_SYSCALL OS_SYS_prlimit64
    b 1f
2:
    mov w0, #0
1:
    add sp, sp, #16
    ret
