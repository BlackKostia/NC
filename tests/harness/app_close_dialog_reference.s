# Frozen reference oracle: original src/app/app_close_dialog.s before migration to src/app/app_close_dialog.c.
# App Controller Class (Inherits from Object) — app close dialog (split from app.s)

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .text
.global App_close_dialog
.global App_cmd_help
.global App_cmd_mkdir

# void App_close_dialog(App *this, int result)
App_close_dialog:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, PATH_MAX * 2 + 16
    mov rbx, rdi              # app
    mov r12d, esi             # result
    mov r13, [rbx + App.active_dialog]
    test r13, r13
    jz .Lacd_done

    mov qword ptr [rbx + App.active_dialog], 0
    mov dword ptr [rbx + App.need_redraw], 1

    cmp r12d, DLG_OK
    jne .Lacd_free

    mov eax, [r13 + Dialog.op_tag]
    mov r14, [rbx + App.active_pane]
    mov r8, [r14 + FilePane.model]

    cmp eax, OP_MKDIR
    je .Lacd_mkdir
    cmp eax, OP_NEWFILE
    je .Lacd_newfile
    cmp eax, OP_RENAME
    je .Lacd_rename
    cmp eax, OP_COPY
    je .Lacd_copy
    cmp eax, OP_MOVE
    je .Lacd_move
    cmp eax, OP_DELETE
    je .Lacd_delete
    cmp eax, OP_FILTER
    je .Lacd_filter
    cmp eax, OP_GOTO
    je .Lacd_goto
    cmp eax, OP_QUIT; je .Lacd_quit; cmp eax, 25; je .Lacd_pkg_inst
    call App_close_dialog__close_dialog_ext
    js .Lacd_fs_err
    jmp .Lacd_free

.Lacd_pkg_inst: mov rdi, rbx; mov rsi, r13; call App_pkg_install_confirm; jmp .Lacd_free
.Lacd_mkdir:
    cmp byte ptr [r13 + InputDialog.buf], 0
    je .Lacd_free
    call App_close_dialog__path_join
    js .Lacd_fs_err
    call App_close_dialog__reload_both_panes
    jmp .Lacd_free

.Lacd_newfile:
    cmp byte ptr [r13 + InputDialog.buf], 0
    je .Lacd_free
    call App_close_dialog__path_join_2
    js .Lacd_fs_err
    call App_close_dialog__reload_both_panes_2
    jmp .Lacd_free

.Lacd_rename:
    cmp byte ptr [r13 + InputDialog.buf], 0
    je .Lacd_free
    mov rdi, r14
    call FilePane_get_selected_entry
    test rax, rax
    jz .Lacd_free
    call App_close_dialog__path_join_3
    js .Lacd_fs_err
    call App_close_dialog__undo_rename
    jmp .Lacd_free

.Lacd_copy:
    mov esi, TASK_OP_COPY
    jmp .Lacd_task
.Lacd_move:
    mov esi, TASK_OP_MOVE
.Lacd_task:
    # Copy / Move / Delete run in a background worker (non-blocking UI, see app_task.s)
    mov rdi, rbx
    lea rdx, [r13 + InputDialog.buf]
    call App_task_start
    jmp .Lacd_free

.Lacd_delete:
    mov rdi, rbx
    mov esi, TASK_OP_DELETE
    xor edx, edx
    call App_task_start
    jmp .Lacd_free

.Lacd_quit:
    mov dword ptr [rbx + App.running], 0
    jmp .Lacd_free

.Lacd_filter:
    call App_close_dialog__apply_filter
    jmp .Lacd_free

.Lacd_goto:
    cmp byte ptr [r13 + InputDialog.buf], 0
    je .Lacd_free
    call App_close_dialog__chdir
    js .Lacd_fs_err
    call App_close_dialog__ensure_visible
    jmp .Lacd_free

# .Lacd_bm_fre..search moved to App_close_dialog_ext in app_ext.s

.Lacd_fs_err:
    call App_close_dialog__reload_both_panes_3
.Lacd_free:
    DELETE_OBJ r13
