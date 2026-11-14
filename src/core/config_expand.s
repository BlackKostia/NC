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
.equ CFG_TOTAL_SZ,    15008
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

# void config_expand_cmd(const char *tmpl, char *out, size_t cap, const ConfigExpandCtx *ctx)
# ConfigExpandCtx: +0 cur_name, +8 cur_path, +16 sel_names, +24 active_dir, +32 inactive_dir
config_expand_cmd:
    push rbx
    push r12
    push r13
    push r14
    mov rbx, rdi              # tmpl
    mov r12, rsi              # out
    mov r13, rdx              # cap
    mov r14, rcx              # ctx
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
    xor r8d, r8d
    cmp dl, 'f'; jne .Lcec_p
    mov r8, [r14 + 0]; jmp .Lcec_sub
.Lcec_p:
    cmp dl, 'p'; jne .Lcec_F
    mov r8, [r14 + 8]; jmp .Lcec_sub
.Lcec_F:
    cmp dl, 'F'; jne .Lcec_s
    mov r8, [r14 + 16]; jmp .Lcec_sub
.Lcec_s:
    cmp dl, 's'; jne .Lcec_d
    mov r8, [r14 + 16]; jmp .Lcec_sub
.Lcec_d:
    cmp dl, 'd'; jne .Lcec_D
    mov r8, [r14 + 24]; jmp .Lcec_sub
.Lcec_D:
    cmp dl, 'D'; jne .Lcec_lit
    mov r8, [r14 + 32]
.Lcec_sub:
    add rbx, 2
    test r8, r8
    jz .Lcec_loop
.Lcec_cp:
    movzx eax, byte ptr [r8]
    test al, al
    jz .Lcec_loop
    cmp rcx, r13
    jae .Lcec_done
    mov [r12 + rcx], al
    inc rcx
    inc r8
    jmp .Lcec_cp

.Lcec_pct:
    add rbx, 2
    cmp rcx, r13
    jae .Lcec_done
    mov byte ptr [r12 + rcx], '%'
    inc rcx
    jmp .Lcec_loop

.Lcec_lit:
    cmp rcx, r13
    jae .Lcec_done
    mov [r12 + rcx], al
    inc rcx
    inc rbx
    jmp .Lcec_loop

.Lcec_done:
    mov byte ptr [r12 + rcx], 0
.Lcec_ret:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
