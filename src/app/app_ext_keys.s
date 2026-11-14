# src/app/app_ext.s - Extended App dialog close & keybind routing — app ext keys (split from app_ext.s)

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
.global app_handle_ext_key

# int app_handle_ext_key(App *app, int key, int mods) -> 1 if handled, 0 otherwise
app_handle_ext_key:
    test edx, MOD_CTRL
    jz .Lahek_alt
    cmp esi, 'f'; je .Lahek_srch
    cmp esi, 'z'; je .Lahek_undo
    cmp esi, 'k'; je .Lahek_pal
    cmp esi, '`'; je .Lahek_term
    xor eax, eax
    ret
.Lahek_alt:
    test edx, MOD_ALT
    jz .Lahek_plain
    mov eax, esi
    or eax, 0x20                      # Alt+letter works in either case
    cmp eax, 'p'; je .Lahek_fuz
    cmp eax, 'a'; je .Lahek_chm
    cmp eax, 'v'; je App_cmd_view_mode
    cmp eax, 'i'; je .Lahek_inf
    cmp eax, 's'; je .Lahek_sym
    cmp eax, 'h'; je .Lahek_hrd
    cmp eax, 'd'; je .Lahek_du
    cmp eax, 'b'; je .Lahek_br; cmp eax, 'k'; je App_cmd_packages
    cmp esi, '='; je .Lahek_diff
    cmp esi, KEY_LEFT;  je .Lahek_hb
    cmp esi, KEY_RIGHT; je .Lahek_hf
    jmp .Lahek_no
.Lahek_plain:
    cmp esi, KEY_ENTER
    jne .Lahek_no
    jmp arc_handle_enter
.Lahek_no:
    xor eax, eax
    ret
.Lahek_hb:
    push rbx; mov rbx, rdi
    mov rdi, [rbx + App.active_pane]
    call FilePane_hist_back
    jmp .Lahek_hchk
.Lahek_hf:
    push rbx; mov rbx, rdi
    mov rdi, [rbx + App.active_pane]
    call FilePane_hist_fwd
.Lahek_hchk:
    test eax, eax
    jnz .Lahek_hok
    call i18n_get
    mov rsi, [rax + LangStrings.msg_hist_empty]
    mov rdi, rbx; mov edx, MSG_INFO
    call App_set_status
    mov eax, 1; pop rbx; ret
.Lahek_hok:
    mov rdi, rbx; call App_sync_preview
    mov dword ptr [rbx + App.need_redraw], 1
    mov eax, 1; pop rbx; ret
.Lahek_srch:
    call app_handle_ext_key__new
    ret
.Lahek_undo:
    call App_cmd_undo
    mov eax, 1
    ret
.Lahek_chm:
    call App_cmd_chmod
    mov eax, 1
    ret
.Lahek_inf:
    call App_cmd_info
    mov eax, 1
    ret
.Lahek_sym:
    xor esi, esi
    call App_cmd_link
    mov eax, 1
    ret
.Lahek_hrd:
    mov esi, 1
    call App_cmd_link
    mov eax, 1
    ret
.Lahek_du:
    call du_toggle
    mov eax, 1
    ret
.Lahek_diff:
    jmp app_cmd_diff
.Lahek_term:
    call app_handle_ext_key__term_toggle
    ret
.Lahek_br:
    jmp app_open_bulkrename
.Lahek_pal:
    xor esi, esi
    jmp app_open_fuzzy
.Lahek_fuz:
    mov esi, 1
app_open_fuzzy:
    push rbx
    mov rbx, rdi
    mov rax, [rbx + App.active_pane]
    mov rax, [rax + FilePane.model]
    lea rdx, [rax + DirModel.path]
    call FuzzyDialog_new
    test rax, rax
    jz .Lahek_fdone
    mov [rbx + App.active_dialog], rax
    mov dword ptr [rbx + App.need_redraw], 1
.Lahek_fdone:
    mov eax, 1
    pop rbx
    ret

# app_handle_ext_key step: new (runs on the caller's frame)
app_handle_ext_key__new:
    lea rsp, [rsp - 8]
    push rbx
    mov rbx, rdi
    call SearchDialog_new
    test rax, rax
    jz .Lahek_sdone
    mov [rbx + App.active_dialog], rax
    mov dword ptr [rbx + App.need_redraw], 1
.Lahek_sdone:
    mov eax, 1
    pop rbx
.Lapp_handle_ext_key__new_ret:
    lea rsp, [rsp + 8]
    ret

# app_handle_ext_key step: term_toggle (runs on the caller's frame)
app_handle_ext_key__term_toggle:
    lea rsp, [rsp - 8]
    push rbx
    mov rbx, rdi
    call term_toggle
    mov rdi, rbx
    call App_layout
    mov eax, 1
    pop rbx
.Lapp_handle_ext_key__term_toggle_ret:
    lea rsp, [rsp + 8]
    ret

app_open_bulkrename:
    push rbx
    mov rbx, rdi
    mov rsi, [rbx + App.active_pane]
    call BulkRenameDialog_new
    test rax, rax
    jz .Laob_done
    mov [rbx + App.active_dialog], rax
    mov dword ptr [rbx + App.need_redraw], 1
.Laob_done:
    mov eax, 1
    pop rbx
    ret

app_cmd_diff:
    push rbx; push r12
    sub rsp, 64
    mov rbx, rdi
    mov rax, [rbx + App.active_pane]
    mov rdx, [rbx + App.right_pane]
    cmp rax, rdx
    jne .Lacd_have_other
    mov rdx, [rbx + App.left_pane]
.Lacd_have_other:
    mov rdi, [rax + FilePane.model]
    mov rsi, [rdx + FilePane.model]
    call dir_diff_mark
    mov r12d, eax
    call i18n_get
    mov rsi, [rax + LangStrings.diff_pfx]
    mov rdi, rsp
    call str_copy
    mov edi, r12d
    lea rsi, [rsp + 32]
    call u64_to_dec
    mov rdi, rsp
    lea rsi, [rsp + 32]
    call str_cat
    mov rdi, rbx; mov rsi, rsp; mov edx, MSG_INFO
    call App_set_status
    mov dword ptr [rbx + App.need_redraw], 1
    mov eax, 1
    add rsp, 64; pop r12; pop rbx; ret
