# Environment locale detection for Duop i18n

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