.Lacd_done:
    add rsp, PATH_MAX * 2 + 16
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# App_close_dialog step: close_dialog_ext (runs on the caller's frame)
App_close_dialog__close_dialog_ext:
    lea rsp, [rsp - 8]
    mov rdi, rbx
    mov rsi, r13
    mov rdx, r14
    mov rcx, r8
    mov r8d, r12d
    call App_close_dialog_ext
    test rax, rax
.LApp_close_dialog__close_dialog_ext_ret:
    lea rsp, [rsp + 8]
    ret

# App_close_dialog step: path_join (runs on the caller's frame)
App_close_dialog__path_join:
    lea rsp, [rsp - 8]
    lea rdi, [rsp + 16]
    lea rsi, [r8 + DirModel.path]
    lea rdx, [r13 + InputDialog.buf]
    mov ecx, PATH_MAX
    call path_join            # path-checked
    test rax, rax
    js .LApp_close_dialog__path_join_ret
    lea rdi, [rsp + 16]
    call fs_mkdir
    test rax, rax
.LApp_close_dialog__path_join_ret:
    lea rsp, [rsp + 8]
    ret

# App_close_dialog step: reload_both_panes (runs on the caller's frame)
App_close_dialog__reload_both_panes:
    lea rsp, [rsp - 8]
    mov rdi, rbx
    lea rsi, [r13 + InputDialog.buf]
    call reload_both_panes
    call i18n_get
    mov rsi, [rax + LangStrings.app_ok_mkdir]
    mov rdi, rbx
    mov edx, MSG_OK
    call App_set_status
.LApp_close_dialog__reload_both_panes_ret:
    lea rsp, [rsp + 8]
    ret

# App_close_dialog step: path_join (runs on the caller's frame)
App_close_dialog__path_join_2:
    lea rsp, [rsp - 8]
    lea rdi, [rsp + 16]
    lea rsi, [r8 + DirModel.path]
    lea rdx, [r13 + InputDialog.buf]
    mov ecx, PATH_MAX
    call path_join            # path-checked
    test rax, rax
    js .LApp_close_dialog__path_join_2_ret
    lea rdi, [rsp + 16]
    call fs_touch
    test rax, rax
.LApp_close_dialog__path_join_2_ret:
    lea rsp, [rsp + 8]
    ret

# App_close_dialog step: reload_both_panes (runs on the caller's frame)
App_close_dialog__reload_both_panes_2:
    lea rsp, [rsp - 8]
    mov rdi, rbx
    lea rsi, [r13 + InputDialog.buf]
    call reload_both_panes
    call i18n_get
    mov rsi, [rax + LangStrings.app_ok_newfile]
    mov rdi, rbx
    mov edx, MSG_OK
    call App_set_status
.LApp_close_dialog__reload_both_panes_2_ret:
    lea rsp, [rsp + 8]
    ret

# App_close_dialog step: path_join (runs on the caller's frame)
App_close_dialog__path_join_3:
    lea rsp, [rsp - 8]
    mov r8, [r14 + FilePane.model]
    mov rdi, r8
    mov rsi, rax
    call DirModel_entry_name
    mov rdx, rax
    lea rdi, [rsp + 16]
    mov r8, [r14 + FilePane.model]
    lea rsi, [r8 + DirModel.path]
    mov ecx, PATH_MAX
    call path_join
    test rax, rax
    js .LApp_close_dialog__path_join_3_ret

    cmp byte ptr [r13 + InputDialog.buf], '/'
    je .Lacd_ren_abs
    lea rdi, [rsp + PATH_MAX + 16]
    mov r8, [r14 + FilePane.model]
    lea rsi, [r8 + DirModel.path]
    lea rdx, [r13 + InputDialog.buf]
    mov ecx, PATH_MAX
    call path_join
    test rax, rax
    js .LApp_close_dialog__path_join_3_ret
    jmp .Lacd_ren_go
.Lacd_ren_abs:
    lea rdi, [rsp + PATH_MAX + 16]
    lea rsi, [r13 + InputDialog.buf]
    mov edx, PATH_MAX
    call str_copy
.Lacd_ren_go:
    lea rdi, [rsp + 16]
    lea rsi, [rsp + PATH_MAX + 16]
    call fs_rename_noreplace
    test rax, rax
.LApp_close_dialog__path_join_3_ret:
    lea rsp, [rsp + 8]
    ret

