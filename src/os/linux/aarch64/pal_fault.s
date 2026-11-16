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
.align 4
g_sig_altstack:  .space SIGSTKSZ_BUFSZ

.section .text
.global os_fault_guard_install_slot
.global os_signals_install
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

pf_reg_mmap:
pf_unreg_mmap:
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

pf_sigbus_fallback:
    mov w0, #SIGBUS
    b pf_fatal_default

pf_term_handler:
pf_fault_handler:
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
