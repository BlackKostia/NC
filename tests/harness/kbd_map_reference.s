# Frozen reference oracle: the hand-written asm that src/tui/kbd_map.c replaced (tests/test_c_tui_data.py diffs against it)
# Keyboard layout table: parses *.layout text into {codepoint -> Latin key} pairs and answers
# kbd_latin(key) for hotkey matching (Event.lat). File syntax (UTF-8, one setting per line):
#   # comment
#   name  = Українська      -- ignored, for people
#   keys  = qwertyuiop[]    -- Latin keys of one keyboard row, left to right
#   chars = йцукенгшщзхї    -- what the layout types on the same keys, in the same order
# Each `chars` line pairs with the nearest preceding `keys` line. ASCII chars are skipped (ordinary
# keys never change meaning), targets must be printable ASCII, and the first mapping of a
# codepoint wins. Where the files are found: kbd_layout.s.

.intel_syntax noprefix
.include "pal.inc"
.include "config.inc"

.section .bss
.align 8
g_kbd_n:    .space 8
g_kbd_map:  .space KBD_MAP_MAX * 8          # {u32 codepoint, u32 Latin key}

.section .rodata
kw_keys:    .asciz "keys"
kw_chars:   .asciz "chars"

.section .text
.global kbd_map_reset
.global kbd_latin
.global kbd_layout_parse

# void kbd_map_reset(void)
kbd_map_reset:
    mov dword ptr [rip + g_kbd_n], 0
    ret

# int kbd_latin(int key) -> the Latin key under `key` when a layout maps it, else key
kbd_latin:
    mov eax, edi
    cmp edi, 0x80
    jb .Lkl_ret
    mov ecx, [rip + g_kbd_n]
    lea rdx, [rip + g_kbd_map]
.Lkl_scan:
    test ecx, ecx
    jz .Lkl_ret
    cmp [rdx], edi
    je .Lkl_hit
    add rdx, 8
    dec ecx
    jmp .Lkl_scan
.Lkl_hit:
    mov eax, [rdx + 4]
.Lkl_ret:
    ret

# void kbd_layout_parse(char *text) -- NUL-terminated layout file, modified in place
kbd_layout_parse:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    xor r12d, r12d                    # pending `keys` value (0 = none yet)
.Lkp_line:
    cmp byte ptr [rbx], 0
    je .Lkp_ret
    mov rdi, rbx
    call kp_cut_line
    mov r13, rax                      # next line
    mov rdi, rbx
    call kp_value                     # rax = value, edx = 1 keys / 2 chars / 0 other
    cmp edx, 1
    jne .Lkp_chars
    mov r12, rax
    jmp .Lkp_next
.Lkp_chars:
    cmp edx, 2
    jne .Lkp_next
    test r12, r12
    jz .Lkp_next
    mov rdi, r12
    mov rsi, rax
    call kp_pair
.Lkp_next:
    mov rbx, r13
    jmp .Lkp_line
.Lkp_ret:
    pop r13
    pop r12
    pop rbx
    ret

# Internal: char *kp_cut_line(char *p) -- NUL-terminates the line at '\n', returns the next one
kp_cut_line:
    mov rax, rdi
.Lcl_scan:
    movzx ecx, byte ptr [rax]
    test cl, cl
    jz .Lcl_ret
    inc rax
    cmp cl, '\n'
    jne .Lcl_scan
    mov byte ptr [rax - 1], 0
.Lcl_ret:
    ret

# Internal: (char *value, int kind) kp_value(char *line) -- "keys = v" -> 1, "chars = v" -> 2
kp_value:
    push rbx
    push r12
    sub rsp, 8
    call skip_ws
    mov rbx, rax
    mov r12d, 1
    mov rdi, rbx
    lea rsi, [rip + kw_keys]
    call str_starts_with
    lea rcx, [rbx + 4]
    test eax, eax
    jnz .Lkv_eq
    mov r12d, 2
    mov rdi, rbx
    lea rsi, [rip + kw_chars]
    call str_starts_with
    lea rcx, [rbx + 5]
    test eax, eax
    jz .Lkv_none
.Lkv_eq:
    mov rdi, rcx
    call skip_ws
    cmp byte ptr [rax], '='
    jne .Lkv_none
    lea rdi, [rax + 1]
    call skip_ws
    mov rbx, rax
    mov rdi, rax
    call kp_trim
    mov rax, rbx
    mov edx, r12d
    jmp .Lkv_ret
.Lkv_none:
    xor eax, eax
    xor edx, edx
.Lkv_ret:
    add rsp, 8
    pop r12
    pop rbx
    ret

# Internal: void kp_trim(char *s) -- strip trailing spaces, tabs and CR
kp_trim:
    mov rax, rdi
.Ltr_end:
    cmp byte ptr [rax], 0
    je .Ltr_back
    inc rax
    jmp .Ltr_end
.Ltr_back:
    cmp rax, rdi
    jbe .Ltr_ret
    movzx ecx, byte ptr [rax - 1]
    cmp cl, ' '
    je .Ltr_cut
    cmp cl, '\t'
    je .Ltr_cut
    cmp cl, '\r'
    jne .Ltr_ret
.Ltr_cut:
    dec rax
    mov byte ptr [rax], 0
    jmp .Ltr_back
.Ltr_ret:
    ret

# Internal: void kp_pair(const char *keys, const char *chars) -- add every valid column pair
kp_pair:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
.Lpp_next:
    mov rdi, rbx
    call utf8_decode
    test edx, edx
    jz .Lpp_ret
    add rbx, rdx
    mov r13d, eax                     # Latin key
    mov rdi, r12
    call utf8_decode
    test edx, edx
    jz .Lpp_ret
    add r12, rdx
    cmp r13d, 0x20
    jbe .Lpp_next
    cmp r13d, 0x7F
    jae .Lpp_next                     # target must be a printable ASCII key
    cmp eax, 0x80
    jb .Lpp_next                      # ASCII keeps its own meaning
    cmp eax, 0xFFFD
    je .Lpp_next                      # malformed UTF-8
    cmp eax, KEY_UP
    jae .Lpp_next                     # never shadow special keys
    mov edi, eax
    mov esi, r13d
    call kp_insert
    jmp .Lpp_next
.Lpp_ret:
    pop r13
    pop r12
    pop rbx
    ret

# Internal: void kp_insert(int cp, int key) -- append unless cp is already mapped or the table is full
kp_insert:
    mov ecx, [rip + g_kbd_n]
    lea rdx, [rip + g_kbd_map]
    xor eax, eax
.Lki_dup:
    cmp eax, ecx
    jae .Lki_add
    cmp [rdx + rax * 8], edi
    je .Lki_ret
    inc eax
    jmp .Lki_dup
.Lki_add:
    cmp ecx, KBD_MAP_MAX
    jae .Lki_ret
    mov [rdx + rcx * 8], edi
    mov [rdx + rcx * 8 + 4], esi
    inc ecx
    mov [rip + g_kbd_n], ecx
.Lki_ret:
    ret
