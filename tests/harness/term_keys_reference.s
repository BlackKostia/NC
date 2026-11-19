# Frozen reference oracle: the hand-written asm that src/ui/term_keys.c replaced (tests/test_c_ui_leaf1.py diffs against it)
# Embedded terminal key encoder: Event -> bytes for the child PTY (xterm-compatible).
#
# Printable Unicode is sent as UTF-8, Ctrl+ASCII as C0 controls, Alt as an ESC prefix and
# navigation/editing keys as VT sequences. F-keys are left to the file manager.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.equ TK_ENTRY, 5                       # [len][up to 4 bytes]

.section .rodata
# Indexed by key - KEY_UP (KEY_UP .. KEY_ESC)
tk_special:
    .byte 3; .ascii "\x1b[A\0"         # UP
    .byte 3; .ascii "\x1b[B\0"         # DOWN
    .byte 3; .ascii "\x1b[D\0"         # LEFT
    .byte 3; .ascii "\x1b[C\0"         # RIGHT
    .byte 3; .ascii "\x1b[H\0"         # HOME
    .byte 3; .ascii "\x1b[F\0"         # END
    .byte 4; .ascii "\x1b[5~"          # PGUP
    .byte 4; .ascii "\x1b[6~"          # PGDN
    .byte 4; .ascii "\x1b[2~"          # INSERT
    .byte 4; .ascii "\x1b[3~"          # DELETE
    .byte 1; .ascii "\x7f\0\0\0"       # BACKSPACE
    .byte 1; .ascii "\t\0\0\0"         # TAB
    .byte 3; .ascii "\x1b[Z\0"         # BTAB
    .byte 1; .ascii "\r\0\0\0"         # ENTER
    .byte 1; .ascii "\x1b\0\0\0"       # ESC

.section .text
.global term_key_encode

# int term_key_encode(const Event *evt, char *out /* >= 8 bytes */)
#   -> n > 0 : bytes to write to the PTY
#   ->     0 : key swallowed (no meaningful encoding)
#   ->    -1 : not a terminal key (let the file manager handle it, e.g. F1..F12)
term_key_encode:
    mov eax, [rdi + Event.key]
    mov ecx, [rdi + Event.mods]
    cmp eax, KEY_UP
    jae .Ltke_special
    cmp eax, 0x110000
    jae .Ltke_none
    xor r8d, r8d                       # prefix length
    test ecx, MOD_ALT
    jz .Ltke_ctrl
    mov byte ptr [rsi], 0x1B
    inc rsi
    inc r8d
.Ltke_ctrl:
    test ecx, MOD_CTRL
    jz .Ltke_utf8
    cmp eax, 0x20
    jb .Ltke_utf8
    cmp eax, 0x7E
    ja .Ltke_utf8
    and eax, 0x1F
.Ltke_utf8:
    push r8
    mov edi, eax
    call utf8_encode
    pop r8
    add eax, r8d
    ret

.Ltke_special:
    cmp eax, KEY_ESC
    ja .Ltke_pass
    sub eax, KEY_UP
    imul eax, eax, TK_ENTRY
    lea rdx, [rip + tk_special]
    add rdx, rax
    mov ecx, [rdx + 1]
    mov [rsi], ecx
    movzx eax, byte ptr [rdx]
    ret
.Ltke_pass:
    mov eax, -1
    ret
.Ltke_none:
    xor eax, eax
    ret
