# App Background Task Controller
# Turns the active pane selection into a TaskJob, starts the fork worker (src/fs/task.s),
# drives periodic snapshots, the deferred ProgressDialog, pause / cancel / hide actions,
# quit confirmation and final pane reload + EN/UA status reporting.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .text
.global App_task_start
.global App_task_tick
.global App_task_show
.global App_task_hide
.global App_task_toggle_pause
.global App_task_cancel
.global App_task_confirm_quit
.global App_task_shutdown
.global App_task_conflict_done

# Internal: void task_status_errno(App *app, int64_t neg_errno)
task_status_errno:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    mov edi, r12d
    call fs_errno_message
    mov edx, MSG_ERR
    cmp r12, -ECANCELED
    jne .Ltse_set
    mov edx, MSG_WARN
.Ltse_set:
    mov rdi, rbx
    mov rsi, rax
    call App_set_status
    add rsp, 8
    pop r12
    pop rbx
    ret

# void App_task_start(App *app, int op, const char *dst_input)
# Snapshots the selection (marked entries, else cursor entry) of the active pane into a
# heap TaskJob and launches it in the background. Errors are reported in the StatusBar.
App_task_start:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 80               # [0]=sel_count [8]=names_len [16]=job [24]=idx [32..79]=FileStat
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx

    call fs_task_is_active
    test eax, eax
    jz .Lats_collect
    mov rdi, rbx
    mov rsi, -EBUSY
    call task_status_errno
    jmp .Lats_ret

.Lats_collect:
    cmp r12d, TASK_OP_DELETE
    je .Lats_sel
    test r13, r13
    jz .Lats_ret
    cmp byte ptr [r13], 0     # empty destination: nothing to do (never resolve against CWD)
    je .Lats_ret
.Lats_sel:
    mov r14, [rbx + App.active_pane]
    mov r15, [r14 + FilePane.model]
    mov rdi, r15
    xor esi, esi
    call DirModel_count_selected
    mov [rsp], rax
    mov qword ptr [rsp + 8], 0
    test rax, rax
    jnz .Lats_sum_multi

    # Single cursor entry
    mov rdi, r14
    call FilePane_get_selected_entry
    test rax, rax
    jz .Lats_ret
    test dword ptr [rax + FileEntry.flags], FE_IS_PARENT
    jnz .Lats_parent
    mov rdi, r15
    mov rsi, rax
    call DirModel_entry_name
    mov rdi, rax
    call str_len
    inc rax
    mov [rsp + 8], rax
    mov qword ptr [rsp], 1
    jmp .Lats_alloc

.Lats_sum_multi:
    xor ecx, ecx
    mov [rsp + 24], rcx
.Lats_sum_loop:
    mov rcx, [rsp + 24]
    cmp rcx, [r15 + DirModel.count]
    jae .Lats_alloc
    mov rdi, r15
    mov rsi, rcx
    call DirModel_get_entry
    test dword ptr [rax + FileEntry.flags], FE_SELECTED
    jz .Lats_sum_next
    mov rdi, r15
    mov rsi, rax
    call DirModel_entry_name
    mov rdi, rax
    call str_len
    inc rax
    add [rsp + 8], rax
.Lats_sum_next:
    inc qword ptr [rsp + 24]
    jmp .Lats_sum_loop

