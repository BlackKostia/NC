# src/app/app_attr.s - App commands for File Info, Chmod/Chown, Symlink/Hardlink, Trash & Undo
.intel_syntax noprefix

.include "pal.inc"
.include "classes.inc"

.equ UNDO_TRASH, 3

.section .text
.global App_cmd_info
.global App_cmd_chmod
.global App_cmd_link
.global App_cmd_trash
.global App_cmd_undo
.global App_apply_chmod
.global App_apply_link

.extern FilePane_get_selected_entry
.extern DirModel_entry_name
.extern path_join
.extern get_inactive_pane
.extern App_reload_panes
.extern App_set_status
.extern App_sync_preview
.extern fs_errno_message
.extern i18n_get
.extern InfoDialog_new
.extern ChmodDialog_new
.extern InputDialog_new
.extern trash_move_file
.extern undo_push
.extern undo_pop_and_apply

# Helper: int aa_get_selected_path(App *app, char *out_path, int allow_dotdot)
aa_get_selected_path:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx

    mov rdi, [rbx + App.active_pane]
    call FilePane_get_selected_entry
    test rax, rax
    jz .Laag_none
    test r13d, r13d
    jnz .Laag_ok
    test dword ptr [rax + FileEntry.flags], FE_IS_PARENT
    jnz .Laag_none
.Laag_ok:
    mov rcx, [rbx + App.active_pane]
    mov rdi, [rcx + FilePane.model]
    mov rsi, rax
    call DirModel_entry_name
    mov rdx, rax
    mov rcx, [rbx + App.active_pane]
    mov r8, [rcx + FilePane.model]
    lea rsi, [r8 + DirModel.path]
    mov rdi, r12
    mov ecx, PATH_MAX
    call path_join
    mov eax, 1
    jmp .Laag_ret
.Laag_none:
    xor eax, eax
.Laag_ret:
    pop r13
    pop r12
    pop rbx
    ret

# void App_cmd_info(App *this)
App_cmd_info:
    push rbx
    sub rsp, PATH_MAX + 8
    mov rbx, rdi
    mov rsi, rsp
    xor edx, edx
    call aa_get_selected_path
    test eax, eax
    jz .Laci_done
    mov rdi, rbx
    mov rsi, rsp
    call InfoDialog_new
    test rax, rax
    jz .Laci_done
    mov [rbx + App.active_dialog], rax
    mov dword ptr [rbx + App.need_redraw], 1
.Laci_done:
    add rsp, PATH_MAX + 8
    pop rbx
    ret

# void App_cmd_chmod(App *this)
App_cmd_chmod:
    push rbx
    sub rsp, PATH_MAX + 8
    mov rbx, rdi
    mov rsi, rsp
    xor edx, edx
    call aa_get_selected_path
    test eax, eax
    jz .Lacc_done
    mov rdi, rbx
    mov rsi, rsp
    call ChmodDialog_new
    test rax, rax
    jz .Lacc_done
    mov [rbx + App.active_dialog], rax
    mov dword ptr [rbx + App.need_redraw], 1
.Lacc_done:
    add rsp, PATH_MAX + 8
    pop rbx
    ret

# void App_cmd_link(App *this, int is_hard)
App_cmd_link:
    push rbx
    push r12
    sub rsp, PATH_MAX + 8
    mov rbx, rdi
    mov r12d, esi

    mov rdi, [rbx + App.active_pane]
    call FilePane_get_selected_entry
    test rax, rax
    jz .Lacl_done
    test dword ptr [rax + FileEntry.flags], FE_IS_PARENT
    jnz .Lacl_done

    mov rcx, [rbx + App.active_pane]
    mov rdi, [rcx + FilePane.model]
    mov rsi, rax
    call DirModel_entry_name
    push rax
    mov rdi, rbx
    call get_inactive_pane
    mov rcx, [rax + FilePane.model]
    lea rsi, [rcx + DirModel.path]
    pop rdx
    mov rdi, rsp
    mov ecx, PATH_MAX
    call path_join

    call i18n_get
    mov rsi, [rax + LangStrings.dlg_title_symlink]
    mov r8d, OP_SYMLINK
    test r12d, r12d
    jz .Lacl_open
    mov rsi, [rax + LangStrings.dlg_title_hardlink]
    mov r8d, OP_HARDLINK
.Lacl_open:
    mov rdx, [rax + LangStrings.prm_link_target]
    mov rdi, rbx
    mov rcx, rsp
    call InputDialog_new
    test rax, rax
    jz .Lacl_done
    mov [rbx + App.active_dialog], rax
    mov dword ptr [rbx + App.need_redraw], 1
.Lacl_done:
    add rsp, PATH_MAX + 8
    pop r12
    pop rbx
    ret

# void App_cmd_trash(App *this)
App_cmd_trash:
    push rbx
    sub rsp, PATH_MAX * 3 + 8
    # [rsp+0]          = src_path
    # [rsp+PATH_MAX]   = trash_path
    # [rsp+PATH_MAX*2] = info_path
    mov rbx, rdi
    mov rsi, rsp
    xor edx, edx
    call aa_get_selected_path
    test eax, eax
    jz .Lact_done

    mov rdi, rsp
    mov rsi, [rbx + App.envp]
    lea rdx, [rsp + PATH_MAX]
    lea rcx, [rsp + PATH_MAX * 2]
    call trash_move_file
    test eax, eax
    js .Lact_err

    mov edi, UNDO_TRASH
    mov rsi, rsp
    lea rdx, [rsp + PATH_MAX]
    lea rcx, [rsp + PATH_MAX * 2]
    call undo_push

    mov rdi, rbx
    xor esi, esi
    call App_reload_panes
    mov rdi, rbx
    call App_sync_preview
    call i18n_get
    mov rsi, [rax + LangStrings.msg_trashed]
    mov rdi, rbx
    mov edx, MSG_OK
    call App_set_status
    jmp .Lact_done
