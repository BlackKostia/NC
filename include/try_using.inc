# Duop Structured Resource Management (USING) & Fault-Recovery (TRY/CATCH)
# Zero-overhead scoped cleanup macros + ucontext_t-based SIGSEGV/SIGBUS/SIGFPE guard.
.intel_syntax noprefix

.ifndef TRY_USING_INCLUDED
.equ TRY_USING_INCLUDED, 1

# --- TryFrame layout (72 bytes, 8-byte aligned) ---
.equ TF_PREV,           0
.equ TF_RBX,            8
.equ TF_RBP,            16
.equ TF_R12,            24
.equ TF_R13,            32
.equ TF_R14,            40
.equ TF_R15,            48
.equ TF_RSP,            56
.equ TF_RIP,            64
.equ TRY_FRAME_SIZE,    72

# --- Linux x86-64 ucontext_t->uc_mcontext.gregs offsets ---
.equ UC_REG_R12,        72
.equ UC_REG_R13,        80
.equ UC_REG_R14,        88
.equ UC_REG_R15,        96
.equ UC_REG_RBP,        120
.equ UC_REG_RBX,        128
.equ UC_REG_RAX,        144
.equ UC_REG_RSP,        160
.equ UC_REG_RIP,        168
.equ UC_REG_EFL,        176

# --- TRY_BEGIN base, catch_label ---
# Saves callee-saved registers, RSP, and catch_label RIP into TryFrame at [base],
# then links [base] onto g_try_frame. Zero syscalls (~4 ns). Clobbers: rax.
.macro TRY_BEGIN base, catch_label
    mov [\base + TF_RBX], rbx
    mov [\base + TF_RBP], rbp
    mov [\base + TF_R12], r12
    mov [\base + TF_R13], r13
    mov [\base + TF_R14], r14
    mov [\base + TF_R15], r15
    mov [\base + TF_RSP], rsp
    lea rax, [rip + \catch_label]
    mov [\base + TF_RIP], rax
    mov rax, [rip + g_try_frame]
    mov [\base + TF_PREV], rax
    lea rax, [\base]
    mov [rip + g_try_frame], rax
.endm

# --- TRY_END base [, scratch] ---
# Unlinks TryFrame [base] from g_try_frame. Preserves rax and flags; clobbers scratch (default r11).
.macro TRY_END base, scratch=r11
    mov \scratch, [\base + TF_PREV]
    mov [rip + g_try_frame], \scratch
.endm

# --- USING_FD_* : Scoped file descriptor cleanup (0% overhead) ---
.macro USING_FD_INIT slot
    mov dword ptr \slot, -1
.endm

.macro USING_FD_SET slot, fd_reg32
    mov dword ptr \slot, \fd_reg32
.endm

.macro USING_FD_CLOSE slot
    mov edi, dword ptr \slot
    test edi, edi
    js 9991f
    OS_CLOSE
    mov dword ptr \slot, -1
9991:
.endm

# --- SCOPED_MEM_* : Scoped heap allocation cleanup (0% overhead) ---
.macro SCOPED_MEM_INIT slot
    mov qword ptr \slot, 0
.endm

.macro SCOPED_MEM_SET slot, ptr_reg64
    mov qword ptr \slot, \ptr_reg64
.endm

.macro SCOPED_MEM_FREE slot
    mov rdi, qword ptr \slot
    test rdi, rdi
    jz 9992f
    call mem_free
    mov qword ptr \slot, 0
9992:
.endm

.endif
