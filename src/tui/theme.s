# TrueColor 24-bit Modern Themes (Tokyo Night, Catppuccin Mocha, Cyber Emerald)

.intel_syntax noprefix
.include "types.inc"

.section .rodata
str_theme_tokyo:   .asciz "Tokyo Night"
str_theme_catp:    .asciz "Catppuccin"
str_theme_cyber:   .asciz "Emerald"

.align 8
.global themes_table
themes_table:
    # --- Theme 0: Tokyo Night ---
    .quad str_theme_tokyo
    .long 0x0116161E   # bg
    .long 0x011A1B26   # surface
    .long 0x011F2335   # surface_alt
    .long 0x0113141C   # header_bg
    .long 0x01C0CAF5   # header_fg
    .long 0x017AA2F7   # accent
    .long 0x0115161E   # accent_fg
    .long 0x017AA2F7   # border_active
    .long 0x013B4261   # border_inactive
    .long 0x01C0CAF5   # text
    .long 0x01565F89   # muted
    .long 0x017DCFFF   # dir_fg
    .long 0x019ECE6A   # exec_fg
    .long 0x01BB9AF7   # link_fg
    .long 0x016B739E   # hidden_fg
    .long 0x01E0AF68   # selected_fg
    .long 0x01292E42   # selected_bg
    .long 0x01283457   # cursor_active_bg
    .long 0x01202436   # cursor_inactive_bg
    .long 0x0124283B   # badge_bg
    .long 0x013B4261   # badge_hover_bg
    .long 0x01C0CAF5   # badge_fg
    .long 0x011D202F   # dialog_bg
    .long 0x01BB9AF7   # dialog_border
    .long 0x019ECE6A   # ok_fg
    .long 0x01E0AF68   # warn_fg
    .long 0x01F7768E   # err_fg
    .long 0x01292E42   # scroll_track
    .long 0x017AA2F7   # scroll_thumb
    .long 0            # pad

    # --- Theme 1: Catppuccin Mocha ---
    .quad str_theme_catp
    .long 0x01181825   # bg
    .long 0x011E1E2E   # surface
    .long 0x01252538   # surface_alt
    .long 0x0111111B   # header_bg
    .long 0x01CDD6F4   # header_fg
    .long 0x01CBA6F7   # accent
    .long 0x0111111B   # accent_fg
    .long 0x01CBA6F7   # border_active
    .long 0x0145475A   # border_inactive
    .long 0x01CDD6F4   # text
    .long 0x016C7086   # muted
    .long 0x0189B4FA   # dir_fg
    .long 0x01A6E3A1   # exec_fg
    .long 0x0194E2D5   # link_fg
    .long 0x017F849C   # hidden_fg
    .long 0x01F9E2AF   # selected_fg
    .long 0x01313244   # selected_bg
    .long 0x01363850   # cursor_active_bg
    .long 0x01262738   # cursor_inactive_bg
    .long 0x01313244   # badge_bg
    .long 0x0145475A   # badge_hover_bg
    .long 0x01CDD6F4   # badge_fg
    .long 0x011E1E2E   # dialog_bg
    .long 0x01F5C2E7   # dialog_border
    .long 0x01A6E3A1   # ok_fg
    .long 0x01F9E2AF   # warn_fg
    .long 0x01F38BA8   # err_fg
    .long 0x01313244   # scroll_track
    .long 0x01CBA6F7   # scroll_thumb
    .long 0            # pad

    # --- Theme 2: Cyber Emerald ---
    .quad str_theme_cyber
    .long 0x010A1014   # bg
    .long 0x010F171C   # surface
    .long 0x01142026   # surface_alt
    .long 0x01070C0F   # header_bg
    .long 0x01D8E8EE   # header_fg
    .long 0x0100E5A3   # accent
    .long 0x01061210   # accent_fg
    .long 0x0100E5A3   # border_active
    .long 0x01243B44   # border_inactive
    .long 0x01D8E8EE   # text
    .long 0x015D7882   # muted
    .long 0x0138BDF8   # dir_fg
    .long 0x01A3E635   # exec_fg
    .long 0x01F472B6   # link_fg
    .long 0x01607D87   # hidden_fg
    .long 0x01FBBF24   # selected_fg
    .long 0x01182C34   # selected_bg
    .long 0x01173842   # cursor_active_bg
    .long 0x0113222A   # cursor_inactive_bg
    .long 0x01182830   # badge_bg
    .long 0x01243B44   # badge_hover_bg
    .long 0x01D8E8EE   # badge_fg
    .long 0x01111C22   # dialog_bg
    .long 0x0138BDF8   # dialog_border
    .long 0x0100E5A3   # ok_fg
    .long 0x01FBBF24   # warn_fg
    .long 0x01FB7185   # err_fg
    .long 0x01182C34   # scroll_track
    .long 0x0100E5A3   # scroll_thumb
    .long 0            # pad

.equ THEME_COUNT, 3

.section .bss
.align 8
g_active_theme:    .space Theme._size

.section .text
.global theme_get
.global theme_count
.extern config_get

# const Theme *theme_get(int idx)
theme_get:
    push rbx
    mov eax, edi
    cdq
    mov ecx, THEME_COUNT
    idiv ecx
    test edx, edx
    jns .Ltg_ok
    add edx, THEME_COUNT
.Ltg_ok:
    imul rax, rdx, Theme._size
    lea rsi, [rip + themes_table]
    add rsi, rax
    lea rdi, [rip + g_active_theme]
    mov rbx, rdi
    mov ecx, Theme._size / 8
    rep movsq

    call config_get
    mov r8d, [rax + 16]       # CFG_COLOR_MASK
    test r8d, r8d
    jz .Ltg_done
    xor ecx, ecx
.Ltg_ov:
    cmp ecx, 29
    jae .Ltg_done
    bt r8d, ecx
    jnc .Ltg_next
    mov edx, [rax + 32 + rcx * 4]  # CFG_COLORS
    mov [rbx + Theme.bg + rcx * 4], edx
.Ltg_next:
    inc ecx
    jmp .Ltg_ov
.Ltg_done:
    mov rax, rbx
    pop rbx
    ret

# int theme_count(void)
theme_count:
    mov eax, THEME_COUNT
    ret
