# Frozen reference oracle: src/ui/popup_menu.s (before C23 migration to src/ui/popup_menu.c).
# Popup Context Menu, OSC 52 Clipboard, and Mouse Drag-and-Drop between panes

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.struct Dialog._size
PopupMenuDialog.cursor: .space 4
PopupMenuDialog.pad:    .space 4
PopupMenuDialog._size:

.section .rodata
str_PopupMenuDialog:
    .asciz "PopupMenuDialog"
.align 8
popup_item_offs:
    .long LangStrings.ctx_view
    .long LangStrings.ctx_copy
    .long LangStrings.ctx_move
    .long LangStrings.ctx_copy_path
    .long LangStrings.ctx_delete

.align 8
PopupMenuDialog_vtbl:
    DIALOG_VTBL_SLOTS str_PopupMenuDialog, Dialog_vtbl, PopupMenuDialog._size, Dialog_dtor, PopupMenu_layout, PopupMenu_render, PopupMenu_on_key, PopupMenu_on_mouse, Widget_on_focus, Widget_hit_test, Dialog_on_confirm, Dialog_on_cancel

.section .bss
g_dnd_active:   .space 4
.align 8
g_dnd_src_pane: .space 8

.section .text
.global PopupMenu_new
.global pane_mouse_ext

.extern osc52_copy_text

.extern App_close_dialog
.extern App_cmd_view
.extern App_cmd_copy
.extern App_cmd_move
.extern App_cmd_delete
.extern App_run_pkg_action
.extern DirModel_entry_name
.extern FilePane_get_selected_entry
.extern pkg_popup_refresh
.extern pkg_popup_count
.extern pkg_popup_label
.extern pkg_popup_get
.extern Dialog_dtor
.extern Dialog_on_confirm
.extern Dialog_on_cancel
.extern Widget_on_focus
.extern Widget_hit_test

# PopupMenuDialog *PopupMenu_new(App *app, int x, int y)
PopupMenu_new:
    push rbx; push r12; push r13; push r14
    mov r12, rdi              # app
    mov r13d, esi             # x
    mov r14d, edx             # y
    mov edi, PopupMenuDialog._size
    call mem_alloc
    mov rbx, rax
    lea rax, [rip + PopupMenuDialog_vtbl]
    mov [rbx], rax
    mov [rbx + Dialog.app], r12
    mov dword ptr [rbx + PopupMenuDialog.cursor], 0
    mov rdi, [r12 + App.active_pane]; call FilePane_get_selected_entry
    xor esi, esi; xor edx, edx
    test rax, rax; jz .Lpmn_ref
    mov ecx, [rax + FileEntry.flags]; test ecx, FE_IS_DIR; jz .Lpmn_nm
    mov esi, 1
.Lpmn_nm:
    push rsi; mov rcx, [r12 + App.active_pane]; mov rdi, [rcx + FilePane.model]; mov rsi, rax
    call DirModel_entry_name; mov rdx, rax; pop rsi
.Lpmn_ref:
    mov rdi, [r12 + App.envp]; call pkg_popup_refresh
    add eax, 7; mov [rbx + Widget.h], eax
    mov ecx, 24; cmp eax, 7; je .Lpmn_w; mov ecx, 30
.Lpmn_w:
    mov [rbx + Widget.w], ecx
    mov [rbx + Widget.x], r13d; mov [rbx + Widget.y], r14d
    mov rdi, rbx
    call PopupMenu_layout
    mov [r12 + App.active_dialog], rbx
    mov dword ptr [r12 + App.need_redraw], 1
    mov rax, rbx
    pop r14; pop r13; pop r12; pop rbx; ret

PopupMenu_layout:
    mov rax, [rdi + Dialog.app]
    mov rcx, [rax + App.screen]
    mov r8d, [rcx + ScreenBuffer.width]
    mov r9d, [rcx + ScreenBuffer.height]
    sub r8d, [rdi + Widget.w]
    sub r9d, [rdi + Widget.h]
    cmp [rdi + Widget.x], r8d; jle .Lpml_x0
    mov [rdi + Widget.x], r8d
.Lpml_x0:
    cmp dword ptr [rdi + Widget.x], 0; jge .Lpml_y
    mov dword ptr [rdi + Widget.x], 0
