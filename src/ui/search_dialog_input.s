# src/ui/search_dialog.s - Recursive search dialog (name mask + content grep) — search dialog input (split from search_dialog.s)

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"
.extern DirModel_reload
.extern FilePane_ensure_visible
.extern arc_nav_up
.extern Dialog_vtbl
.extern Dialog_init
.extern Dialog_dtor
.extern Dialog_draw_frame
.extern Dialog_on_confirm
.extern Dialog_on_cancel
.extern Dialog_on_mouse
.extern dlg_layout_right_buttons
.extern Widget_on_focus
.extern Widget_hit_test
.extern ScreenBuffer_set_pen
.extern ScreenBuffer_draw_hline
.extern ScreenBuffer_draw_text
.extern i18n_get
.extern mem_alloc

.section .text
.global SearchDialog_on_key
.global SearchDialog_on_mouse

# ==============================================================================
# Helper: void sd_edit_char(SearchDialog *this, uint32_t key, int is_bs)
# ==============================================================================
sd_edit_char:
    lea r8, [rdi + SearchDialog.name_buf]
    lea r9, [rdi + SearchDialog.name_len]
    cmp dword ptr [rdi + SearchDialog.focus_field], 0
    je .Lsdec_got
    lea r8, [rdi + SearchDialog.grep_buf]
    lea r9, [rdi + SearchDialog.grep_len]
.Lsdec_got:
    mov ecx, [r9]
    test edx, edx
    jnz .Lsdec_bs
    # Append UTF-8 codepoint
    cmp esi, 0x80
    jae .Lsdec_utf8
    cmp ecx, 126
    jae .Lsdec_done
    mov [r8 + rcx], sil
    inc ecx
    mov byte ptr [r8 + rcx], 0
    mov [r9], ecx
    ret
.Lsdec_utf8:
    cmp esi, 0x800
    jae .Lsdec_u3
    cmp ecx, 125
    jae .Lsdec_done
    mov eax, esi
    shr eax, 6
    or eax, 0xC0
    mov [r8 + rcx], al
    mov eax, esi
    and eax, 0x3F
    or eax, 0x80
    mov [r8 + rcx + 1], al
    add ecx, 2
    mov byte ptr [r8 + rcx], 0
    mov [r9], ecx
    ret
.Lsdec_u3:
    cmp esi, 0x10000
    jae .Lsdec_done
    cmp ecx, 124
    jae .Lsdec_done
    mov eax, esi
    shr eax, 12
    or eax, 0xE0
    mov [r8 + rcx], al
    mov eax, esi
    shr eax, 6
    and eax, 0x3F
    or eax, 0x80
    mov [r8 + rcx + 1], al
    mov eax, esi
    and eax, 0x3F
    or eax, 0x80
    mov [r8 + rcx + 2], al
    add ecx, 3
    mov byte ptr [r8 + rcx], 0
    mov [r9], ecx
    ret
.Lsdec_bs:
    test ecx, ecx
    jz .Lsdec_done
.Lsdec_bs_loop:
    dec ecx
    movzx eax, byte ptr [r8 + rcx]
    and eax, 0xC0
    cmp eax, 0x80
    jne .Lsdec_bs_done
    test ecx, ecx
    jnz .Lsdec_bs_loop
.Lsdec_bs_done:
    mov byte ptr [r8 + rcx], 0
    mov [r9], ecx
.Lsdec_done:
    ret

# ==============================================================================
# void SearchDialog_on_key(SearchDialog *this, Event *ev)
# ==============================================================================
SearchDialog_on_key:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    mov eax, [r12 + Event.key]

    cmp eax, KEY_TAB
    je .Lsdk_toggle
    cmp eax, KEY_UP
    je .Lsdk_toggle
    cmp eax, KEY_DOWN
    je .Lsdk_toggle
    cmp eax, KEY_ENTER
    je .Lsdk_ok
    cmp eax, KEY_ESC
    je .Lsdk_esc
    cmp eax, KEY_BACKSPACE
    je .Lsdk_bs
    cmp eax, 8
    je .Lsdk_bs

    test dword ptr [r12 + Event.mods], MOD_CTRL | MOD_ALT
    jnz .Lsdk_done
    cmp eax, 32
    jl .Lsdk_done
    mov rdi, rbx
    mov esi, eax
    xor edx, edx
    call sd_edit_char
    jmp .Lsdk_redraw

.Lsdk_bs:
    mov rdi, rbx
    xor esi, esi
    mov edx, 1
    call sd_edit_char
    jmp .Lsdk_redraw

.Lsdk_toggle:
    xor dword ptr [rbx + SearchDialog.focus_field], 1
.Lsdk_redraw:
    mov rax, [rbx + Dialog.app]
    mov dword ptr [rax + App.need_redraw], 1
    jmp .Lsdk_done

.Lsdk_ok:
    mov rdi, rbx
    call Dialog_on_confirm
    jmp .Lsdk_done

.Lsdk_esc:
    mov rdi, rbx
    call Dialog_on_cancel

.Lsdk_done:
    add rsp, 8
    pop r12
    pop rbx
    ret

# ==============================================================================
# void SearchDialog_on_mouse(SearchDialog *this, Event *ev)
# ==============================================================================
SearchDialog_on_mouse:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    cmp dword ptr [r12 + Event.mouse_kind], MACT_PRESS
    jne .Lsdm_base
    cmp dword ptr [r12 + Event.mouse_btn], MOUSE_LEFT
    jne .Lsdm_base
    mov eax, [r12 + Event.mouse_y]
    sub eax, [rbx + Widget.y]
    cmp eax, 3
    je .Lsdm_f0
    cmp eax, 6
    je .Lsdm_f1
    jmp .Lsdm_base
.Lsdm_f0:
    mov dword ptr [rbx + SearchDialog.focus_field], 0
    jmp .Lsdm_redr
.Lsdm_f1:
    mov dword ptr [rbx + SearchDialog.focus_field], 1
.Lsdm_redr:
    mov rax, [rbx + Dialog.app]
    mov dword ptr [rax + App.need_redraw], 1
    jmp .Lsdm_done
.Lsdm_base:
    mov rdi, rbx
    mov rsi, r12
    call Dialog_on_mouse
.Lsdm_done:
    add rsp, 8
    pop r12
    pop rbx
    ret
