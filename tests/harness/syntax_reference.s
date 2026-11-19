# Frozen reference oracle: the hand-written asm that src/ui/syntax.c replaced (tests/test_c_syntax.py diffs against it)
# src/ui/syntax.s - Table-driven syntax highlighter for C, ASM, Python, Shell, JSON, Markdown, Makefile
.intel_syntax noprefix

.include "classes.inc"

.section .rodata
syn_ext_py:   .asciz ".py"
syn_ext_sh:   .asciz ".sh"
syn_ext_mk:   .asciz "Makefile"
syn_ext_c:    .asciz ".c"
syn_ext_h:    .asciz ".h"
syn_ext_s:    .asciz ".s"
syn_ext_asm:  .asciz ".asm"
syn_ext_json: .asciz ".json"
syn_ext_md:   .asciz ".md"

syn_kw_table:
    .asciz "def"
    .asciz "class"
    .asciz "return"
    .asciz "import"
    .asciz "from"
    .asciz "if"
    .asciz "elif"
    .asciz "else"
    .asciz "for"
    .asciz "while"
    .asciz "in"
    .asciz "not"
    .asciz "and"
    .asciz "or"
    .asciz "int"
    .asciz "void"
    .asciz "char"
    .asciz "struct"
    .asciz "const"
    .asciz "mov"
    .asciz "call"
    .asciz "ret"
    .asciz "jmp"
    .asciz "push"
    .asciz "pop"
    .asciz "lea"
    .asciz "cmp"
    .asciz "test"
    .asciz "add"
    .asciz "sub"
    .asciz "xor"
    .asciz "true"
    .asciz "false"
    .asciz "null"
    .byte 0

.section .text
.global syntax_detect
.global syntax_draw_line

.extern ScreenBuffer_set_pen
.extern ScreenBuffer_set_cell_pen
.extern ScreenBuffer_draw_text
.extern str_len
.extern path_basename
.extern str_cmp

# int syn_ends_with(const char *s, const char *sfx) -> 1 or 0
syn_ends_with:
    push rbx; push r12
    mov rbx, rdi; mov r12, rsi
    call str_len; mov r8, rax
    mov rdi, r12; call str_len; mov r9, rax
    cmp r8, r9; jb .Lsew_no
    lea rdi, [rbx + r8]
    sub rdi, r9
    mov rsi, r12; call str_cmp
    test eax, eax; jnz .Lsew_no
    mov eax, 1; pop r12; pop rbx; ret
.Lsew_no:
    xor eax, eax; pop r12; pop rbx; ret

# int syntax_detect(const char *path) -> 0=plain, 1=hash-comment(py/sh/mk/s), 2=c/json, 3=md
syntax_detect:
    test rdi, rdi; jz .Lsd_none
    push rbx
    mov rbx, rdi
    lea rsi, [rip + syn_ext_py];  call syn_ends_with; test eax, eax; jnz .Lsd_1
    mov rdi, rbx; lea rsi, [rip + syn_ext_sh];  call syn_ends_with; test eax, eax; jnz .Lsd_1
    mov rdi, rbx; lea rsi, [rip + syn_ext_s];   call syn_ends_with; test eax, eax; jnz .Lsd_1
    mov rdi, rbx; lea rsi, [rip + syn_ext_asm]; call syn_ends_with; test eax, eax; jnz .Lsd_1
    mov rdi, rbx; call path_basename
    mov rdi, rax; lea rsi, [rip + syn_ext_mk]; call str_cmp; test eax, eax; jz .Lsd_1
    mov rdi, rbx; lea rsi, [rip + syn_ext_c];    call syn_ends_with; test eax, eax; jnz .Lsd_2
    mov rdi, rbx; lea rsi, [rip + syn_ext_h];    call syn_ends_with; test eax, eax; jnz .Lsd_2
    mov rdi, rbx; lea rsi, [rip + syn_ext_json]; call syn_ends_with; test eax, eax; jnz .Lsd_2
    mov rdi, rbx; lea rsi, [rip + syn_ext_md];   call syn_ends_with; test eax, eax; jnz .Lsd_3
    xor eax, eax; pop rbx; ret
.Lsd_1:
    mov eax, 1; pop rbx; ret
.Lsd_2:
    mov eax, 2; pop rbx; ret
.Lsd_3:
    mov eax, 3; pop rbx; ret
