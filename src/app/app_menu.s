# src/app/app_menu.s - User Menu, Action Dispatch & Command Expansion
.intel_syntax noprefix

.include "pal.inc"
.include "classes.inc"

.section .text
.global App_cmd_usermenu
.global App_dispatch_action
.global App_run_expanded_cmd
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
.extern config_expand_cmd
.extern sys_exec_sh_arg
.extern sys_exec_argv
.extern pkg_action_build_argv
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

# Helper: void am_collect_selected(App *this, const char *cur_name, char *sel_buf)
am_collect_selected:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    mov r13, rsi
    mov r15, rdx
    mov byte ptr [r15], 0
    xor eax, eax
    mov rcx, [rbx + App.active_pane]
    mov r8, [rcx + FilePane.model]
    xor r9d, r9d
    mov r10d, [r8 + DirModel.count]
    push rax
.Lacs_loop:
    cmp r9d, r10d
    jge .Lacs_done
    push r8; push r9; push r10
    mov rdi, r8
    mov esi, r9d
    call DirModel_get_entry
    pop r10; pop r9; pop r8
    test rax, rax
    jz .Lacs_next
    test dword ptr [rax + FileEntry.flags], FE_SELECTED
    jz .Lacs_next
    push r8; push r9; push r10
    mov rdi, r8
    mov rsi, rax
    call DirModel_entry_name
    mov r11, rax
    pop r10; pop r9; pop r8
    mov rax, [rsp]
    test rax, rax
    jz .Lacs_nosp
    cmp rax, 2040
    jae .Lacs_done
    mov byte ptr [r15 + rax], ' '
    inc rax
.Lacs_nosp:
    xor ecx, ecx
.Lacs_cpy:
    mov dl, [r11 + rcx]
    test dl, dl
    jz .Lacs_cend
    cmp rax, 2046
    jae .Lacs_done
    mov [r15 + rax], dl
    inc rax
    inc rcx
    jmp .Lacs_cpy
.Lacs_cend:
    mov byte ptr [r15 + rax], 0
    mov [rsp], rax
.Lacs_next:
    inc r9d
    jmp .Lacs_loop
.Lacs_done:
    pop rax
    test rax, rax
    jnz .Lacs_ret
    test r13, r13
    jz .Lacs_ret
    mov rdi, r15
    mov rsi, r13
    mov edx, 2048
    call str_copy
.Lacs_ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# void App_run_expanded_cmd(App *this, const char *tmpl, const char *cur_name, const char *cur_path)
App_run_expanded_cmd:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 40 + 2048 + 2048 + PATH_MAX + 8
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx

    lea r15, [rsp + 40]
    mov rdi, rbx
    mov rsi, r13
    mov rdx, r15
    call am_collect_selected

    mov [rsp + 0], r13
    mov [rsp + 8], r14
    mov [rsp + 16], r15
    mov rax, [rbx + App.active_pane]
    mov rax, [rax + FilePane.model]
    lea rax, [rax + DirModel.path]
    mov [rsp + 24], rax
    mov rdi, rbx
    call get_inactive_pane
    mov rax, [rax + FilePane.model]
    lea rax, [rax + DirModel.path]
    mov [rsp + 32], rax

    mov rdi, r12
    lea rsi, [rsp + 2088]
    mov edx, 2048
    mov rcx, rsp
    call config_expand_cmd

    lea rdi, [rsp + 4136]
    mov esi, PATH_MAX
    OS_GETCWD

    mov rcx, [rbx + App.active_pane]
    mov rcx, [rcx + FilePane.model]
    lea rdi, [rcx + DirModel.path]
    OS_CHDIR

    lea rdi, [rsp + 2088]
    mov rsi, r14
    mov rdx, [rbx + App.envp]
    call sys_exec_sh_arg

    lea rdi, [rsp + 4136]
    OS_CHDIR

    mov rdi, [rbx + App.screen]
    mov dword ptr [rdi + ScreenBuffer.force_full], 1
    mov rdi, rbx
    xor esi, esi
    call App_reload_panes

    add rsp, 40 + 2048 + 2048 + PATH_MAX + 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# void App_exec_menu_tmpl(App *this, const char *tmpl)
