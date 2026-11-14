# Interface language packs: every "*.lang" file on the data path (data_dirs.s: $DUOP_LANGS,
# ~/.config/duop/lang, lang/ beside the binary, share/duop/lang) becomes one language, so new
# interface languages need no rebuild. A pack is "key = value" lines over the LangStrings slots
# (i18n_keys.s); missing keys keep the built-in English text. Values may be "quoted" to keep
# outer spaces and use \n \t \" \\ escapes; {version} expands to the Duop version. A pack must set
# `code`; the first file of an id (file name without .lang) on the path wins. Packs live in a
# static arena for the whole run (no heap, nothing to free).

.intel_syntax noprefix
.include "pal.inc"
.include "config.inc"
.include "types.inc"
.include "version.inc"

.section .bss
.align 16
g_ip_arena:     .space I18N_ARENA
g_ip_used:      .space 8

.section .rodata
env_langs:      .asciz "DUOP_LANGS="
sub_lang:       .asciz "lang"
ext_lang:       .asciz ".lang"
tok_version:    .asciz "{version}"
ip_version:
    DUOP_VER_ASCII
    .byte 0
.equ IP_VERSION_LEN, . - ip_version - 1

.align 8
ip_spec:
    .quad env_langs, sub_lang, ext_lang, ip_load_file

.section .text
.global i18n_load

# void i18n_load(char **envp) -- (re)build the language registry from the packs on the data path
i18n_load:
    push rbx
    mov rbx, rdi
    call i18n_lang_reset
    mov qword ptr [rip + g_ip_used], 0
    mov rdi, rbx
    lea rsi, [rip + ip_spec]
    call data_dirs_scan
    pop rbx
    ret

# Internal: void ip_load_file(const char *path, const char *name)
ip_load_file:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, I18N_ID_LEN + 8          # [rsp] = id
    mov r12, rdi
    mov rdi, rsi
    mov rsi, rsp
    call ip_stem                      # id = name without ".lang"; eax = 0 when too long
    test eax, eax
    jz .Llf_ret
    mov rdi, rsp
    call i18n_has_id
    test eax, eax
    jnz .Llf_ret                      # an earlier directory already provided this language
    call ip_reserve                   # rax = table slot, rdx = text capacity (0 = arena full)
    test rdx, rdx
    jz .Llf_ret
    mov rbx, rax
    mov r13, rdx
    mov rdi, rbx
    lea rsi, [rip + lang_en_table]
    mov edx, LangStrings._size
    call mem_copy                     # every key starts as English
    mov rdi, r12
    lea rsi, [rbx + LangStrings._size]
    mov rdx, r13
    call data_read_file
    test rax, rax
    js .Llf_ret
    mov r14, rax
    lea rdi, [rbx + LangStrings._size]
    mov rsi, rbx
    call ip_parse
    lea rax, [rip + lang_en_table]
    mov rax, [rax + LangStrings.code]
    cmp [rbx + LangStrings.code], rax
    je .Llf_ret                       # no `code`: not a language pack
    lea rax, [r14 + LangStrings._size + 8]
    and rax, -8
    add [rip + g_ip_used], rax
    mov rdi, rbx
    mov rsi, rsp
    call i18n_register
.Llf_ret:
    add rsp, I18N_ID_LEN + 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: (LangStrings *slot, size_t cap) ip_reserve(void) -- next free arena slot
ip_reserve:
    mov rcx, [rip + g_ip_used]
    lea rax, [rip + g_ip_arena]
    add rax, rcx
    mov edx, I18N_ARENA - LangStrings._size
    sub rdx, rcx
    jbe .Lrs_full
    cmp rdx, I18N_FILE_MAX
    jbe .Lrs_cap
    mov edx, I18N_FILE_MAX
.Lrs_cap:
    cmp rdx, 256
    jae .Lrs_ret
.Lrs_full:
    xor edx, edx
.Lrs_ret:
    ret

# Internal: int ip_stem(const char *name, char *id) -- copy name minus ".lang"; 0 if it does not fit
ip_stem:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    call str_len
    sub rax, 5                        # strlen(".lang")
    jbe .Lst_no
    cmp rax, I18N_ID_LEN
    jae .Lst_no
    mov rdi, r12
    mov rsi, rbx
    lea rdx, [rax + 1]
    call str_copy
    mov eax, 1
    jmp .Lst_ret
.Lst_no:
    xor eax, eax
.Lst_ret:
    add rsp, 8
    pop r12
    pop rbx
    ret

# Internal: void ip_parse(char *text, LangStrings *tbl) -- NUL-terminated, rewritten in place
ip_parse:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
.Lps_line:
    cmp byte ptr [rbx], 0
    je .Lps_ret
    mov rax, rbx