.Lsd_none:
    xor eax, eax; ret

# int syn_is_ident(uint8_t c)
syn_is_ident:
    cmp al, '_'; je .Lsii_y
    cmp al, 'a'; jb .Lsii_u
    cmp al, 'z'; jbe .Lsii_y
.Lsii_u:
    cmp al, 'A'; jb .Lsii_d
    cmp al, 'Z'; jbe .Lsii_y
.Lsii_d:
    cmp al, '0'; jb .Lsii_n
    cmp al, '9'; jbe .Lsii_y
.Lsii_n:
    xor eax, eax; ret
.Lsii_y:
    mov eax, 1; ret

# int syn_is_kw(const char *tok, int len) -> 1 or 0
syn_is_kw:
    lea r8, [rip + syn_kw_table]
.Lsik_next:
    cmp byte ptr [r8], 0; je .Lsik_no
    xor ecx, ecx
.Lsik_cmp:
    mov al, [r8 + rcx]
    cmp ecx, esi; je .Lsik_end
    test al, al; jz .Lsik_skip
    cmp al, [rdi + rcx]; jne .Lsik_skip
    inc ecx; jmp .Lsik_cmp
.Lsik_end:
    test al, al; jz .Lsik_yes
.Lsik_skip:
    cmp byte ptr [r8], 0; je .Lsik_adv
    inc r8; jmp .Lsik_skip
.Lsik_adv:
    inc r8; jmp .Lsik_next
.Lsik_yes:
    mov eax, 1; ret
.Lsik_no:
    xor eax, eax; ret

# int syn_draw_ident(scr, x, y, tok, rem_w, theme, bg) -> consumed len
syn_draw_ident:
    push rbx; push r12; push r13; push r14; push r15
    mov rbx, rdi; mov r12d, esi; mov r13d, edx; mov r14, rcx; mov r15d, r8d
    xor ecx, ecx
.Lsdi_l:
    mov al, [r14 + rcx]
    push rcx; call syn_is_ident; pop rcx
    test eax, eax; jz .Lsdi_chk
    inc ecx; jmp .Lsdi_l
.Lsdi_chk:
    push rcx
    mov rdi, r14; mov esi, ecx; call syn_is_kw
    mov r8, r9                # Theme*
    mov edx, [rsp + 56]       # bg (stack arg 7: 5*8 + 8 + 8 = 56)
    test eax, eax; jz .Lsdi_norm
    mov rdi, rbx; mov esi, [r8 + Theme.accent]; mov ecx, ATTR_BOLD
    call ScreenBuffer_set_pen
    jmp .Lsdi_draw
.Lsdi_norm:
    mov rdi, rbx; mov esi, [r8 + Theme.text]; xor ecx, ecx
    call ScreenBuffer_set_pen
.Lsdi_draw:
    pop rcx
    mov r8d, ecx
    cmp r8d, r15d; jle .Lsdi_w; mov r8d, r15d
.Lsdi_w:
    push rcx
    mov rdi, rbx; mov esi, r12d; mov edx, r13d; mov rcx, r14
    call ScreenBuffer_draw_text
    pop rax
    pop r15; pop r14; pop r13; pop r12; pop rbx
    ret

# void syntax_draw_line(ScreenBuffer *scr, int x, int y, const char *line, int max_w,
#                       const char *path, Theme *theme, uint32_t bg)
syntax_draw_line:
    push rbx; push r12; push r13; push r14; push r15; push rbp
    sub rsp, 24
    mov rbx, rdi; mov r12d, esi; mov r13d, edx; mov r14, rcx; mov r15d, r8d
    mov rdi, r9; call syntax_detect
    mov rbp, [rsp + 80]       # Theme*
    mov edx, [rsp + 88]; mov [rsp + 16], edx
    test eax, eax; jnz .Lsdl_hi
    mov rdi, rbx; mov esi, [rbp + Theme.text]; xor ecx, ecx
    call ScreenBuffer_set_pen
    mov rdi, rbx; mov esi, r12d; mov edx, r13d; mov rcx, r14; mov r8d, r15d
    call ScreenBuffer_draw_text
    jmp .Lsdl_done
.Lsdl_hi:
    mov [rsp + 8], eax
    mov dword ptr [rsp], 0
