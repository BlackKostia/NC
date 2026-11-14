# Background Task Worker: fork-isolated copy / move / delete with shared-memory progress — task control (split from task.s)

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"
.if NAME_MAX != 256 || PATH_MAX != 4096
    .error "TaskShared/TaskSnap/TaskJob layouts in include/types.inc assume NAME_MAX=256, PATH_MAX=4096"
.endif
.if TaskShared._size > TASK_SHM_SIZE
    .error "TaskShared must fit in one shared page"
.endif
.equ TW_SRC,   0
.equ TW_DST,   PATH_MAX
.equ TW_ST,    PATH_MAX * 2
.equ TW_DEV,   PATH_MAX * 2 + 48
.equ TW_CUM,   PATH_MAX * 2 + 56
.equ TW_RES,   PATH_MAX * 2 + 64
.equ TW_FRAME, PATH_MAX * 2 + 80

.section .bss
g_task_shm:       .space 8     # UI: TaskShared* of the running worker
g_task_pause_ms:  .space 8     # accumulated paused time
g_task_pause_at:  .space 8     # start of the current pause
g_task_cancel_at: .space 8     # when cancel was requested (0 = none)
g_task_pid:       .space 4
g_task_paused:    .space 4

.section .text
.global fs_task_poll
.global fs_task_snapshot
.global fs_task_toggle_pause
.global fs_task_cancel
.global fs_task_shutdown
.global g_task_shm
.global g_task_pause_ms
.global g_task_cancel_at
.global g_task_pid
.global g_task_paused

# Internal: release UI-side resources of a reaped worker (preserves rax)
task_release:
    push rax
    mov edi, [rip + g_task_wake_fd]
    OS_CLOSE
    mov rdi, [rip + g_task_shm]
    mov esi, TASK_SHM_SIZE
    OS_MUNMAP
    xor eax, eax
    mov [rip + g_task_pid], eax
    mov [rip + g_task_shm], rax
    mov [rip + g_task_paused], eax
    mov [rip + g_task_cancel_at], rax
    mov dword ptr [rip + g_task_wake_fd], -1
    pop rax
    ret

# int fs_task_poll(int64_t *out_result)
# Non-blocking. Returns 1 and stores 0 / -errno / -ECANCELED once the worker was reaped,
# else 0. While a cancel is pending it re-sends SIGTERM, closing the window where the
# worker checked the flag just before entering a blocking syscall.
fs_task_poll:
    push rbx
    push r12
    sub rsp, 24                       # [rsp] = wait status
    mov r12, rdi
    xor ebx, ebx
    cmp dword ptr [rip + g_task_pid], 0
    je .Ltp_ret
.Ltp_wait:
    movsxd rdi, dword ptr [rip + g_task_pid]
    mov rsi, rsp
    mov edx, WNOHANG
    xor r10d, r10d
    OS_WAIT4
    cmp rax, -EINTR
    je .Ltp_wait
    cmp rax, -ECHILD
    je .Ltp_reaped
    test rax, rax
    jle .Ltp_pending
.Ltp_reaped:
    mov rcx, [rip + g_task_shm]
    mov rax, -EIO                     # worker died without publishing a result
    cmp dword ptr [rcx + TaskShared.phase], TASK_PHASE_DONE
    jne .Ltp_have
    mov rax, [rcx + TaskShared.result]
.Ltp_have:
    call task_release
    mov [r12], rax
    mov ebx, 1
    jmp .Ltp_ret
.Ltp_pending:
    cmp qword ptr [rip + g_task_cancel_at], 0
    je .Ltp_ret
    movsxd rdi, dword ptr [rip + g_task_pid]
    mov esi, SIGTERM
    OS_KILL
.Ltp_ret:
    mov eax, ebx
    add rsp, 24
    pop r12; pop rbx; ret

# void fs_task_snapshot(TaskSnap *out)
# Copies counters, computes percent / speed / ETA (pauses excluded) and a torn-free name.
fs_task_snapshot:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, [rip + g_task_shm]
    test r12, r12
    jz .Lsn_ret

    call fs_task_snapshot__seqlock_read_current_item
    # Metric: bytes for copy/move when known, else entries
    call fs_task_snapshot__metric_bytes_copy_move
    # Speed & ETA once at least 500 ms of active time elapsed
    call fs_task_snapshot__speed_eta_once_least
.Lsn_ret:
    pop r13
    pop r12; pop rbx; ret