App_exec_menu_tmpl:
    push rbx
    push r12
    push r13
    sub rsp, PATH_MAX + 16
    mov rbx, rdi
    mov r12, rsi
    xor r13d, r13d
    mov byte ptr [rsp], 0

    mov rdi, [rbx + App.active_pane]
    call FilePane_get_selected_entry
    test rax, rax
    jz .Laemt_go
    mov rcx, [rbx + App.active_pane]
    mov rdi, [rcx + FilePane.model]
    mov rsi, rax
    call DirModel_entry_name
    mov r13, rax

    mov rcx, [rbx + App.active_pane]
    mov rcx, [rcx + FilePane.model]
    lea rsi, [rcx + DirModel.path]
    mov rdi, rsp
    mov rdx, r13
    mov ecx, PATH_MAX
    call path_join

.Laemt_go:
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov rcx, rsp
    call App_run_expanded_cmd

    add rsp, PATH_MAX + 16
    pop r13
    pop r12
    pop rbx
    ret

# void App_run_pkg_action(App *this, PkgAction *act)
App_run_pkg_action:
    push rbx; push r12; push r13
    # Stack: [0..31]=ctx[4], [32..32+PATH_MAX-1]=path_buf,
    # [32+PATH_MAX..1055+PATH_MAX]=str_buf[1024], [1056+PATH_MAX..1311+PATH_MAX]=argv[32*8],
    # [1312+PATH_MAX..1312+2*PATH_MAX-1]=cwd_buf
    sub rsp, 32 + PATH_MAX * 2 + 1024 + 256 + 8
    mov rbx, rdi; mov r12, rsi
    mov rax, [rbx + App.active_pane]; mov rax, [rax + FilePane.model]
    lea rcx, [rax + DirModel.path]; mov [rsp + 0], rcx
    mov rdi, rbx; call get_inactive_pane
    mov rax, [rax + FilePane.model]; lea rax, [rax + DirModel.path]
    mov [rsp + 8], rax
    mov qword ptr [rsp + 16], 0
    mov byte ptr [rsp + 32], 0
    lea rax, [rsp + 32]; mov [rsp + 24], rax
    mov rdi, [rbx + App.active_pane]; call FilePane_get_selected_entry
    test rax, rax; jz .Larpa_build
    mov rcx, [rbx + App.active_pane]; mov rdi, [rcx + FilePane.model]; mov rsi, rax
    call DirModel_entry_name
    mov [rsp + 16], rax
    lea rdi, [rsp + 32]; mov rsi, [rsp + 0]; mov rdx, rax; mov ecx, PATH_MAX
    call path_join
.Larpa_build:
    mov rdi, r12; mov rsi, rsp
    lea rdx, [rsp + 32 + PATH_MAX]; mov ecx, 1024
    lea r8, [rsp + 32 + PATH_MAX + 1024]; mov r9d, 32
    call pkg_action_build_argv
    lea r13, [rsp + 32 + PATH_MAX + 1024 + 256]
    mov rdi, r13; mov esi, PATH_MAX; OS_GETCWD
    mov rdi, [rsp + 0]; OS_CHDIR
    lea rsi, [rsp + 32 + PATH_MAX + 1024]
    mov rdi, [rsi]; push rdi; push rsi
    mov rsi, rdi; mov edi, AT_FDCWD; mov edx, 0755; xor r10d, r10d; OS_FCHMODAT
    pop rsi; pop rdi
    mov rdx, [rbx + App.envp]; call sys_exec_argv
    mov rdi, r13; OS_CHDIR
    mov rdi, [rbx + App.screen]; mov dword ptr [rdi + ScreenBuffer.force_full], 1
    mov rdi, rbx; xor esi, esi; call App_reload_panes
    add rsp, 32 + PATH_MAX * 2 + 1024 + 256 + 8
    pop r13; pop r12; pop rbx
    ret