.Lats_alloc:
    mov rdi, [rsp + 8]
    add rdi, TaskJob._size + 16
    call mem_alloc
    test rax, rax
    jz .Lats_nomem
    mov [rsp + 16], rax
    mov r14, rax              # job (pane no longer needed except for single-entry refetch)
    mov [r14 + TaskJob.op], r12d
    mov rax, [rsp]
    mov [r14 + TaskJob.count], eax
    lea rdi, [r14 + TaskJob.src_dir]
    lea rsi, [r15 + DirModel.path]
    mov edx, PATH_MAX
    call str_copy

    cmp r12d, TASK_OP_DELETE
    je .Lats_names
    lea rdi, [r14 + TaskJob.dst]
    mov rsi, r13
    mov edx, PATH_MAX
    call str_copy
    mov dword ptr [r14 + TaskJob.join_dst], 1
    cmp qword ptr [rsp], 1
    jne .Lats_names
    mov rdi, r15
    xor esi, esi
    call DirModel_count_selected
    test rax, rax
    jnz .Lats_names           # one *marked* item: always dst/<name> (batch semantics)
    # Single cursor item: join only when the destination is an existing directory
    mov edi, AT_FDCWD
    mov rsi, r13
    lea rdx, [rsp + 32]
    mov ecx, 1
    call os_statat
    xor ecx, ecx
    test rax, rax
    js .Lats_join_set
    mov eax, [rsp + 32 + FileStat.mode]
    and eax, S_IFMT
    cmp eax, S_IFDIR
    sete cl
.Lats_join_set:
    mov [r14 + TaskJob.join_dst], ecx

.Lats_names:
    lea rax, [r14 + TaskJob.names]
    mov [rsp + 24], rax       # write cursor
    mov rdi, r15
    xor esi, esi
    call DirModel_count_selected
    test rax, rax
    jnz .Lats_fill_multi

    mov rax, [rbx + App.active_pane]
    mov rdi, rax
    call FilePane_get_selected_entry
    mov rdi, r15
    mov rsi, rax
    call DirModel_entry_name
    mov rdi, [rsp + 24]
    mov rsi, rax
    mov rdx, [rsp + 8]
    call str_copy
    jmp .Lats_launch

.Lats_fill_multi:
    xor r13d, r13d            # idx (dst_input already copied into the job)
.Lats_fill_loop:
    cmp r13, [r15 + DirModel.count]
    jae .Lats_launch
    mov rdi, r15
    mov rsi, r13
    call DirModel_get_entry
    test dword ptr [rax + FileEntry.flags], FE_SELECTED
    jz .Lats_fill_next
    mov rdi, r15
    mov rsi, rax
    call DirModel_entry_name
    mov rdi, rax
    push rax
    sub rsp, 8
    call str_len
    add rsp, 8
    pop rsi
    lea rdx, [rax + 1]
    mov rdi, [rsp + 24]
    add [rsp + 24], rdx
    call str_copy
.Lats_fill_next:
    inc r13
    jmp .Lats_fill_loop

.Lats_launch:
    mov rax, [rsp + 8]
    mov [r14 + TaskJob.names_len], rax
    mov rdi, r14
    call fs_task_start
    mov r13, rax
    mov rdi, r14
    call mem_free             # the worker owns a private copy now
    test r13, r13
    jns .Lats_started
    mov rdi, rbx
    mov rsi, r13
    call task_status_errno
    jmp .Lats_ret

.Lats_started:
    lea rdi, [rbx + App.task_snap]
    mov esi, TaskSnap._size
    call mem_zero
    mov [rbx + App.task_snap + TaskSnap.op], r12d
    mov dword ptr [rbx + App.task_snap + TaskSnap.phase], TASK_PHASE_SCAN
    mov qword ptr [rbx + App.task_snap + TaskSnap.eta_sec], -1
    mov dword ptr [rbx + App.task_active], 1
    mov dword ptr [rbx + App.task_hidden], 0
    mov qword ptr [rbx + App.task_last_ms], 0
    call os_clock_ms
    add rax, TASK_DLG_DELAY_MS
    mov [rbx + App.task_dlg_at], rax
    call fs_task_wake_fd
    mov edi, eax
    call input_set_wake_fd
    mov dword ptr [rbx + App.need_redraw], 1
    jmp .Lats_ret

.Lats_parent:
    call i18n_get
    mov rsi, [rax + LangStrings.app_err_parent]
    mov rdi, rbx
    mov edx, MSG_WARN
    call App_set_status
    jmp .Lats_ret
.Lats_nomem:
    mov rdi, rbx
    mov rsi, -ENOMEM
    call task_status_errno
.Lats_ret:
    add rsp, 80
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

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