# fs_task_snapshot step: Seqlock read of the current item name (runs on the caller's frame)
fs_task_snapshot__seqlock_read_current_item:
    lea rsp, [rsp - 8]
    mov rax, [r12 + TaskShared.total_bytes]
    mov [rbx + TaskSnap.total_bytes], rax
    mov rax, [r12 + TaskShared.total_files]
    mov [rbx + TaskSnap.total_files], rax
    mov rax, [r12 + TaskShared.done_bytes]
    mov [rbx + TaskSnap.done_bytes], rax
    mov rax, [r12 + TaskShared.done_files]
    mov [rbx + TaskSnap.done_files], rax
    mov eax, [r12 + TaskShared.phase]
    mov [rbx + TaskSnap.phase], eax
    mov eax, [rip + g_task_op]
    mov [rbx + TaskSnap.op], eax
    mov eax, [rip + g_task_paused]
    mov [rbx + TaskSnap.paused], eax
    xor eax, eax
    cmp qword ptr [rip + g_task_cancel_at], 0
    setne al
    mov [rbx + TaskSnap.canceling], eax

    # Seqlock read of the current item name (bounded retries)
    mov r13d, 8
.Lsn_name:
    mov eax, [r12 + TaskShared.seq]
    test eax, 1
    jnz .Lsn_name_retry
    push rax
    sub rsp, 8
    lea rdi, [rbx + TaskSnap.cur_name]
    lea rsi, [r12 + TaskShared.cur_name]
    mov edx, NAME_MAX
    call mem_copy
    add rsp, 8
    pop rax
    cmp eax, [r12 + TaskShared.seq]
    je .Lsn_name_ok
.Lsn_name_retry:
    dec r13d
    jnz .Lsn_name
.Lsn_name_ok:
    mov byte ptr [rbx + TaskSnap.cur_name + NAME_MAX - 1], 0

    # Active elapsed time (pauses excluded)
    call os_clock_ms
    mov rcx, rax
    sub rax, [rip + g_task_start_ms]
    sub rax, [rip + g_task_pause_ms]
    cmp dword ptr [rip + g_task_paused], 0
    je .Lsn_el
    mov rdx, rcx
    sub rdx, [rip + g_task_pause_at]
    sub rax, rdx
.Lsn_el:
    test rax, rax
    jns .Lsn_el_ok
    xor eax, eax
.Lsn_el_ok:
    mov [rbx + TaskSnap.elapsed_ms], rax
    mov r13, rax

.Lfs_task_snapshot__seqlock_read_current_item_ret:
    lea rsp, [rsp + 8]
    ret

# fs_task_snapshot step: Metric bytes for copy move when known else entries (runs on the caller's frame)
fs_task_snapshot__metric_bytes_copy_move:
    lea rsp, [rsp - 8]
    mov r8, [rbx + TaskSnap.done_files]
    mov r9, [rbx + TaskSnap.total_files]
    cmp dword ptr [rbx + TaskSnap.op], TASK_OP_DELETE
    je .Lsn_metric
    cmp qword ptr [rbx + TaskSnap.total_bytes], 0
    je .Lsn_metric
    mov r8, [rbx + TaskSnap.done_bytes]
    mov r9, [rbx + TaskSnap.total_bytes]
.Lsn_metric:
    cmp r8, r9
    jbe .Lsn_clamped
    mov r8, r9
.Lsn_clamped:
    xor eax, eax
    test r9, r9
    jz .Lsn_pct
    cmp dword ptr [rbx + TaskSnap.phase], TASK_PHASE_SCAN
    je .Lsn_pct
    mov rax, r8
    mov ecx, 100
    mul rcx
    div r9
.Lsn_pct:
    mov [rbx + TaskSnap.percent], eax

.Lfs_task_snapshot__metric_bytes_copy_move_ret:
    lea rsp, [rsp + 8]
    ret

# fs_task_snapshot step: Speed ETA once at least ms of active time elapsed (runs on the caller's frame)
fs_task_snapshot__speed_eta_once_least:
    lea rsp, [rsp - 8]
    mov qword ptr [rbx + TaskSnap.speed_bps], 0
    mov qword ptr [rbx + TaskSnap.eta_sec], -1
    cmp r13, 500
    jb .Lfs_task_snapshot__speed_eta_once_least_ret
    mov rax, [rbx + TaskSnap.done_bytes]
    mov ecx, 1000
    mul rcx
    cmp rdx, r13
    jae .Lsn_eta
    div r13
    mov [rbx + TaskSnap.speed_bps], rax
