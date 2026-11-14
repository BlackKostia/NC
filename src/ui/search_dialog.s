# src/ui/search_dialog.s - Recursive search dialog (name mask + content grep)
.intel_syntax noprefix

.include "pal.inc"
.include "classes.inc"

.section .rodata
str_SearchDialog: .asciz "SearchDialog"

.section .text
.global SearchDialog_vtbl
SearchDialog_vtbl:
    DIALOG_VTBL_SLOTS str_SearchDialog, Dialog_vtbl, SearchDialog._size, Dialog_dtor, SearchDialog_layout, SearchDialog_render, SearchDialog_on_key, SearchDialog_on_mouse, Widget_on_focus, Widget_hit_test, Dialog_on_confirm, Dialog_on_cancel

.global SearchDialog_new
.global SearchDialog_layout
.global SearchDialog_render
.global SearchDialog_on_key
.global SearchDialog_on_mouse
.global fp_exit_virtual
.global fp_draw_search_badge

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

# ==============================================================================
# SearchDialog *SearchDialog_new(App *app)
# ==============================================================================
SearchDialog_new:
    push rbx
    push r12
    sub rsp, 8
    mov r12, rdi
    NEW_OBJ SearchDialog_vtbl, SearchDialog._size
    test rax, rax
    jz .Lsdn_ret
    mov rbx, rax
    call i18n_get
    mov rdx, [rax + LangStrings.dlg_title_search]
    mov rdi, rbx
    mov rsi, r12
    mov ecx, OP_SEARCH
    call Dialog_init

    mov ecx, 80
    mov r8d, 24
    test r12, r12
    jz .Lsdn_lay
    mov ecx, [r12 + App.term_w]
    mov r8d, [r12 + App.term_h]
.Lsdn_lay:
    mov rdi, rbx
    xor esi, esi
    xor edx, edx
    call SearchDialog_layout
    mov rax, rbx
.Lsdn_ret:
    add rsp, 8
    pop r12
    pop rbx
    ret

# int fp_exit_virtual(FilePane *pane) -> 1 if exited virtual mode, 0 otherwise
fp_exit_virtual:
    mov rcx, [rdi + FilePane.model]
    cmp dword ptr [rcx + DirModel.virtual_mode], 2
    je arc_nav_up
    cmp dword ptr [rcx + DirModel.virtual_mode], 0
    jne .Lfev_exit
    xor eax, eax
    ret
.Lfev_exit:
    push rbx
    mov rbx, rdi
    mov dword ptr [rcx + DirModel.virtual_mode], 0
    mov rdi, rcx
    call DirModel_reload
    mov dword ptr [rbx + FilePane.cursor], 0
    mov dword ptr [rbx + FilePane.scroll], 0
    mov rdi, rbx
    call FilePane_ensure_visible
    mov eax, 1
    pop rbx
    ret

# void fp_draw_search_badge(FilePane *pane, ScreenBuffer *scr)
fp_draw_search_badge:
    mov rax, [rdi + FilePane.model]
    cmp dword ptr [rax + DirModel.virtual_mode], 0
    je fp_draw_du_badge
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    call i18n_get
    mov rcx, [rax + LangStrings.fp_search_badge]
    mov esi, [rbx + Widget.x]
    add esi, [rbx + Widget.w]
    sub esi, 12
    mov edx, [rbx + Widget.y]
    mov rdi, r12
    mov r8d, 10
    call ScreenBuffer_draw_text
    add rsp, 8
    pop r12
    pop rbx
.Lfdsb_done:
    ret

# ==============================================================================
# void SearchDialog_layout(SearchDialog *this, int x, int y, int cols, int rows)
# ==============================================================================
SearchDialog_layout:
    mov eax, ecx
    sub eax, 4
    cmp eax, 62
    jle .Lsdl_w_ok
    mov eax, 62
.Lsdl_w_ok:
    cmp eax, 36
    jge .Lsdl_w_min
    mov eax, 36
