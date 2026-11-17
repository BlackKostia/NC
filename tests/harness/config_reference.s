# Frozen reference oracle: the hand-written asm that src/core/config.c replaced (tests/test_c_config.py diffs against it)
# Duop Runtime Configuration (~/.config/duop/duoprc) & User Menu Expansion
# Pure x86-64 GAS, zero .data, PAL-clean (no raw syscalls, no upward layer deps).

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

.section .rodata

pfx_ctrl:          .asciz "ctrl+"
pfx_alt:           .asciz "alt+"

.section .text
.global cfg_getenv
.global skip_ws
.global parse_hex_rgb
.global parse_key_spec
.global next_token

# Helper: const char *cfg_getenv(char **envp, const char *key_eq)
cfg_getenv:
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    test rbx, rbx
    jz .Lcge_none
    mov rdi, r12
    call str_len
    mov rcx, rax
.Lcge_loop:
    mov rdx, [rbx]
    test rdx, rdx
    jz .Lcge_none
    push rcx
    mov rdi, rdx
    mov rsi, r12
    call str_starts_with
    pop rcx
    test eax, eax
    jnz .Lcge_found
    add rbx, 8
    jmp .Lcge_loop
.Lcge_found:
    mov rax, [rbx]
    add rax, rcx
    pop r12
    pop rbx
    ret
.Lcge_none:
    xor eax, eax
    pop r12
    pop rbx
    ret

# Helper: skip spaces/tabs; returns advanced ptr in rax
skip_ws:
    mov rax, rdi
.Lsw_loop:
    movzx ecx, byte ptr [rax]
    cmp cl, ' '
    je .Lsw_next
    cmp cl, '\t'
    je .Lsw_next
    ret
.Lsw_next:
    inc rax
    jmp .Lsw_loop

# Helper: parse hex digit in al -> 0..15 or -1
hex_val:
    cmp al, '0'; jb .Lhv_bad
    cmp al, '9'; jbe .Lhv_dig
    or al, 0x20
    cmp al, 'a'; jb .Lhv_bad
    cmp al, 'f'; ja .Lhv_bad
    sub al, 'a' - 10
    movzx eax, al
    ret
.Lhv_dig:
    sub al, '0'
    movzx eax, al
    ret
.Lhv_bad:
    mov eax, -1
    ret

# Helper: parse "#RRGGBB" or "RRGGBB" -> rax = 0x01RRGGBB or -1
parse_hex_rgb:
    push rbx
    mov rbx, rdi
    cmp byte ptr [rbx], '#'
    jne .Lphr_digits
    inc rbx
.Lphr_digits:
    xor ecx, ecx              # acc
    xor edx, edx              # i = 0..5
.Lphr_loop:
    cmp edx, 6
    jae .Lphr_ok
    mov al, [rbx + rdx]
    call hex_val
    test eax, eax
    js .Lphr_bad
    shl ecx, 4
    or ecx, eax
    inc edx
    jmp .Lphr_loop
.Lphr_ok:
    or ecx, 0x01000000
    mov eax, ecx
    pop rbx
    ret
.Lphr_bad:
    mov eax, -1
    pop rbx
    ret

# Helper: parse key spec ("F1".."F12", "Ctrl+X", "Alt+X", or single char)
# rdi = tok -> eax = key, edx = mods (or eax = 0 on invalid)
parse_key_spec:
    push rbx
    push r12
    call parse_key_spec__case_insensitive_prefix_check
    cmp byte ptr [rbx], 0
    je .Lpks_bad
    # Single char?
    cmp byte ptr [rbx + 1], 0
    jne .Lpks_fn
    call parse_key_spec__normalize_ctrl_letter_lowercase
.Lpks_ok:
    mov edx, r12d
    pop r12
    pop rbx
    ret

.Lpks_fn:
    mov al, [rbx]
    or al, 0x20
    cmp al, 'f'
    jne .Lpks_bad
    movzx eax, byte ptr [rbx + 1]
    cmp al, '1'; jb .Lpks_bad
    cmp al, '9'; ja .Lpks_bad
    cmp byte ptr [rbx + 2], 0
    jne .Lpks_f10
    sub eax, '1'
    add eax, KEY_F1
    jmp .Lpks_ok
.Lpks_f10:
    cmp byte ptr [rbx + 1], '1'
    jne .Lpks_bad
    cmp byte ptr [rbx + 3], 0
    jne .Lpks_bad
    movzx eax, byte ptr [rbx + 2]
    cmp al, '0'; je .Lpks_is_f10
    cmp al, '1'; je .Lpks_is_f11
    cmp al, '2'; je .Lpks_is_f12
    jmp .Lpks_bad
