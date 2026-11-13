# Background Task Worker: fork-isolated copy / move / delete with shared-memory progress
#
# The UI process forks one worker per batch. The worker owns a private copy of the address
# space (no CLONE_VM threads => allocator and global buffers stay race-free) and publishes
# progress into a MAP_SHARED page (TaskShared). A CLOEXEC pipe whose write end only the
# worker holds hangs up the instant the worker exits, waking the UI event loop at once.
#
# Cancellation is cooperative (TaskShared.cancel polled per 32 KiB chunk / per entry) and
# backed by SIGTERM, which the worker handles without SA_RESTART so blocking open()/read()
# calls (FIFOs, slow network filesystems) are interrupted with -EINTR. Pause = SIGSTOP/SIGCONT.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.if NAME_MAX != 256 || PATH_MAX != 4096
    .error "TaskShared/TaskSnap/TaskJob layouts in include/types.inc assume NAME_MAX=256, PATH_MAX=4096"
.endif
.if TaskShared._size > TASK_SHM_SIZE
    .error "TaskShared must fit in one shared page"
.endif

# Worker stack frame layout
.equ TW_SRC,   0
.equ TW_DST,   PATH_MAX
.equ TW_ST,    PATH_MAX * 2
.equ TW_DEV,   PATH_MAX * 2 + 48
.equ TW_CUM,   PATH_MAX * 2 + 56
.equ TW_RES,   PATH_MAX * 2 + 64
.equ TW_FRAME, PATH_MAX * 2 + 80

.section .bss
.align 8
.global g_fs_progress
g_fs_progress:    .space 8     # worker: TaskShared* receiving fs_progress_* hooks (UI: NULL)
g_task_shm:       .space 8     # UI: TaskShared* of the running worker
g_task_start_ms:  .space 8
g_task_pause_ms:  .space 8     # accumulated paused time
g_task_pause_at:  .space 8     # start of the current pause
g_task_cancel_at: .space 8     # when cancel was requested (0 = none)
g_task_pipe:      .space 8     # int[2] scratch for pipe2
g_task_pid:       .space 4
g_task_wake_fd:   .space 4
g_task_op:        .space 4
g_task_paused:    .space 4

.section .text
.global fs_task_start
.global fs_task_is_active
.global fs_task_wake_fd
.global fs_task_poll
.global fs_task_snapshot
.global fs_task_toggle_pause
.global fs_task_cancel
.global fs_task_shutdown
.global fs_progress_begin
.global fs_progress_bytes
.global fs_progress_item
.global fs_progress_cancelled

# ==============================================================================
# Worker-side progress hooks (no-ops in the UI process where g_fs_progress == NULL)
# ==============================================================================

# void fs_progress_begin(const char *path)
# Publishes basename(path) as the current item using the TaskShared.seq seqlock.
fs_progress_begin:
    mov rax, [rip + g_fs_progress]
    test rax, rax
    jz .Lfpb_ret
    push rbx
    mov rbx, rax
    call path_basename
    inc dword ptr [rbx + TaskShared.seq]       # odd: write in progress
    lea rdi, [rbx + TaskShared.cur_name]
    mov rsi, rax
    mov edx, NAME_MAX
    call str_copy
    inc dword ptr [rbx + TaskShared.seq]       # even: stable
    pop rbx
.Lfpb_ret:
    ret

# void fs_progress_bytes(uint64_t n) -- preserves every register
fs_progress_bytes:
    push rax
    mov rax, [rip + g_fs_progress]
    test rax, rax
    jz 1f
    add [rax + TaskShared.done_bytes], rdi
1:  pop rax
    ret

# void fs_progress_item(void) -- preserves every register
fs_progress_item:
    push rax
    mov rax, [rip + g_fs_progress]
    test rax, rax
    jz 1f
    inc qword ptr [rax + TaskShared.done_files]
1:  pop rax
    ret

# int fs_progress_cancelled(void) -- eax = 1 when cancel was requested; clobbers only rax
fs_progress_cancelled:
    mov rax, [rip + g_fs_progress]
    test rax, rax
    jz 1f
    mov eax, [rax + TaskShared.cancel]
    ret
1:  xor eax, eax
    ret

# ==============================================================================
# Worker process
# ==============================================================================

