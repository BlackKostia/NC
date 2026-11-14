# PreviewPane Widget (Inherits from Widget) — preview pane mouse (split from preview_pane.s)

.intel_syntax noprefix
.include "classes.inc"

.section .text
.global PreviewPane_on_mouse

# int PreviewPane_on_mouse(PreviewPane *this, Event *evt)
PreviewPane_on_mouse:
    cmp dword ptr [rsi + Event.mouse_kind], MACT_WHEEL
    jne .Lppm_ret0
    mov eax, [rdi + PreviewPane.scroll]
    cmp dword ptr [rsi + Event.mouse_btn], MOUSE_WHEEL_UP
    jne .Lppm_dn
    sub eax, 3
    jns .Lppm_apply
    xor eax, eax
    jmp .Lppm_apply
.Lppm_dn:
    add eax, 3
    mov ecx, [rdi + PreviewPane.total_lines]
    cmp dword ptr [rdi + PreviewPane.is_binary], 0
    je .Lppm_chk_max
    mov rcx, [rdi + PreviewPane.buf_len]
    shr rcx, 3
.Lppm_chk_max:
    dec ecx
    jns .Lppm_max_nonneg
    xor ecx, ecx
.Lppm_max_nonneg:
    cmp eax, ecx
    jle .Lppm_apply
    mov eax, ecx
.Lppm_apply:
    mov [rdi + PreviewPane.scroll], eax
    mov rax, [rdi + PreviewPane.app]
    mov dword ptr [rax + App.need_redraw], 1
    mov eax, 1
    ret
.Lppm_ret0:
    xor eax, eax
    ret
