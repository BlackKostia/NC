# NeoCommander Entry Point (_start)
# Pure Linux x86-64 ELF64 binary with zero libc dependencies.

.intel_syntax noprefix
.include "linux_sys.inc"
.include "classes.inc"
.include "version.inc"

.section .rodata
str_flag_h:      .asciz "-h"
str_flag_help:   .asciz "--help"
str_flag_v:      .asciz "-v"
str_flag_V:      .asciz "-V"
str_flag_ver:    .asciz "--version"
str_flag_l:      .asciz "-l"
str_flag_lang:   .asciz "--lang"
str_flag_langeq: .asciz "--lang="

str_version:
    .ascii "NeoCommander v"
    NC_VER_ASCII
    .ascii " (x86-64 Linux ELF64, zero-libc)\n"
.equ str_version_len, . - str_version

str_version_ua:
    .ascii "NeoCommander v"
    NC_VER_ASCII
    .ascii " (x86-64 Linux ELF64, без libc)\n"
.equ str_version_ua_len, . - str_version_ua

str_usage:
    .ascii "NeoCommander v"
    NC_VER_ASCII
    .ascii " — Modern Terminal File Manager (Pure x86-64 Assembly)\n"
    .ascii "Usage: nc [--lang en|ua] [-V|--version] [LEFT_DIR [RIGHT_DIR]]\n"
    .ascii "\n"
    .ascii "Features:\n"
    .ascii "  • 24-bit TrueColor UI with 3 switchable themes (Alt+T)\n"
    .ascii "  • Bilingual English / Ukrainian interface (Alt+L, --lang ua, or LANG=uk_*)\n"
    .ascii "  • Full SGR 1006 Mouse support (click, double-click, right-click, wheel, drag, hover)\n"
    .ascii "  • Dual-pane navigation & Live Preview mode (F9 / Ctrl+P)\n"
    .ascii "  • Built-in Text & Hex Viewer (F3), Copy/Move/Rename/Mkdir/Delete, Live Filter (/)\n"
    .ascii "\n"
    .ascii "Press F1 inside NeoCommander for full keyboard and mouse shortcuts.\n"
.equ str_usage_len, . - str_usage

str_usage_ua:
    .ascii "NeoCommander v"
    NC_VER_ASCII
    .ascii " — Сучасний термінальний файловий менеджер (чистий x86-64 Assembler)\n"
    .ascii "Використання: nc [--lang ua|en] [-V|--version] [ЛІВА_ТЕКА [ПРАВА_ТЕКА]]\n"
    .ascii "\n"
    .ascii "Можливості:\n"
    .ascii "  • 24-бітний TrueColor інтерфейс з 3 темами оформлення (Alt+T)\n"
    .ascii "  • Двомовний інтерфейс Українська / English (Alt+L, --lang ua або LANG=uk_*)\n"
    .ascii "  • Повна підтримка миші SGR 1006 (клік, подвійний клік, правий клік, колесо, скролбар)\n"
    .ascii "  • Двопанельна навігація та режим швидкого перегляду (F9 / Ctrl+P)\n"
    .ascii "  • Вбудований переглядач Текст/Hex (F3), копіювання/переміщення/фільтр (/)\n"
    .ascii "\n"
    .ascii "Натисніть F1 усередині NeoCommander для повної довідки гарячих клавіш.\n"
.equ str_usage_ua_len, . - str_usage_ua

.section .text
.global _start

# Helper: parse language string -> LANG_UA or LANG_EN
parse_lang_val:
    call i18n_is_uk_code
    test eax, eax
    jz .Lplv_en
    mov eax, LANG_UA
    ret
.Lplv_en:
    xor eax, eax              # LANG_EN
    ret

_start:
    # Read argc, argv, envp from initial Linux stack
    mov rbx, [rsp]            # argc
    lea r12, [rsp + 8]        # argv
    lea r13, [r12 + rbx*8 + 8] # envp
    and rsp, -16              # ensure 16-byte ABI stack alignment
    sub rsp, 32               # [rsp+0]=lang_override (-1), [rsp+4]=show_help (0), [rsp+8]=arg_idx (1), [rsp+12]=show_version (0)

    mov dword ptr [rsp], -1
    mov dword ptr [rsp + 4], 0
    mov dword ptr [rsp + 8], 1
    mov dword ptr [rsp + 12], 0
    xor r14d, r14d            # left_path = NULL
    xor r15d, r15d            # right_path = NULL

