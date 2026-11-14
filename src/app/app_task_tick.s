# App Background Task Controller — app task tick (split from app_task.s)

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .text
.global App_task_tick
.global App_task_show
.global App_task_hide
.global App_task_toggle_pause
.global App_task_cancel
.global App_task_confirm_quit
.global App_task_shutdown
.global App_task_conflict_done

# Internal: void task_finalize(App *app, int64_t result)
task_finalize:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    mov dword ptr [rbx + App.task_active], 0
    mov edi, -1
    call input_set_wake_fd

    mov rdi, [rbx + App.active_dialog]
    test rdi, rdi
    jz .Ltf_reload
    cmp dword ptr [rdi + Dialog.op_tag], OP_PROGRESS
    jne .Ltf_reload
    mov qword ptr [rbx + App.active_dialog], 0
    DELETE_OBJ rdi

.Ltf_reload:
    mov rdi, rbx
    xor esi, esi
    call App_reload_panes

    test r12, r12
    jz .Ltf_ok
    mov rdi, rbx
    mov rsi, r12
    call task_status_errno
    jmp .Ltf_done
.Ltf_ok:
    call i18n_get
    mov rsi, [rax + LangStrings.app_ok_copy]
    mov ecx, [rbx + App.task_snap + TaskSnap.op]
    cmp ecx, TASK_OP_MOVE
    jne .Ltf_chk_del
    mov rsi, [rax + LangStrings.app_ok_move]
.Ltf_chk_del:
    cmp ecx, TASK_OP_DELETE
    jne .Ltf_set
    mov rsi, [rax + LangStrings.app_ok_delete]
.Ltf_set:
    mov rdi, rbx
    mov edx, MSG_OK
    call App_set_status
.Ltf_done:
    mov dword ptr [rbx + App.need_redraw], 1
    add rsp, 8
    pop r12
    pop rbx
    ret

# void App_task_tick(App *app)
# Called once per event-loop iteration: reaps a finished worker, refreshes the snapshot
# every TASK_TICK_MS and opens the ProgressDialog for operations slower than
# TASK_DLG_DELAY_MS (unless the user sent it to background or another dialog is open).
App_task_tick:
    cmp dword ptr [rdi + App.task_active], 0
    je .Ltt_fast
    push rbx
    push r12
    sub rsp, 24
    mov rbx, rdi
    mov rdi, rsp
    call fs_task_poll
    test eax, eax
    jz .Ltt_running
    mov rdi, rbx
    mov rsi, [rsp]
    call task_finalize
    jmp .Ltt_ret

.Ltt_running:
    call os_clock_ms
    mov r12, rax
    sub rax, [rbx + App.task_last_ms]
    cmp rax, TASK_TICK_MS - 20
    jb .Ltt_dialog
    mov [rbx + App.task_last_ms], r12
    lea rdi, [rbx + App.task_snap]
    call fs_task_snapshot
    mov dword ptr [rbx + App.need_redraw], 1

.Ltt_dialog:
    # Check if background worker hit a file conflict
    sub rsp, NAME_MAX + 17
    mov rdi, rsp
    lea rsi, [rsp + NAME_MAX + 1]
    lea rdx, [rsp + NAME_MAX + 9]
    call fs_task_check_conflict
    test eax, eax
    jz .Ltt_no_cfl
    mov rdi, [rbx + App.active_dialog]
    test rdi, rdi
    jz .Ltt_open_cfl
    cmp dword ptr [rdi + Dialog.op_tag], OP_PROGRESS
    jne .Ltt_no_cfl
    mov qword ptr [rbx + App.active_dialog], 0
    DELETE_OBJ rdi
.Ltt_open_cfl:
    mov rdi, rbx
    mov rsi, rsp
    mov rdx, [rsp + NAME_MAX + 1]
    mov rcx, [rsp + NAME_MAX + 9]
    call ConflictDialog_new
    mov [rbx + App.active_dialog], rax
    mov dword ptr [rbx + App.need_redraw], 1
    add rsp, NAME_MAX + 17
    jmp .Ltt_ret
