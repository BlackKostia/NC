# src/ui/bulk_rename.s - Bulk Rename Dialog (templates {n}/{name}/{ext}, find/replace, live preview)

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
str_BulkRename: .asciz "BulkRenameDialog"
br_tok_n:       .asciz "{n}"
br_tok_name:    .asciz "{name}"
br_tok_ext:     .asciz "{ext}"

BulkRenameDialog_vtbl:
    DIALOG_VTBL_SLOTS str_BulkRename, Dialog_vtbl, BulkRenameDialog._size, BulkRenameDialog_dtor, BulkRenameDialog_layout, BulkRenameDialog_render, BulkRenameDialog_on_key, Dialog_on_mouse, Widget_on_focus, Widget_hit_test, Dialog_on_confirm, Dialog_on_cancel

.section .text
.global BulkRenameDialog_new
.global br_compute_name
.global br_draw_field
.global BulkRenameDialog_vtbl

# void BulkRenameDialog_dtor(BulkRenameDialog *this)
BulkRenameDialog_dtor:
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + BulkRenameDialog.names]
    test rdi, rdi
    jz .Lbrd_base
    call mem_free
.Lbrd_base:
    mov rdi, rbx
    call Dialog_dtor
    pop rbx
    ret

# int br_collect_names(BulkRenameDialog *dlg, FilePane *pane) -> count
br_collect_names:
    push rbx; push r12; push r13; push r14; push r15
    mov rbx, rdi
    mov r12, [rsi + FilePane.model]
    mov r13d, [r12 + DirModel.count]
    mov r14, [r12 + DirModel.order]
    mov r15, [r12 + DirModel.entries]
    xor ecx, ecx              # marked count
    xor edx, edx              # loop idx
.Lbcn_cnt:
    cmp edx, r13d; jge .Lbcn_chk
    mov eax, [r14 + rdx*4]
    imul rax, FileEntry._size
    mov eax, [r15 + rax + FileEntry.flags]
    test eax, FE_IS_PARENT; jnz .Lbcn_cn
    test eax, FE_SELECTED; jz .Lbcn_cn
    inc ecx
.Lbcn_cn:
    inc edx; jmp .Lbcn_cnt
.Lbcn_chk:
    test ecx, ecx
    jnz .Lbcn_alloc
    mov rdi, rsi
    push rsi
    call FilePane_get_selected_entry
    pop rsi
    test rax, rax; jz .Lbcn_zero
    test dword ptr [rax + FileEntry.flags], FE_IS_PARENT; jnz .Lbcn_zero
    push rax
    mov edi, 256; call mem_alloc
    pop rcx
    test rax, rax; jz .Lbcn_zero
    mov [rbx + BulkRenameDialog.names], rax
    mov dword ptr [rbx + BulkRenameDialog.count], 1
    push rax
    mov rdi, r12; mov rsi, rcx; call DirModel_entry_name
    pop rdi
    mov rsi, rax; mov edx, 256; call str_copy
    mov eax, 1; jmp .Lbcn_ret
.Lbcn_alloc:
    mov [rbx + BulkRenameDialog.count], ecx
    mov edi, ecx; imul rdi, 256; call mem_alloc
    test rax, rax; jz .Lbcn_zero
    mov [rbx + BulkRenameDialog.names], rax
    xor ecx, ecx              # out idx
    xor edx, edx              # scan idx
.Lbcn_fill:
    cmp edx, r13d; jge .Lbcn_ok
    mov eax, [r14 + rdx*4]
    imul rax, FileEntry._size
    add rax, r15
    mov r8d, [rax + FileEntry.flags]
    test r8d, FE_IS_PARENT; jnz .Lbcn_fn
    test r8d, FE_SELECTED; jz .Lbcn_fn
    push rcx; push rdx; push rax
    mov rdi, r12; mov rsi, rax; call DirModel_entry_name
    mov rsi, rax
    mov rcx, [rsp + 16]
    imul rdi, rcx, 256
    add rdi, [rbx + BulkRenameDialog.names]
    mov edx, 256; call str_copy
    pop rax; pop rdx; pop rcx
    inc ecx
.Lbcn_fn:
    inc edx; jmp .Lbcn_fill
.Lbcn_ok:
    mov eax, [rbx + BulkRenameDialog.count]; jmp .Lbcn_ret
.Lbcn_zero:
    xor eax, eax
.Lbcn_ret:
    pop r15; pop r14; pop r13; pop r12; pop rbx
    ret

