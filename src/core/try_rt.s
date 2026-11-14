# src/core/try_rt.s - Runtime state and startup installer for TRY/CATCH fault guard
.intel_syntax noprefix

.section .bss
.align 8
.global g_try_frame
g_try_frame:    .space 8

.section .text
.global os_fault_guard_install
.extern os_fault_guard_install_slot

# void os_fault_guard_install(void)
# Installs unified SA_SIGINFO handler for SIGSEGV, SIGBUS, SIGFPE once at startup.
os_fault_guard_install:
    lea rdi, [rip + g_try_frame]
    jmp os_fault_guard_install_slot
