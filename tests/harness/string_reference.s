# Frozen reference oracle: the hand-written asm that src/core/string.c replaced (tests/test_c_string.py diffs against it)
# Core String, Formatting, and Path Utilities

.intel_syntax noprefix
.include "pal.inc"
.include "config.inc"

.section .rodata
hex_digits:
    .ascii "0123456789abcdef"

.section .text
.global str_len
.global str_copy
.global str_cat
.global str_cmp
.global str_casecmp
.global str_contains_ci
.global str_chr
.global str_rchr
.global str_starts_with
.global u64_to_dec
.global u64_to_hex

# size_t str_len(const char *s) -- NULL-safe; preserves all registers except rax (SSE2 PAL)
str_len:
    test rdi, rdi
    jz .Lsl_null
    jmp os_str_len_fast
.Lsl_null:
    xor eax, eax
    ret

# size_t str_copy(char *dst, const char *src, size_t cap)
# Safely copies src into dst (NUL-terminated if cap > 0). Returns chars written.
str_copy:
    xor eax, eax
    test rdx, rdx
    jz .Lsc_done
    test rsi, rsi
    jz .Lsc_null
    dec rdx                   # reserve 1 byte for NUL
.Lsc_loop:
    cmp rax, rdx
    jae .Lsc_null
    mov cl, byte ptr [rsi + rax]
    test cl, cl
    jz .Lsc_null
    mov byte ptr [rdi + rax], cl
    inc rax
    jmp .Lsc_loop
.Lsc_null:
    mov byte ptr [rdi + rax], 0
.Lsc_done:
    ret

# size_t str_cat(char *dst, const char *src, size_t cap)
str_cat:
    push rbx
    push r12
    push r13
    mov rbx, rdi              # dst
    mov r12, rsi              # src
    mov r13, rdx              # cap
    call str_len
    cmp rax, r13
    jae .Lscat_done
    lea rdi, [rbx + rax]
    mov rsi, r12
    mov rdx, r13
    sub rdx, rax
    push rax
    call str_copy
    pop rcx
    add rax, rcx
.Lscat_done:
    pop r13
    pop r12
    pop rbx
    ret

# int str_cmp(const char *a, const char *b)
str_cmp:
.Lscmp_loop:
    movzx eax, byte ptr [rdi]
    movzx ecx, byte ptr [rsi]
    cmp eax, ecx
    jne .Lscmp_diff
    test eax, eax
    jz .Lscmp_eq
    inc rdi
    inc rsi
    jmp .Lscmp_loop
.Lscmp_diff:
    sub eax, ecx
    ret
.Lscmp_eq:
    xor eax, eax
    ret

# int str_casecmp(const char *a, const char *b)
str_casecmp:
.Lscc_loop:
    movzx eax, byte ptr [rdi]
    movzx ecx, byte ptr [rsi]
    cmp eax, 'A'
    jb .Lscc_a_ok
    cmp eax, 'Z'
    ja .Lscc_a_ok
    add eax, 32
.Lscc_a_ok:
    cmp ecx, 'A'
    jb .Lscc_c_ok
    cmp ecx, 'Z'
    ja .Lscc_c_ok
    add ecx, 32
.Lscc_c_ok:
    cmp eax, ecx
    jne .Lscc_diff
    test eax, eax
    jz .Lscc_eq
    inc rdi
    inc rsi
    jmp .Lscc_loop
.Lscc_diff:
    sub eax, ecx
    ret
.Lscc_eq:
    xor eax, eax
    ret

# int str_contains_ci(const char *haystack, const char *needle)
# Returns 1 if needle occurs in haystack (case-insensitive ASCII), else 0.
# Lowercases the needle once, then runs the SSE2 candidate scan (os_str_contains_ci_fast).
str_contains_ci:
    cmp byte ptr [rsi], 0
    je .Lsci_found
    push rdx
    push rsi
    sub rsp, 264
    xor ecx, ecx
.Lsci_lc:
    movzx eax, byte ptr [rsi + rcx]
    test eax, eax
    jz .Lsci_lc_done
    cmp ecx, 255
    jae .Lsci_long
    cmp eax, 'A'
    jb .Lsci_lc_put
    cmp eax, 'Z'
    ja .Lsci_lc_put
    add eax, 32
.Lsci_lc_put:
    mov [rsp + rcx], al
    inc ecx
    jmp .Lsci_lc
