# App Controller Class (Inherits from Object)
# Coordinates layout, polymorphic widget rendering, input routing, dialogs, and FS actions.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .rodata
str_App:            .asciz "App"

str_sh_edit:        .asciz "exec \"${EDITOR:-vi}\" \"$1\""
str_sh_shell:       .asciz "exec \"${SHELL:-/bin/sh}\""

.global App_vtbl
App_vtbl:
    OBJECT_VTBL_SLOTS str_App, Object_vtbl, App._size, App_dtor

.section .text
.global App_new
.global App_dtor
.global App_run
.global App_layout
.global App_render
.global App_set_status
.global App_set_active_pane
.global App_sync_preview
.global App_open_selected_entry
.global App_close_dialog
.global App_dispatch_f_action
.global App_reload_panes

.global App_cmd_help
.global App_cmd_rename
.global App_cmd_view
.global App_cmd_edit
.global App_cmd_copy
.global App_cmd_move
.global App_cmd_mkdir
.global App_cmd_delete
.global App_cmd_toggle_preview
.global App_cmd_newfile
.global App_cmd_toggle_hidden
.global App_cmd_cycle_theme
.global App_cmd_toggle_lang
.global App_cmd_start_filter
.global App_cmd_goto
.global App_cmd_shell
.global App_cmd_quit

# App *App_new(const char *left_path, const char *right_path, char **envp, int lang_override)
App_new:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi              # left_path
    mov r13, rsi              # right_path
    mov r14, rdx              # envp
    mov r15d, ecx             # lang_override (-1 = auto)

    NEW_OBJ App_vtbl, App._size
    test rax, rax
    jz .Lan_fail
    mov rbx, rax

    mov [rbx + App.envp], r14
    mov rdi, r14
    call DirModel_init_env
    mov dword ptr [rbx + App.running], 1
    mov dword ptr [rbx + App.need_redraw], 1
    mov dword ptr [rbx + App.theme_idx], 0
    mov dword ptr [rbx + App.right_mode], RIGHT_MODE_PANE

    cmp r15d, 0
    jge .Lan_set_lang
    mov rdi, r14
    call i18n_detect_env
    mov r15d, eax
.Lan_set_lang:
    mov edi, r15d
    call i18n_set_lang
    mov [rbx + App.lang], rax
    call i18n_get_idx
    mov [rbx + App.lang_idx], eax

    xor edi, edi
    call theme_get
    mov [rbx + App.theme], rax

    lea rdi, [rbx + App.term_w]
    lea rsi, [rbx + App.term_h]
    call sys_get_winsize

    mov edi, [rbx + App.term_w]
    mov esi, [rbx + App.term_h]
    call ScreenBuffer_new
    mov [rbx + App.screen], rax

    mov rdi, rbx
    call HeaderBar_new
    mov [rbx + App.header_bar], rax

    mov rdi, rbx
    call FunctionBar_new
    mov [rbx + App.func_bar], rax

    mov rdi, rbx
    call StatusBar_new
    mov [rbx + App.status_bar], rax

    mov rdi, rbx
    mov rsi, r12
    mov edx, 1
    call FilePane_new
    mov [rbx + App.left_pane], rax

    mov rdi, rbx
    mov rsi, r13
    mov edx, 2
    call FilePane_new
    mov [rbx + App.right_pane], rax

    mov rdi, rbx
    call PreviewPane_new
    mov [rbx + App.preview_pane], rax

    mov rdi, rbx
    mov rsi, [rbx + App.left_pane]
    call App_set_active_pane

    mov rdi, rbx
    call App_layout

    mov rax, rbx
.Lan_fail:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# void App_dtor(App *this)
App_dtor:
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + App.active_dialog]
    DELETE_OBJ rdi
    mov rdi, [rbx + App.preview_pane]
    DELETE_OBJ rdi
    mov rdi, [rbx + App.right_pane]
    DELETE_OBJ rdi
    mov rdi, [rbx + App.left_pane]
    DELETE_OBJ rdi
    mov rdi, [rbx + App.status_bar]
    DELETE_OBJ rdi
    mov rdi, [rbx + App.func_bar]
    DELETE_OBJ rdi
    mov rdi, [rbx + App.header_bar]
    DELETE_OBJ rdi
    mov rdi, [rbx + App.screen]
    DELETE_OBJ rdi
    pop rbx
    ret

# void App_layout(App *this)
App_layout:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi

    mov r12d, [rbx + App.term_w]
    mov r13d, [rbx + App.term_h]

    mov rdi, [rbx + App.screen]
    mov esi, r12d
    mov edx, r13d
    call ScreenBuffer_resize

    # main_h = max(6, term_h - 3)
    mov r14d, r13d
    sub r14d, 3
    cmp r14d, 6
    jge .Lal_mh_ok
    mov r14d, 6
