# Frozen reference oracle: original src/app/app_menu.s before migration to src/app/app_menu.c.
# src/app/app_menu.s - User Menu, Action Dispatch & Command Expansion
.intel_syntax noprefix

.include "pal.inc"
.include "classes.inc"

.section .text
.global App_cmd_usermenu
.global App_dispatch_action
.global App_exec_menu_tmpl
.global App_run_pkg_action

.extern UserMenuDialog_new
.extern App_cmd_quit
.extern App_cmd_help
.extern App_cmd_rename
.extern App_cmd_view
.extern App_cmd_edit
.extern App_cmd_copy
.extern App_cmd_move
.extern App_cmd_mkdir
.extern App_cmd_delete
.extern App_cmd_toggle_preview
.extern App_cmd_toggle_hidden
.extern App_cmd_cycle_theme
.extern App_cmd_toggle_lang
.extern App_cmd_start_filter
.extern App_cmd_goto
.extern App_cmd_newfile
.extern App_cmd_shell
.extern App_reload_panes
.extern get_inactive_pane
.extern DirModel_get_entry
.extern DirModel_entry_name
.extern FilePane_get_selected_entry
.extern App_run_expanded_cmd
.extern sys_exec_sh_arg
.extern sys_exec_argv
.extern sys_exec_argv_bg
.extern App_set_status
.extern i18n_get
.extern pkg_action_build_argv
.extern pkg_action_has_marked
.extern pkg_ensure_exec
.extern pkg_write_marked_list
.extern str_copy
.extern path_join

# void App_cmd_usermenu(App *this)
App_cmd_usermenu:
    push rbx
    mov rbx, rdi
    call UserMenuDialog_new
    mov [rbx + App.active_dialog], rax
    mov dword ptr [rbx + App.need_redraw], 1
    pop rbx
    ret

# void App_dispatch_action(App *this, int act_id)
App_dispatch_action:
    cmp esi, ACT_QUIT;     je App_cmd_quit
    cmp esi, ACT_HELP;     je App_cmd_help
    cmp esi, ACT_RENAME;   je App_cmd_rename
    cmp esi, ACT_VIEW;     je App_cmd_view
    cmp esi, ACT_EDIT;     je App_cmd_edit
    cmp esi, ACT_COPY;     je App_cmd_copy
    cmp esi, ACT_MOVE;     je App_cmd_move
    cmp esi, ACT_MKDIR;    je App_cmd_mkdir
    cmp esi, ACT_DELETE;   je App_cmd_delete
    cmp esi, ACT_PREVIEW;  je App_cmd_toggle_preview
    cmp esi, ACT_HIDDEN;   je App_cmd_toggle_hidden
    cmp esi, ACT_THEME;    je App_cmd_cycle_theme
    cmp esi, ACT_LANG;     je App_cmd_toggle_lang
    cmp esi, ACT_FILTER;   je App_cmd_start_filter
    cmp esi, ACT_GOTO;     je App_cmd_goto
    cmp esi, ACT_NEWFILE;  je App_cmd_newfile
    cmp esi, ACT_SHELL;    je App_cmd_shell
    cmp esi, ACT_REFRESH
    jne .Lada_chk_um
    xor esi, esi
    jmp App_reload_panes
.Lada_chk_um:
    cmp esi, ACT_USERMENU; je App_cmd_usermenu
    ret

am_err_status:
    push rbx; mov rbx, rdi; mov edi, esi; call fs_errno_message
    mov rdi, rbx; mov rsi, rax; mov edx, MSG_ERR; call App_set_status
    pop rbx; ret

# void App_exec_menu_tmpl(App *this, const char *tmpl)
App_exec_menu_tmpl:
    push rbx; push r12; push r13; sub rsp, PATH_MAX + 16
    mov rbx, rdi; mov r12, rsi; xor r13d, r13d; mov byte ptr [rsp], 0
    mov rdi, [rbx + App.active_pane]; call FilePane_get_selected_entry
    test rax, rax; jz .Laemt_go
    mov rcx, [rbx + App.active_pane]; mov rdi, [rcx + FilePane.model]
    mov rsi, rax; call DirModel_entry_name; mov r13, rax
    mov rcx, [rbx + App.active_pane]; mov rcx, [rcx + FilePane.model]
    lea rsi, [rcx + DirModel.path]; mov rdi, rsp; mov rdx, r13; mov ecx, PATH_MAX
    call path_join # path-checked
    test rax, rax; js .Laemt_ret
.Laemt_go:
    mov rdi, rbx; mov rsi, r12; mov rdx, r13; mov rcx, rsp
    call App_run_expanded_cmd
.Laemt_ret:
    add rsp, PATH_MAX + 16; pop r13; pop r12; pop rbx; ret

am_pkg_exec_cwd:
    push rbx; push r12; push r13; push r14; sub rsp, PATH_MAX + 8
    mov rbx, rdi; mov r12, rsi; mov r13, rdx; mov r14, rcx
    mov rdi, [r14]; call pkg_ensure_exec
    test eax, eax; js .Lapec_bg_err
    mov rdi, rsp; mov esi, PATH_MAX; OS_GETCWD
    test rax, rax; jns 1f; mov byte ptr [rsp], 0