.Lsn_eta:
    cmp dword ptr [rbx + TaskSnap.phase], TASK_PHASE_RUN
    jne .Lfs_task_snapshot__speed_eta_once_least_ret
    test r8, r8
    jz .Lfs_task_snapshot__speed_eta_once_least_ret
    mov rax, r9
    sub rax, r8                       # remaining
    mul r13                           # remaining * elapsed_ms
    cmp rdx, r8
    jae .Lfs_task_snapshot__speed_eta_once_least_ret
    div r8                            # -> remaining ms
    add rax, 999
    xor edx, edx
    mov ecx, 1000
    div rcx
    mov [rbx + TaskSnap.eta_sec], rax
.Lfs_task_snapshot__speed_eta_once_least_ret:
    lea rsp, [rsp + 8]
    ret

# Internal: void task_resume(int64_t now_ms) -- SIGCONT a paused worker, account pause time
task_resume:
    cmp dword ptr [rip + g_task_paused], 0
    je 1f
    sub rdi, [rip + g_task_pause_at]
    add [rip + g_task_pause_ms], rdi
    mov dword ptr [rip + g_task_paused], 0
    movsxd rdi, dword ptr [rip + g_task_pid]
    mov esi, SIGCONT
    OS_KILL
1:  ret

# int fs_task_toggle_pause(void) -> new paused state (0/1)
fs_task_toggle_pause:
    push rbx
    cmp dword ptr [rip + g_task_pid], 0
    je .Ltt_state
    cmp qword ptr [rip + g_task_cancel_at], 0
    jne .Ltt_state                    # canceling: the worker must keep running to stop
    call os_clock_ms
    mov rbx, rax
    cmp dword ptr [rip + g_task_paused], 0
    jne .Ltt_resume
    movsxd rdi, dword ptr [rip + g_task_pid]
    mov esi, SIGSTOP
    OS_KILL
    test rax, rax
    js .Ltt_state
    mov [rip + g_task_pause_at], rbx
    mov dword ptr [rip + g_task_paused], 1
    jmp .Ltt_state
.Ltt_resume:
    mov rdi, rbx
    call task_resume
.Ltt_state:
    mov eax, [rip + g_task_paused]
    pop rbx
    ret

# void fs_task_cancel(void) -- cooperative flag + SIGCONT + SIGTERM (interrupts blocking I/O)
fs_task_cancel:
    push rbx
    cmp dword ptr [rip + g_task_pid], 0
    je .Ltc_ret
    mov rax, [rip + g_task_shm]
    mov dword ptr [rax + TaskShared.cancel], 1
    call os_clock_ms
    mov rbx, rax
    cmp qword ptr [rip + g_task_cancel_at], 0
    jne .Ltc_resume
    mov [rip + g_task_cancel_at], rax
.Ltc_resume:
    mov rdi, rbx
    call task_resume
    movsxd rdi, dword ptr [rip + g_task_pid]
    mov esi, SIGTERM
    OS_KILL
.Ltc_ret:
    pop rbx
    ret

# void fs_task_shutdown(void)
# Cancels and reaps the worker before the UI exits (SIGKILL after TASK_KILL_GRACE_MS),
# so no orphan keeps writing files once Duop has quit.
fs_task_shutdown:
    push rbx
    push r12
    sub rsp, 24
    cmp dword ptr [rip + g_task_pid], 0
    je .Lsd_ret
    call fs_task_cancel
    call os_clock_ms
    lea r12, [rax + TASK_KILL_GRACE_MS]
.Lsd_loop:
    mov rdi, rsp
    call fs_task_poll
    test eax, eax
    jnz .Lsd_ret
    call os_clock_ms
    cmp rax, r12
    jb .Lsd_sleep
    movsxd rdi, dword ptr [rip + g_task_pid]
    mov esi, SIGKILL
    OS_KILL
    mov r12, -1
.Lsd_sleep:
    mov edi, [rip + g_task_wake_fd]
    mov esi, 50
    call os_poll_in                   # returns early on worker exit (pipe hang-up)
    jmp .Lsd_loop
.Lsd_ret:
    add rsp, 24
    pop r12; pop rbx; ret

# --- Conflict helpers moved to src/fs/task_conflict.s ---