.Lal_mh_ok:
    mov r15d, r12d
    shr r15d, 1               # left_w = term_w / 2

    # HeaderBar: (0, 0, term_w, 1)
    mov rdi, [rbx + App.header_bar]
    xor esi, esi
    xor edx, edx
    mov ecx, r12d
    mov r8d, 1
    VCALL WidgetVtbl.layout

    # Left FilePane: (0, 1, left_w, main_h)
    mov rdi, [rbx + App.left_pane]
    xor esi, esi
    mov edx, 1
    mov ecx, r15d
    mov r8d, r14d
    VCALL WidgetVtbl.layout

    # Right FilePane & PreviewPane: (left_w, 1, term_w - left_w, main_h)
    mov ecx, r12d
    sub ecx, r15d
    push rcx
    mov rdi, [rbx + App.right_pane]
    mov esi, r15d
    mov edx, 1
    mov r8d, r14d
    VCALL WidgetVtbl.layout
    pop rcx

    mov rdi, [rbx + App.preview_pane]
    mov esi, r15d
    mov edx, 1
    mov r8d, r14d
    VCALL WidgetVtbl.layout

    # StatusBar: (0, term_h - 2, term_w, 1)
    mov rdi, [rbx + App.status_bar]
    xor esi, esi
    lea edx, [r13d - 2]
    mov ecx, r12d
    mov r8d, 1
    VCALL WidgetVtbl.layout

    # FunctionBar: (0, term_h - 1, term_w, 1)
    mov rdi, [rbx + App.func_bar]
    xor esi, esi
    lea edx, [r13d - 1]
    mov ecx, r12d
    mov r8d, 1
    VCALL WidgetVtbl.layout

    # Active modal dialog (if any)
    mov rdi, [rbx + App.active_dialog]
    test rdi, rdi
    jz .Lal_done
    xor esi, esi
    xor edx, edx
    mov ecx, r12d
    mov r8d, r13d
    VCALL WidgetVtbl.layout

.Lal_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# void App_render(App *this)
App_render:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, [rbx + App.screen]
    mov r13, [rbx + App.theme]

    mov rdi, r12
    mov esi, [r13 + Theme.text]
    mov edx, [r13 + Theme.bg]
    call ScreenBuffer_clear

    mov rdi, [rbx + App.header_bar]
    mov rsi, r12
    mov rdx, r13
    VCALL WidgetVtbl.render

    mov rdi, [rbx + App.left_pane]
    mov rsi, r12
    mov rdx, r13
    VCALL WidgetVtbl.render

    cmp dword ptr [rbx + App.right_mode], RIGHT_MODE_PREVIEW
    je .Lar_preview
    mov rdi, [rbx + App.right_pane]
    jmp .Lar_right_draw
.Lar_preview:
    mov rdi, [rbx + App.preview_pane]
.Lar_right_draw:
    mov rsi, r12
    mov rdx, r13
    VCALL WidgetVtbl.render

    mov rdi, [rbx + App.status_bar]
    mov rsi, r12
    mov rdx, r13
    VCALL WidgetVtbl.render

    mov rdi, [rbx + App.func_bar]
    mov rsi, r12
    mov rdx, r13
    VCALL WidgetVtbl.render

    mov rdi, [rbx + App.active_dialog]
    test rdi, rdi
    jz .Lar_flush
    mov rsi, r12
    mov rdx, r13
    VCALL WidgetVtbl.render

.Lar_flush:
    mov rdi, r12
    call ScreenBuffer_flush
    mov dword ptr [rbx + App.need_redraw], 0

    pop r13
    pop r12
    pop rbx
    ret

# void App_set_status(App *this, const char *msg, int kind)
App_set_status:
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + App.status_bar]
    # rsi = msg, edx = kind
    mov ecx, 3500             # 3.5s display
    call StatusBar_set_message
    mov dword ptr [rbx + App.need_redraw], 1
    pop rbx
    ret

# void App_set_active_pane(App *this, FilePane *pane)
App_set_active_pane:
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    cmp r12, [rbx + App.active_pane]
    je .Lsap_done

    mov rdi, [rbx + App.left_pane]
    xor esi, esi
    VCALL WidgetVtbl.on_focus

    mov rdi, [rbx + App.right_pane]
    xor esi, esi
    VCALL WidgetVtbl.on_focus

    mov [rbx + App.active_pane], r12
    mov rdi, r12
    mov esi, 1
    VCALL WidgetVtbl.on_focus

    mov rdi, rbx
    call App_sync_preview
    mov dword ptr [rbx + App.need_redraw], 1
