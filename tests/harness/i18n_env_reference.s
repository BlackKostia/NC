# Frozen reference oracle: the hand-written asm that src/tui/i18n_env.c replaced (tests/test_c_i18n.py diffs against it)
# Duop i18n runtime: the registry of interface languages (index 0 = built-in English, then the
# *.lang packs sorted by id), current-language accessors, lookup by id / code and POSIX locale
# detection. The packs themselves are loaded by i18n_pack.s.

.intel_syntax noprefix
.include "pal.inc"
.include "config.inc"
.include "types.inc"

.section .rodata
env_lc_all:      .asciz "LC_ALL"
env_lc_messages: .asciz "LC_MESSAGES"
env_lang:        .asciz "LANG"
id_en:           .asciz "en"

.section .bss
.align 8
g_lang_tbl:     .space I18N_MAX * 8           # LangStrings * per language
g_lang_id:      .space I18N_MAX * I18N_ID_LEN # id (pack file name without .lang)
g_lang_n:       .space 4                      # 0 until i18n_lang_reset: English only
g_cur_lang_idx: .space 4
g_cur_lang:     .space 8

.section .text
.global i18n_lang_reset
.global i18n_register
.global i18n_has_id
.global i18n_find
.global i18n_detect_env
.global i18n_get
.global i18n_set_lang
.global i18n_get_idx
.global i18n_count

# void i18n_lang_reset(void) -- registry = { English }
i18n_lang_reset:
    lea rax, [rip + lang_en_table]
    mov [rip + g_lang_tbl], rax
    mov eax, [rip + id_en]
    mov [rip + g_lang_id], eax
    mov dword ptr [rip + g_lang_n], 1
    mov dword ptr [rip + g_cur_lang_idx], 0
    mov qword ptr [rip + g_cur_lang], 0
    ret

# int i18n_count(void)
i18n_count:
    mov eax, [rip + g_lang_n]
    test eax, eax
    jnz .Lic_ret
    mov eax, 1
.Lic_ret:
    ret

# int i18n_has_id(const char *id) -> 1 when a language with this id is registered
i18n_has_id:
    push rbx
    push r12
    sub rsp, 8
    mov r12, rdi
    call str_len
    mov rsi, rax
    mov rdi, r12
    call il_find_id
    not eax
    shr eax, 31                        # idx >= 0 -> 1
    add rsp, 8
    pop r12
    pop rbx
    ret

# void i18n_register(LangStrings *tbl, const char *id) -- insert keeping packs sorted by id
i18n_register:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov r13, rsi
    call i18n_count
    cmp eax, I18N_MAX
    jae .Lrg_ret
    mov ebx, eax                       # insertion slot, moved down while id < id[slot - 1]
.Lrg_pos:
    cmp ebx, 1
    jbe .Lrg_put
    lea eax, [ebx - 1]
    imul eax, eax, I18N_ID_LEN
    lea rsi, [rip + g_lang_id]
    add rsi, rax
    mov rdi, r13
    call str_cmp
    test eax, eax
    jns .Lrg_put
    mov edi, ebx
    call il_shift_up                   # slot - 1 -> slot
    dec ebx
    jmp .Lrg_pos
.Lrg_put:
    lea rax, [rip + g_lang_tbl]
    mov [rax + rbx * 8], r12
    imul edi, ebx, I18N_ID_LEN
    lea rax, [rip + g_lang_id]
    add rdi, rax
    mov rsi, r13
    mov edx, I18N_ID_LEN
    call str_copy
    call i18n_count
    inc eax
    mov [rip + g_lang_n], eax
.Lrg_ret:
    pop r13
    pop r12
    pop rbx
    ret

# Internal: void il_shift_up(int slot) -- copy entry slot - 1 into slot
il_shift_up:
    lea rcx, [rip + g_lang_tbl]
    mov rax, [rcx + rdi * 8 - 8]
    mov [rcx + rdi * 8], rax
    imul eax, edi, I18N_ID_LEN
    lea rcx, [rip + g_lang_id]
    add rcx, rax
    mov rax, [rcx - I18N_ID_LEN]
    mov [rcx], rax
    mov rax, [rcx - I18N_ID_LEN + 8]
    mov [rcx + 8], rax
    ret

# int i18n_find(const char *s) -> language index, or -1
# s is an id, a code or a locale ("uk", "UA", "uk_UA.UTF-8"); ids win over codes, any case.
i18n_find:
    push rbx
    push r12
    sub rsp, 8
    mov eax, -1
    test rdi, rdi
    jz .Lfd_ret
    mov rbx, rdi
    call il_code_len
    test eax, eax
    jz .Lfd_none
    mov r12d, eax
    mov rdi, rbx
    mov esi, r12d
    call il_find_id
    test eax, eax
    jns .Lfd_ret
    mov rdi, rbx
    mov esi, r12d
    call il_find_code
    jmp .Lfd_ret
.Lfd_none:
    mov eax, -1
.Lfd_ret:
    add rsp, 8
    pop r12
    pop rbx
    ret

# Internal: int il_code_len(const char *s) -- length up to '_' '-' '.' '@' ' ' or NUL
il_code_len:
    xor eax, eax