.Lsdl_loop:
    mov ecx, [rsp]; cmp ecx, r15d; jge .Lsdl_done
    movzx eax, byte ptr [r14]; test eax, eax; jz .Lsdl_done
    cmp eax, '#'; jne .Lsdl_chk_slash
    cmp dword ptr [rsp + 8], 1; je .Lsdl_comment
    cmp dword ptr [rsp + 8], 3; je .Lsdl_comment
.Lsdl_chk_slash:
    cmp eax, '/'; jne .Lsdl_chk_str
    cmp byte ptr [r14 + 1], '/'; jne .Lsdl_chk_str
.Lsdl_comment:
    mov rdi, rbx; mov esi, [rbp + Theme.muted]; mov edx, [rsp + 16]; xor ecx, ecx
    call ScreenBuffer_set_pen
    mov rdi, rbx; mov esi, r12d; add esi, [rsp]; mov edx, r13d
    mov rcx, r14; mov r8d, r15d; sub r8d, [rsp]
    call ScreenBuffer_draw_text; jmp .Lsdl_done
.Lsdl_chk_str:
    cmp eax, '"'; je .Lsdl_str
    cmp eax, 39;  je .Lsdl_str
    cmp eax, '0'; jb .Lsdl_chk_id
    cmp eax, '9'; ja .Lsdl_chk_id
    mov rdi, rbx; mov esi, [rbp + Theme.warn_fg]; mov edx, [rsp + 16]; xor ecx, ecx
    call ScreenBuffer_set_pen
.Lsdl_num:
    mov ecx, [rsp]; cmp ecx, r15d; jge .Lsdl_done
    movzx eax, byte ptr [r14]
    cmp eax, '0'; jb .Lsdl_loop; cmp eax, '9'; jbe .Lsdl_nput
    cmp eax, 'x'; je .Lsdl_nput
    cmp eax, 'a'; jb .Lsdl_loop; cmp eax, 'f'; ja .Lsdl_loop
.Lsdl_nput:
    mov rdi, rbx; mov esi, r12d; add esi, [rsp]; mov edx, r13d; mov ecx, eax
    call ScreenBuffer_set_cell_pen
    inc r14; inc dword ptr [rsp]; jmp .Lsdl_num
.Lsdl_str:
    mov [rsp + 20], al
    mov rdi, rbx; mov esi, [rbp + Theme.exec_fg]; mov edx, [rsp + 16]; xor ecx, ecx
    call ScreenBuffer_set_pen
    mov rdi, rbx; mov esi, r12d; add esi, [rsp]; mov edx, r13d; movzx ecx, byte ptr [r14]
    call ScreenBuffer_set_cell_pen; inc r14; inc dword ptr [rsp]
.Lsdl_sl:
    mov ecx, [rsp]; cmp ecx, r15d; jge .Lsdl_done
    movzx eax, byte ptr [r14]; test eax, eax; jz .Lsdl_done
    mov rdi, rbx; mov esi, r12d; add esi, [rsp]; mov edx, r13d; mov ecx, eax
    push rax; call ScreenBuffer_set_cell_pen; pop rax
    inc r14; inc dword ptr [rsp]
    cmp al, [rsp + 20]; jne .Lsdl_sl; jmp .Lsdl_loop
.Lsdl_chk_id:
    call syn_is_ident; test eax, eax; jz .Lsdl_punct
    mov edi, [rsp + 16]; push rdi
    mov rdi, rbx; mov esi, r12d; add esi, [rsp + 8]; mov edx, r13d
    mov rcx, r14; mov r8d, r15d; sub r8d, [rsp + 8]; mov r9, rbp
    call syn_draw_ident; add rsp, 8
    add r14, rax; add [rsp], eax; jmp .Lsdl_loop
.Lsdl_punct:
    mov rdi, rbx; mov esi, [rbp + Theme.text]; mov edx, [rsp + 16]; xor ecx, ecx
    call ScreenBuffer_set_pen
    movzx ecx, byte ptr [r14]
    mov rdi, rbx; mov esi, r12d; add esi, [rsp]; mov edx, r13d
    call ScreenBuffer_set_cell_pen
    inc r14; inc dword ptr [rsp]; jmp .Lsdl_loop
.Lsdl_done:
    add rsp, 24; pop rbp; pop r15; pop r14; pop r13; pop r12; pop rbx; ret
