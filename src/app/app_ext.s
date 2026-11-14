# src/app/app_ext.s - Extended App dialog close & keybind routing

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"
.extern FilePane_nav_to
.extern FilePane_ensure_visible
.extern FilePane_hist_back
.extern FilePane_hist_fwd
.extern DirModel_find_by_name
.extern DirModel_sort
.extern dir_search_run
.extern SearchDialog_new
.extern BookmarkDialog_get_selected
.extern App_task_conflict_done
.extern App_exec_menu_tmpl
.extern App_sync_preview
.extern App_set_status
.extern App_apply_chmod
.extern App_apply_link
.extern App_cmd_undo
.extern App_cmd_chmod
.extern App_cmd_info
.extern App_cmd_link
.extern App_dispatch_action
.extern FuzzyDialog_new
.extern FuzzyDialog_get_selected
.extern du_toggle
.extern arc_handle_enter
.extern BulkRenameDialog_new
.extern path_join
.extern config_menu_item
.extern i18n_get
.extern path_basename
.extern str_copy

.section .text
.global app_jump_virtual_entry
.global App_close_dialog_ext

# void app_jump_virtual_entry(App *app, FilePane *pane, char *full_path)
app_jump_virtual_entry:
    push rbx
    push r12
    push r13
    sub rsp, NAME_MAX + 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx

    mov rdi, r13
    call path_basename
    mov rdi, rsp
    mov rsi, rax
    mov edx, NAME_MAX
    call str_copy
    mov rdi, r13
    call path_basename
    cmp rax, r13
    jbe .Lajve_root
    dec rax
    cmp rax, r13
    jne .Lajve_trunc
    mov byte ptr [rax + 1], 0
    jmp .Lajve_nav
.Lajve_trunc:
    mov byte ptr [rax], 0
    jmp .Lajve_nav
.Lajve_root:
    mov byte ptr [r13], '/'
    mov byte ptr [r13 + 1], 0
.Lajve_nav:
    mov rax, [r12 + FilePane.model]
    mov dword ptr [rax + DirModel.virtual_mode], 0
    mov rdi, r12
    mov rsi, r13
    call FilePane_nav_to
    test rax, rax
    js .Lajve_done
    mov rdi, [r12 + FilePane.model]
    mov rsi, rsp
    call DirModel_find_by_name
    cmp rax, 0
    jl .Lajve_sync
    mov [r12 + FilePane.cursor], eax
    mov rdi, r12
    call FilePane_ensure_visible
.Lajve_sync:
    mov rdi, rbx
    call App_sync_preview
    mov dword ptr [rbx + App.need_redraw], 1
.Lajve_done:
    add rsp, NAME_MAX + 16
    pop r13
    pop r12
    pop rbx
    ret

# Helper: void app_close_fuzzy_dlg(App *app, FuzzyDialog *dlg, FilePane *pane)
app_close_fuzzy_dlg:
    push rbx; push r12; push r13
    mov rbx, rdi; mov r12, rsi; mov r13, rdx
    mov rdi, r12; call FuzzyDialog_get_selected
    test rax, rax; jz .Lacfd_done
    cmp dword ptr [r12 + Dialog.op_tag], OP_PALETTE
    jne .Lacfd_fuz
    mov rdi, rbx; mov esi, eax; call App_dispatch_action
    jmp .Lacfd_done
.Lacfd_fuz:
    sub rsp, PATH_MAX
    mov rdi, rsp; lea rsi, [r12 + FuzzyDialog.base_path]; mov rdx, rax
    call path_join
    mov rdi, rbx; mov rsi, r13; mov rdx, rsp
    call app_jump_virtual_entry
    add rsp, PATH_MAX
.Lacfd_done:
    pop r13; pop r12; pop rbx; ret