# int task_measure(const char *path)
# Adds entries / regular-file bytes of the tree at `path` (symlinks not followed) to the
# shared totals. Unreadable parts are skipped (the real operation reports them).
# Returns 0 or -ECANCELED.
task_measure:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48                       # FileStat
    mov r12, rdi
    call fs_progress_cancelled
    test eax, eax
    jnz .Ltm_cancel

    mov edi, AT_FDCWD
    mov rsi, r12
    mov rdx, rsp
    xor ecx, ecx
    call os_statat
    test rax, rax
    js .Ltm_ok

    mov rbx, [rip + g_fs_progress]
    inc qword ptr [rbx + TaskShared.total_files]
    mov eax, [rsp + FileStat.mode]
    and eax, S_IFMT
    cmp eax, S_IFREG
    jne .Ltm_chk_dir
    mov rax, [rsp + FileStat.size]
    add [rbx + TaskShared.total_bytes], rax
    jmp .Ltm_ok
.Ltm_chk_dir:
    cmp eax, S_IFDIR
    jne .Ltm_ok

    mov rdi, r12
    call fs_progress_begin
    mov edi, AT_FDCWD
    mov rsi, r12
    mov edx, O_RDONLY | O_DIRECTORY | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
    js .Ltm_ok
    mov r13d, eax                     # dirfd

    mov edi, OPS_DIRENTS_BUF_SIZE + PATH_MAX + 16
    call mem_alloc
    test rax, rax
    jz .Ltm_close_ok
    mov rbx, rax                      # [0]=dents, [+BUF]=child path, [+BUF+PATH_MAX]=cursor

.Ltm_dents:
    mov edi, r13d
    mov rsi, rbx
    mov edx, OPS_DIRENTS_BUF_SIZE
    call os_dir_read
    test rax, rax
    jle .Ltm_free_ok
    mov r14, rax
    mov qword ptr [rbx + OPS_DIRENTS_BUF_SIZE + PATH_MAX], 0
.Ltm_entry:
    mov rdi, rbx
    mov rsi, r14
    lea rdx, [rbx + OPS_DIRENTS_BUF_SIZE + PATH_MAX]
    call os_dir_next
    test rax, rax
    jz .Ltm_dents
    cmp byte ptr [rax], '.'
    jne .Ltm_child
    cmp byte ptr [rax + 1], 0
    je .Ltm_entry
    cmp byte ptr [rax + 1], '.'
    jne .Ltm_child
    cmp byte ptr [rax + 2], 0
    je .Ltm_entry
.Ltm_child:
    lea rdi, [rbx + OPS_DIRENTS_BUF_SIZE]
    mov rsi, r12
    mov rdx, rax
    mov ecx, PATH_MAX
    call path_join
    lea rdi, [rbx + OPS_DIRENTS_BUF_SIZE]
    call task_measure
    test rax, rax
    jns .Ltm_entry
    mov r15, rax
    mov rdi, rbx
    call mem_free
    mov edi, r13d
    OS_CLOSE
    mov rax, r15
    jmp .Ltm_done

.Ltm_free_ok:
    mov rdi, rbx
    call mem_free
.Ltm_close_ok:
    mov edi, r13d
    OS_CLOSE
.Ltm_ok:
    xor eax, eax
    jmp .Ltm_done
.Ltm_cancel:
    mov rax, -ECANCELED
.Ltm_done:
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# noreturn void task_worker_main(const TaskJob *job, TaskShared *shm)
# Phase SCAN: measures every item (live totals). Phase RUN: executes items in order and
# stops at the first failure (same semantics as the former synchronous batch).
task_worker_main:
    mov r12, rdi                      # job (private COW copy)
    mov r13, rsi                      # shm
    and rsp, -16
    sub rsp, TW_FRAME
    mov [rip + g_fs_progress], r13
    call os_signals_worker_mode
    mov qword ptr [rsp + TW_RES], 0
    mov qword ptr [rsp + TW_DEV], -1

    # Per-item cumulative (bytes, entries) after scan -> exact resync after each item
    mov eax, [r12 + TaskJob.count]
    shl rax, 4
    lea rdi, [rax + 16]
    call mem_alloc
    test rax, rax
    jz .Ltw_nomem
    mov [rsp + TW_CUM], rax

    # MOVE: same device as destination dir => atomic rename, skip the tree scan
    cmp dword ptr [r12 + TaskJob.op], TASK_OP_MOVE
    jne .Ltw_scan
    lea rsi, [r12 + TaskJob.dst]
    cmp dword ptr [r12 + TaskJob.join_dst], 0
    jne .Ltw_dev_stat
    lea rdi, [r12 + TaskJob.dst]
    lea rsi, [rsp + TW_DST]
    mov edx, PATH_MAX
    call path_dirname
    lea rsi, [rsp + TW_DST]
