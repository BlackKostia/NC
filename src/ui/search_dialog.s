# src/ui/search_dialog.s - Recursive search dialog (name mask + content grep)

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

.section .rodata
str_SearchDialog: .asciz "SearchDialog"

.section .text
.global SearchDialog_vtbl
.global SearchDialog_new
.global fp_exit_virtual
.global fp_draw_search_badge
.global SearchDialog_layout
.global SearchDialog_render

.section .rodata
.balign 8
SearchDialog_vtbl:
    DIALOG_VTBL_SLOTS str_SearchDialog, Dialog_vtbl, SearchDialog._size, Dialog_dtor, SearchDialog_layout, SearchDialog_render, SearchDialog_on_key, SearchDialog_on_mouse, Widget_on_focus, Widget_hit_test, Dialog_on_confirm, Dialog_on_cancel
.section .text

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