.Lsap_done:
    pop r12
    pop rbx
    ret

# FilePane *get_inactive_pane(App *this)
get_inactive_pane:
    mov rax, [rdi + App.left_pane]
    cmp rax, [rdi + App.active_pane]
    jne .Lgip_done
    mov rax, [rdi + App.right_pane]
.Lgip_done:
    ret

# void App_sync_preview(App *this)
App_sync_preview:
    cmp dword ptr [rdi + App.right_mode], RIGHT_MODE_PREVIEW
    jne .Lasp_done
    push rbx
    push r12
    sub rsp, PATH_MAX + 16
    mov rbx, rdi
    mov r12, [rbx + App.active_pane]
    mov rdi, r12
    call FilePane_get_selected_entry
    test rax, rax
    jz .Lasp_empty

    push rax                  # FileEntry *
    sub rsp, 8
    mov rdi, [r12 + FilePane.model]
    mov rsi, rax
    call DirModel_entry_name
    mov rdx, rax
    lea rdi, [rsp + 16]
    mov rcx, [r12 + FilePane.model]
    lea rsi, [rcx + DirModel.path]
    mov ecx, PATH_MAX
    call path_join
    add rsp, 8
    pop rdx                   # FileEntry *
    mov rdi, [rbx + App.preview_pane]
    mov rsi, rsp
    call PreviewPane_load
    jmp .Lasp_exit
.Lasp_empty:
    mov rdi, [rbx + App.preview_pane]
    xor esi, esi
    xor edx, edx
    call PreviewPane_load
.Lasp_exit:
    add rsp, PATH_MAX + 16
    pop r12
    pop rbx
.Lasp_done:
    ret

# void App_open_selected_entry(App *this, FilePane *pane)
App_open_selected_entry:
    push rbx
    push r12
    push r13
    sub rsp, PATH_MAX + 16
    mov rbx, rdi              # app
    mov r12, rsi              # pane

    mov rdi, r12
    call FilePane_get_selected_entry
    test rax, rax
    jz .Laos_done
    mov r13, rax

    test dword ptr [r13 + FileEntry.flags], FE_IS_PARENT
    jz .Laos_chk_dir
    mov rdi, r12
    call FilePane_enter_parent
    mov rdi, rbx
    call App_sync_preview
    mov dword ptr [rbx + App.need_redraw], 1
    jmp .Laos_done

.Laos_chk_dir:
    # Build full path
    mov rdi, [r12 + FilePane.model]
    mov rsi, r13
    call DirModel_entry_name
    mov rdx, rax
    mov rdi, rsp
    mov rcx, [r12 + FilePane.model]
    lea rsi, [rcx + DirModel.path]
    mov ecx, PATH_MAX
    call path_join

    test dword ptr [r13 + FileEntry.flags], (FE_IS_DIR | FE_LINK_DIR)
    jz .Laos_open_file

    mov rdi, [r12 + FilePane.model]
    mov rsi, rsp
    call DirModel_chdir
    test rax, rax
    js .Laos_err
    mov dword ptr [r12 + FilePane.cursor], 0
    mov dword ptr [r12 + FilePane.scroll], 0
    mov rdi, r12
    call FilePane_ensure_visible
    mov rdi, rbx
    call App_sync_preview
    mov dword ptr [rbx + App.need_redraw], 1
    jmp .Laos_done

.Laos_open_file:
    # Open built-in ViewerDialog
    mov rdi, rbx
    mov rsi, rsp
    call ViewerDialog_new
    mov [rbx + App.active_dialog], rax
    mov dword ptr [rbx + App.need_redraw], 1
    jmp .Laos_done

.Laos_err:
    mov edi, eax
    call fs_errno_message
    mov rdi, rbx
    mov rsi, rax
    mov edx, MSG_ERR
    call App_set_status

.Laos_done:
    add rsp, PATH_MAX + 16
    pop r13
    pop r12
    pop rbx
    ret

# Helper: reload both panes preserving cursors (or focusing given name on active)
# void App_reload_panes(App *this, const char *focus_name_or_null)
App_reload_panes:
reload_both_panes:
    # rdi=app, rsi=focus_name_or_null
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    mov rdi, [rbx + App.active_pane]
    mov rsi, r12
    call FilePane_reload_keep_cursor

    mov rdi, rbx
    call get_inactive_pane
    mov rdi, rax
    xor esi, esi
    call FilePane_reload_keep_cursor

    mov rdi, rbx
    call App_sync_preview
    mov dword ptr [rbx + App.need_redraw], 1
    pop r12
    pop rbx
    ret

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
    cmp eax, OP_QUIT
    je .Lacd_quit
    jmp .Lacd_free