.Ltw_dev_stat:
    mov edi, AT_FDCWD
    lea rdx, [rsp + TW_ST]
    mov ecx, 1
    call os_statat
    test rax, rax
    js .Ltw_scan
    mov rax, [rsp + TW_ST + FileStat.dev]
    mov [rsp + TW_DEV], rax

.Ltw_scan:
    mov dword ptr [r13 + TaskShared.phase], TASK_PHASE_SCAN
    lea rbx, [r12 + TaskJob.names]
    xor r14d, r14d
.Ltw_scan_loop:
    cmp r14d, [r12 + TaskJob.count]
    jae .Ltw_run
    lea rdi, [rsp + TW_SRC]
    lea rsi, [r12 + TaskJob.src_dir]
    mov rdx, rbx
    mov ecx, PATH_MAX
    call path_join

    cmp qword ptr [rsp + TW_DEV], -1
    je .Ltw_measure
    mov edi, AT_FDCWD
    lea rsi, [rsp + TW_SRC]
    lea rdx, [rsp + TW_ST]
    xor ecx, ecx
    call os_statat
    test rax, rax
    js .Ltw_measure
    mov rax, [rsp + TW_ST + FileStat.dev]
    cmp rax, [rsp + TW_DEV]
    jne .Ltw_measure
    inc qword ptr [r13 + TaskShared.total_files]
    jmp .Ltw_scan_store
.Ltw_measure:
    lea rdi, [rsp + TW_SRC]
    call task_measure
    test rax, rax
    js .Ltw_fail
.Ltw_scan_store:
    mov rcx, [rsp + TW_CUM]
    mov rax, r14
    shl rax, 4
    mov rdx, [r13 + TaskShared.total_bytes]
    mov [rcx + rax], rdx
    mov rdx, [r13 + TaskShared.total_files]
    mov [rcx + rax + 8], rdx
    mov rdi, rbx
    call str_len
    lea rbx, [rbx + rax + 1]
    inc r14d
    jmp .Ltw_scan_loop

.Ltw_run:
    mov dword ptr [r13 + TaskShared.phase], TASK_PHASE_RUN
    lea rbx, [r12 + TaskJob.names]
    xor r14d, r14d
.Ltw_run_loop:
    cmp r14d, [r12 + TaskJob.count]
    jae .Ltw_finish
    call fs_progress_cancelled
    test eax, eax
    jnz .Ltw_canceled
    lea rdi, [rsp + TW_SRC]
    lea rsi, [r12 + TaskJob.src_dir]
    mov rdx, rbx
    mov ecx, PATH_MAX
    call path_join
    cmp dword ptr [r12 + TaskJob.join_dst], 0
    je .Ltw_dst_verbatim
    lea rdi, [rsp + TW_DST]
    lea rsi, [r12 + TaskJob.dst]
    mov rdx, rbx
    mov ecx, PATH_MAX
    call path_join
    jmp .Ltw_exec
.Ltw_dst_verbatim:
    lea rdi, [rsp + TW_DST]
    lea rsi, [r12 + TaskJob.dst]
    mov edx, PATH_MAX
    call str_copy
.Ltw_exec:
    lea rdi, [rsp + TW_SRC]
    call fs_progress_begin
    lea rdi, [rsp + TW_SRC]
    lea rsi, [rsp + TW_DST]
    mov eax, [r12 + TaskJob.op]
    cmp eax, TASK_OP_COPY
    je .Ltw_do_copy
    cmp eax, TASK_OP_MOVE
    je .Ltw_do_move
    call fs_delete_recursive
    jmp .Ltw_exec_chk
.Ltw_do_copy:
    call fs_copy_recursive
    jmp .Ltw_exec_chk
.Ltw_do_move:
    call fs_move_recursive
.Ltw_exec_chk:
    test rax, rax
    js .Ltw_fail
    mov rcx, [rsp + TW_CUM]
    mov rax, r14
    shl rax, 4
    mov rdx, [rcx + rax]
    mov [r13 + TaskShared.done_bytes], rdx
    mov rdx, [rcx + rax + 8]
    mov [r13 + TaskShared.done_files], rdx
    mov rdi, rbx
    call str_len
    lea rbx, [rbx + rax + 1]
    inc r14d
    jmp .Ltw_run_loop

.Ltw_nomem:
    mov rax, -ENOMEM
.Ltw_fail:
    mov [rsp + TW_RES], rax
    call fs_progress_cancelled        # failures after a cancel request (e.g. -EINTR) = cancel
    test eax, eax
    jz .Ltw_finish
