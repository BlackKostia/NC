# App Controller Class (Inherits from Object) — app toggles (split from app.s)

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .text
.global App_cmd_toggle_preview
.global App_cmd_toggle_hidden
.global App_cmd_cycle_theme
.global App_cmd_toggle_lang
.global App_cmd_quit
.global App_dispatch_f_action

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
