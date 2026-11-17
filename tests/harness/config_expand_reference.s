# Frozen reference oracle: the hand-written asm that src/core/config_expand.c replaced (tests/test_c_config_expand.py)
# Duop Runtime Configuration (~/.config/duop/duoprc) — shell command template expansion (split from config.s)
#
# config_expand_cmd turns a User Menu / open-rule template into a /bin/sh script. Placeholders:
#   %f current name   %p current full path   %d / %D active / opposite pane directory
#   %F / %s  every marked name (or the current one): one shell word per name, space separated
#   %%       a literal percent sign
# Every value is escaped for the quoting context in force at the placeholder (none, '...' or "...")
# so no file name can end its word, and a backslash in the template protects the next byte. The
# expansion is all-or-nothing: if it does not fit the output buffer the call fails, the output is
# emptied and the command MUST NOT be run (a truncated command would act on the wrong target).

.intel_syntax noprefix
.include "pal.inc"

.section .text
.global config_expand_cmd

# size_t cec_emit_sq(char *out, size_t i, size_t max, const char *src, int mode)
# mode 0: writes '<src>' with its own quotes; mode 1: already inside '...' (no wrapper).
# ' becomes '\''. Returns the new index or -1 when it does not fit; rcx -> the NUL of src.
cec_emit_sq:
    mov rax, rsi
    test r8d, r8d
    jnz .Lces_loop
    cmp rax, rdx; jae .Lces_over
    mov byte ptr [rdi + rax], '\''
    inc rax
.Lces_loop:
    movzx r10d, byte ptr [rcx]
    test r10d, r10d; jz .Lces_end
    cmp r10d, '\''; je .Lces_esc
    cmp rax, rdx; jae .Lces_over
    mov [rdi + rax], r10b
    inc rax; inc rcx
    jmp .Lces_loop
.Lces_esc:
    lea r11, [rax + 4]; cmp r11, rdx; ja .Lces_over
    mov dword ptr [rdi + rax], 0x27275C27             # '\''
    add rax, 4; inc rcx
    jmp .Lces_loop
.Lces_end:
    test r8d, r8d; jnz .Lces_ret
    cmp rax, rdx; jae .Lces_over
    mov byte ptr [rdi + rax], '\''
    inc rax
.Lces_ret:
    ret
.Lces_over:
    mov rax, -1
    ret

# size_t cec_emit_dq(char *out, size_t i, size_t max, const char *src)
# Inside "...": " \ $ ` get a backslash. Returns the new index or -1; rcx -> the NUL of src.
cec_emit_dq:
    mov rax, rsi
.Lced_loop:
    movzx r10d, byte ptr [rcx]
    test r10d, r10d; jz .Lced_ret
    cmp r10d, '"'; je .Lced_esc
    cmp r10d, '\\'; je .Lced_esc
    cmp r10d, '$'; je .Lced_esc
    cmp r10d, '`'; je .Lced_esc
    cmp rax, rdx; jae .Lced_over
    mov [rdi + rax], r10b
    inc rax; inc rcx
    jmp .Lced_loop
.Lced_esc:
    lea r11, [rax + 2]; cmp r11, rdx; ja .Lced_over
    mov byte ptr [rdi + rax], '\\'
    mov [rdi + rax + 1], r10b
    add rax, 2; inc rcx
    jmp .Lced_loop
.Lced_ret:
    ret
.Lced_over:
    mov rax, -1
    ret

# size_t cec_emit_value(char *out, size_t i, size_t max, const char *val, int mode, int is_list)
# One placeholder value escaped for `mode` (0 none, 1 '...', 2 "..."). A list is NUL separated
# names ended by an empty name, emitted as space separated words (each word quoted in mode 0).
# Returns the new index or -1 when the output buffer is too small; NULL val emits nothing.
cec_emit_value:
    mov rax, rsi
    test rcx, rcx; jz .Lcev_ret
    push rbx; push r12; push r13; push r14; push r15
    mov rbx, rdi; mov r12, rdx; mov r13, rcx; mov r14d, r8d; mov r15d, r9d
.Lcev_one:
    mov rdi, rbx; mov rsi, rax; mov rdx, r12; mov rcx, r13; mov r8d, r14d
    cmp r14d, 2; je .Lcev_dq
    call cec_emit_sq
    jmp .Lcev_got
.Lcev_dq:
    call cec_emit_dq
.Lcev_got:
    test rax, rax; js .Lcev_done
    test r15d, r15d; jz .Lcev_done
    lea r13, [rcx + 1]                                # next name
    cmp byte ptr [r13], 0; je .Lcev_done
    cmp rax, r12; jae .Lcev_over
    mov byte ptr [rbx + rax], ' '
    inc rax
    jmp .Lcev_one
.Lcev_over:
    mov rax, -1
.Lcev_done:
    pop r15; pop r14; pop r13; pop r12; pop rbx
.Lcev_ret:
    ret