.Lpml_y:
    cmp [rdi + Widget.y], r9d; jle .Lpml_y0
    mov [rdi + Widget.y], r9d
.Lpml_y0:
    cmp dword ptr [rdi + Widget.y], 0; jge .Lpml_ok
    mov dword ptr [rdi + Widget.y], 0
.Lpml_ok:
    ret

PopupMenu_render:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, 8
    mov rbx, rdi; mov r12, rsi; mov r13, rdx
    mov rdi, r12; mov esi, [r13 + Theme.text]; mov edx, [r13 + Theme.dialog_bg]; xor ecx, ecx
    call ScreenBuffer_set_pen
    mov rdi, r12; mov esi, [rbx + Widget.x]; mov edx, [rbx + Widget.y]
    mov ecx, [rbx + Widget.w]; mov r8d, [rbx + Widget.h]; mov r9d, ' '
    call ScreenBuffer_fill_rect
    mov rdi, r12; mov esi, [r13 + Theme.dialog_border]; mov edx, [r13 + Theme.dialog_bg]; xor ecx, ecx
    call ScreenBuffer_set_pen
    mov rdi, r12; mov esi, [rbx + Widget.x]; mov edx, [rbx + Widget.y]
    mov ecx, [rbx + Widget.w]; mov r8d, [rbx + Widget.h]; mov r9d, 1
    call ScreenBuffer_draw_box

    xor r14d, r14d
.Lpmr_loop:
    call pkg_popup_count; add eax, 5
    cmp r14d, eax; jge .Lpmr_done
    mov eax, [rbx + Widget.y]; lea r15d, [rax + r14 + 1]
    mov esi, [r13 + Theme.text]; mov edx, [r13 + Theme.dialog_bg]
    cmp r14d, [rbx + PopupMenuDialog.cursor]; jne .Lpmr_pen
    mov esi, [r13 + Theme.accent_fg]; mov edx, [r13 + Theme.cursor_active_bg]
.Lpmr_pen:
    mov rdi, r12; xor ecx, ecx
    call ScreenBuffer_set_pen
    mov rdi, r12; mov esi, [rbx + Widget.x]; inc esi; mov edx, r15d
    mov ecx, [rbx + Widget.w]; sub ecx, 2; mov r8d, 1; mov r9d, ' '
    call ScreenBuffer_fill_rect

    cmp r14d, 5; jge .Lpmr_pkg_lbl
    call i18n_get
    lea rcx, [rip + popup_item_offs]
    mov edx, [rcx + r14 * 4]
    mov rcx, [rax + rdx]; jmp .Lpmr_txt
.Lpmr_pkg_lbl:
    lea edi, [r14d - 5]; call pkg_popup_label; mov rcx, rax
.Lpmr_txt:
    mov rdi, r12; mov esi, [rbx + Widget.x]; add esi, 2; mov edx, r15d
    mov r8d, [rbx + Widget.w]; sub r8d, 4
    call ScreenBuffer_draw_text
    inc r14d; jmp .Lpmr_loop
.Lpmr_done:
    add rsp, 8; pop r15; pop r14; pop r13; pop r12; pop rbx; ret

popup_copy_cur_path:
    push rbx; push r12; push r13
    sub rsp, 4112
    mov rbx, rdi              # app
    mov r12, [rbx + App.active_pane]
    mov r13, [r12 + FilePane.model]
    mov ecx, [r12 + FilePane.cursor]
    cmp rcx, [r13 + DirModel.count]; jae .Lpcp_done
    mov rax, [r13 + DirModel.order]
    mov eax, [rax + rcx * 4]
    imul rax, FileEntry._size
    add rax, [r13 + DirModel.entries]
    mov edx, [rax + FileEntry.name_off]
    add rdx, [r13 + DirModel.name_pool]
    mov rdi, rsp
    lea rsi, [r13 + DirModel.path]
    mov ecx, 4096
    call path_join
    mov rdi, rsp
    call osc52_copy_text
    call i18n_get
    mov rsi, [rax + LangStrings.msg_copied_path]
    mov rdi, rbx; mov edx, MSG_INFO
    call App_set_status
    mov dword ptr [rbx + App.need_redraw], 1
.Lpcp_done:
    add rsp, 4112; pop r13; pop r12; pop rbx; ret

