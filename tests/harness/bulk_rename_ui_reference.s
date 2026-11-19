# Frozen reference oracle: original src/ui/bulk_rename_ui.s before C23 migration (v2.6.57).
# src/ui/bulk_rename.s - Bulk Rename Dialog (templates {n}/{name}/{ext}, find/replace, live preview) — bulk rename ui (split from bulk_rename.s)

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"
.include "dialogs_ext.inc"
.extern Dialog_vtbl
.extern Dialog_init
.extern Dialog_dtor
.extern Dialog_draw_frame
.extern Dialog_on_mouse
.extern Dialog_on_confirm
.extern Dialog_on_cancel
.extern Widget_on_focus
.extern Widget_hit_test
.extern dlg_layout_right_buttons
.extern dlg_draw_buttons
.extern DirModel_entry_name
.extern DirModel_reload
.extern FilePane_get_selected_entry
.extern ScreenBuffer_set_pen
.extern ScreenBuffer_draw_hline
.extern ScreenBuffer_draw_text
.extern ScreenBuffer_set_cell_pen
.extern i18n_get
.extern mem_alloc
.extern mem_free
.extern str_copy
.extern str_cat
.extern str_len
.extern str_cmp
.extern u64_to_dec

.section .rodata
br_arrow:       .asciz " -> "

.section .text
.global BulkRenameDialog_render
.global BulkRenameDialog_on_key

# void BulkRenameDialog_render(dlg, scr, theme)
BulkRenameDialog_render:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, 520              # [0..255]=new_name, [256..511]=line
    mov rbx, rdi; mov r12, rsi; mov r13, rdx
    call i18n_get
    mov r14, rax
    mov rdi, rbx; mov rsi, r12; mov rdx, r13
    mov rcx, [r14 + LangStrings.dlg_btn_ok]
    mov r8, [r14 + LangStrings.dlg_btn_cancel]
    call Dialog_draw_frame

    # 3 fields: Template, Find, Replace
    xor eax, eax; cmp dword ptr [rbx + BulkRenameDialog.focus], 0; sete al
    push rax
    mov rdi, r12; mov rsi, r13; mov rdx, rbx
    mov ecx, [rbx + Widget.y]; add ecx, 2
    mov r8, [r14 + LangStrings.br_tmpl]
    lea r9, [rbx + BulkRenameDialog.tmpl]
    call br_draw_field
    add rsp, 8

    xor eax, eax; cmp dword ptr [rbx + BulkRenameDialog.focus], 1; sete al
    push rax
    mov rdi, r12; mov rsi, r13; mov rdx, rbx
    mov ecx, [rbx + Widget.y]; add ecx, 3
    mov r8, [r14 + LangStrings.br_find]
    lea r9, [rbx + BulkRenameDialog.find]
    call br_draw_field
    add rsp, 8

    xor eax, eax; cmp dword ptr [rbx + BulkRenameDialog.focus], 2; sete al
    push rax
    mov rdi, r12; mov rsi, r13; mov rdx, rbx
    mov ecx, [rbx + Widget.y]; add ecx, 4
    mov r8, [r14 + LangStrings.br_repl]
    lea r9, [rbx + BulkRenameDialog.repl]
    call br_draw_field
    add rsp, 8

    # Preview rows
    mov rdi, r12; mov esi, [r13 + Theme.muted]; mov edx, [r13 + Theme.dialog_bg]
    xor ecx, ecx; call ScreenBuffer_set_pen
    xor r15d, r15d
    mov r14d, [rbx + Widget.h]; sub r14d, 9
.Lbrr_prev:
    cmp r15d, r14d; jge .Lbrr_btns
    cmp r15d, [rbx + BulkRenameDialog.count]; jge .Lbrr_btns
    imul rsi, r15, 256; add rsi, [rbx + BulkRenameDialog.names]
    push rsi
    mov rdi, rbx; mov rdx, rsi; mov esi, r15d
    lea rcx, [rsp + 8]; mov r8d, 256
    call br_compute_name
    pop rsi
    lea rdi, [rsp + 256]; mov edx, 256; call str_copy
    lea rdi, [rsp + 256]; lea rsi, [rip + br_arrow]; mov edx, 256; call str_cat
    lea rdi, [rsp + 256]; mov rsi, rsp; mov edx, 256; call str_cat
    mov rdi, r12
    mov esi, [rbx + Widget.x]; add esi, 2
    mov edx, [rbx + Widget.y]; add edx, 6; add edx, r15d
    lea rcx, [rsp + 256]
    mov r8d, [rbx + Widget.w]; sub r8d, 4
    call ScreenBuffer_draw_text
    inc r15d; jmp .Lbrr_prev

.Lbrr_btns:
    add rsp, 520
    pop r15; pop r14; pop r13; pop r12; pop rbx
    ret

