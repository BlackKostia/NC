# Duop Entry Point (_start)
# Pure Linux x86-64 ELF64 binary with zero libc dependencies.

.intel_syntax noprefix
.include "pal.inc"
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
str_flag_cdir:   .asciz "--choosedir"
str_flag_cdireq: .asciz "--choosedir="
str_flag_L:      .asciz "-L"
str_flag_lic:    .asciz "--license"

str_version:
    .ascii "Duop v"
    DUOP_VER_ASCII
    .ascii " (x86-64 Linux ELF64, zero-libc)\n"
    .ascii "Copyright (C) 2026 Kostiantyn Nedbailo (Недбайло Костянтин Геннадійович) <ChessPlayerSedoy@gmail.com>\n"
    .ascii "License: MIT License (Open Source — run with --license for full text)\n"
.equ str_version_len, . - str_version

str_version_ua:
    .ascii "Duop v"
    DUOP_VER_ASCII
    .ascii " (x86-64 Linux ELF64, без libc)\n"
    .ascii "Розробник: Недбайло Костянтин Геннадійович (Kostiantyn Nedbailo) <ChessPlayerSedoy@gmail.com>\n"
    .ascii "Ліцензія: MIT License (відкритий вихідний код — див. --license)\n"
.equ str_version_ua_len, . - str_version_ua

str_usage:
    .ascii "Duop v"
    DUOP_VER_ASCII
    .ascii " — Modern Dual-Pane Terminal File Manager (Pure x86-64 Assembly)\n"
    .ascii "Usage: duop [--lang en|ua] [--choosedir=FILE] [-V|--version] [-L|--license] [LEFT_DIR [RIGHT_DIR]]\n"
    .ascii "\n"
    .ascii "Features:\n"
    .ascii "  • 24-bit TrueColor UI with 3 switchable themes (Alt+T)\n"
    .ascii "  • Bilingual English / Ukrainian interface (Alt+L, --lang ua, or LANG=uk_*)\n"
    .ascii "  • Full SGR 1006 Mouse support (click, double-click, right-click, wheel, drag, hover)\n"
    .ascii "  • Dual-pane navigation & Live Preview mode (F9 / Ctrl+P)\n"
    .ascii "  • Built-in Text & Hex Viewer (F3), Copy/Move/Rename/Mkdir/Delete, Live Filter (/)\n"
    .ascii "\n"
    .ascii "Author: Kostiantyn Nedbailo (Недбайло Костянтин Геннадійович) <ChessPlayerSedoy@gmail.com>\n"
    .ascii "License: MIT License (Open Source)\n"
    .ascii "Press F1 inside Duop for full keyboard and mouse shortcuts.\n"
.equ str_usage_len, . - str_usage

str_usage_ua:
    .ascii "Duop v"
    DUOP_VER_ASCII
    .ascii " — Сучасний двопанельний термінальний файловий менеджер (чистий x86-64 Assembler)\n"
    .ascii "Використання: duop [--lang ua|en] [--choosedir=FILE] [-V|--version] [-L|--license] [ЛІВА_ТЕКА [ПРАВА_ТЕКА]]\n"
    .ascii "\n"
    .ascii "Можливості:\n"
    .ascii "  • 24-бітний TrueColor інтерфейс з 3 темами оформлення (Alt+T)\n"
    .ascii "  • Двомовний інтерфейс Українська / English (Alt+L, --lang ua або LANG=uk_*)\n"
    .ascii "  • Повна підтримка миші SGR 1006 (клік, подвійний клік, правий клік, колесо, скролбар)\n"
    .ascii "  • Двопанельна навігація та режим швидкого перегляду (F9 / Ctrl+P)\n"
    .ascii "  • Вбудований переглядач Текст/Hex (F3), копіювання/переміщення/фільтр (/)\n"
    .ascii "\n"
    .ascii "Розробник: Недбайло Костянтин Геннадійович <ChessPlayerSedoy@gmail.com>\n"
    .ascii "Ліцензія: MIT License (відкритий вихідний код)\n"
    .ascii "Натисніть F1 усередині Duop для повної довідки гарячих клавіш.\n"
.equ str_usage_ua_len, . - str_usage_ua