.Lacd_mkdir:
    cmp byte ptr [r13 + InputDialog.buf], 0
    je .Lacd_free
    mov rdi, rsp
    lea rsi, [r8 + DirModel.path]
    lea rdx, [r13 + InputDialog.buf]
    mov ecx, PATH_MAX
    call path_join
    mov rdi, rsp
    call fs_mkdir
    test rax, rax
    js .Lacd_fs_err
    mov rdi, rbx
    lea rsi, [r13 + InputDialog.buf]
    call reload_both_panes
    call i18n_get
    mov rsi, [rax + LangStrings.app_ok_mkdir]
    mov rdi, rbx
    mov edx, MSG_OK
    call App_set_status
    jmp .Lacd_free

.Lacd_newfile:
    cmp byte ptr [r13 + InputDialog.buf], 0
    je .Lacd_free
    mov rdi, rsp
    lea rsi, [r8 + DirModel.path]
    lea rdx, [r13 + InputDialog.buf]
    mov ecx, PATH_MAX
    call path_join
    mov rdi, rsp
    call fs_touch
    test rax, rax
    js .Lacd_fs_err
    mov rdi, rbx
    lea rsi, [r13 + InputDialog.buf]
    call reload_both_panes
    call i18n_get
    mov rsi, [rax + LangStrings.app_ok_newfile]
    mov rdi, rbx
    mov edx, MSG_OK
    call App_set_status
    jmp .Lacd_free

.Lacd_rename:
    cmp byte ptr [r13 + InputDialog.buf], 0
    je .Lacd_free
    mov rdi, r14
    call FilePane_get_selected_entry
    test rax, rax
    jz .Lacd_free
    mov r8, [r14 + FilePane.model]
    mov rdi, r8
    mov rsi, rax
    call DirModel_entry_name
    mov rdx, rax
    mov rdi, rsp
    mov r8, [r14 + FilePane.model]
    lea rsi, [r8 + DirModel.path]
    mov ecx, PATH_MAX
    call path_join

    cmp byte ptr [r13 + InputDialog.buf], '/'
    je .Lacd_ren_abs
    lea rdi, [rsp + PATH_MAX]
    mov r8, [r14 + FilePane.model]
    lea rsi, [r8 + DirModel.path]
    lea rdx, [r13 + InputDialog.buf]
    mov ecx, PATH_MAX
    call path_join
    jmp .Lacd_ren_go
.Lacd_ren_abs:
    lea rdi, [rsp + PATH_MAX]
    lea rsi, [r13 + InputDialog.buf]
    mov edx, PATH_MAX
    call str_copy
.Lacd_ren_go:
    mov rdi, rsp
    lea rsi, [rsp + PATH_MAX]
    call fs_rename
    test rax, rax
    js .Lacd_fs_err
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
    jmp .Lacd_free

.Lacd_goto:
    cmp byte ptr [r13 + InputDialog.buf], 0
    je .Lacd_free
    mov rax, [rbx + App.status_bar]
    mov qword ptr [rax + StatusBar.msg_expire_ms], 0
    mov rdi, r8
    lea rsi, [r13 + InputDialog.buf]
    call DirModel_chdir
    test rax, rax
    js .Lacd_fs_err
    mov dword ptr [r14 + FilePane.cursor], 0
    mov dword ptr [r14 + FilePane.scroll], 0
    mov rdi, r14
    call FilePane_ensure_visible
    mov rdi, rbx
    call App_sync_preview
    jmp .Lacd_free

.Lacd_fs_err:
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

.Lacd_free:
    DELETE_OBJ r13
.Lacd_done:
    add rsp, PATH_MAX * 2 + 16
    pop r14
    pop r13
    pop r12
    pop rbx
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
    mov rsi, rax
    call DirModel_entry_name
    mov rdx, rax
    mov rcx, [rbx + App.active_pane]
    mov rcx, [rcx + FilePane.model]
    mov rdi, rsp
    lea rsi, [rcx + DirModel.path]
    mov ecx, PATH_MAX
    call path_join
    mov rdi, rbx
    mov rsi, rsp
    call ViewerDialog_new
    mov [rbx + App.active_dialog], rax
    mov dword ptr [rbx + App.need_redraw], 1
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

App_cmd_toggle_preview:
    xor dword ptr [rdi + App.right_mode], 1
    cmp dword ptr [rdi + App.right_mode], RIGHT_MODE_PREVIEW
    jne .Lactp_dual
    # Ensure left pane is active when right side switches to preview
    push rdi
    mov rsi, [rdi + App.left_pane]
    call App_set_active_pane
    pop rdi
    push rdi
    call App_sync_preview
    pop rdi