.Ltw_canceled:
    mov qword ptr [rsp + TW_RES], -ECANCELED
.Ltw_finish:
    mov rax, [rsp + TW_RES]
    mov [r13 + TaskShared.result], rax
    mov dword ptr [r13 + TaskShared.phase], TASK_PHASE_DONE
    xor edi, edi
    OS_EXIT

# ==============================================================================
# UI-process API
# ==============================================================================

# int fs_task_start(const TaskJob *job)
# Forks the worker. Returns 0 (caller keeps and may free `job`), -EBUSY, or -errno.
fs_task_start:
    push rbx
    push r12
    push r13
    mov r12, rdi
    cmp dword ptr [rip + g_task_pid], 0
    jne .Lts_busy

    xor edi, edi
    mov esi, TASK_SHM_SIZE
    mov edx, PROT_RW
    OS_MMAP_SHARED_ANON
    cmp rax, -4095
    jae .Lts_ret
    mov r13, rax                      # zero-filled shared page
    mov dword ptr [r13 + TaskShared.phase], TASK_PHASE_SCAN

    lea rdi, [rip + g_task_pipe]
    call os_pipe_cloexec
    test rax, rax
    js .Lts_unmap

    mov eax, [r12 + TaskJob.op]
    mov [rip + g_task_op], eax
    mov dword ptr [rip + g_task_paused], 0
    xor eax, eax
    mov [rip + g_task_pause_ms], rax
    mov [rip + g_task_cancel_at], rax
    call os_clock_ms
    mov [rip + g_task_start_ms], rax

    OS_FORK
    test rax, rax
    js .Lts_close_pipe
    jz .Lts_child

    mov [rip + g_task_pid], eax
    mov [rip + g_task_shm], r13
    mov edi, [rip + g_task_pipe + 4]
    OS_CLOSE                          # only the worker holds the write end
    mov eax, [rip + g_task_pipe]
    mov [rip + g_task_wake_fd], eax
    xor eax, eax
    jmp .Lts_ret

.Lts_child:
    mov edi, [rip + g_task_pipe]
    OS_CLOSE                          # worker keeps only the write end (closed by exit)
    mov rdi, r12
    mov rsi, r13
    jmp task_worker_main

.Lts_close_pipe:
    mov rbx, rax
    mov edi, [rip + g_task_pipe]
    OS_CLOSE
    mov edi, [rip + g_task_pipe + 4]
    OS_CLOSE
    mov rax, rbx
.Lts_unmap:
    mov rbx, rax
    mov rdi, r13
    mov esi, TASK_SHM_SIZE
    OS_MUNMAP
    mov rax, rbx
    jmp .Lts_ret
.Lts_busy:
    mov rax, -EBUSY
.Lts_ret:
    pop r13
    pop r12
    pop rbx
    ret

# int fs_task_is_active(void)
fs_task_is_active:
    xor eax, eax
    cmp dword ptr [rip + g_task_pid], 0
    setne al
    ret

# int fs_task_wake_fd(void) -> read end that hangs up when the worker exits, or -1
fs_task_wake_fd:
    mov eax, -1
    cmp dword ptr [rip + g_task_pid], 0
    je 1f
    mov eax, [rip + g_task_wake_fd]
1:  ret

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
    pop r12
    pop rbx
    ret

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

    # Metric: bytes for copy/move when known, else entries
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

    # Speed & ETA once at least 500 ms of active time elapsed
    mov qword ptr [rbx + TaskSnap.speed_bps], 0
    mov qword ptr [rbx + TaskSnap.eta_sec], -1
    cmp r13, 500
    jb .Lsn_ret
    mov rax, [rbx + TaskSnap.done_bytes]
    mov ecx, 1000
    mul rcx
    cmp rdx, r13
    jae .Lsn_eta
    div r13
    mov [rbx + TaskSnap.speed_bps], rax
.Lsn_eta:
    cmp dword ptr [rbx + TaskSnap.phase], TASK_PHASE_RUN
    jne .Lsn_ret
    test r8, r8
    jz .Lsn_ret
    mov rax, r9
    sub rax, r8                       # remaining
    mul r13                           # remaining * elapsed_ms
    cmp rdx, r8
    jae .Lsn_ret
    div r8                            # -> remaining ms
    add rax, 999
    xor edx, edx
    mov ecx, 1000
    div rcx
    mov [rbx + TaskSnap.eta_sec], rax
.Lsn_ret:
    pop r13
    pop r12
    pop rbx
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
    pop r12
    pop rbx
    ret
