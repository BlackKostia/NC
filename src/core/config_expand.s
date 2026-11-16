# Duop Runtime Configuration (~/.config/duop/duoprc) & User Menu Expansion — config expand (split from config.s)

.intel_syntax noprefix
.include "pal.inc"
.include "config.inc"
.include "types.inc"
.equ CFG_MAX_BINDS,   32
.equ CFG_MAX_OPENS,   32
.equ CFG_MAX_MENUS,   24
.equ CFG_BIND_SZ,     16      # key(4), mods(4), action(4), pad(4)
.equ CFG_OPEN_SZ,     256     # ext(16), cmd(240)
.equ CFG_MENU_SZ,     256     # label(64), cmd(192)
.equ CFG_THEME,       0
.equ CFG_LANG,        4
.equ CFG_HIDDEN,      8
.equ CFG_SORT,        12
.equ CFG_COLOR_MASK,  16
.equ CFG_BIND_CNT,    20
.equ CFG_OPEN_CNT,    24
.equ CFG_MENU_CNT,    28
.equ CFG_COLORS,      32
.equ CFG_BINDS,       160
.equ CFG_OPENS,       672
.equ CFG_MENUS,       8864
.equ CFG_TOTAL_SZ,    15024         # + CFG_LANG_ID (config.inc)
.equ CFG_FILE_MAX,    16384
.equ COLOR_FIELD_COUNT, 29
.equ ACTION_NAME_COUNT, 19
.equ DEFAULT_MENU_COUNT, 3
.extern mem_alloc
.extern mem_free
.extern mem_zero
.extern sys_read_retry
.extern str_len
.extern str_copy
.extern str_cmp
.extern str_casecmp
.extern str_starts_with
.extern path_join

.section .text
.global config_expand_cmd

# Helper: size_t cec_emit_sq(char *out, size_t rax, size_t rdx, const char *rcx, int r8d)
cec_emit_sq:
    test r8d, r8d
    jnz .Lces_loop
    cmp rax, rdx
    jae .Lces_ret
    mov byte ptr [rdi + rax], '\''
    inc rax
.Lces_loop:
    movzx r10d, byte ptr [rcx]
    test r10d, r10d
    jz .Lces_end
    cmp r10d, '\''
    je .Lces_esc
    cmp rax, rdx
    jae .Lces_ret
    mov [rdi + rax], r10b
    inc rax
    inc rcx
    jmp .Lces_loop
.Lces_esc:
    lea r11, [rax + 4]
    cmp r11, rdx
    ja .Lces_ret
    mov byte ptr [rdi + rax], '\''
    mov byte ptr [rdi + rax + 1], '\\'
    mov byte ptr [rdi + rax + 2], '\''
    mov byte ptr [rdi + rax + 3], '\''
    add rax, 4
    inc rcx
    jmp .Lces_loop
.Lces_end:
    test r8d, r8d
    jnz .Lces_ret
    cmp rax, rdx
    jae .Lces_ret
    mov byte ptr [rdi + rax], '\''
    inc rax
.Lces_ret:
    ret

# Helper: size_t cec_emit_dq(char *out, size_t rax, size_t rdx, const char *rcx)
cec_emit_dq:
    movzx r10d, byte ptr [rcx]
    test r10d, r10d
    jz .Lced_ret
    cmp r10d, '"';  je .Lced_esc
    cmp r10d, '\\'; je .Lced_esc
    cmp r10d, '$';  je .Lced_esc
    cmp r10d, '`';  je .Lced_esc
    cmp rax, rdx
    jae .Lced_ret
    mov [rdi + rax], r10b
    inc rax
    inc rcx
    jmp cec_emit_dq
.Lced_esc:
    lea r11, [rax + 2]
    cmp r11, rdx
    ja .Lced_ret
    mov byte ptr [rdi + rax], '\\'
    mov [rdi + rax + 1], r10b
    add rax, 2
    inc rcx
    jmp cec_emit_dq
.Lced_ret:
    ret

# Helper: size_t cec_emit_escaped(char *out, size_t out_i, size_t max_i, const char *val, int qmode, int raw)
cec_emit_escaped:
    mov rax, rsi
    test rcx, rcx
    jz .Lcee_ret
    test r9d, r9d
    jnz .Lcee_raw
    cmp r8d, 2
    je cec_emit_dq
    jmp cec_emit_sq
.Lcee_raw:
    movzx r10d, byte ptr [rcx]
    test r10d, r10d
    jz .Lcee_ret
    cmp rax, rdx
    jae .Lcee_ret
    mov [rdi + rax], r10b
    inc rax
    inc rcx
    jmp .Lcee_raw
.Lcee_ret:
    ret

# Helper: int cec_update_quote(int qmode, uint8_t ch)
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

# Helper: const char *cec_lookup_var(uint8_t ch, const ConfigExpandCtx *ctx, int *out_raw) -> val or NULL (r8d=1 if unknown)
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

# void config_expand_cmd(const char *tmpl, char *out, size_t cap, const ConfigExpandCtx *ctx)
# ConfigExpandCtx: +0 cur_name, +8 cur_path, +16 sel_names, +24 active_dir, +32 inactive_dir
config_expand_cmd:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi              # tmpl
    mov r12, rsi              # out
    mov r13, rdx              # cap
    mov r14, rcx              # ctx
    xor r15d, r15d            # quote_mode: 0=none, 1=single, 2=double
    test r13, r13
    jz .Lcec_ret
    dec r13                   # reserve NUL
    xor ecx, ecx              # out_i = 0

.Lcec_loop:
    movzx eax, byte ptr [rbx]
    test al, al
    jz .Lcec_done
    cmp al, '%'
    jne .Lcec_lit
    movzx edx, byte ptr [rbx + 1]
    test dl, dl
    jz .Lcec_lit

    cmp dl, '%'
    je .Lcec_pct
    sub rsp, 16
    mov edi, edx
    mov rsi, r14
    mov rdx, rsp
    mov r10, rcx
    call cec_lookup_var
    mov r9d, [rsp]
    add rsp, 16
    mov rcx, r10
    test r8d, r8d
    jnz .Lcec_lit_restore
    add rbx, 2
    mov rdi, r12
    mov rsi, rcx
    mov rdx, r13
    mov rcx, rax
    mov r8d, r15d
    call cec_emit_escaped
    mov rcx, rax
    jmp .Lcec_loop
.Lcec_lit_restore:
    movzx eax, byte ptr [rbx]
    jmp .Lcec_lit

.Lcec_pct:
    add rbx, 2
    cmp rcx, r13
    jae .Lcec_done
    mov byte ptr [r12 + rcx], '%'
    inc rcx
    jmp .Lcec_loop

.Lcec_lit:
    mov edi, r15d
    mov esi, eax
    call cec_update_quote
    mov r15d, eax
    cmp rcx, r13
    jae .Lcec_done
    mov [r12 + rcx], sil
    inc rcx
    inc rbx
    jmp .Lcec_loop

.Lcec_done:
    mov byte ptr [r12 + rcx], 0
.Lcec_ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