# int App_close_dialog_ext(App *app, Dialog *dlg, FilePane *pane, DirModel *model, int dlg_res)
App_close_dialog_ext:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 24
    call App_close_dialog_ext__part1
    cmp eax, OP_USERMENU;  je .Lacde_um
    cmp eax, OP_BOOKMARKS; je .Lacde_bm
    cmp eax, OP_FRECENCY;  je .Lacde_bm
    cmp eax, OP_CONFLICT;  je .Lacde_cfl
    cmp eax, OP_SEARCH;    je .Lacde_srch
    cmp eax, OP_CHMOD;     je .Lacde_chm
    cmp eax, OP_SYMLINK;   je .Lacde_sym
    cmp eax, OP_HARDLINK;  je .Lacde_hrd
    cmp eax, OP_PALETTE;   je .Lacde_fuz
    cmp eax, OP_FUZZY;     je .Lacde_fuz
    cmp eax, OP_VIEWAS;    je .Lacde_vas
    jmp .Lacde_ok

.Lacde_vas:
    mov rdi, rbx; mov rsi, r13; call App_view_as_done; jmp .Lacde_ok

.Lacde_fuz:
    mov rdi, rbx; mov rsi, r13; mov rdx, r14
    call app_close_fuzzy_dlg
    jmp .Lacde_ok

.Lacde_um:
    mov edi, [r13 + UserMenuDialog.cursor]
    mov rsi, rsp
    lea rdx, [rsp + 8]
    call config_menu_item
    test eax, eax
    jz .Lacde_ok
    mov rdi, rbx
    mov rsi, [rsp + 8]
    call App_exec_menu_tmpl
    jmp .Lacde_ok
.Lacde_bm:
    mov rdi, r13
    call BookmarkDialog_get_selected
    test rax, rax
    jz .Lacde_ok
    mov rdi, r14
    mov rsi, rax
    call FilePane_nav_to
    test rax, rax
    js .Lacde_ret
    mov rdi, rbx
    call App_sync_preview
    jmp .Lacde_ok
.Lacde_cfl:
    mov rdi, rbx; mov esi, r12d; mov rdx, r13; call App_task_conflict_done; jmp .Lacde_ok
.Lacde_chm:
    mov rdi, rbx
    mov rsi, r13
    call App_apply_chmod
    jmp .Lacde_ok
.Lacde_sym:
    mov rdi, rbx
    mov rsi, r13
    xor edx, edx
    call App_apply_link
    jmp .Lacde_ok
.Lacde_hrd:
    mov rdi, rbx
    mov rsi, r13
    mov edx, 1
    call App_apply_link
    jmp .Lacde_ok
.Lacde_srch:
    call App_close_dialog_ext__dir_search_run
.Lacde_ok:
    xor eax, eax
.Lacde_ret:
    add rsp, 24
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# App_close_dialog_ext step (runs on the caller's frame)
App_close_dialog_ext__part1:
    lea rsp, [rsp - 8]
    mov rbx, rdi
    mov r13, rsi
    mov r14, rdx
    mov r12d, r8d
    mov eax, [r13 + Dialog.op_tag]

.LApp_close_dialog_ext__part1_ret:
    lea rsp, [rsp + 8]
    ret

# App_close_dialog_ext step: dir_search_run (runs on the caller's frame)
App_close_dialog_ext__dir_search_run:
    lea rsp, [rsp - 8]
    mov rdi, rcx
    lea rsi, [rcx + DirModel.path]
    lea rdx, [r13 + SearchDialog.name_buf]
    lea rcx, [r13 + SearchDialog.grep_buf]
    call dir_search_run
    push rax
    xor ecx, ecx
    test eax, eax
    jle .Lacde_scur
    mov rdi, [r14 + FilePane.model]
    call DirModel_sort
    mov r8, [r14 + FilePane.model]
    cmp dword ptr [r8 + DirModel.has_dotdot], 0
    je .Lacde_scur
    cmp qword ptr [r8 + DirModel.count], 1
    jbe .Lacde_scur
    mov ecx, 1
.Lacde_scur:
    mov [r14 + FilePane.cursor], ecx
    mov dword ptr [r14 + FilePane.scroll], 0
    mov rdi, r14
    call FilePane_ensure_visible
    mov rdi, rbx
    call App_sync_preview
    pop rax
    test eax, eax
    jnz .LApp_close_dialog_ext__dir_search_run_ret
    call i18n_get
    mov rsi, [rax + LangStrings.msg_search_none]
    mov rdi, rbx
    mov edx, MSG_INFO
    call App_set_status
.LApp_close_dialog_ext__dir_search_run_ret:
    lea rsp, [rsp + 8]
    ret