# void br_apply(BulkRenameDialog *dlg)
br_apply:
    push rbx; push r12; push r13; push r14
    sub rsp, 272
    mov rbx, rdi
    mov rax, [rbx + BulkRenameDialog.pane]
    mov r12, [rax + FilePane.model]
    mov edi, AT_FDCWD
    lea rsi, [r12 + DirModel.path]
    mov edx, O_RDONLY | O_DIRECTORY | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    test rax, rax; js .Lbra_done
    mov r13d, eax             # dir_fd
    xor r14d, r14d
.Lbra_loop:
    cmp r14d, [rbx + BulkRenameDialog.count]; jge .Lbra_close
    imul rdx, r14, 256; add rdx, [rbx + BulkRenameDialog.names]
    push rdx
    mov rdi, rbx; mov esi, r14d; lea rcx, [rsp + 8]; mov r8d, 256
    call br_compute_name
    pop rsi                   # old_name
    cmp byte ptr [rsp], 0; je .Lbra_next
    mov rdi, rsp; push rsi; call str_cmp; pop rsi
    test eax, eax; jz .Lbra_next
    mov edi, r13d
    # rsi = old_name
    mov edx, r13d
    mov r10, rsp              # new_name
    mov r8d, RENAME_NOREPLACE
    OS_RENAMEAT2
    test rax, rax
    jns .Lbra_next
    # On collision or error, keep existing files intact and record error
    mov [rsp + 256], rax
.Lbra_next:
    inc r14d; jmp .Lbra_loop
.Lbra_close:
    mov edi, r13d; OS_CLOSE
    mov rdi, r12; call DirModel_reload
.Lbra_done:
    mov rdi, rbx; call Dialog_on_confirm
    add rsp, 272
    pop r14; pop r13; pop r12; pop rbx
    ret

# int BulkRenameDialog_on_key(dlg, Event *ev)
BulkRenameDialog_on_key:
    push rbx; push r12
    mov rbx, rdi; mov r12, rsi
    mov eax, [r12 + Event.key]
    cmp eax, KEY_ESC; jne .Lbrk_tab
    mov rdi, rbx; call Dialog_on_cancel
    mov eax, 1; jmp .Lbrk_ret
.Lbrk_tab:
    cmp eax, KEY_TAB; jne .Lbrk_ent
    mov ecx, [rbx + BulkRenameDialog.focus]
    inc ecx; cmp ecx, 5; jl .Lbrk_ft; xor ecx, ecx
.Lbrk_ft:
    mov [rbx + BulkRenameDialog.focus], ecx
    jmp .Lbrk_ok
.Lbrk_ent:
    cmp eax, KEY_ENTER; jne .Lbrk_bs
    cmp dword ptr [rbx + BulkRenameDialog.focus], 4
    jne .Lbrk_do_ok
    mov rdi, rbx; call Dialog_on_cancel
    mov eax, 1; jmp .Lbrk_ret
.Lbrk_do_ok:
    mov rdi, rbx; call br_apply
    mov eax, 1; jmp .Lbrk_ret
.Lbrk_bs:
    mov ecx, [rbx + BulkRenameDialog.focus]
    cmp ecx, 3; jge .Lbrk_ret0
    # Resolve active buf & len ptr
    lea r8, [rbx + BulkRenameDialog.tmpl]; lea r9, [rbx + BulkRenameDialog.tlen]
    cmp ecx, 1; jne .Lbrk_f2
    lea r8, [rbx + BulkRenameDialog.find]; lea r9, [rbx + BulkRenameDialog.flen]
    jmp .Lbrk_edit
.Lbrk_f2:
    cmp ecx, 2; jne .Lbrk_edit
    lea r8, [rbx + BulkRenameDialog.repl]; lea r9, [rbx + BulkRenameDialog.rlen]
.Lbrk_edit:
    cmp eax, KEY_BACKSPACE; jne .Lbrk_chr
    mov edx, [r9]; test edx, edx; jz .Lbrk_ok
    dec edx; mov [r9], edx; mov byte ptr [r8 + rdx], 0
    jmp .Lbrk_ok
.Lbrk_chr:
    cmp eax, 32; jl .Lbrk_ret0
    cmp eax, 126; jg .Lbrk_ret0
    mov edx, [r9]; cmp edx, 126; jge .Lbrk_ok
    mov [r8 + rdx], al; inc edx; mov [r9], edx; mov byte ptr [r8 + rdx], 0
.Lbrk_ok:
    mov rcx, [rbx + Dialog.app]
    mov dword ptr [rcx + App.need_redraw], 1
    mov eax, 1; jmp .Lbrk_ret
.Lbrk_ret0:
    xor eax, eax
.Lbrk_ret:
    pop r12; pop rbx
    ret