.Lsci_lc_done:
    mov byte ptr [rsp + rcx], 0
    mov edx, ecx
    mov rsi, rsp
    call os_str_contains_ci_fast
    add rsp, 264
    pop rsi
    pop rdx
    ret
.Lsci_long:
    add rsp, 264
    pop rsi
    pop rdx
.Lsci_outer:
    cmp byte ptr [rdi], 0
    je .Lsci_not_found
    mov r8, rdi
    mov r9, rsi
.Lsci_inner:
    movzx ecx, byte ptr [r9]
    test ecx, ecx
    jz .Lsci_found
    movzx eax, byte ptr [r8]
    test eax, eax
    jz .Lsci_not_found
    cmp eax, 'A'
    jb .Lsci_a1
    cmp eax, 'Z'
    ja .Lsci_a1
    add eax, 32
.Lsci_a1:
    cmp ecx, 'A'
    jb .Lsci_c1
    cmp ecx, 'Z'
    ja .Lsci_c1
    add ecx, 32
.Lsci_c1:
    cmp eax, ecx
    jne .Lsci_next
    inc r8
    inc r9
    jmp .Lsci_inner
.Lsci_next:
    inc rdi
    jmp .Lsci_outer
.Lsci_found:
    mov eax, 1
    ret
.Lsci_not_found:
    xor eax, eax
    ret

# const char *str_chr(const char *s, int ch)
str_chr:
.Lschr_loop:
    movzx eax, byte ptr [rdi]
    cmp eax, esi
    je .Lschr_hit
    test eax, eax
    jz .Lschr_miss
    inc rdi
    jmp .Lschr_loop
.Lschr_hit:
    mov rax, rdi
    ret
.Lschr_miss:
    xor eax, eax
    ret

# const char *str_rchr(const char *s, int ch)
str_rchr:
    xor eax, eax
.Lsrchr_loop:
    movzx ecx, byte ptr [rdi]
    cmp ecx, esi
    cmove rax, rdi
    test ecx, ecx
    jz .Lsrchr_done
    inc rdi
    jmp .Lsrchr_loop
.Lsrchr_done:
    ret

# int str_starts_with(const char *s, const char *prefix)
str_starts_with:
.Lssw_loop:
    movzx ecx, byte ptr [rsi]
    test ecx, ecx
    jz .Lssw_yes
    movzx eax, byte ptr [rdi]
    cmp eax, ecx
    jne .Lssw_no
    inc rdi
    inc rsi
    jmp .Lssw_loop
.Lssw_yes:
    mov eax, 1
    ret
.Lssw_no:
    xor eax, eax
    ret

# size_t u64_to_dec(uint64_t val, char *buf)
# buf must have >= 21 bytes. Returns length (NUL-terminated).
u64_to_dec:
    mov rax, rdi
    mov r8, rsi               # buf start
    sub rsp, 32
    xor ecx, ecx              # digit count
    mov r9, 10
.Lud_div:
    xor edx, edx
    div r9
    add dl, '0'
    mov byte ptr [rsp + rcx], dl
    inc rcx
    test rax, rax
    jnz .Lud_div

    mov rax, rcx              # return length
    xor r10d, r10d
.Lud_rev:
    dec rcx
    mov dl, byte ptr [rsp + rcx]
    mov byte ptr [r8 + r10], dl
    inc r10
    test rcx, rcx
    jnz .Lud_rev

    mov byte ptr [r8 + r10], 0
    add rsp, 32
    ret

# size_t u64_to_hex(uint64_t val, char *buf, int min_digits)
u64_to_hex:
    push rbx
    mov rax, rdi
    mov r8, rsi
    mov r9d, edx
    sub rsp, 32
    xor ecx, ecx
    lea rbx, [rip + hex_digits]
.Luh_div:
    mov r10, rax
    and r10, 15
    mov dl, byte ptr [rbx + r10]
    mov byte ptr [rsp + rcx], dl
    inc ecx
    shr rax, 4
    test rax, rax
    jnz .Luh_div
.Luh_pad:
    cmp ecx, r9d
    jge .Luh_rev_prep
    mov byte ptr [rsp + rcx], '0'
    inc ecx
    jmp .Luh_pad
.Luh_rev_prep:
    mov eax, ecx
    xor r10d, r10d
.Luh_rev:
    dec ecx
    mov dl, byte ptr [rsp + rcx]
    mov byte ptr [r8 + r10], dl
    inc r10
    test ecx, ecx
    jnz .Luh_rev
    mov byte ptr [r8 + r10], 0
    add rsp, 32
    pop rbx
    ret