.Lactp_dual:
    mov dword ptr [rdi + App.need_redraw], 1
    ret

App_cmd_toggle_hidden:
    push rbx
    mov rbx, rdi
    mov rax, [rbx + App.left_pane]
    mov rcx, [rax + FilePane.model]
    xor dword ptr [rcx + DirModel.show_hidden], 1
    mov edx, [rcx + DirModel.show_hidden]
    mov rax, [rbx + App.right_pane]
    mov rcx, [rax + FilePane.model]
    mov [rcx + DirModel.show_hidden], edx

    mov rax, [rbx + App.left_pane]
    mov rdi, [rax + FilePane.model]
    call DirModel_apply_filter
    mov rdi, [rbx + App.left_pane]
    call FilePane_ensure_visible

    mov rax, [rbx + App.right_pane]
    mov rdi, [rax + FilePane.model]
    call DirModel_apply_filter
    mov rdi, [rbx + App.right_pane]
    call FilePane_ensure_visible

    mov rdi, rbx
    call App_sync_preview
    mov dword ptr [rbx + App.need_redraw], 1
    pop rbx
    ret

App_cmd_cycle_theme:
    push rbx
    mov rbx, rdi
    inc dword ptr [rbx + App.theme_idx]
    mov edi, [rbx + App.theme_idx]
    call theme_get
    mov [rbx + App.theme], rax
    mov rdi, [rbx + App.screen]
    mov dword ptr [rdi + ScreenBuffer.force_full], 1
    mov dword ptr [rbx + App.need_redraw], 1
    pop rbx
    ret

App_cmd_toggle_lang:
    push rbx
    mov rbx, rdi
    mov edi, [rbx + App.lang_idx]
    xor edi, 1
    mov [rbx + App.lang_idx], edi
    call i18n_set_lang
    mov [rbx + App.lang], rax
    mov rdi, rbx
    call App_layout
    mov rax, [rbx + App.lang]
    mov rsi, [rax + LangStrings.msg_lang_switched]
    mov rdi, rbx
    mov edx, MSG_INFO
    call App_set_status
    mov rdi, [rbx + App.screen]
    mov dword ptr [rdi + ScreenBuffer.force_full], 1
    mov dword ptr [rbx + App.need_redraw], 1
    pop rbx
    ret

App_cmd_quit:
    cmp dword ptr [rdi + App.task_active], 0
    jne App_task_confirm_quit
    mov dword ptr [rdi + App.running], 0
    ret

# void App_dispatch_f_action(App *this, int idx_0_to_9)
App_dispatch_f_action:
    cmp esi, 0; je App_cmd_help
    cmp esi, 1; je App_cmd_rename
    cmp esi, 2; je App_cmd_view
    cmp esi, 3; je App_cmd_edit
    cmp esi, 4; je App_cmd_copy
    cmp esi, 5; je App_cmd_move
    cmp esi, 6; je App_cmd_mkdir
    cmp esi, 7; je App_cmd_delete
    cmp esi, 8; je App_cmd_toggle_preview
    cmp esi, 9; je App_cmd_quit
    ret

# Internal: handle key event
handle_key:
    # rdi=app, rsi=evt
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi

    # Modal dialog intercepts keys first
    mov rdi, [rbx + App.active_dialog]
    test rdi, rdi
    jz .Lhk_no_dlg
    mov rsi, r12
    VCALL WidgetVtbl.on_key
    jmp .Lhk_done

.Lhk_no_dlg:
    mov eax, [r12 + Event.key]
    mov ecx, [r12 + Event.mods]

    # Ctrl+combos
    test ecx, MOD_CTRL
    jz .Lhk_chk_alt
    cmp eax, 'c'; je .Lhk_quit
    cmp eax, 'q'; je .Lhk_quit
    cmp eax, 'p'; je .Lhk_prev
    cmp eax, 'h'; je .Lhk_hidden
    cmp eax, 'r'; je .Lhk_refresh
    cmp eax, 'n'; je .Lhk_newfile
    cmp eax, 'g'; je .Lhk_goto
    cmp eax, 'o'; je .Lhk_shell
    jmp .Lhk_pane

.Lhk_chk_alt:
    test ecx, MOD_ALT
    jz .Lhk_plain
    cmp eax, 't'; je .Lhk_theme
    cmp eax, 'T'; je .Lhk_theme
    cmp eax, 0x0435; je .Lhk_theme   # Cyrillic 'е' (Alt+T in UA layout)
    cmp eax, 0x0415; je .Lhk_theme   # Cyrillic 'Е'
    cmp eax, 'l'; je .Lhk_lang
    cmp eax, 'L'; je .Lhk_lang
    cmp eax, 0x0434; je .Lhk_lang    # Cyrillic 'д' (Alt+L in UA layout)
    cmp eax, 0x0414; je .Lhk_lang    # Cyrillic 'Д'
    cmp eax, 'j'; je .Lhk_tasks
    cmp eax, 'J'; je .Lhk_tasks
    cmp eax, 0x043E; je .Lhk_tasks   # Cyrillic 'о' (Alt+J in UA layout)
    cmp eax, 0x041E; je .Lhk_tasks   # Cyrillic 'О'
    jmp .Lhk_pane

