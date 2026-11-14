# App Controller Class (Inherits from Object) — app keys (split from app.s)

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .text
.global handle_key

# Internal: handle key event
handle_key:
    # rdi=app, rsi=evt
    push rbx
    push r12
    call handle_key__modal_dialog_intercepts_keys
    jz .Lhk_no_dlg
    mov rsi, r12
    VCALL WidgetVtbl.on_key
    jmp .Lhk_done

.Lhk_no_dlg:
    call handle_key__configurable_keybinds_from_duopr
    jl .Lhk_default_keys
    mov rdi, rbx
    mov esi, eax
    call App_dispatch_action
    jmp .Lhk_done

.Lhk_default_keys:
    call handle_key__term_key
    jne .Lhk_tok_chk
    mov rdi, rbx
    call App_layout
    jmp .Lhk_done
.Lhk_tok_chk:
    test eax, eax
    jnz .Lhk_done
    call handle_key__app_handle_ext_key
    jnz .Lhk_done
    mov eax, edx
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
    cmp eax, 't'; je .Lhk_tab_new
    cmp eax, 'w'; je .Lhk_tab_close
    cmp eax, 'd'; je .Lhk_bookmarks
    jmp .Lhk_pane

.Lhk_chk_alt:
    test ecx, MOD_ALT
    jz .Lhk_plain
    or eax, 0x20                      # Alt+letter in either case
    cmp eax, 't'; je .Lhk_theme
    cmp eax, 'l'; je .Lhk_lang
    cmp eax, 'j'; je .Lhk_tasks
    cmp eax, 'u'; je .Lhk_usermenu
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
    cmp eax, 'z';        je .Lhk_frecency
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
    call handle_key__apply_filter
    jmp .Lhk_done

.Lhk_cancel_stream:
    call handle_key__cancel_load
    jmp .Lhk_done

.Lhk_refresh:
    call handle_key__reload_both_panes
    jmp .Lhk_done

.Lhk_quit:
    mov rdi, rbx; call App_cmd_quit; jmp .Lhk_done
.Lhk_prev:
    mov rdi, rbx; call App_cmd_toggle_preview; jmp .Lhk_done
.Lhk_hidden:
    mov rdi, rbx; call App_cmd_toggle_hidden; jmp .Lhk_done
.Lhk_theme:
    mov rdi, rbx; call App_cmd_cycle_theme; jmp .Lhk_done
.Lhk_lang:
    mov rdi, rbx; call App_cmd_toggle_lang; jmp .Lhk_done
.Lhk_filter:
    mov rdi, rbx; call App_cmd_start_filter; jmp .Lhk_done
.Lhk_newfile:
    mov rdi, rbx; call App_cmd_newfile; jmp .Lhk_done
.Lhk_goto:
    mov rdi, rbx; call App_cmd_goto; jmp .Lhk_done
.Lhk_shell:
    mov rdi, rbx; call App_cmd_shell; jmp .Lhk_done
.Lhk_del:
    mov rdi, rbx; call App_cmd_trash; jmp .Lhk_done
.Lhk_tasks:
    mov rdi, rbx; call App_task_show; jmp .Lhk_done
.Lhk_usermenu:
    mov rdi, rbx; call App_cmd_usermenu; jmp .Lhk_done

.Lhk_tab_new:
    mov rdi, [rbx + App.active_pane]
    call FilePane_tab_new
    mov dword ptr [rbx + App.need_redraw], 1
    jmp .Lhk_done

.Lhk_tab_close:
    mov rdi, [rbx + App.active_pane]
    mov esi, -1
    call FilePane_tab_close
    test eax, eax
    jnz .Lhk_tc_ok
    call i18n_get
    mov rsi, [rax + LangStrings.msg_tab_last]
    mov rdi, rbx
    mov edx, MSG_WARN
    call App_set_status
    jmp .Lhk_done