# BulkRenameDialog *BulkRenameDialog_new(App *app, FilePane *pane)
BulkRenameDialog_new:
    push rbx; push r12; push r13
    mov r12, rdi; mov r13, rsi
    NEW_OBJ BulkRenameDialog_vtbl, BulkRenameDialog._size
    test rax, rax; jz .Lbrn_ret
    mov rbx, rax
    mov [rbx + BulkRenameDialog.pane], r13
    mov rdi, rbx; mov rsi, r13; call br_collect_names
    test eax, eax; jnz .Lbrn_init
    mov rdi, rbx; call mem_free
    xor eax, eax; jmp .Lbrn_ret
.Lbrn_init:
    call i18n_get
    mov rdx, [rax + LangStrings.br_title]
    mov rdi, rbx; mov rsi, r12; xor ecx, ecx; call Dialog_init
    mov rdi, rbx; xor esi, esi; xor edx, edx
    mov ecx, [r12 + App.term_w]; mov r8d, [r12 + App.term_h]
    call BulkRenameDialog_layout
    mov rax, rbx
.Lbrn_ret:
    pop r13; pop r12; pop rbx
    ret

# void BulkRenameDialog_layout(dlg, x, y, term_w, term_h)
BulkRenameDialog_layout:
    push rbx; push r12; push r13
    mov rbx, rdi
    mov eax, ecx; sub eax, 4; cmp eax, 68; jle .Lbrl_w
    mov eax, 68
.Lbrl_w:
    cmp eax, 36; jge .Lbrl_w2; mov eax, 36
.Lbrl_w2:
    mov r12d, eax             # w
    mov eax, r8d; sub eax, 4; cmp eax, 20; jle .Lbrl_h
    mov eax, 20
.Lbrl_h:
    cmp eax, 12; jge .Lbrl_h2; mov eax, 12
.Lbrl_h2:
    mov r13d, eax             # h
    sub ecx, r12d; sar ecx, 1; mov esi, ecx
    sub r8d, r13d; sar r8d, 1; mov edx, r8d
    mov rdi, rbx; mov ecx, r12d; mov r8d, r13d
    call Widget_layout
    call i18n_get
    mov rdi, rbx
    mov rsi, [rax + LangStrings.dlg_btn_ok]
    mov rdx, [rax + LangStrings.dlg_btn_cancel]
    xor ecx, ecx; call dlg_layout_right_buttons
    pop r13; pop r12; pop rbx
    ret

# Helper: int match_prefix(const char *s, const char *tok) -> len if match, 0 else
br_match_tok:
    xor eax, eax
.Lbmt_l:
    mov cl, [rsi + rax]
    test cl, cl; jz .Lbmt_ok
    cmp [rdi + rax], cl; jne .Lbmt_no
    inc eax; jmp .Lbmt_l
.Lbmt_ok:
    ret
.Lbmt_no:
    xor eax, eax; ret

# void br_expand_tmpl(BulkRenameDialog *dlg, int idx, const char *old, char *out, int cap)
br_expand_tmpl:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, 32
    mov rbx, rdi; mov r12d, esi; mov r13, rdx; mov r14, rcx; mov r15d, r8d
    lea r8, [rbx + BulkRenameDialog.tmpl]
    xor r9d, r9d              # out pos
    dec r15d                  # max out len
    # Find last '.' in old -> store dot offset or -1 at [rsp+24]
    mov rdi, r13; call str_len
    mov ecx, eax; dec ecx
.Lbet_dot:
    test ecx, ecx; js .Lbet_nodot
    cmp byte ptr [r13 + rcx], '.'; je .Lbet_gotdot
    dec ecx; jmp .Lbet_dot
.Lbet_nodot:
    mov ecx, -1
.Lbet_gotdot:
    mov [rsp + 24], ecx
.Lbet_loop:
    mov al, [r8]; test al, al; jz .Lbet_done
    cmp al, '{'; jne .Lbet_lit
    # Check {n}
    mov rdi, r8; lea rsi, [rip + br_tok_n]
    push r8; push r9; call br_match_tok; pop r9; pop r8
    test eax, eax; jz .Lbet_chk_name
    add r8, rax
    lea edi, [r12d + 1]; mov rsi, rsp
    push r8; push r9; call u64_to_dec; pop r9; pop r8
    mov rsi, rsp; jmp .Lbet_ins
.Lbet_chk_name:
    mov rdi, r8; lea rsi, [rip + br_tok_name]
    push r8; push r9; call br_match_tok; pop r9; pop r8
    test eax, eax; jz .Lbet_chk_ext
    add r8, rax
    mov ecx, [rsp + 24]; xor edx, edx
.Lbet_nm:
    cmp ecx, 0; jl .Lbet_nm_all
    cmp edx, ecx; jge .Lbet_loop
.Lbet_nm_all:
    mov al, [r13 + rdx]; test al, al; jz .Lbet_loop
    cmp r9d, r15d; jge .Lbet_loop
    mov [r14 + r9], al; inc r9d; inc edx; jmp .Lbet_nm