# int cec_update_quote(int qmode, uint8_t ch) -> new qmode (0 none, 1 single, 2 double)
cec_update_quote:
    mov eax, edi
    cmp sil, '\''
    jne .Lcuq_dq
    cmp eax, 2
    je .Lcuq_ret
    xor eax, 1
    ret
.Lcuq_dq:
    cmp sil, '"'
    jne .Lcuq_ret
    cmp eax, 1
    je .Lcuq_ret
    xor eax, 2
.Lcuq_ret:
    ret

# const char *cec_lookup_var(uint8_t ch, const ConfigExpandCtx *ctx, int *out_is_list)
# -> value (0 = unset), r8d = 1 when ch is not a placeholder letter
cec_lookup_var:
    xor eax, eax
    mov dword ptr [rdx], 0
    xor r8d, r8d
    cmp dil, 'f'; jne .Lclv_p
    mov rax, [rsi + 0]; ret
.Lclv_p:
    cmp dil, 'p'; jne .Lclv_F
    mov rax, [rsi + 8]; ret
.Lclv_F:
    cmp dil, 'F'; jne .Lclv_s
    mov rax, [rsi + 16]; mov dword ptr [rdx], 1; ret
.Lclv_s:
    cmp dil, 's'; jne .Lclv_d
    mov rax, [rsi + 16]; mov dword ptr [rdx], 1; ret
.Lclv_d:
    cmp dil, 'd'; jne .Lclv_D
    mov rax, [rsi + 24]; ret
.Lclv_D:
    cmp dil, 'D'; jne .Lclv_unk
    mov rax, [rsi + 32]; ret
.Lclv_unk:
    mov r8d, 1; ret

# int config_expand_cmd(const char *tmpl, char *out, size_t cap, const ConfigExpandCtx *ctx)
# ConfigExpandCtx: +0 cur_name, +8 cur_path, +16 selection list (NUL separated names, ended by an
# empty name), +24 active_dir, +32 inactive_dir.
# Returns 0, or -ENAMETOOLONG when the expansion does not fit (out is then an empty string).
config_expand_cmd:
    push rbx; push rbp; push r12; push r13; push r14; push r15
    sub rsp, 24
    mov rbx, rdi              # template cursor
    mov r12, rsi              # out
    mov r14, rcx              # ctx
    xor ebp, ebp              # out index
    xor r15d, r15d            # quote mode
    test rdx, rdx; jz .Lcec_nocap
    lea r13, [rdx - 1]        # max: the last byte is reserved for the NUL
.Lcec_loop:
    movzx eax, byte ptr [rbx]
    test al, al; jz .Lcec_ok
    cmp al, '%'; jne .Lcec_lit
    movzx edx, byte ptr [rbx + 1]
    test dl, dl; jz .Lcec_lit
    cmp dl, '%'; je .Lcec_pct
    mov edi, edx; mov rsi, r14; mov rdx, rsp
    call cec_lookup_var
    test r8d, r8d; jnz .Lcec_unknown
    add rbx, 2
    mov rdi, r12; mov rsi, rbp; mov rdx, r13; mov rcx, rax; mov r8d, r15d; mov r9d, [rsp]
    call cec_emit_value
    test rax, rax; js .Lcec_over
    mov rbp, rax
    jmp .Lcec_loop
.Lcec_unknown:
    movzx eax, byte ptr [rbx]                         # "%x", x unknown: the '%' stays literal
.Lcec_lit:
    cmp r15d, 1; je .Lcec_plain                       # inside '...' a backslash is an ordinary byte
    cmp al, '\\'; jne .Lcec_plain
    movzx edx, byte ptr [rbx + 1]
    test dl, dl; jz .Lcec_plain
    lea rcx, [rbp + 2]; cmp rcx, r13; ja .Lcec_over   # backslash protects the next template byte
    mov byte ptr [r12 + rbp], '\\'
    mov [r12 + rbp + 1], dl
    mov rbp, rcx; add rbx, 2
    jmp .Lcec_loop
.Lcec_plain:
    mov edi, r15d; mov esi, eax
    call cec_update_quote
    mov r15d, eax
    movzx eax, byte ptr [rbx]
    cmp rbp, r13; jae .Lcec_over
    mov [r12 + rbp], al
    inc rbp; inc rbx
    jmp .Lcec_loop
.Lcec_pct:
    cmp rbp, r13; jae .Lcec_over
    mov byte ptr [r12 + rbp], '%'
    inc rbp; add rbx, 2
    jmp .Lcec_loop
.Lcec_ok:
    mov byte ptr [r12 + rbp], 0
    xor eax, eax
    jmp .Lcec_ret
.Lcec_over:
    mov byte ptr [r12], 0                             # never leave a runnable half-command behind
.Lcec_nocap:
    mov rax, -ENAMETOOLONG
.Lcec_ret:
    add rsp, 24
    pop r15; pop r14; pop r13; pop r12; pop rbp; pop rbx
    ret