.Lps_eol:
    movzx ecx, byte ptr [rax]
    test cl, cl
    jz .Lps_cut
    inc rax
    cmp cl, '\n'
    jne .Lps_eol
    mov byte ptr [rax - 1], 0
.Lps_cut:
    mov r13, rax                      # next line
    mov rdi, rbx
    mov rsi, r12
    call ip_line
    mov rbx, r13
    jmp .Lps_line
.Lps_ret:
    pop r13
    pop r12
    pop rbx
    ret

# Internal: void ip_line(char *line, LangStrings *tbl) -- one "key = value" line
ip_line:
    push rbx
    push r12
    push r13
    mov r12, rsi
    call skip_ws
    mov rbx, rax                      # key
    mov rdi, rax
.Lln_key:
    movzx ecx, byte ptr [rdi]
    cmp cl, '_'
    je .Lln_kch
    cmp cl, '.'
    je .Lln_kch
    mov eax, ecx
    sub eax, '0'
    cmp eax, 9
    jbe .Lln_kch
    or ecx, 0x20
    sub ecx, 'a'
    cmp ecx, 25
    ja .Lln_kend
.Lln_kch:
    inc rdi
    jmp .Lln_key
.Lln_kend:
    cmp rdi, rbx
    je .Lln_ret                       # comment, blank or junk line
    mov r13, rdi
    call skip_ws
    cmp byte ptr [rax], '='
    jne .Lln_ret
    mov byte ptr [r13], 0
    lea r13, [rax + 1]                # value
    mov rdi, rbx
    call i18n_key_offset
    test eax, eax
    js .Lln_ret                       # unknown key: ignored
    mov ebx, eax
    mov rdi, r13
    call skip_ws
    mov rdi, rax
    call ip_value
    mov [r12 + rbx], rax
.Lln_ret:
    pop r13
    pop r12
    pop rbx
    ret

# Internal: char *ip_value(char *v) -- decode a value in place (quotes, escapes, {version})
ip_value:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    mov rbx, rdi
    call ip_rtrim
    mov r12, rbx                      # read
    mov r13, rbx                      # write
    xor r14d, r14d                    # quoted
    cmp byte ptr [rbx], '"'
    jne .Lv_loop
    inc r12
    mov r14d, 1
.Lv_loop:
    movzx eax, byte ptr [r12]
    test al, al
    jz .Lv_end
    cmp al, '"'
    jne .Lv_esc
    test r14d, r14d
    jnz .Lv_end                       # closing quote
.Lv_esc:
    cmp al, 0x5C                     # backslash
    jne .Lv_ver
    movzx ecx, byte ptr [r12 + 1]
    call ip_escape                    # eax = decoded byte for "\<cl>", or -1
    test eax, eax
    js .Lv_put
    add r12, 2
    mov [r13], al
    inc r13
    jmp .Lv_loop
.Lv_ver:
    cmp al, '{'
    jne .Lv_put
    mov rdi, r12
    lea rsi, [rip + tok_version]
    call str_starts_with
    test eax, eax
    jz .Lv_put
    mov rdi, r13
    lea rsi, [rip + ip_version]
    mov edx, IP_VERSION_LEN
    call mem_copy
    add r13, IP_VERSION_LEN
    add r12, 9                        # strlen("{version}") >= IP_VERSION_LEN
    jmp .Lv_loop
.Lv_put:
    movzx eax, byte ptr [r12]
    mov [r13], al
    inc r12
    inc r13
    jmp .Lv_loop
.Lv_end:
    mov byte ptr [r13], 0
    mov rax, rbx
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.if IP_VERSION_LEN > 9
    .error "{version} expands in place: the version string must fit in 9 bytes"
.endif

# Internal: int ip_escape(char c) -> byte for "\c", or -1 to keep the backslash literally
ip_escape:
    mov eax, 10
    cmp cl, 'n'
    je .Le_ret
    mov eax, 9
    cmp cl, 't'
    je .Le_ret
    movzx eax, cl
    cmp cl, 0x5C
    je .Le_ret
    cmp cl, '"'
    je .Le_ret
    mov eax, -1
.Le_ret:
    ret

# Internal: void ip_rtrim(char *s) -- strip trailing spaces, tabs and CR
ip_rtrim:
    mov rax, rdi
.Lrt_end:
    cmp byte ptr [rax], 0
    je .Lrt_back
    inc rax
    jmp .Lrt_end
.Lrt_back:
    cmp rax, rdi
    jbe .Lrt_ret
    movzx ecx, byte ptr [rax - 1]
    cmp cl, ' '
    je .Lrt_cut
    cmp cl, '\t'
    je .Lrt_cut
    cmp cl, '\r'
    jne .Lrt_ret
.Lrt_cut:
    dec rax
    mov byte ptr [rax], 0
    jmp .Lrt_back
.Lrt_ret:
    ret