popup_exec_item:
    push rbx; push r12
    mov rbx, [rdi + Dialog.app]
    mov r12d, [rdi + PopupMenuDialog.cursor]
    mov rdi, rbx; mov esi, DLG_CANCEL
    call App_close_dialog
    mov rdi, rbx
    cmp r12d, 0; je .Lpei_view
    cmp r12d, 1; je .Lpei_copy
    cmp r12d, 2; je .Lpei_move
    cmp r12d, 3; je .Lpei_cpath
    cmp r12d, 4; je .Lpei_del
    cmp r12d, 5; jl .Lpei_done
    lea edi, [r12d - 5]; call pkg_popup_get
    test rax, rax; jz .Lpei_done
    mov rdi, rbx; mov rsi, rax; call App_run_pkg_action
    jmp .Lpei_done
.Lpei_view:  call App_cmd_view; jmp .Lpei_done
.Lpei_copy:  call App_cmd_copy; jmp .Lpei_done
.Lpei_move:  call App_cmd_move; jmp .Lpei_done
.Lpei_cpath: call popup_copy_cur_path; jmp .Lpei_done
.Lpei_del:   call App_cmd_delete
.Lpei_done:
    pop r12; pop rbx; ret

PopupMenu_on_key:
    push rbx; mov rbx, rdi
    mov eax, [rsi + Event.key]
    cmp eax, KEY_ESC; je .Lpmk_esc
    cmp eax, KEY_UP; je .Lpmk_up
    cmp eax, KEY_DOWN; je .Lpmk_dn
    cmp eax, KEY_ENTER; je .Lpmk_ent
    xor eax, eax; pop rbx; ret
.Lpmk_up:
    call pkg_popup_count; lea ecx, [eax + 5]; lea r8d, [ecx - 1]
    mov eax, [rbx + PopupMenuDialog.cursor]; add eax, r8d; xor edx, edx; div ecx
    mov [rbx + PopupMenuDialog.cursor], edx
    mov rax, [rbx + Dialog.app]; mov dword ptr [rax + App.need_redraw], 1
    mov eax, 1; pop rbx; ret
.Lpmk_dn:
    call pkg_popup_count; lea ecx, [eax + 5]
    mov eax, [rbx + PopupMenuDialog.cursor]; inc eax; xor edx, edx; div ecx
    mov [rbx + PopupMenuDialog.cursor], edx
    mov rax, [rbx + Dialog.app]; mov dword ptr [rax + App.need_redraw], 1
    mov eax, 1; pop rbx; ret
.Lpmk_ent:
    mov rdi, rbx; call popup_exec_item
    mov eax, 1; pop rbx; ret
.Lpmk_esc:
    mov rdi, [rbx + Dialog.app]; mov esi, DLG_CANCEL; call App_close_dialog
    mov eax, 1; pop rbx; ret

PopupMenu_on_mouse:
    push rbx; mov rbx, rdi
    cmp dword ptr [rsi + Event.mouse_kind], MACT_PRESS; jne .Lpmm_ret
    cmp dword ptr [rsi + Event.mouse_btn], MOUSE_LEFT; jne .Lpmm_ret
    mov r8d, [rsi + Event.mouse_x]; mov r9d, [rsi + Event.mouse_y]
    mov eax, [rbx + Widget.x]; cmp r8d, eax; jl .Lpmm_out
    add eax, [rbx + Widget.w]; cmp r8d, eax; jge .Lpmm_out
    mov eax, [rbx + Widget.y]; inc eax; cmp r9d, eax; jl .Lpmm_out
    push r9; push rax; call pkg_popup_count; mov ecx, eax; pop rax; pop r9
    lea eax, [eax + ecx + 5]; cmp r9d, eax; jge .Lpmm_out
    sub r9d, [rbx + Widget.y]; dec r9d
    mov [rbx + PopupMenuDialog.cursor], r9d
    mov rdi, rbx; call popup_exec_item
    mov eax, 1; pop rbx; ret
.Lpmm_out:
    mov rdi, [rbx + Dialog.app]; mov esi, DLG_CANCEL; call App_close_dialog
.Lpmm_ret:
    mov eax, 1; pop rbx; ret