# App_close_dialog step: UNDO_RENAME (runs on the caller's frame)
App_close_dialog__undo_rename:
    lea rsp, [rsp - 8]
    mov edi, 1                # UNDO_RENAME
    lea rsi, [rsp + 16]
    lea rdx, [rsp + PATH_MAX + 16]
    xor ecx, ecx
    call undo_push
    lea rdi, [r13 + InputDialog.buf]
    call path_basename
    mov rdi, rbx
    mov rsi, rax
    call reload_both_panes
    call i18n_get
    mov rsi, [rax + LangStrings.app_ok_rename]
    mov rdi, rbx
    mov edx, MSG_OK
    call App_set_status
.LApp_close_dialog__undo_rename_ret:
    lea rsp, [rsp + 8]
    ret

# App_close_dialog step: apply_filter (runs on the caller's frame)
App_close_dialog__apply_filter:
    lea rsp, [rsp - 8]
    mov rax, [rbx + App.status_bar]
    mov qword ptr [rax + StatusBar.msg_expire_ms], 0
    lea rdi, [r8 + DirModel.filter]
    lea rsi, [r13 + InputDialog.buf]
    mov edx, FILTER_MAX
    call str_copy
    mov rdi, r8
    call DirModel_apply_filter
    mov dword ptr [r14 + FilePane.cursor], 0
    mov dword ptr [r14 + FilePane.scroll], 0
    mov rdi, r14
    call FilePane_ensure_visible
    mov rdi, rbx
    call App_sync_preview
.LApp_close_dialog__apply_filter_ret:
    lea rsp, [rsp + 8]
    ret

# App_close_dialog step: chdir (runs on the caller's frame)
App_close_dialog__chdir:
    lea rsp, [rsp - 8]
    mov rax, [rbx + App.status_bar]
    mov qword ptr [rax + StatusBar.msg_expire_ms], 0
    mov rdi, [rbx + App.envp]
    mov rsi, r8
    lea rdx, [r13 + InputDialog.buf]
    call pkg_vfs_load_dir
    test eax, eax
    jz .LApp_close_dialog__chdir_ret
    mov rdi, [r14 + FilePane.model]
    lea rsi, [r13 + InputDialog.buf]
    call DirModel_chdir
    test rax, rax
.LApp_close_dialog__chdir_ret:
    lea rsp, [rsp + 8]
    ret

# App_close_dialog step: ensure_visible (runs on the caller's frame)
App_close_dialog__ensure_visible:
    lea rsp, [rsp - 8]
    mov dword ptr [r14 + FilePane.cursor], 0
    mov dword ptr [r14 + FilePane.scroll], 0
    mov rdi, r14
    call FilePane_ensure_visible
    mov rdi, rbx
    call App_sync_preview
.LApp_close_dialog__ensure_visible_ret:
    lea rsp, [rsp + 8]
    ret

# App_close_dialog step: reload_both_panes (runs on the caller's frame)
App_close_dialog__reload_both_panes_3:
    lea rsp, [rsp - 8]
    mov r14d, eax
    mov rdi, rbx
    xor esi, esi
    call reload_both_panes
    mov edi, r14d
    call fs_errno_message
    mov rdi, rbx
    mov rsi, rax
    mov edx, MSG_ERR
    call App_set_status

.LApp_close_dialog__reload_both_panes_3_ret:
    lea rsp, [rsp + 8]
    ret

# ==============================================================================
# App Commands (Invoked by Keys, HeaderBar, FunctionBar)
# ==============================================================================
App_cmd_help:
    push rbx
    mov rbx, rdi
    call HelpDialog_new
    mov [rbx + App.active_dialog], rax
    mov dword ptr [rbx + App.need_redraw], 1
    pop rbx
    ret

App_cmd_mkdir:
    push rbx
    mov rbx, rdi
    call i18n_get
    mov rsi, [rax + LangStrings.app_title_mkdir]
    mov rdx, [rax + LangStrings.app_prm_mkdir]
    mov rdi, rbx
    xor ecx, ecx
    mov r8d, OP_MKDIR
    call InputDialog_new
    mov [rbx + App.active_dialog], rax
    mov dword ptr [rbx + App.need_redraw], 1
    pop rbx
    ret