.Lpks_is_f10:
    mov eax, KEY_F10
    jmp .Lpks_ok
.Lpks_is_f11:
    mov eax, KEY_F11
    jmp .Lpks_ok
.Lpks_is_f12:
    mov eax, KEY_F12
    jmp .Lpks_ok

.Lpks_bad:
    xor eax, eax
    xor edx, edx
    pop r12
    pop rbx
    ret

# parse_key_spec step: case insensitive prefix check for (runs on the caller's frame)
parse_key_spec__case_insensitive_prefix_check:
    lea rsp, [rsp - 8]
    mov rbx, rdi
    xor r12d, r12d            # mods = 0

.Lpks_pfx:
    mov rdi, rbx
    lea rsi, [rip + pfx_ctrl]
    call str_len
    # case-insensitive prefix check for "ctrl+" (5) / "alt+" (4)
    mov al, [rbx]
    or al, 0x20
    cmp al, 'c'
    jne .Lpks_chk_alt
    mov al, [rbx + 1]; or al, 0x20; cmp al, 't'; jne .Lpks_chk_alt
    mov al, [rbx + 2]; or al, 0x20; cmp al, 'r'; jne .Lpks_chk_alt
    mov al, [rbx + 3]; or al, 0x20; cmp al, 'l'; jne .Lpks_chk_alt
    cmp byte ptr [rbx + 4], '+'
    jne .Lpks_chk_alt
    or r12d, MOD_CTRL
    add rbx, 5
    jmp .Lpks_pfx

.Lpks_chk_alt:
    mov al, [rbx]
    or al, 0x20
    cmp al, 'a'
    jne .Lpks_main
    mov al, [rbx + 1]; or al, 0x20; cmp al, 'l'; jne .Lpks_main
    mov al, [rbx + 2]; or al, 0x20; cmp al, 't'; jne .Lpks_main
    cmp byte ptr [rbx + 3], '+'
    jne .Lpks_main
    or r12d, MOD_ALT
    add rbx, 4
    jmp .Lpks_pfx

.Lpks_main:
.Lparse_key_spec__case_insensitive_prefix_check_ret:
    lea rsp, [rsp + 8]
    ret

# parse_key_spec step: Normalize Ctrl letter to lowercase ASCII (runs on the caller's frame)
parse_key_spec__normalize_ctrl_letter_lowercase:
    lea rsp, [rsp - 8]
    movzx eax, byte ptr [rbx]
    test r12d, MOD_CTRL
    jz .Lparse_key_spec__normalize_ctrl_letter_lowercase_ret
    # Normalize Ctrl+<letter> to lowercase ASCII
    cmp eax, 'A'; jb .Lparse_key_spec__normalize_ctrl_letter_lowercase_ret
    cmp eax, 'Z'; ja .Lparse_key_spec__normalize_ctrl_letter_lowercase_ret
    add eax, 32
.Lparse_key_spec__normalize_ctrl_letter_lowercase_ret:
    lea rsp, [rsp + 8]
    ret

# Helper: extract next whitespace-delimited token (or "..." quoted token) in place
# rdi = cursor -> rax = token_start (NUL-terminated in buffer), rdx = next_cursor
next_token:
    call skip_ws
    mov r8, rax
    cmp byte ptr [r8], 0
    je .Lnt_empty
    cmp byte ptr [r8], '"'
    je .Lnt_quoted
    mov r9, r8
.Lnt_scan:
    movzx ecx, byte ptr [r9]
    test cl, cl
    jz .Lnt_end
    cmp cl, ' '
    je .Lnt_term
    cmp cl, '\t'
    je .Lnt_term
    cmp cl, '='
    je .Lnt_term
    inc r9
    jmp .Lnt_scan
.Lnt_term:
    mov byte ptr [r9], 0
    lea rdx, [r9 + 1]
    mov rax, r8
    ret
.Lnt_end:
    mov rax, r8
    mov rdx, r9
    ret
.Lnt_quoted:
    inc r8
    mov r9, r8
.Lnt_qscan:
    movzx ecx, byte ptr [r9]
    test cl, cl
    jz .Lnt_end
    cmp cl, '"'
    je .Lnt_term
    inc r9
    jmp .Lnt_qscan
.Lnt_empty:
    xor eax, eax
    mov rdx, r8
    ret