# Helper: FilePane *pane_at_xy(App *app, int x, int y)
pane_at_xy:
    mov rax, [rdi + App.left_pane]
    cmp esi, [rax + Widget.x]; jl .Lpax_r
    mov ecx, [rax + Widget.x]; add ecx, [rax + Widget.w]; dec ecx
    cmp esi, ecx; jge .Lpax_r
    mov ecx, [rax + Widget.y]; add ecx, 3
    cmp edx, ecx; jl .Lpax_r
    mov ecx, [rax + Widget.y]; add ecx, [rax + Widget.h]; sub ecx, 2
    cmp edx, ecx; jge .Lpax_r
    ret
.Lpax_r:
    cmp dword ptr [rdi + App.right_mode], RIGHT_MODE_PREVIEW; je .Lpax_none
    mov rax, [rdi + App.right_pane]
    cmp esi, [rax + Widget.x]; jl .Lpax_none
    mov ecx, [rax + Widget.x]; add ecx, [rax + Widget.w]; dec ecx
    cmp esi, ecx; jge .Lpax_none
    mov ecx, [rax + Widget.y]; add ecx, 3
    cmp edx, ecx; jl .Lpax_none
    mov ecx, [rax + Widget.y]; add ecx, [rax + Widget.h]; sub ecx, 2
    cmp edx, ecx; jge .Lpax_none
    ret
.Lpax_none:
    xor eax, eax; ret

# int pane_mouse_ext(App *app, Event *evt) -> 1 if handled, 0 else
pane_mouse_ext:
    push rbx; push r12; push r13
    mov rbx, rdi; mov r12, rsi
    mov esi, [r12 + Event.mouse_x]; mov edx, [r12 + Event.mouse_y]
    call pane_at_xy
    mov r13, rax

    cmp dword ptr [r12 + Event.mouse_kind], MACT_PRESS
    jne .Lpme_check_rel
    cmp dword ptr [r12 + Event.mouse_btn], MOUSE_RIGHT
    je .Lpme_right
    cmp dword ptr [r12 + Event.mouse_btn], MOUSE_LEFT
    jne .Lpme_zero
    test r13, r13; jz .Lpme_zero
    mov [rip + g_dnd_src_pane], r13
    mov dword ptr [rip + g_dnd_active], 1
    jmp .Lpme_zero

.Lpme_right:
    test r13, r13; jz .Lpme_zero
    mov rdi, [rbx + App.left_pane]
    xor esi, esi; cmp rdi, r13; sete sil
    VCALL WidgetVtbl.on_focus
    mov rdi, [rbx + App.right_pane]
    xor esi, esi; cmp rdi, r13; sete sil
    VCALL WidgetVtbl.on_focus
    mov [rbx + App.active_pane], r13
    mov eax, [r12 + Event.mouse_y]
    sub eax, [r13 + Widget.y]; sub eax, 3
    add eax, [r13 + FilePane.scroll]
    mov rcx, [r13 + FilePane.model]
    mov rdx, [rcx + DirModel.count]
    test rdx, rdx; jz .Lpme_open_pm
    dec rdx
    cmp rax, rdx; jbe .Lpme_setcur
    mov rax, rdx
.Lpme_setcur:
    mov [r13 + FilePane.cursor], eax
.Lpme_open_pm:
    mov rdi, rbx; mov esi, [r12 + Event.mouse_x]; mov edx, [r12 + Event.mouse_y]
    call PopupMenu_new
    mov eax, 1; pop r13; pop r12; pop rbx; ret

.Lpme_check_rel:
    cmp dword ptr [r12 + Event.mouse_kind], MACT_RELEASE
    jne .Lpme_zero
    cmp dword ptr [rip + g_dnd_active], 0
    je .Lpme_zero
    mov dword ptr [rip + g_dnd_active], 0
    test r13, r13; jz .Lpme_zero
    mov rax, [rip + g_dnd_src_pane]
    cmp r13, rax; je .Lpme_zero
    mov rdi, [rbx + App.left_pane]
    xor esi, esi; cmp rdi, rax; sete sil
    push rax; VCALL WidgetVtbl.on_focus; pop rax
    mov rdi, [rbx + App.right_pane]
    xor esi, esi; cmp rdi, rax; sete sil
    push rax; VCALL WidgetVtbl.on_focus; pop rax
    mov [rbx + App.active_pane], rax
    mov rdi, rbx; call App_cmd_copy
    mov eax, 1; pop r13; pop r12; pop rbx; ret

.Lpme_zero:
    xor eax, eax; pop r13; pop r12; pop rbx; ret
