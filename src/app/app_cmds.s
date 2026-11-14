# App Controller Class (Inherits from Object) — app cmds (split from app.s)

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .rodata

str_sh_edit:        .asciz "exec \"${EDITOR:-vi}\" \"$1\""
str_sh_shell:       .asciz "exec \"${SHELL:-/bin/sh}\""

.section .text
.global App_cmd_newfile
.global App_cmd_start_filter
.global App_cmd_goto
.global App_cmd_rename
.global App_cmd_view
.global App_cmd_edit
.global App_cmd_shell
.global App_cmd_copy
.global App_cmd_move
.global App_cmd_delete

App_cmd_newfile:
    push rbx
    mov rbx, rdi
    call i18n_get
    mov rsi, [rax + LangStrings.app_title_newfile]
    mov rdx, [rax + LangStrings.app_prm_newfile]
    mov rdi, rbx
    xor ecx, ecx
    mov r8d, OP_NEWFILE
    call InputDialog_new
    mov [rbx + App.active_dialog], rax
    mov dword ptr [rbx + App.need_redraw], 1
    pop rbx
    ret

App_cmd_start_filter:
    push rbx
    mov rbx, rdi
    mov rax, [rbx + App.active_pane]
    mov rax, [rax + FilePane.model]
    lea rcx, [rax + DirModel.filter]
    call i18n_get
    mov rsi, [rax + LangStrings.app_title_filter]
    mov rdx, [rax + LangStrings.app_prm_filter]
    mov rdi, rbx
    mov r8d, OP_FILTER
    call InputDialog_new
    mov [rbx + App.active_dialog], rax
    mov dword ptr [rbx + App.need_redraw], 1
    pop rbx
    ret

App_cmd_goto:
    push rbx
    mov rbx, rdi
    mov rax, [rbx + App.active_pane]
    mov rax, [rax + FilePane.model]
    lea rcx, [rax + DirModel.path]
    call i18n_get
    mov rsi, [rax + LangStrings.app_title_goto]
    mov rdx, [rax + LangStrings.app_prm_goto]
    mov rdi, rbx
    mov r8d, OP_GOTO
    call InputDialog_new
    mov [rbx + App.active_dialog], rax
    mov dword ptr [rbx + App.need_redraw], 1
    pop rbx
    ret

App_cmd_rename:
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + App.active_pane]
    call FilePane_get_selected_entry
    test rax, rax
    jz .Lacr_done
    test dword ptr [rax + FileEntry.flags], FE_IS_PARENT
    jnz .Lacr_parent
    mov rcx, [rbx + App.active_pane]
    mov rdi, [rcx + FilePane.model]
    mov rsi, rax
    call DirModel_entry_name
    push rax
    sub rsp, 8
    call i18n_get
    mov rcx, [rsp + 8]
    add rsp, 16
    mov rsi, [rax + LangStrings.app_title_rename]
    mov rdx, [rax + LangStrings.app_prm_rename]
    mov rdi, rbx
    mov r8d, OP_RENAME
    call InputDialog_new
    mov [rbx + App.active_dialog], rax
    mov dword ptr [rbx + App.need_redraw], 1
    pop rbx
    ret
.Lacr_parent:
    call i18n_get
    mov rsi, [rax + LangStrings.app_err_parent]
    mov rdi, rbx
    mov edx, MSG_WARN
    call App_set_status
.Lacr_done:
    pop rbx
    ret

App_cmd_view:
    push rbx
    sub rsp, PATH_MAX + 16
    mov rbx, rdi
    mov rdi, [rbx + App.active_pane]
    call FilePane_get_selected_entry
    test rax, rax
    jz .Lacv_done
    test dword ptr [rax + FileEntry.flags], (FE_IS_DIR | FE_LINK_DIR)
    jnz .Lacv_isdir
    mov rcx, [rbx + App.active_pane]
    mov rdi, [rcx + FilePane.model]
    cmp dword ptr [rdi + DirModel.virtual_mode], 2
    jne .Lacv_normal
    mov rdi, rcx
    mov rsi, rsp
    call arc_extract_selected
    test eax, eax
    jnz .Lacv_done
    jmp .Lacv_open
.Lacv_normal:
    mov rsi, rax
    call DirModel_entry_name
    mov rdx, rax
    mov rcx, [rbx + App.active_pane]
    mov rcx, [rcx + FilePane.model]
    mov rdi, rsp
    lea rsi, [rcx + DirModel.path]
    mov ecx, PATH_MAX
    call path_join
.Lacv_open:
    mov rdi, rbx
    mov rsi, rsp
    call App_open_viewer              # images ask Image / Hex / Text first
    jmp .Lacv_done
.Lacv_isdir:
    call i18n_get
    mov rsi, [rax + LangStrings.app_err_isdir]
    mov rdi, rbx
    mov edx, MSG_WARN
    call App_set_status
.Lacv_done:
    add rsp, PATH_MAX + 16
    pop rbx
    ret

App_cmd_edit:
    push rbx
    sub rsp, PATH_MAX + 16
    mov rbx, rdi
    mov rdi, [rbx + App.active_pane]
    call FilePane_get_selected_entry
    test rax, rax
    jz .Lace_done
    test dword ptr [rax + FileEntry.flags], (FE_IS_DIR | FE_LINK_DIR)
    jnz .Lace_isdir
    mov rcx, [rbx + App.active_pane]
    mov rdi, [rcx + FilePane.model]
    mov rsi, rax
    call DirModel_entry_name
    mov rdx, rax
    mov rcx, [rbx + App.active_pane]
    mov rcx, [rcx + FilePane.model]
    mov rdi, rsp
    lea rsi, [rcx + DirModel.path]
    mov ecx, PATH_MAX
    call path_join
    lea rdi, [rip + str_sh_edit]
    mov rsi, rsp
    mov rdx, [rbx + App.envp]
    call sys_exec_sh_arg
    mov rdi, [rbx + App.screen]
    mov dword ptr [rdi + ScreenBuffer.force_full], 1
    mov rdi, rbx
    xor esi, esi
    call reload_both_panes
    jmp .Lace_done