.Lmain_arg_loop:
    mov eax, [rsp + 8]
    cmp eax, ebx
    jge .Lmain_args_done
    mov rbp, [r12 + rax*8]    # argv[i]

    mov rdi, rbp
    lea rsi, [rip + str_flag_h]
    call str_cmp
    test eax, eax
    jz .Lmain_set_help

    mov rdi, rbp
    lea rsi, [rip + str_flag_help]
    call str_cmp
    test eax, eax
    jz .Lmain_set_help

    mov rdi, rbp
    lea rsi, [rip + str_flag_v]
    call str_cmp
    test eax, eax
    jz .Lmain_set_version

    mov rdi, rbp
    lea rsi, [rip + str_flag_V]
    call str_cmp
    test eax, eax
    jz .Lmain_set_version

    mov rdi, rbp
    lea rsi, [rip + str_flag_ver]
    call str_cmp
    test eax, eax
    jz .Lmain_set_version

    mov rdi, rbp
    lea rsi, [rip + str_flag_lang]
    call str_cmp
    test eax, eax
    jz .Lmain_flag_lang_next

    mov rdi, rbp
    lea rsi, [rip + str_flag_l]
    call str_cmp
    test eax, eax
    jz .Lmain_flag_lang_next

    mov rdi, rbp
    lea rsi, [rip + str_flag_langeq]
    call str_starts_with
    test eax, eax
    jnz .Lmain_flag_langeq

    # Positional directory arguments
    test r14, r14
    jnz .Lmain_pos_right
    mov r14, rbp
    jmp .Lmain_arg_next
.Lmain_pos_right:
    test r15, r15
    jnz .Lmain_arg_next
    mov r15, rbp
    jmp .Lmain_arg_next

.Lmain_set_help:
    mov dword ptr [rsp + 4], 1
    jmp .Lmain_arg_next

.Lmain_set_version:
    mov dword ptr [rsp + 12], 1
    jmp .Lmain_arg_next

.Lmain_flag_lang_next:
    mov eax, [rsp + 8]
    inc eax
    cmp eax, ebx
    jge .Lmain_arg_next
    mov [rsp + 8], eax
    mov rdi, [r12 + rax*8]
    call parse_lang_val
    mov [rsp], eax
    jmp .Lmain_arg_next

.Lmain_flag_langeq:
    lea rdi, [rbp + 7]        # skip "--lang="
    call parse_lang_val
    mov [rsp], eax

.Lmain_arg_next:
    inc dword ptr [rsp + 8]
    jmp .Lmain_arg_loop

.Lmain_args_done:
    cmp dword ptr [rsp + 4], 0
    jne .Lmain_help
    cmp dword ptr [rsp + 12], 0
    jne .Lmain_version

.Lmain_run:
    call signals_install
    call term_enter_raw

    mov rdi, r14
    mov rsi, r15
    mov rdx, r13
    mov ecx, [rsp]            # lang_override
    call App_new
    test rax, rax
    jz .Lmain_cleanup_err
    mov rbx, rax

    mov rdi, rbx
    call App_run

    DELETE_OBJ rbx
    call term_exit_raw

    xor edi, edi
    mov rax, SYS_exit
    syscall

.Lmain_cleanup_err:
    call term_exit_raw
    mov edi, 1
    mov rax, SYS_exit
    syscall

.Lmain_help:
    mov eax, [rsp]
    cmp eax, 0
    jge .Lmain_help_pick
    mov rdi, r13
    call i18n_detect_env
.Lmain_help_pick:
    cmp eax, LANG_UA
    je .Lmain_help_ua
    lea rsi, [rip + str_usage]
    mov edx, str_usage_len
    jmp .Lmain_help_print
.Lmain_help_ua:
    lea rsi, [rip + str_usage_ua]
    mov edx, str_usage_ua_len
.Lmain_help_print:
    mov edi, STDOUT_FD
    call sys_write_all

    xor edi, edi
    mov rax, SYS_exit
    syscall

.Lmain_version:
    mov eax, [rsp]
    cmp eax, 0
    jge .Lmain_ver_pick
    mov rdi, r13
    call i18n_detect_env
.Lmain_ver_pick:
    cmp eax, LANG_UA
    je .Lmain_ver_ua
    lea rsi, [rip + str_version]
    mov edx, str_version_len
    jmp .Lmain_help_print
.Lmain_ver_ua:
    lea rsi, [rip + str_version_ua]
    mov edx, str_version_ua_len
    jmp .Lmain_help_print