.Lact_err:
    mov edi, eax
    call fs_errno_message
    mov rdi, rbx
    mov rsi, rax
    mov edx, MSG_ERR
    call App_set_status
.Lact_done:
    add rsp, PATH_MAX * 3 + 8
    pop rbx
    ret

# void App_cmd_undo(App *this)
App_cmd_undo:
    push rbx
    mov rbx, rdi
    call undo_pop_and_apply
    test eax, eax
    js .Lacu_err
    jz .Lacu_empty
    mov rdi, rbx
    xor esi, esi
    call App_reload_panes
    mov rdi, rbx
    call App_sync_preview
    call i18n_get
    mov rsi, [rax + LangStrings.msg_undone]
    mov rdi, rbx
    mov edx, MSG_OK
    call App_set_status
    pop rbx
    ret
.Lacu_empty:
    call i18n_get
    mov rsi, [rax + LangStrings.msg_undo_empty]
    mov rdi, rbx
    mov edx, MSG_INFO
    call App_set_status
    pop rbx
    ret
.Lacu_err:
    mov edi, eax
    call fs_errno_message
    mov rdi, rbx
    mov rsi, rax
    mov edx, MSG_ERR
    call App_set_status
    pop rbx
    ret

# Helper: int aa_parse_uid_gid(const char *s, int *uid, int *gid)
aa_parse_uid_gid:
    xor eax, eax
.Lapu_u:
    movzx ecx, byte ptr [rdi]
    cmp cl, ':'
    je .Lapu_colon
    sub ecx, '0'
    cmp ecx, 9
    ja .Lapu_err
    imul eax, eax, 10
    add eax, ecx
    inc rdi
    jmp .Lapu_u
.Lapu_colon:
    mov [rsi], eax
    inc rdi
    xor eax, eax
    cmp byte ptr [rdi], 0
    je .Lapu_err
.Lapu_g:
    movzx ecx, byte ptr [rdi]
    test cl, cl
    jz .Lapu_ok
    sub ecx, '0'
    cmp ecx, 9
    ja .Lapu_err
    imul eax, eax, 10
    add eax, ecx
    inc rdi
    jmp .Lapu_g
.Lapu_ok:
    mov [rdx], eax
    xor eax, eax
    ret
.Lapu_err:
    mov eax, -1
    ret

# void App_apply_chmod(App *this, ChmodDialog *dlg)
App_apply_chmod:
    push rbx
    push r12
    sub rsp, 24               # [rsp+0]=uid, [rsp+4]=gid
    mov rbx, rdi
    mov r12, rsi

    mov edi, AT_FDCWD
    lea rsi, [r12 + ChmodDialog.target_path]
    mov edx, [r12 + ChmodDialog.mode]
    xor r10d, r10d
    OS_FCHMODAT
    test rax, rax
    js .Laac_err

    lea rdi, [r12 + ChmodDialog.owner_buf]
    lea rsi, [rsp + 0]
    lea rdx, [rsp + 4]
    call aa_parse_uid_gid
    test eax, eax
    js .Laac_reload
    mov eax, [rsp + 0]
    cmp eax, [r12 + ChmodDialog.uid]
    jne .Laac_chown
    mov eax, [rsp + 4]
    cmp eax, [r12 + ChmodDialog.gid]
    je .Laac_reload
.Laac_chown:
    mov edi, AT_FDCWD
    lea rsi, [r12 + ChmodDialog.target_path]
    mov edx, [rsp + 0]
    mov r10d, [rsp + 4]
    mov r8d, AT_SYMLINK_NOFOLLOW
    OS_FCHOWNAT
.Laac_reload:
    mov rdi, rbx
    xor esi, esi
    call App_reload_panes
    jmp .Laac_done
.Laac_err:
    mov edi, eax
    call fs_errno_message
    mov rdi, rbx
    mov rsi, rax
    mov edx, MSG_ERR
    call App_set_status
.Laac_done:
    add rsp, 24
    pop r12
    pop rbx
    ret

# void App_apply_link(App *this, InputDialog *dlg, int is_hard)
App_apply_link:
    push rbx
    push r12
    push r13
    sub rsp, PATH_MAX + 8
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx

    mov rdi, rbx
    mov rsi, rsp
    xor edx, edx
    call aa_get_selected_path
    test eax, eax
    jz .Laal_done

    test r13d, r13d
    jnz .Laal_hard
    mov rdi, rsp              # oldpath (target)
    mov esi, AT_FDCWD
    lea rdx, [r12 + InputDialog.buf]
    OS_SYMLINKAT
    jmp .Laal_chk
.Laal_hard:
    mov edi, AT_FDCWD
    mov rsi, rsp
    mov edx, AT_FDCWD
    lea r10, [r12 + InputDialog.buf]
    xor r8d, r8d
    OS_LINKAT
.Laal_chk:
    test rax, rax
    js .Laal_err
    mov rdi, rbx
    xor esi, esi
    call App_reload_panes
    jmp .Laal_done
.Laal_err:
    mov edi, eax
    call fs_errno_message
    mov rdi, rbx
    mov rsi, rax
    mov edx, MSG_ERR
    call App_set_status
.Laal_done:
    add rsp, PATH_MAX + 8
    pop r13
    pop r12
    pop rbx
    ret
