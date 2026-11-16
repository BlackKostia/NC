# Frozen reference oracle: the hand-written utf8.s that src/core/utf8.c replaced (tests/test_c_utf8.py diffs against it)
# UTF-8 Codec & Display Width Helpers

.intel_syntax noprefix

.section .text
.global utf8_decode
.global utf8_encode
.global utf8_char_width
.global utf8_display_width

# (uint32_t codepoint, int bytes_consumed) utf8_decode(const char *p)
# rdi = ptr -> rax = codepoint, rdx = bytes consumed (0 only if *p == 0)
utf8_decode:
    movzx eax, byte ptr [rdi]
    test eax, eax
    jz .Lud_nul

    cmp eax, 0x80
    jb .Lud_1byte

    mov ecx, eax
    and ecx, 0xE0
    cmp ecx, 0xC0
    je .Lud_2byte

    mov ecx, eax
    and ecx, 0xF0
    cmp ecx, 0xE0
    je .Lud_3byte

    mov ecx, eax
    and ecx, 0xF8
    cmp ecx, 0xF0
    je .Lud_4byte

.Lud_invalid:
    mov eax, 0xFFFD
    mov edx, 1
    ret

.Lud_nul:
    xor eax, eax
    xor edx, edx
    ret

.Lud_1byte:
    mov edx, 1
    ret

.Lud_2byte:
    movzx r8d, byte ptr [rdi + 1]
    mov ecx, r8d
    and ecx, 0xC0
    cmp ecx, 0x80
    jne .Lud_invalid
    and eax, 0x1F
    shl eax, 6
    and r8d, 0x3F
    or eax, r8d
    cmp eax, 0x80
    jb .Lud_invalid
    mov edx, 2
    ret

.Lud_3byte:
    movzx r8d, byte ptr [rdi + 1]
    mov ecx, r8d
    and ecx, 0xC0
    cmp ecx, 0x80
    jne .Lud_invalid
    movzx r9d, byte ptr [rdi + 2]
    mov ecx, r9d
    and ecx, 0xC0
    cmp ecx, 0x80
    jne .Lud_invalid
    and eax, 0x0F
    shl eax, 12
    and r8d, 0x3F
    shl r8d, 6
    and r9d, 0x3F
    or eax, r8d
    or eax, r9d
    cmp eax, 0x800
    jb .Lud_invalid
    mov edx, 3
    ret

.Lud_4byte:
    movzx r8d, byte ptr [rdi + 1]
    mov ecx, r8d
    and ecx, 0xC0
    cmp ecx, 0x80
    jne .Lud_invalid
    movzx r9d, byte ptr [rdi + 2]
    mov ecx, r9d
    and ecx, 0xC0
    cmp ecx, 0x80
    jne .Lud_invalid
    movzx r10d, byte ptr [rdi + 3]
    mov ecx, r10d
    and ecx, 0xC0
    cmp ecx, 0x80
    jne .Lud_invalid
    and eax, 0x07
    shl eax, 18
    and r8d, 0x3F
    shl r8d, 12
    and r9d, 0x3F
    shl r9d, 6
    and r10d, 0x3F
    or eax, r8d
    or eax, r9d
    or eax, r10d
    cmp eax, 0x10000
    jb .Lud_invalid
    cmp eax, 0x10FFFF
    ja .Lud_invalid
    mov edx, 4
    ret

# int utf8_encode(uint32_t cp, char *buf)
# rdi = cp, rsi = buf (needs >= 4 bytes) -> rax = byte count (1..4)
utf8_encode:
    cmp edi, 0x80
    jae .Lue_2
    mov byte ptr [rsi], dil
    mov eax, 1
    ret
.Lue_2:
    cmp edi, 0x800
    jae .Lue_3
    mov eax, edi
    shr eax, 6
    or eax, 0xC0
    mov byte ptr [rsi], al
    mov eax, edi
    and eax, 0x3F
    or eax, 0x80
    mov byte ptr [rsi + 1], al
    mov eax, 2
    ret
.Lue_3:
    cmp edi, 0x10000
    jae .Lue_4
    mov eax, edi
    shr eax, 12
    or eax, 0xE0
    mov byte ptr [rsi], al
    mov eax, edi
    shr eax, 6
    and eax, 0x3F
    or eax, 0x80
    mov byte ptr [rsi + 1], al
    mov eax, edi
    and eax, 0x3F
    or eax, 0x80
    mov byte ptr [rsi + 2], al
    mov eax, 3
    ret
.Lue_4:
    cmp edi, 0x10FFFF
    jbe .Lue_4_ok
    mov edi, 0xFFFD
    jmp .Lue_3
.Lue_4_ok:
    mov eax, edi
    shr eax, 18
    or eax, 0xF0
    mov byte ptr [rsi], al
    mov eax, edi
    shr eax, 12
    and eax, 0x3F
    or eax, 0x80
    mov byte ptr [rsi + 1], al
    mov eax, edi
    shr eax, 6
    and eax, 0x3F
    or eax, 0x80
    mov byte ptr [rsi + 2], al
    mov eax, edi
    and eax, 0x3F
    or eax, 0x80
    mov byte ptr [rsi + 3], al
    mov eax, 4
    ret

# int utf8_char_width(uint32_t cp)
# Returns 0 (combining/ctrl), 1 (normal), or 2 (wide CJK/Emoji)
utf8_char_width:
    cmp edi, 0x20
    jb .Lcw_zero
    cmp edi, 0x7F
    jb .Lcw_one
    cmp edi, 0xA0
    jb .Lcw_zero

    # Combining diacritics / variation selectors
    cmp edi, 0x0300
    jb .Lcw_check_wide
    cmp edi, 0x036F
    jbe .Lcw_zero
    cmp edi, 0xFE00
    jb .Lcw_check_wide
    cmp edi, 0xFE0F
    jbe .Lcw_zero

.Lcw_check_wide:
    cmp edi, 0x1100
    jb .Lcw_one
    cmp edi, 0x115F
    jbe .Lcw_two

    cmp edi, 0x2E80
    jb .Lcw_one
    cmp edi, 0xA4CF
    jbe .Lcw_two

    cmp edi, 0xAC00
    jb .Lcw_one
    cmp edi, 0xD7A3
    jbe .Lcw_two

    cmp edi, 0xF900
    jb .Lcw_one
    cmp edi, 0xFAFF
    jbe .Lcw_two

    cmp edi, 0xFF00
    jb .Lcw_one
    cmp edi, 0xFF60
    jbe .Lcw_two

    cmp edi, 0x1F300
    jb .Lcw_one
    cmp edi, 0x1FAFF
    jbe .Lcw_two

    cmp edi, 0x20000
    jb .Lcw_one
    cmp edi, 0x2FFFD
    jbe .Lcw_two

.Lcw_one:
    mov eax, 1
    ret
.Lcw_two:
    mov eax, 2
    ret
.Lcw_zero:
    xor eax, eax
    ret

# int utf8_display_width(const char *s)
utf8_display_width:
    push rbx
    push r12
    mov rbx, rdi
    xor r12d, r12d
    test rbx, rbx
    jz .Ldw_done
.Ldw_loop:
    mov rdi, rbx
    call utf8_decode
    test rdx, rdx
    jz .Ldw_done
    add rbx, rdx
    mov edi, eax
    call utf8_char_width
    add r12d, eax
    jmp .Ldw_loop
.Ldw_done:
    mov eax, r12d
    pop r12
    pop rbx
    ret