.Lhk_plain:
    cmp eax, KEY_F1;  jb .Lhk_not_f
    cmp eax, KEY_F10; ja .Lhk_not_f
    sub eax, KEY_F1
    mov rdi, rbx
    mov esi, eax
    call App_dispatch_f_action
    jmp .Lhk_done

.Lhk_not_f:
    cmp eax, KEY_TAB;    je .Lhk_tab
    cmp eax, KEY_BTAB;   je .Lhk_tab
    cmp eax, 'q';        je .Lhk_quit
    cmp eax, 'Q';        je .Lhk_quit
    cmp eax, '/';        je .Lhk_filter
    cmp eax, '.';        je .Lhk_hidden
    cmp eax, KEY_DELETE; je .Lhk_del
    cmp eax, KEY_ESC;    je .Lhk_esc

.Lhk_pane:
    mov rdi, [rbx + App.active_pane]
    mov rsi, r12
    VCALL WidgetVtbl.on_key
    jmp .Lhk_done

.Lhk_tab:
    cmp dword ptr [rbx + App.right_mode], RIGHT_MODE_PREVIEW
    je .Lhk_done
    mov rdi, rbx
    call get_inactive_pane
    mov rdi, rbx
    mov rsi, rax
    call App_set_active_pane
    jmp .Lhk_done

.Lhk_esc:
    mov rcx, [rbx + App.active_pane]
    mov r8, [rcx + FilePane.model]
    cmp dword ptr [r8 + DirModel.is_loading], 0
    jne .Lhk_cancel_stream
    mov rcx, [rbx + App.left_pane]
    mov r8, [rcx + FilePane.model]
    cmp dword ptr [r8 + DirModel.is_loading], 0
    jne .Lhk_cancel_stream
    mov rcx, [rbx + App.right_pane]
    mov r8, [rcx + FilePane.model]
    cmp dword ptr [r8 + DirModel.is_loading], 0
    jne .Lhk_cancel_stream

    mov rcx, [rbx + App.active_pane]
    mov r8, [rcx + FilePane.model]
    cmp byte ptr [r8 + DirModel.filter], 0
    je .Lhk_done
    mov byte ptr [r8 + DirModel.filter], 0
    mov rdi, r8
    call DirModel_apply_filter
    mov rdi, [rbx + App.active_pane]
    mov dword ptr [rdi + FilePane.cursor], 0
    mov dword ptr [rdi + FilePane.scroll], 0
    call FilePane_ensure_visible
    mov rdi, rbx
    call App_sync_preview
    mov dword ptr [rbx + App.need_redraw], 1
    jmp .Lhk_done

.Lhk_cancel_stream:
    mov rdi, r8
    call DirModel_cancel_load
    call i18n_get
    mov rsi, [rax + LangStrings.app_load_aborted]
    mov rdi, rbx
    mov edx, MSG_INFO
    call App_set_status
    mov rdi, [rbx + App.active_pane]
    call FilePane_ensure_visible
    mov rdi, rbx
    call App_sync_preview
    mov dword ptr [rbx + App.need_redraw], 1
    jmp .Lhk_done

.Lhk_refresh:
    mov rdi, rbx
    xor esi, esi
    call reload_both_panes
    call i18n_get
    mov rsi, [rax + LangStrings.app_ok_refresh]
    mov rdi, rbx
    mov edx, MSG_INFO
    call App_set_status
    jmp .Lhk_done

.Lhk_quit:    mov rdi, rbx; call App_cmd_quit; jmp .Lhk_done
.Lhk_prev:    mov rdi, rbx; call App_cmd_toggle_preview; jmp .Lhk_done
.Lhk_hidden:  mov rdi, rbx; call App_cmd_toggle_hidden; jmp .Lhk_done
.Lhk_theme:   mov rdi, rbx; call App_cmd_cycle_theme; jmp .Lhk_done
.Lhk_lang:    mov rdi, rbx; call App_cmd_toggle_lang; jmp .Lhk_done
.Lhk_filter:  mov rdi, rbx; call App_cmd_start_filter; jmp .Lhk_done
.Lhk_newfile: mov rdi, rbx; call App_cmd_newfile; jmp .Lhk_done
.Lhk_goto:    mov rdi, rbx; call App_cmd_goto; jmp .Lhk_done
.Lhk_shell:   mov rdi, rbx; call App_cmd_shell; jmp .Lhk_done
.Lhk_del:     mov rdi, rbx; call App_cmd_delete; jmp .Lhk_done
.Lhk_tasks:   mov rdi, rbx; call App_task_show; jmp .Lhk_done