.Lhk_tc_ok:
    mov rdi, rbx
    call App_sync_preview
    mov dword ptr [rbx + App.need_redraw], 1
    jmp .Lhk_done

.Lhk_bookmarks:
    mov rdi, rbx
    xor esi, esi
    call BookmarkDialog_new
    mov [rbx + App.active_dialog], rax
    mov dword ptr [rbx + App.need_redraw], 1
    jmp .Lhk_done

.Lhk_frecency:
    call handle_key__new
.Lhk_done:
    pop r12
    pop rbx
    ret

# handle_key step: Modal dialog intercepts keys first (runs on the caller's frame)
handle_key__modal_dialog_intercepts_keys:
    lea rsp, [rsp - 8]
    mov rbx, rdi
    mov r12, rsi

    # Modal dialog intercepts keys first
    mov rdi, [rbx + App.active_dialog]
    test rdi, rdi
.Lhandle_key__modal_dialog_intercepts_keys_ret:
    lea rsp, [rsp + 8]
    ret

# handle_key step: Configurable keybinds from duoprc (runs on the caller's frame)
handle_key__configurable_keybinds_from_duopr:
    lea rsp, [rsp - 8]
    mov eax, [r12 + Event.lat]        # hotkeys by key position: any layout (*.layout files)
    mov ecx, [r12 + Event.mods]

    # Configurable keybinds from duoprc
    push rax
    push rcx
    mov edi, eax
    mov esi, ecx
    call config_lookup_bind
    pop rcx
    pop rdx                   # rdx = saved key
    cmp eax, 0
.Lhandle_key__configurable_keybinds_from_duopr_ret:
    lea rsp, [rsp + 8]
    ret

# handle_key step: term_on_key (runs on the caller's frame)
handle_key__term_key:
    lea rsp, [rsp - 8]
    push rdx
    push rcx
    mov rdi, rbx
    mov rsi, r12
    call term_on_key
    pop rcx
    pop rdx
    cmp eax, 2
.Lhandle_key__term_key_ret:
    lea rsp, [rsp + 8]
    ret

# handle_key step: app_handle_ext_key (runs on the caller's frame)
handle_key__app_handle_ext_key:
    lea rsp, [rsp - 8]
    push rdx
    push rcx
    mov rdi, rbx
    mov esi, edx
    mov edx, ecx
    call app_handle_ext_key
    pop rcx
    pop rdx
    test eax, eax
.Lhandle_key__app_handle_ext_key_ret:
    lea rsp, [rsp + 8]
    ret

# handle_key step: apply_filter (runs on the caller's frame)
handle_key__apply_filter:
    lea rsp, [rsp - 8]
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
.Lhandle_key__apply_filter_ret:
    lea rsp, [rsp + 8]
    ret

# handle_key step: cancel_load (runs on the caller's frame)
handle_key__cancel_load:
    lea rsp, [rsp - 8]
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
.Lhandle_key__cancel_load_ret:
    lea rsp, [rsp + 8]
    ret

# handle_key step: reload_both_panes (runs on the caller's frame)
handle_key__reload_both_panes:
    lea rsp, [rsp - 8]
    mov rdi, rbx
    xor esi, esi
    call reload_both_panes
    call i18n_get
    mov rsi, [rax + LangStrings.app_ok_refresh]
    mov rdi, rbx
    mov edx, MSG_INFO
    call App_set_status
.Lhandle_key__reload_both_panes_ret:
    lea rsp, [rsp + 8]
    ret

# handle_key step: new (runs on the caller's frame)
handle_key__new:
    lea rsp, [rsp - 8]
    mov rdi, rbx
    mov esi, 1
    call BookmarkDialog_new
    mov [rbx + App.active_dialog], rax
    mov dword ptr [rbx + App.need_redraw], 1
    jmp .Lhandle_key__new_ret

.Lhandle_key__new_ret:
    lea rsp, [rsp + 8]
    ret