.Ltt_no_cfl:
    add rsp, NAME_MAX + 17

    cmp qword ptr [rbx + App.active_dialog], 0
    jne .Ltt_ret
    cmp dword ptr [rbx + App.task_hidden], 0
    jne .Ltt_ret
    cmp r12, [rbx + App.task_dlg_at]
    jb .Ltt_ret
    mov rdi, rbx
    call App_task_show
.Ltt_ret:
    add rsp, 24
    pop r12
    pop rbx
.Ltt_fast:
    ret

# void App_task_show(App *app) -- open the ProgressDialog (Alt+J, status-bar click, auto)
App_task_show:
    cmp dword ptr [rdi + App.task_active], 0
    je .Ltsh_fast
    cmp qword ptr [rdi + App.active_dialog], 0
    jne .Ltsh_fast
    push rbx
    mov rbx, rdi
    lea rdi, [rbx + App.task_snap]
    call fs_task_snapshot
    mov rdi, rbx
    call ProgressDialog_new
    mov [rbx + App.active_dialog], rax
    mov dword ptr [rbx + App.task_hidden], 0
    mov dword ptr [rbx + App.need_redraw], 1
    pop rbx
.Ltsh_fast:
    ret

# void App_task_hide(App *app) -- send the ProgressDialog to background (task keeps running)
App_task_hide:
    mov dword ptr [rdi + App.task_hidden], 1
    mov esi, DLG_CANCEL
    jmp App_close_dialog

# void App_task_toggle_pause(App *app)
App_task_toggle_pause:
    push rbx
    mov rbx, rdi
    call fs_task_toggle_pause
    mov [rbx + App.task_snap + TaskSnap.paused], eax
    mov dword ptr [rbx + App.need_redraw], 1
    pop rbx
    ret

# void App_task_cancel(App *app)
App_task_cancel:
    push rbx
    mov rbx, rdi
    call fs_task_cancel
    mov dword ptr [rbx + App.task_snap + TaskSnap.canceling], 1
    mov dword ptr [rbx + App.task_snap + TaskSnap.paused], 0
    mov dword ptr [rbx + App.need_redraw], 1
    pop rbx
    ret

# void App_task_confirm_quit(App *app) -- quit requested while a worker runs
App_task_confirm_quit:
    push rbx
    sub rsp, 256
    mov rbx, rdi
    mov rdi, [rbx + App.active_dialog]
    test rdi, rdi
    jnz .Ltcq_ret             # never stack dialogs
    lea rdi, [rbx + App.task_snap]
    mov rsi, rsp
    call ProgressDialog_format_summary
    call i18n_get
    mov rsi, [rax + LangStrings.app_title_quit_task]
    mov rdx, [rax + LangStrings.app_msg_quit_task]
    mov rdi, rbx
    mov rcx, rsp
    mov r8d, OP_QUIT
    call ConfirmDialog_new
    mov [rbx + App.active_dialog], rax
    mov dword ptr [rbx + App.need_redraw], 1
.Ltcq_ret:
    add rsp, 256
    pop rbx
    ret

# void App_task_shutdown(App *app) -- cancel + reap the worker before the UI exits
App_task_shutdown:
    push rbx
    mov rbx, rdi
    call fs_task_shutdown
    mov dword ptr [rbx + App.task_active], 0
    mov edi, -1
    call input_set_wake_fd
    pop rbx
    ret

# void App_task_conflict_done(App *app, int result, ConflictDialog *dlg)
App_task_conflict_done:
    cmp esi, DLG_OK
    jne .Latcd_cancel
    mov edi, [rdx + ConflictDialog.action]
    mov esi, [rdx + ConflictDialog.for_all]
    jmp fs_task_reply_conflict
.Latcd_cancel:
    push rdi
    mov edi, CONFLICT_ACT_SKIP
    mov esi, 1
    call fs_task_reply_conflict
    pop rdi
    jmp App_task_cancel