.Lcl_loop:
    movzx ecx, byte ptr [rdi + rax]
    test cl, cl
    jz .Lcl_ret
    cmp cl, '_'
    je .Lcl_ret
    cmp cl, '-'
    je .Lcl_ret
    cmp cl, '.'
    je .Lcl_ret
    cmp cl, '@'
    je .Lcl_ret
    cmp cl, ' '
    je .Lcl_ret
    inc eax
    jmp .Lcl_loop
.Lcl_ret:
    ret

# Internal: int il_find_id(const char *s, int len) -> index of the id equal to s[0..len), or -1
il_find_id:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov r13d, esi
    xor ebx, ebx
.Lfi_loop:
    call i18n_count
    cmp ebx, eax
    jae .Lfi_none
    imul esi, ebx, I18N_ID_LEN
    lea rax, [rip + g_lang_id]
    add rsi, rax
    mov rdi, r12
    mov edx, r13d
    call il_eq_ci
    test eax, eax
    jnz .Lfi_hit
    inc ebx
    jmp .Lfi_loop
.Lfi_hit:
    mov eax, ebx
    jmp .Lfi_ret
.Lfi_none:
    mov eax, -1
.Lfi_ret:
    pop r13
    pop r12
    pop rbx
    ret

# Internal: int il_find_code(const char *s, int len) -> index whose LangStrings.code matches, or -1
il_find_code:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov r13d, esi
    xor ebx, ebx
.Lfc_loop:
    call i18n_count
    cmp ebx, eax
    jae .Lfc_none
    mov edi, ebx
    call il_table
    mov rsi, [rax + LangStrings.code]
    mov rdi, r12
    mov edx, r13d
    call il_eq_ci
    test eax, eax
    jnz .Lfc_hit
    inc ebx
    jmp .Lfc_loop
.Lfc_hit:
    mov eax, ebx
    jmp .Lfc_ret
.Lfc_none:
    mov eax, -1
.Lfc_ret:
    pop r13
    pop r12
    pop rbx
    ret

# Internal: int il_eq_ci(const char *s, int len, const char *z) -> 1 when z is s[0..len), any case
il_eq_ci:
    xor ecx, ecx
.Leq_loop:
    cmp ecx, edx
    jae .Leq_end
    movzx eax, byte ptr [rdi + rcx]
    movzx r8d, byte ptr [rsi + rcx]
    test r8d, r8d
    jz .Leq_no
    or eax, 0x20
    or r8d, 0x20
    cmp eax, r8d
    jne .Leq_no
    inc ecx
    jmp .Leq_loop
.Leq_end:
    cmp byte ptr [rsi + rcx], 0
    jne .Leq_no
    mov eax, 1
    ret
.Leq_no:
    xor eax, eax
    ret

# Internal: LangStrings *il_table(int idx) -- English for index 0 or an empty registry
il_table:
    lea rax, [rip + lang_en_table]
    test edi, edi
    jz .Lt_ret
    lea rcx, [rip + g_lang_tbl]
    mov rax, [rcx + rdi * 8]
.Lt_ret:
    ret

# int i18n_detect_env(char **envp) -> index of the first set of LC_ALL / LC_MESSAGES / LANG,
# English (0) when that locale has no pack
i18n_detect_env:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    xor eax, eax
    test rbx, rbx
    jz .Lde_ret
    lea r12, [rip + env_lc_all]
    call il_getenv_set
    jnz .Lde_found
    lea r12, [rip + env_lc_messages]
    call il_getenv_set
    jnz .Lde_found
    lea r12, [rip + env_lang]
    call il_getenv_set
    jz .Lde_ret
.Lde_found:
    mov rdi, rax
    call i18n_find
    test eax, eax
    jns .Lde_ret
    xor eax, eax
.Lde_ret:
    add rsp, 8
    pop r12
    pop rbx
    ret

# i18n_detect_env step: rax = value of env var r12 (envp rbx); ZF set when unset or empty
il_getenv_set:
    lea rsp, [rsp - 8]
    mov rdi, rbx
    mov rsi, r12
    call env_getenv
    test rax, rax
    jz .Lgs_ret
    cmp byte ptr [rax], 0
.Lgs_ret:
    lea rsp, [rsp + 8]
    ret

# const LangStrings *i18n_get(void)
# Preserves all registers except RAX.
i18n_get:
    mov rax, [rip + g_cur_lang]
    test rax, rax
    jnz .Lig_ret
    lea rax, [rip + lang_en_table]
.Lig_ret:
    ret

# const LangStrings *i18n_set_lang(int idx) -- out-of-range indices select English
i18n_set_lang:
    push rbx
    mov ebx, edi
    call i18n_count
    cmp ebx, eax
    jb .Lsl_ok
    xor ebx, ebx
.Lsl_ok:
    mov [rip + g_cur_lang_idx], ebx
    mov edi, ebx
    call il_table
    mov [rip + g_cur_lang], rax
    pop rbx
    ret

# int i18n_get_idx(void)
i18n_get_idx:
    mov eax, [rip + g_cur_lang_idx]
    ret