.Lace_isdir:
    call i18n_get
    mov rsi, [rax + LangStrings.app_err_isdir]
    mov rdi, rbx
    mov edx, MSG_WARN
    call App_set_status
.Lace_done:
    add rsp, PATH_MAX + 16
    pop rbx
    ret

App_cmd_shell:
    push rbx
    sub rsp, PATH_MAX + 16
    mov rbx, rdi
    mov rdi, rsp
    mov esi, PATH_MAX
    OS_GETCWD

    mov rcx, [rbx + App.active_pane]
    mov rcx, [rcx + FilePane.model]
    lea rdi, [rcx + DirModel.path]
    OS_CHDIR

    lea rdi, [rip + str_sh_shell]
    xor esi, esi
    mov rdx, [rbx + App.envp]
    call sys_exec_sh_arg

    mov rdi, rsp
    OS_CHDIR

    mov rdi, [rbx + App.screen]
    mov dword ptr [rdi + ScreenBuffer.force_full], 1
    mov rdi, rbx
    xor esi, esi
    call reload_both_panes
    add rsp, PATH_MAX + 16
    pop rbx
    ret

# Helper for Copy/Move dialog prompt
open_transfer_dlg:
    # rdi=app, esi=op_tag (OP_COPY / OP_MOVE)
    push rbx
    push r12
    mov rbx, rdi
    mov r12d, esi

    mov rdi, [rbx + App.active_pane]
    mov rdi, [rdi + FilePane.model]
    xor esi, esi
    call DirModel_count_selected
    test eax, eax
    jnz .Lotd_open
    mov rdi, [rbx + App.active_pane]
    call FilePane_get_selected_entry
    test rax, rax
    jz .Lotd_done
    test dword ptr [rax + FileEntry.flags], FE_IS_PARENT
    jnz .Lotd_parent

.Lotd_open:
    mov rdi, rbx
    call get_inactive_pane
    mov rax, [rax + FilePane.model]
    lea rcx, [rax + DirModel.path]
    call i18n_get
    cmp r12d, OP_MOVE
    je .Lotd_mv
    mov rsi, [rax + LangStrings.app_title_copy]
    mov rdx, [rax + LangStrings.app_prm_copy]
    jmp .Lotd_create
.Lotd_mv:
    mov rsi, [rax + LangStrings.app_title_move]
    mov rdx, [rax + LangStrings.app_prm_move]
.Lotd_create:
    mov rdi, rbx
    mov r8d, r12d
    call InputDialog_new
    mov [rbx + App.active_dialog], rax
    mov dword ptr [rbx + App.need_redraw], 1
    pop rbx
    pop r12
    ret
.Lotd_parent:
    call i18n_get
    mov rsi, [rax + LangStrings.app_err_parent]
    mov rdi, rbx
    mov edx, MSG_WARN
    call App_set_status
.Lotd_done:
    pop r12
    pop rbx
    ret

App_cmd_copy:
    mov esi, OP_COPY
    jmp open_transfer_dlg

App_cmd_move:
    mov esi, OP_MOVE
    jmp open_transfer_dlg

App_cmd_delete:
    push rbx
    sub rsp, 128
    mov rbx, rdi
    mov rdi, [rbx + App.active_pane]
    mov rdi, [rdi + FilePane.model]
    xor esi, esi
    call DirModel_count_selected
    test eax, eax
    jnz .Lacd_many

    mov rdi, [rbx + App.active_pane]
    call FilePane_get_selected_entry
    test rax, rax
    jz .Lacd_ret
    test dword ptr [rax + FileEntry.flags], FE_IS_PARENT
    jnz .Lacd_parent

    mov rcx, [rbx + App.active_pane]
    mov rdi, [rcx + FilePane.model]
    mov rsi, rax
    call DirModel_entry_name
    push rax
    sub rsp, 8
    call i18n_get
    mov rcx, [rsp + 8]
    add rsp, 16
    mov rsi, [rax + LangStrings.app_title_delete]
    mov rdx, [rax + LangStrings.app_msg_del_one]
    mov rdi, rbx
    mov r8d, OP_DELETE
    call ConfirmDialog_new
    mov [rbx + App.active_dialog], rax
    mov dword ptr [rbx + App.need_redraw], 1
    jmp .Lacd_ret

.Lacd_many:
    mov edi, eax
    mov rsi, rsp
    call u64_to_dec
    call i18n_get
    mov rsi, [rax + LangStrings.app_sel_items_sfx]
    mov rdi, rsp
    mov edx, 128
    call str_cat

    call i18n_get
    mov rsi, [rax + LangStrings.app_title_delete]
    mov rdx, [rax + LangStrings.app_msg_del_many]
    mov rdi, rbx
    mov rcx, rsp
    mov r8d, OP_DELETE
    call ConfirmDialog_new
    mov [rbx + App.active_dialog], rax
    mov dword ptr [rbx + App.need_redraw], 1
    jmp .Lacd_ret

.Lacd_parent:
    call i18n_get
    mov rsi, [rax + LangStrings.app_err_parent]
    mov rdi, rbx
    mov edx, MSG_WARN
    call App_set_status
.Lacd_ret:
    add rsp, 128
    pop rbx
    ret