.Lhk_done:
    pop r12
    pop rbx
    ret

# Internal: handle mouse event
handle_mouse:
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi

    mov eax, [r12 + Event.mouse_x]
    mov [rbx + App.mouse_x], eax
    mov eax, [r12 + Event.mouse_y]
    mov [rbx + App.mouse_y], eax

    # Modal dialog captures all mouse input
    mov rdi, [rbx + App.active_dialog]
    test rdi, rdi
    jz .Lhm_check_drag
    mov rsi, r12
    VCALL WidgetVtbl.on_mouse
    jmp .Lhm_done

.Lhm_check_drag:
    # Forward drag/release to whichever pane is dragging its scrollbar
    mov rdi, [rbx + App.left_pane]
    cmp dword ptr [rdi + FilePane.dragging_scroll], 0
    jne .Lhm_fwd_drag
    mov rdi, [rbx + App.right_pane]
    cmp dword ptr [rdi + FilePane.dragging_scroll], 0
    je .Lhm_route
.Lhm_fwd_drag:
    mov rsi, r12
    VCALL WidgetVtbl.on_mouse
    jmp .Lhm_done

.Lhm_route:
    # On MACT_MOVE, let HeaderBar, FunctionBar, and panes update hover states cleanly
    cmp dword ptr [r12 + Event.mouse_kind], MACT_MOVE
    jne .Lhm_hit_test
    mov rdi, [rbx + App.header_bar]
    mov rsi, r12
    VCALL WidgetVtbl.on_mouse
    mov rdi, [rbx + App.func_bar]
    mov rsi, r12
    VCALL WidgetVtbl.on_mouse
    mov rdi, [rbx + App.left_pane]
    mov rsi, r12
    VCALL WidgetVtbl.on_mouse
    cmp dword ptr [rbx + App.right_mode], RIGHT_MODE_PREVIEW
    je .Lhm_done
    mov rdi, [rbx + App.right_pane]
    mov rsi, r12
    VCALL WidgetVtbl.on_mouse
    jmp .Lhm_done

.Lhm_hit_test:
    cmp dword ptr [rbx + App.task_active], 0
    je .Lhm_ht_hdr
    cmp dword ptr [r12 + Event.mouse_kind], MACT_PRESS
    jne .Lhm_ht_hdr
    mov rax, [rbx + App.status_bar]
    mov ecx, [rax + Widget.y]
    cmp ecx, [r12 + Event.mouse_y]
    jne .Lhm_ht_hdr
    mov rdi, rbx
    call App_task_show
    jmp .Lhm_done

.Lhm_ht_hdr:
    mov r8d, [r12 + Event.mouse_x]
    mov r9d, [r12 + Event.mouse_y]

    mov rdi, [rbx + App.header_bar]
    mov esi, r8d
    mov edx, r9d
    VCALL WidgetVtbl.hit_test
    test eax, eax
    jz .Lhm_ht_func
    mov rdi, [rbx + App.header_bar]
    mov rsi, r12
    VCALL WidgetVtbl.on_mouse
    test eax, eax
    jnz .Lhm_done

.Lhm_ht_func:
    mov rdi, [rbx + App.func_bar]
    mov esi, r8d
    mov edx, r9d
    VCALL WidgetVtbl.hit_test
    test eax, eax
    jz .Lhm_ht_left
    mov rdi, [rbx + App.func_bar]
    mov rsi, r12
    VCALL WidgetVtbl.on_mouse
    test eax, eax
    jnz .Lhm_done

.Lhm_ht_left:
    mov rdi, [rbx + App.left_pane]
    mov esi, r8d
    mov edx, r9d
    VCALL WidgetVtbl.hit_test
    test eax, eax
    jz .Lhm_ht_right
    mov rdi, [rbx + App.left_pane]
    mov rsi, r12
    VCALL WidgetVtbl.on_mouse
    jmp .Lhm_done

.Lhm_ht_right:
    mov rdi, [rbx + App.right_pane]
    cmp dword ptr [rbx + App.right_mode], RIGHT_MODE_PREVIEW
    jne .Lhm_ht_rtest
    mov rdi, [rbx + App.preview_pane]
.Lhm_ht_rtest:
    push rdi
    mov esi, r8d
    mov edx, r9d
    VCALL WidgetVtbl.hit_test
    pop rdi
    test eax, eax
    jz .Lhm_done
    mov rsi, r12
    VCALL WidgetVtbl.on_mouse