.Lsdl_w_min:
    mov [rdi + Widget.w], eax
    mov r9d, 11
    mov [rdi + Widget.h], r9d
    sub ecx, eax
    sar ecx, 1
    mov [rdi + Widget.x], ecx
    sub r8d, r9d
    sar r8d, 1
    mov [rdi + Widget.y], r8d
    jmp dlg_layout_right_buttons

# ==============================================================================
# Helper: void sd_draw_field(SearchDialog *this, ScreenBuffer *scr, Theme *th,
#                            int y_off, const char *lbl, const char *val, int active)
# ==============================================================================
sd_draw_field:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 24
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14d, ecx             # y_off
    mov [rsp + 0], r8         # lbl
    mov [rsp + 8], r9         # val
    mov eax, [rsp + 72]       # 7th arg (active) on stack: 5*8 + 24 + 8 = 72
    mov [rsp + 16], eax

    mov rdi, r12
    mov esi, [r13 + Theme.text]
    mov edx, [r13 + Theme.dialog_bg]
    xor ecx, ecx
    call ScreenBuffer_set_pen

    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 2
    mov edx, [rbx + Widget.y]
    add edx, r14d
    mov rcx, [rsp + 0]
    mov r8d, [rbx + Widget.w]
    sub r8d, 4
    call ScreenBuffer_draw_text

    mov esi, [r13 + Theme.text]
    mov edx, [r13 + Theme.surface_alt]
    xor ecx, ecx
    cmp dword ptr [rsp + 16], 0
    je .Lsddf_pen
    mov edx, [r13 + Theme.cursor_active_bg]
    mov ecx, ATTR_BOLD
.Lsddf_pen:
    mov rdi, r12
    call ScreenBuffer_set_pen

    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 2
    mov edx, [rbx + Widget.y]
    add edx, r14d
    inc edx
    mov ecx, [rbx + Widget.w]
    sub ecx, 4
    mov r8d, ' '
    call ScreenBuffer_draw_hline

    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 3
    mov edx, [rbx + Widget.y]
    add edx, r14d
    inc edx
    mov rcx, [rsp + 8]
    mov r8d, [rbx + Widget.w]
    sub r8d, 6
    call ScreenBuffer_draw_text

    add rsp, 24
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# ==============================================================================
# void SearchDialog_render(SearchDialog *this, ScreenBuffer *scr, Theme *theme)
# ==============================================================================
SearchDialog_render:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx

    call i18n_get
    mov r14, rax
    mov rcx, [r14 + LangStrings.dlg_btn_ok]
    mov r8, [r14 + LangStrings.dlg_btn_cancel]
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call Dialog_draw_frame

    xor eax, eax
    cmp dword ptr [rbx + SearchDialog.focus_field], 0
    sete al
    push rax
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov ecx, 2
    mov r8, [r14 + LangStrings.srch_lbl_name]
    lea r9, [rbx + SearchDialog.name_buf]
    call sd_draw_field
    add rsp, 8

    xor eax, eax
    cmp dword ptr [rbx + SearchDialog.focus_field], 1
    sete al
    push rax
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov ecx, 5
    mov r8, [r14 + LangStrings.srch_lbl_grep]
    lea r9, [rbx + SearchDialog.grep_buf]
    call sd_draw_field
    add rsp, 8

    mov rdi, r12
    mov esi, [r13 + Theme.muted]
    mov edx, [r13 + Theme.dialog_bg]
    xor ecx, ecx
    call ScreenBuffer_set_pen

    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 2
    mov edx, [rbx + Widget.y]
    add edx, [rbx + Widget.h]
    sub edx, 2
    mov rcx, [r14 + LangStrings.srch_hint]
    mov r8d, [rbx + Widget.w]
    sub r8d, 26
    cmp r8d, 8
    jge .Lsdr_hd
    mov r8d, 8
.Lsdr_hd:
    call ScreenBuffer_draw_text

    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

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
