# Duop i18n runtime: current-language accessors and environment locale detection
# (the EN/UA string tables themselves live in i18n.s)

.intel_syntax noprefix
.include "pal.inc"
.include "types.inc"
.equ LANG_UA, 1

.section .rodata
env_lc_all:      .asciz "LC_ALL"
env_lc_messages: .asciz "LC_MESSAGES"
env_lang:        .asciz "LANG"

.section .text
.global i18n_detect_env
.global i18n_is_uk_code

# int i18n_is_uk_code(const char *s)
# Returns 1 if s starts with "uk" or "ua" (case-insensitive) as a whole code/locale prefix.
i18n_is_uk_code:
    test rdi, rdi
    jz .Liuk_no
    movzx eax, byte ptr [rdi]
    or eax, 0x20
    cmp al, 'u'
    jne .Liuk_no
    movzx eax, byte ptr [rdi + 1]
    or eax, 0x20
    cmp al, 'k'
    je .Liuk_sep
    cmp al, 'a'
    jne .Liuk_no
.Liuk_sep:
    movzx eax, byte ptr [rdi + 2]
    test eax, eax
    jz .Liuk_yes
    cmp al, '_'
    je .Liuk_yes
    cmp al, '-'
    je .Liuk_yes
    cmp al, '.'
    je .Liuk_yes
    cmp al, '@'
    je .Liuk_yes
    cmp al, ' '
    je .Liuk_yes
.Liuk_no:
    xor eax, eax
    ret
.Liuk_yes:
    mov eax, 1
    ret

# int i18n_detect_env(char **envp)
# POSIX locale precedence: LC_ALL > LC_MESSAGES > LANG. Returns LANG_UA or LANG_EN.
i18n_detect_env:
    push rbx
    mov rbx, rdi
    test rbx, rbx
    jz .Lide_en

    mov rdi, rbx
    lea rsi, [rip + env_lc_all]
    call env_getenv
    test rax, rax
    jz .Lide_lc_msg
    cmp byte ptr [rax], 0
    jne .Lide_check

.Lide_lc_msg:
    mov rdi, rbx
    lea rsi, [rip + env_lc_messages]
    call env_getenv
    test rax, rax
    jz .Lide_lang
    cmp byte ptr [rax], 0
    jne .Lide_check

.Lide_lang:
    mov rdi, rbx
    lea rsi, [rip + env_lang]
    call env_getenv
    test rax, rax
    jz .Lide_en
    cmp byte ptr [rax], 0
    je .Lide_en

.Lide_check:
    mov rdi, rax
    call i18n_is_uk_code
    test eax, eax
    jz .Lide_en
    mov eax, LANG_UA
    pop rbx
    ret

.Lide_en:
    xor eax, eax              # LANG_EN
    pop rbx
    ret

.section .rodata
.align 8
lang_ptrs:
    .quad lang_en_table
    .quad lang_ua_table
.equ LANG_COUNT, 2

.section .bss
.align 8
g_cur_lang:     .space 8
g_cur_lang_idx: .space 4

.section .text
.global i18n_get
.global i18n_set_lang
.global i18n_get_idx
.global i18n_count

# const LangStrings *i18n_get(void)
# Preserves all registers except RAX.
i18n_get:
    mov rax, [rip + g_cur_lang]
    test rax, rax
    jnz .Lig_ret
    lea rax, [rip + lang_en_table]
.Lig_ret:
    ret

# const LangStrings *i18n_set_lang(int idx)
i18n_set_lang:
    xor eax, eax
    cmp edi, LANG_UA
    jne .Lisl_store
    mov eax, LANG_UA
.Lisl_store:
    mov [rip + g_cur_lang_idx], eax
    lea rcx, [rip + lang_ptrs]
    mov rax, [rcx + rax*8]
    mov [rip + g_cur_lang], rax
    ret

# int i18n_get_idx(void)
i18n_get_idx:
    mov eax, [rip + g_cur_lang_idx]
    ret

# int i18n_count(void)
i18n_count:
    mov eax, LANG_COUNT
    ret
