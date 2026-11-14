# App Controller Class (Inherits from Object) — app open (split from app.s)

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .text
.global App_open_selected_entry
.global App_reload_panes
.global reload_both_panes

# Helper: app_jump_virtual_entry moved to src/app/app_ext.s

# void App_open_selected_entry(App *this, FilePane *pane)
App_open_selected_entry:
    push rbx
    push r12
    push r13
    sub rsp, PATH_MAX + 16
    call App_open_selected_entry__app
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
    call App_open_selected_entry__build_full_path
    call App_open_selected_entry__check_duoprc_open_ext
.Laos_done:
    add rsp, PATH_MAX + 16
    pop r13
    pop r12
    pop rbx
    ret

# App_open_selected_entry step: app (runs on the caller's frame)
App_open_selected_entry__app:
    lea rsp, [rsp - 8]
    mov rbx, rdi              # app
    mov r12, rsi              # pane

    mov rdi, r12
    call FilePane_get_selected_entry
    test rax, rax
.LApp_open_selected_entry__app_ret:
    lea rsp, [rsp + 8]
    ret

# App_open_selected_entry step: Build full path (runs on the caller's frame)
App_open_selected_entry__build_full_path:
    lea rsp, [rsp - 8]
    mov rdi, [r12 + FilePane.model]
    mov rsi, r13
    call DirModel_entry_name
    mov rdx, rax
    lea rdi, [rsp + 16]
    mov rcx, [r12 + FilePane.model]
    lea rsi, [rcx + DirModel.path]
    mov ecx, PATH_MAX
    call path_join

.LApp_open_selected_entry__build_full_path_ret:
    lea rsp, [rsp + 8]
    ret

# App_open_selected_entry step: Check duoprc open ext cmd rule first (runs on the caller's frame)
App_open_selected_entry__check_duoprc_open_ext:
    lea rsp, [rsp - 8]
    test dword ptr [r13 + FileEntry.flags], (FE_IS_DIR | FE_LINK_DIR)
    jz .Laos_open_file

    mov rcx, [r12 + FilePane.model]
    mov dword ptr [rcx + DirModel.virtual_mode], 0
    mov rdi, r12
    lea rsi, [rsp + 16]
    call FilePane_nav_to
    test rax, rax
    js .Laos_err
    mov rdi, rbx
    call App_sync_preview
    mov dword ptr [rbx + App.need_redraw], 1
    jmp .LApp_open_selected_entry__check_duoprc_open_ext_ret

.Laos_open_file:
    mov rcx, [r12 + FilePane.model]
    cmp dword ptr [rcx + DirModel.virtual_mode], 0
    je .Laos_open_normal
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rsp + 16]
    call app_jump_virtual_entry
    jmp .LApp_open_selected_entry__check_duoprc_open_ext_ret

.Laos_open_normal:
    # Check duoprc `open <ext> <cmd>` rule first
    mov rdi, [r12 + FilePane.model]
    mov rsi, r13
    call DirModel_entry_name
    mov r13, rax              # cur_name
    mov rdi, r13
    call config_lookup_open
    test rax, rax
    jz .Laos_viewer
    mov rdi, rbx
    mov rsi, rax              # tmpl
    mov rdx, r13              # cur_name
    lea rcx, [rsp + 16]  # cur_path
    call App_run_expanded_cmd
    jmp .LApp_open_selected_entry__check_duoprc_open_ext_ret

.Laos_viewer:
    # Open built-in ViewerDialog
    mov rdi, rbx
    lea rsi, [rsp + 16]
    call ViewerDialog_new
    mov [rbx + App.active_dialog], rax
    mov dword ptr [rbx + App.need_redraw], 1
    jmp .LApp_open_selected_entry__check_duoprc_open_ext_ret

.Laos_err:
    mov edi, eax
    call fs_errno_message
    mov rdi, rbx
    mov rsi, rax
    mov edx, MSG_ERR
    call App_set_status

.LApp_open_selected_entry__check_duoprc_open_ext_ret:
    lea rsp, [rsp + 8]
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
