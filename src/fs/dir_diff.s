# Dir Diff helper: marks entries in active DirModel that are missing or differ in size
# compared to the opposite DirModel.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .text
.global dir_diff_mark

# int dir_diff_mark(DirModel *active, DirModel *other) -> number of differing entries
dir_diff_mark:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, 16
    mov rbx, rdi              # active
    mov r12, rsi              # other
    xor r13d, r13d            # diff_count = 0
    test rbx, rbx; jz .Lddm_done
    test r12, r12; jz .Lddm_done

    mov rcx, [rbx + DirModel.raw_count]
    mov [rsp], rcx            # active raw_count
    mov rcx, [r12 + DirModel.raw_count]
    mov [rsp + 8], rcx        # other raw_count

    xor r14d, r14d            # i = 0
.Lddm_outer:
    cmp r14, [rsp]; jae .Lddm_done
    imul r15, r14, FileEntry._size
    add r15, [rbx + DirModel.entries]
    and dword ptr [r15 + FileEntry.flags], ~FE_SELECTED

    mov eax, [r15 + FileEntry.name_off]
    add rax, [rbx + DirModel.name_pool]
    cmp word ptr [rax], 0x2e2e
    jne .Lddm_search
    cmp byte ptr [rax + 2], 0
    je .Lddm_next             # skip ".."

.Lddm_search:
    mov r8, rax               # active name ptr
    xor ecx, ecx              # j = 0
.Lddm_inner:
    cmp rcx, [rsp + 8]; jae .Lddm_mark
    imul r9, rcx, FileEntry._size
    add r9, [r12 + DirModel.entries]
    mov edx, [r9 + FileEntry.name_off]
    add rdx, [r12 + DirModel.name_pool]
    push rcx; push r8; push r9
    mov rdi, r8; mov rsi, rdx
    call str_cmp
    pop r9; pop r8; pop rcx
    test eax, eax
    jz .Lddm_found
    inc rcx
    jmp .Lddm_inner

.Lddm_found:
    mov eax, [r15 + FileEntry.flags]
    mov edx, [r9 + FileEntry.flags]
    and eax, FE_IS_DIR
    and edx, FE_IS_DIR
    cmp eax, edx
    jne .Lddm_mark
    test eax, eax
    jnz .Lddm_next            # both are directories
    mov rax, [r15 + FileEntry.size]
    cmp rax, [r9 + FileEntry.size]
    je .Lddm_next

.Lddm_mark:
    or dword ptr [r15 + FileEntry.flags], FE_SELECTED
    inc r13d

.Lddm_next:
    inc r14
    jmp .Lddm_outer

.Lddm_done:
    mov eax, r13d
    add rsp, 16; pop r15; pop r14; pop r13; pop r12; pop rbx; ret
