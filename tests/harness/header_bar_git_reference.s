# Frozen reference oracle: the hand-written asm that src/ui/header_bar_git.c replaced (tests/test_c_ui_leaf1.py diffs against it)
# HeaderBar Widget (Inherits from Widget) — header bar git (split from header_bar.s)

.intel_syntax noprefix
.include "classes.inc"

.section .text
.global hdr_draw_mode_and_git

hdr_draw_mode_and_git:
    push rbx; push r12; push r13; push r14; push r15
    mov rbx, rdi; mov r12, rsi; mov r13, rdx; mov r15, rcx
    mov rdi, [r15 + LangStrings.hdr_brand]
    call utf8_display_width
    mov r14d, [rbx + Widget.x]
    add r14d, eax
    inc r14d
    cmp dword ptr [rbx + Widget.w], 30
    jl .Lhdmg_ret
    mov rdi, r12
    mov esi, [r13 + Theme.header_fg]
    mov edx, [r13 + Theme.surface_alt]
    xor ecx, ecx
    call ScreenBuffer_set_pen
    mov r8, [rbx + HeaderBar.app]
    mov rcx, [r15 + LangStrings.hdr_mode_dual]
    cmp dword ptr [r8 + App.right_mode], RIGHT_MODE_PREVIEW
    jne .Lhdmg_dm
    mov rcx, [r15 + LangStrings.hdr_mode_prev]
.Lhdmg_dm:
    push rcx
    mov rdi, rcx
    call utf8_display_width
    mov r8d, eax
    pop rcx
    mov rdi, r12
    mov esi, r14d
    mov edx, [rbx + Widget.y]
    push r8
    call ScreenBuffer_draw_text
    pop r8
    lea ecx, [r14d + r8d + 1]
    mov rdi, rbx; mov rsi, r12; mov rdx, r13
    mov r8d, [rbx + Widget.y]
    call hdr_draw_git_badge
.Lhdmg_ret:
    pop r15; pop r14; pop r13; pop r12; pop rbx
    ret
