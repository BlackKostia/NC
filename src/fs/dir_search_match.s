# src/fs/dir_search_match.s - Glob/substring name matching and file content grep
.intel_syntax noprefix

.include "pal.inc"
.include "classes.inc"

.equ SEARCH_GREP_SZ,  32768
.equ SEARCH_MAX_GREP, 1048576

.section .text
.global ds_glob_ci
.global ds_match_mask
.global ds_grep_file

.extern str_contains_ci
.extern sys_read_retry

# ==============================================================================
# int ds_glob_ci(const char *str, const char *pat)
# Case-insensitive glob matcher supporting '*' and '?'. Returns 1 on match.
# ==============================================================================
ds_glob_ci:
    xor r8d, r8d
    xor r9d, r9d
.Ldgc_loop:
    movzx eax, byte ptr [rdi]
    movzx ecx, byte ptr [rsi]
    cmp cl, '*'
    je .Ldgc_star
    test al, al
    jz .Ldgc_end_str
    cmp cl, '?'
    je .Ldgc_adv
    cmp al, 'A'
    jb .Ldgc_a_ok
    cmp al, 'Z'
    ja .Ldgc_a_ok
    add al, 32
.Ldgc_a_ok:
    cmp cl, 'A'
    jb .Ldgc_c_ok
    cmp cl, 'Z'
    ja .Ldgc_c_ok
    add cl, 32
.Ldgc_c_ok:
    cmp al, cl
    jne .Ldgc_mismatch
.Ldgc_adv:
    inc rdi
    inc rsi
    jmp .Ldgc_loop
.Ldgc_star:
    inc rsi
    mov r8, rsi
    mov r9, rdi
    jmp .Ldgc_loop
.Ldgc_mismatch:
    test r8, r8
    jz .Ldgc_fail
    inc r9
    mov rdi, r9
    mov rsi, r8
    jmp .Ldgc_loop
.Ldgc_end_str:
    cmp byte ptr [rsi], '*'
    jne .Ldgc_chk_pat
    inc rsi
    jmp .Ldgc_end_str
.Ldgc_chk_pat:
    xor eax, eax
    cmp byte ptr [rsi], 0
    sete al
    ret
.Ldgc_fail:
    xor eax, eax
    ret

# ==============================================================================
# int ds_match_mask(const char *name, const char *mask, int has_glob)
# ==============================================================================
ds_match_mask:
    test rsi, rsi
    jz .Ldmm_yes
    cmp byte ptr [rsi], 0
    je .Ldmm_yes
    test edx, edx
    jz str_contains_ci
    jmp ds_glob_ci
.Ldmm_yes:
    mov eax, 1
    ret

# ==============================================================================
# int ds_grep_file(int dirfd, const char *name, const char *pat, size_t pat_len, char *buf)
# Returns 1 if pat is found inside file (up to SEARCH_MAX_GREP bytes).
# ==============================================================================
ds_grep_file:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8
    call ds_grep_file__pat
    call ds_grep_file__total_read
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

# ds_grep_file step: pat (runs on the caller's frame)
ds_grep_file__pat:
    lea rsp, [rsp - 8]
    mov rbp, rdx              # pat
    mov r15, rcx              # pat_len
    mov rbx, r8               # buf
    mov edx, O_RDONLY | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
.Lds_grep_file__pat_ret:
    lea rsp, [rsp + 8]
    ret

# ds_grep_file step: total_read (runs on the caller's frame)
ds_grep_file__total_read:
    lea rsp, [rsp - 8]
    js .Ldgf_no
    mov r12d, eax             # fd
    xor r13d, r13d            # total_read
    xor r14d, r14d            # carry
.Ldgf_loop:
    cmp r13d, SEARCH_MAX_GREP
    jge .Ldgf_close_no
    lea rsi, [rbx + r14]
    mov edx, SEARCH_GREP_SZ - 1
    sub edx, r14d
    jle .Ldgf_close_no
    mov edi, r12d
    call sys_read_retry
    test rax, rax
    jle .Ldgf_close_no
    add r13d, eax
    add eax, r14d
    mov byte ptr [rbx + rax], 0
    mov rdi, rbx
    mov rsi, rbp
    push rax
    call str_contains_ci
    pop rcx
    test eax, eax
    jnz .Ldgf_close_yes
    lea rax, [r15 - 1]
    cmp rax, rcx
    jbe .Ldgf_ov_ok
    mov rax, rcx
.Ldgf_ov_ok:
    mov r14, rax
    test r14, r14
    jz .Ldgf_loop
    mov rsi, rbx
    add rsi, rcx
    sub rsi, r14
    xor edx, edx
.Ldgf_mv:
    mov cl, [rsi + rdx]
    mov [rbx + rdx], cl
    inc rdx
    cmp rdx, r14
    jb .Ldgf_mv
    jmp .Ldgf_loop
.Ldgf_close_yes:
    mov edi, r12d
    OS_CLOSE
    mov eax, 1
    jmp .Ldgf_ret
.Ldgf_close_no:
    mov edi, r12d
    OS_CLOSE
.Ldgf_no:
    xor eax, eax
.Ldgf_ret:
.Lds_grep_file__total_read_ret:
    lea rsp, [rsp + 8]
    ret
