# int try_mix_probe(volatile char *bad) -> 11011 = C TRY caught SIGSEGV, then the assembly TRY caught SIGSEGV: an assembly TRY_BEGIN frame (try_using.inc) around a call into C that opens its own TRY
# (os_try_begin) - both kinds live in one g_try_frame chain. The C TRY catches the first fault; the assembly CATCH the second.
.intel_syntax noprefix
.include "pal.inc"
.include "try_using.inc"
.section .text
.global try_mix_probe
.extern try_mix_c
try_mix_probe:
    push rbx; push r12
    sub rsp, TRY_FRAME_SIZE + 8
    mov rbx, rdi
    lea r12, [rsp]
    TRY_BEGIN r12, .Lcatch
    mov rdi, rbx
    call try_mix_c                         # int: signal caught by the C TRY (11 expected), 0 if none
    mov [rsp + TRY_FRAME_SIZE], eax        # keep it in memory: the fault resume restores rsp, not the scratch registers
    mov byte ptr [rbx], 1                  # fault in the assembly TRY: the chain is back to our frame
    mov eax, -5
    jmp .Ldone
.Lcatch:
    mov ecx, [rsp + TRY_FRAME_SIZE]
    imul ecx, ecx, 1000
    add eax, ecx                           # 1000 * (signal the C TRY caught) + (signal the assembly TRY caught)
.Ldone:
    add rsp, TRY_FRAME_SIZE + 8
    pop r12; pop rbx
    ret