str_license:
    .ascii "MIT License\n\n"
    .ascii "Copyright (c) 2026 Kostiantyn Nedbailo (Недбайло Костянтин Геннадійович) <ChessPlayerSedoy@gmail.com>\n\n"
    .ascii "Permission is hereby granted, free of charge, to any person obtaining a copy\n"
    .ascii "of this software and associated documentation files (the \"Software\"), to deal\n"
    .ascii "in the Software without restriction, including without limitation the rights\n"
    .ascii "to use, copy, modify, merge, publish, distribute, sublicense, and/or sell\n"
    .ascii "copies of the Software, and to permit persons to whom the Software is\n"
    .ascii "furnished to do so, subject to the following conditions:\n\n"
    .ascii "The above copyright notice and this permission notice shall be included in all\n"
    .ascii "copies or substantial portions of the Software.\n\n"
    .ascii "THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR\n"
    .ascii "IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,\n"
    .ascii "FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE\n"
    .ascii "AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER\n"
    .ascii "LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,\n"
    .ascii "OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE\n"
    .ascii "SOFTWARE.\n"
.equ str_license_len, . - str_license

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
    # [rsp+0]=lang (-1), [rsp+4]=help (0), [rsp+8]=arg_idx (1), [rsp+12]=ver (0), [rsp+16]=lic (0), [rsp+24]=choosedir_path (0)
    sub rsp, 32

    mov dword ptr [rsp], -1
    mov dword ptr [rsp + 4], 0
    mov dword ptr [rsp + 8], 1
    mov dword ptr [rsp + 12], 0
    mov dword ptr [rsp + 16], 0
    mov qword ptr [rsp + 24], 0
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
    lea rsi, [rip + str_flag_L]
    call str_cmp
    test eax, eax
    jz .Lmain_set_license

    mov rdi, rbp
    lea rsi, [rip + str_flag_lic]
    call str_cmp
    test eax, eax
    jz .Lmain_set_license

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

    mov rdi, rbp
    lea rsi, [rip + str_flag_cdir]
    call str_cmp
    test eax, eax
    jz .Lmain_flag_cdir_next

    mov rdi, rbp
    lea rsi, [rip + str_flag_cdireq]
    call str_starts_with
    test eax, eax
    jnz .Lmain_flag_cdireq

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

.Lmain_set_license:
    mov dword ptr [rsp + 16], 1
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
    jmp .Lmain_arg_next

.Lmain_flag_cdir_next:
    mov eax, [rsp + 8]
    inc eax
    cmp eax, ebx
    jge .Lmain_arg_next
    mov [rsp + 8], eax
    mov rax, [r12 + rax*8]
    mov [rsp + 24], rax
    jmp .Lmain_arg_next

.Lmain_flag_cdireq:
    lea rax, [rbp + 12]       # skip "--choosedir="
    mov [rsp + 24], rax

.Lmain_arg_next:
    inc dword ptr [rsp + 8]
    jmp .Lmain_arg_loop

.Lmain_args_done:
    cmp dword ptr [rsp + 4], 0
    jne .Lmain_help
    cmp dword ptr [rsp + 12], 0
    jne .Lmain_version
    cmp dword ptr [rsp + 16], 0
    jne .Lmain_license

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

    mov rdi, rbx
    mov rsi, [rsp + 24]
    call App_write_choosedir

    DELETE_OBJ rbx
    call term_exit_raw

    xor edi, edi
    OS_EXIT

.Lmain_cleanup_err:
    call term_exit_raw
    mov edi, 1
    OS_EXIT

.Lmain_help:
    lea rsi, [rip + str_usage]
    mov edx, str_usage_len
    lea r8, [rip + str_usage_ua]
    mov r9d, str_usage_ua_len
    jmp .Lmain_print_i18n

.Lmain_version:
    lea rsi, [rip + str_version]
    mov edx, str_version_len
    lea r8, [rip + str_version_ua]
    mov r9d, str_version_ua_len

.Lmain_print_i18n:
    mov eax, [rsp]
    cmp eax, 0
    jge .Lmain_lang_picked
    push rsi
    push rdx
    push r8
    push r9
    mov rdi, r13
    call i18n_detect_env
    pop r9
    pop r8
    pop rdx
    pop rsi
.Lmain_lang_picked:
    cmp eax, LANG_UA
    jne .Lmain_print_exit
    mov rsi, r8
    mov edx, r9d
    jmp .Lmain_print_exit

.Lmain_license:
    lea rsi, [rip + str_license]
    mov edx, str_license_len

.Lmain_print_exit:
    mov edi, STDOUT_FD
    call sys_write_all

    xor edi, edi
    OS_EXIT