.Lhm_done:
    pop r12
    pop rbx
    ret

# void App_run(App *this)
App_run:
    push rbx
    sub rsp, Event._size + 16
    mov rbx, rdi
    mov qword ptr [rsp + Event._size], 0

    call App_render

.Larun_loop:
    cmp dword ptr [rbx + App.running], 0
    je .Larun_exit
    cmp dword ptr [rip + g_sigterm], 0
    jne .Larun_exit

    # Non-blocking poll (0ms) while streaming large dirs so UI/Esc stay responsive
    mov rcx, [rbx + App.left_pane]
    mov rcx, [rcx + FilePane.model]
    mov edx, [rcx + DirModel.is_loading]
    mov rcx, [rbx + App.right_pane]
    mov rcx, [rcx + FilePane.model]
    or edx, [rcx + DirModel.is_loading]
    mov esi, 200
    xor eax, eax
    test edx, edx
    cmovnz esi, eax
    cmp dword ptr [rbx + App.task_active], 0
    je .Larun_poll
    mov eax, TASK_TICK_MS
    cmp esi, eax
    cmova esi, eax
.Larun_poll:
    mov rdi, rsp
    call input_poll_event

    # Check if temporary status message expired
    mov rcx, [rbx + App.status_bar]
    cmp qword ptr [rcx + StatusBar.msg_expire_ms], 0
    je .Larun_chk_evt
    push rax
    call sys_clock_ms
    mov rcx, [rbx + App.status_bar]
    cmp rax, [rcx + StatusBar.msg_expire_ms]
    jb .Larun_msg_active
    mov qword ptr [rcx + StatusBar.msg_expire_ms], 0
    mov dword ptr [rbx + App.need_redraw], 1
.Larun_msg_active:
    pop rax

.Larun_chk_evt:
    test eax, eax
    jz .Larun_stream_step

    mov eax, [rsp + Event.type]
    cmp eax, EVT_RESIZE
    je .Larun_resize
    cmp eax, EVT_KEY
    je .Larun_key
    cmp eax, EVT_MOUSE
    je .Larun_mouse
    jmp .Larun_stream_step

.Larun_resize:
    lea rdi, [rbx + App.term_w]
    lea rsi, [rbx + App.term_h]
    call sys_get_winsize
    mov rdi, rbx
    call App_layout
    mov dword ptr [rbx + App.need_redraw], 1
    jmp .Larun_stream_step

.Larun_key:
    mov rdi, rbx
    mov rsi, rsp
    call handle_key
    jmp .Larun_stream_step

.Larun_mouse:
    mov rdi, rbx
    mov rsi, rsp
    call handle_mouse

.Larun_stream_step:
    cmp dword ptr [rbx + App.running], 0
    je .Larun_exit
    mov rdi, rbx
    call App_task_tick
    # Stream both panes concurrently: alternate batches when both are loading
    mov rax, [rbx + App.left_pane]
    mov rdi, [rax + FilePane.model]
    mov rax, [rbx + App.right_pane]
    mov rsi, [rax + FilePane.model]
    mov ecx, [rdi + DirModel.is_loading]
    mov edx, [rsi + DirModel.is_loading]
    test ecx, ecx
    jz .Larun_only_right
    test edx, edx
    jz .Larun_do_step
    xor dword ptr [rbx + App.stream_turn], 1
    cmp dword ptr [rbx + App.stream_turn], 0
    je .Larun_do_step
    mov rdi, rsi
    jmp .Larun_do_step
.Larun_only_right:
    test edx, edx
    jz .Larun_redraw
    mov rdi, rsi

.Larun_do_step:
    xor esi, esi
    call DirModel_step_load
    test rax, rax
    jz .Larun_stream_finished

    # Throttle progress footer redraws (~30 FPS) to keep 1M scan at max speed
    call sys_clock_ms
    mov rcx, rax
    sub rcx, [rsp + Event._size]
    cmp rcx, 33
    jb .Larun_redraw
    mov [rsp + Event._size], rax
    mov dword ptr [rbx + App.need_redraw], 1
    jmp .Larun_redraw

.Larun_stream_finished:
    mov rdi, rbx
    call App_sync_preview
    mov dword ptr [rbx + App.need_redraw], 1

.Larun_redraw:
    cmp dword ptr [rbx + App.need_redraw], 0
    je .Larun_loop
    mov rdi, rbx
    call App_render
    jmp .Larun_loop

.Larun_exit:
    mov rdi, rbx
    call App_task_shutdown
    add rsp, Event._size + 16
    pop rbx
    ret