.Lbet_chk_ext:
    mov rdi, r8; lea rsi, [rip + br_tok_ext]
    push r8; push r9; call br_match_tok; pop r9; pop r8
    test eax, eax; jz .Lbet_lit
    add r8, rax
    mov ecx, [rsp + 24]; cmp ecx, 0; jl .Lbet_loop
    lea rsi, [r13 + rcx + 1]
.Lbet_ins:
    mov al, [rsi]; test al, al; jz .Lbet_loop
    cmp r9d, r15d; jge .Lbet_loop
    mov [r14 + r9], al; inc r9d; inc rsi; jmp .Lbet_ins
.Lbet_lit:
    cmp r9d, r15d; jge .Lbet_next
    mov [r14 + r9], al; inc r9d
.Lbet_next:
    inc r8; jmp .Lbet_loop
.Lbet_done:
    mov byte ptr [r14 + r9], 0
    add rsp, 32
    pop r15; pop r14; pop r13; pop r12; pop rbx
    ret

# void br_compute_name(BulkRenameDialog *dlg, int idx, const char *old, char *out, int cap)
br_compute_name:
    push rbx; push r12; push r13
    sub rsp, 256
    mov rbx, rdi; mov r12, rcx; mov r13d, r8d
    cmp dword ptr [rbx + BulkRenameDialog.tlen], 0
    jle .Lbcn_orig
    call br_expand_tmpl
    jmp .Lbcn_repl
.Lbcn_orig:
    mov rdi, r12; mov rsi, rdx; mov edx, r13d; call str_copy
.Lbcn_repl:
    cmp dword ptr [rbx + BulkRenameDialog.flen], 0
    jle .Lbcn_end
    mov r8, r12               # src
    mov r9, rsp               # tmp dst
    xor r10d, r10d            # dst len
.Lbcn_rl:
    mov al, [r8]; test al, al; jz .Lbcn_rdone
    mov rdi, r8; lea rsi, [rbx + BulkRenameDialog.find]
    push r8; push r9; push r10; call br_match_tok; pop r10; pop r9; pop r8
    test eax, eax; jz .Lbcn_rlit
    add r8, rax
    lea rsi, [rbx + BulkRenameDialog.repl]
.Lbcn_rcp:
    mov cl, [rsi]; test cl, cl; jz .Lbcn_rl
    cmp r10d, 255; jge .Lbcn_rl
    mov [r9 + r10], cl; inc r10d; inc rsi; jmp .Lbcn_rcp
.Lbcn_rlit:
    mov al, [r8]
    cmp r10d, 255; jge .Lbcn_rdone
    mov [r9 + r10], al; inc r10d; inc r8; jmp .Lbcn_rl
.Lbcn_rdone:
    mov byte ptr [r9 + r10], 0
    mov rdi, r12; mov rsi, rsp; mov edx, r13d; call str_copy
.Lbcn_end:
    add rsp, 256
    pop r13; pop r12; pop rbx
    ret

# void br_draw_field(scr, theme, dlg, int row_y, const char *lbl, const char *val, int focused)
br_draw_field:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, 8
    mov rbx, rdi; mov r12, rsi; mov r13, rdx; mov r14d, ecx; mov r15, r8
    mov [rsp], r9             # save val
    mov rdi, rbx; mov esi, [r12 + Theme.text]; mov edx, [r12 + Theme.dialog_bg]
    xor ecx, ecx; call ScreenBuffer_set_pen
    mov rdi, rbx
    mov esi, [r13 + Widget.x]; add esi, 2
    mov edx, r14d; mov rcx, r15; mov r8d, 11
    call ScreenBuffer_draw_text

    mov esi, [r12 + Theme.text]
    mov edx, [r12 + Theme.surface]
    xor ecx, ecx
    cmp dword ptr [rsp + 56], 0   # focused (7th arg: 8 + 5*8 + 8 = 56)
    je .Lbdf_pen
    mov edx, [r12 + Theme.surface_alt]
    mov ecx, ATTR_BOLD
.Lbdf_pen:
    mov rdi, rbx; call ScreenBuffer_set_pen
    mov rdi, rbx
    mov esi, [r13 + Widget.x]; add esi, 14
    mov edx, r14d
    mov ecx, [r13 + Widget.w]; sub ecx, 16
    mov r8d, ' '; call ScreenBuffer_draw_hline
    mov rdi, rbx
    mov esi, [r13 + Widget.x]; add esi, 14
    mov edx, r14d
    mov rcx, [rsp]            # val
    mov r8d, [r13 + Widget.w]; sub r8d, 16
    call ScreenBuffer_draw_text
    add rsp, 8
    pop r15; pop r14; pop r13; pop r12; pop rbx
    ret