1:  mov rdi, r13; OS_CHDIR
    test rax, rax; jns 2f
    mov rdi, rbx; mov esi, eax; call am_err_status; jmp .Lapec_ret
2:  mov rdi, [r14]; mov rsi, r14; mov rdx, [rbx + App.envp]
    cmp word ptr [r12 + 336], 0x6762; jne .Lapec_fg
    cmp byte ptr [r12 + 338], 0; jne .Lapec_fg
    call sys_exec_argv_bg; push rax
    cmp byte ptr [rsp + 8], 0; je 3f
    lea rdi, [rsp + 8]; OS_CHDIR; test rax, rax; nop
3:  pop rax; test eax, eax; jnz .Lapec_bg_err
    mov rdi, rbx; lea rsi, [r12 + 128]
    cmp byte ptr [rsi], 0; jne 4f; mov rsi, r12
4:  mov edx, MSG_OK; call App_set_status; jmp .Lapec_ret
.Lapec_bg_err:
    call i18n_get; mov rsi, [rax + LangStrings.pkg_err]; mov edx, MSG_ERR
    mov rdi, rbx; call App_set_status; jmp .Lapec_ret
.Lapec_fg:
    call sys_exec_argv
    cmp byte ptr [rsp], 0; je .Lapec_ret
    mov rdi, rsp; OS_CHDIR; test rax, rax; nop
.Lapec_ret:
    add rsp, PATH_MAX + 8; pop r14; pop r13; pop r12; pop rbx; ret

# void App_run_pkg_action(App *this, PkgAction *act)
App_run_pkg_action:
    push rbx; push r12; push r13
    sub rsp, 40 + PATH_MAX * 2 + 1024 + 256 + 128 + 8
    mov rbx, rdi; mov r12, rsi
    mov rax, [rbx + App.active_pane]; mov rax, [rax + FilePane.model]
    lea rcx, [rax + DirModel.path]; mov [rsp + 0], rcx
    mov rdi, rbx; call get_inactive_pane
    mov rax, [rax + FilePane.model]; lea rax, [rax + DirModel.path]; mov [rsp + 8], rax
    mov qword ptr [rsp + 16], 0; mov byte ptr [rsp + 40], 0
    lea rax, [rsp + 40]; mov [rsp + 24], rax; mov qword ptr [rsp + 32], 0
    lea rax, [rsp + 40 + PATH_MAX * 2 + 1024 + 256]; mov byte ptr [rax], 0
    mov rdi, [rbx + App.active_pane]; call FilePane_get_selected_entry
    test rax, rax; jz .Larpa_chk_mk
    mov rcx, [rbx + App.active_pane]; mov rdi, [rcx + FilePane.model]; mov rsi, rax
    call DirModel_entry_name; mov [rsp + 16], rax
    lea rdi, [rsp + 40]; mov rsi, [rsp + 0]; mov rdx, rax; mov ecx, PATH_MAX
    call path_join # path-checked
    test rax, rax; js .Larpa_done
.Larpa_chk_mk:
    mov rdi, r12; call pkg_action_has_marked; test eax, eax; jz .Larpa_build
    mov rcx, [rbx + App.active_pane]; mov rdi, [rcx + FilePane.model]; mov rsi, [rsp + 24]
    lea rdx, [rsp + 40 + PATH_MAX * 2 + 1024 + 256]; mov ecx, 128
    call pkg_write_marked_list; test eax, eax; jnz .Larpa_build
    lea rax, [rsp + 40 + PATH_MAX * 2 + 1024 + 256]; mov [rsp + 32], rax
.Larpa_build:
    mov rdi, r12; mov rsi, rsp; lea rdx, [rsp + 40 + PATH_MAX]; mov ecx, 1024
    lea r8, [rsp + 40 + PATH_MAX + 1024]; mov r9d, 32
    call pkg_action_build_argv; test eax, eax; jle .Larpa_unlink
    mov rdi, rbx; mov rsi, r12; mov rdx, [rsp + 0]; lea rcx, [rsp + 40 + PATH_MAX + 1024]
    call am_pkg_exec_cwd
.Larpa_unlink:
    lea rsi, [rsp + 40 + PATH_MAX * 2 + 1024 + 256]
    cmp byte ptr [rsi], 0; je .Larpa_redraw
    mov edi, AT_FDCWD; xor edx, edx; OS_UNLINKAT # fault-checked: best-effort marked tmpfile cleanup
.Larpa_redraw:
    mov rdi, [rbx + App.screen]; mov dword ptr [rdi + ScreenBuffer.force_full], 1
    mov rdi, rbx; xor esi, esi; call App_reload_panes
.Larpa_done:
    add rsp, 40 + PATH_MAX * 2 + 1024 + 256 + 128 + 8
    pop r13; pop r12; pop rbx; ret
