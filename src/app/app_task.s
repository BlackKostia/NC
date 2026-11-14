# App Background Task Controller
# Turns the active pane selection into a TaskJob, starts the fork worker (src/fs/task.s),
# drives periodic snapshots, the deferred ProgressDialog, pause / cancel / hide actions,
# quit confirmation and final pane reload + EN/UA status reporting.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .text
.global task_status_errno
.global App_task_start

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
    call App_task_start__fs_task_active
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
    call App_task_start__count_selected
    jnz .Lats_sum_multi

    # Single cursor entry
    mov rdi, r14
    call FilePane_get_selected_entry
    test rax, rax
    jz .Lats_ret
    test dword ptr [rax + FileEntry.flags], FE_IS_PARENT
    jnz .Lats_parent
    call App_task_start__entry_name
    jmp .Lats_alloc

.Lats_sum_multi:
    call App_task_start__get_entry
.Lats_alloc:
    mov rdi, [rsp + 8]
    add rdi, TaskJob._size + 16
    call mem_alloc
    test rax, rax
    jz .Lats_nomem
    call App_task_start__single_cursor_item_join
    call App_task_start__write_cursor
    call App_task_start__worker_owns_private_copy
    jns .Lats_started
    mov rdi, rbx
    mov rsi, r13
    call task_status_errno
    jmp .Lats_ret

.Lats_started:
    call App_task_start__mem_zero
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

# App_task_start step: fs_task_is_active (runs on the caller's frame)
App_task_start__fs_task_active:
    lea rsp, [rsp - 8]
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx

    call fs_task_is_active
    test eax, eax
.LApp_task_start__fs_task_active_ret:
    lea rsp, [rsp + 8]
    ret

# App_task_start step: count_selected (runs on the caller's frame)
App_task_start__count_selected:
    lea rsp, [rsp - 8]
    mov r14, [rbx + App.active_pane]
    mov r15, [r14 + FilePane.model]
    mov rdi, r15
    xor esi, esi
    call DirModel_count_selected
    mov [rsp + 16], rax
    mov qword ptr [rsp + 8 + 16], 0
    test rax, rax
.LApp_task_start__count_selected_ret:
    lea rsp, [rsp + 8]
    ret

# App_task_start step: entry_name (runs on the caller's frame)
App_task_start__entry_name:
    lea rsp, [rsp - 8]
    mov rdi, r15
    mov rsi, rax
    call DirModel_entry_name
    mov rdi, rax
    call str_len
    inc rax
    mov [rsp + 8 + 16], rax
    mov qword ptr [rsp + 16], 1
.LApp_task_start__entry_name_ret:
    lea rsp, [rsp + 8]
    ret

# App_task_start step: get_entry (runs on the caller's frame)
App_task_start__get_entry:
    lea rsp, [rsp - 8]
    xor ecx, ecx
    mov [rsp + 24 + 16], rcx
.Lats_sum_loop:
    mov rcx, [rsp + 24 + 16]
    cmp rcx, [r15 + DirModel.count]
    jae .LApp_task_start__get_entry_ret
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
    add [rsp + 8 + 16], rax
.Lats_sum_next:
    inc qword ptr [rsp + 24 + 16]
    jmp .Lats_sum_loop

.LApp_task_start__get_entry_ret:
    lea rsp, [rsp + 8]
    ret

# App_task_start step: Single cursor item join only when the destination is an existing directory (runs on the caller's frame)
App_task_start__single_cursor_item_join:
    lea rsp, [rsp - 8]
    mov [rsp + 16 + 16], rax
    mov r14, rax              # job (pane no longer needed except for single-entry refetch)
    mov [r14 + TaskJob.op], r12d
    mov rax, [rsp + 16]
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
    cmp qword ptr [rsp + 16], 1
    jne .Lats_names
    mov rdi, r15
    xor esi, esi
    call DirModel_count_selected
    test rax, rax
    jnz .Lats_names           # one *marked* item: always dst/<name> (batch semantics)
    # Single cursor item: join only when the destination is an existing directory
    mov edi, AT_FDCWD
    mov rsi, r13
    lea rdx, [rsp + 32 + 16]
    mov ecx, 1
    call os_statat
    xor ecx, ecx
    test rax, rax
    js .Lats_join_set
    mov eax, [rsp + 32 + FileStat.mode + 16]
    and eax, S_IFMT
    cmp eax, S_IFDIR
    sete cl
.Lats_join_set:
    mov [r14 + TaskJob.join_dst], ecx

.Lats_names:
.LApp_task_start__single_cursor_item_join_ret:
    lea rsp, [rsp + 8]
    ret

# App_task_start step: write cursor (runs on the caller's frame)
App_task_start__write_cursor:
    lea rsp, [rsp - 8]
    lea rax, [r14 + TaskJob.names]
    mov [rsp + 24 + 16], rax  # write cursor
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
    mov rdi, [rsp + 24 + 16]
    mov rsi, rax
    mov rdx, [rsp + 8 + 16]
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
    mov rdi, [rsp + 24 + 16]
    add [rsp + 24 + 16], rdx
    call str_copy
.Lats_fill_next:
    inc r13
    jmp .Lats_fill_loop

.Lats_launch:
.LApp_task_start__write_cursor_ret:
    lea rsp, [rsp + 8]
    ret

# App_task_start step: the worker owns private copy now (runs on the caller's frame)
App_task_start__worker_owns_private_copy:
    lea rsp, [rsp - 8]
    mov rax, [rsp + 8 + 16]
    mov [r14 + TaskJob.names_len], rax
    mov rdi, r14
    call fs_task_start
    mov r13, rax
    mov rdi, r14
    call mem_free             # the worker owns a private copy now
    test r13, r13
.LApp_task_start__worker_owns_private_copy_ret:
    lea rsp, [rsp + 8]
    ret

# App_task_start step: mem_zero (runs on the caller's frame)
App_task_start__mem_zero:
    lea rsp, [rsp - 8]
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
.LApp_task_start__mem_zero_ret:
    lea rsp, [rsp + 8]
    ret
