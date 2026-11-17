# int try_regs_probe(TryFrame *f, volatile char *bad): every callee-saved register holds a known value when os_try_begin runs,
# is clobbered, and a fault on *bad must hand the known values back when os_try_begin "returns" the second time (signal in eax).
.intel_syntax noprefix
.section .text
.global try_regs_probe
try_regs_probe:
    push rbx; push rbp; push r12; push r13; push r14; push r15
    sub rsp, 24
    mov [rsp], rsi
    mov rbx, 0x1111111111111111
    mov rbp, 0x2222222222222222
    mov r12, 0x3333333333333333
    mov r13, 0x4444444444444444
    mov r14, 0x5555555555555555
    mov r15, 0x6666666666666666
    call os_try_begin
    test eax, eax
    jnz 2f
    mov rbx, 0xdead
    mov rbp, 0xdead
    mov r12, 0xdead
    mov r13, 0xdead
    mov r14, 0xdead
    mov r15, 0xdead
    mov rax, [rsp]
    mov byte ptr [rax], 1
    mov eax, -2
    jmp 9f
2:  mov rcx, 0x1111111111111111
    cmp rbx, rcx
    jne 8f
    mov rcx, 0x2222222222222222
    cmp rbp, rcx
    jne 8f
    mov rcx, 0x3333333333333333
    cmp r12, rcx
    jne 8f
    mov rcx, 0x4444444444444444
    cmp r13, rcx
    jne 8f
    mov rcx, 0x5555555555555555
    cmp r14, rcx
    jne 8f
    mov rcx, 0x6666666666666666
    cmp r15, rcx
    jne 8f
    cmp qword ptr [rsp], 0                 # rsp is the value at the call: our spill slot is intact
    je 8f
    jmp 9f
8:  mov eax, -1
9:  add rsp, 24
    pop r15; pop r14; pop r13; pop r12; pop rbp; pop rbx
    ret
