# Background Task Worker: fork-isolated copy / move / delete with shared-memory progress — task worker (split from task.s)

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
g_task_start_ms:  .space 8
g_task_pipe:      .space 8     # int[2] scratch for pipe2
g_task_wake_fd:   .space 4
g_task_op:        .space 4

.section .text
.global fs_task_start
.global fs_task_is_active
.global fs_task_wake_fd
.global g_task_start_ms
.global g_task_wake_fd
.global g_task_op

# noreturn void task_worker_main(const TaskJob *job, TaskShared *shm)
# Phase SCAN: measures every item (live totals). Phase RUN: executes items in order and
# stops at the first failure (same semantics as the former synchronous batch).
task_worker_main:
    mov r12, rdi                      # job (private COW copy)
    mov r13, rsi                      # shm
    and rsp, -16
    sub rsp, TW_FRAME
    call task_worker_main__os_signals_worker_mode
    # Per-item cumulative (bytes, entries) after scan -> exact resync after each item
    mov eax, [r12 + TaskJob.count]
    shl rax, 4
    lea rdi, [rax + 16]
    call mem_alloc
    test rax, rax
    jz .Ltw_nomem
    call task_worker_main__move_same_device_as
    mov dword ptr [r13 + TaskShared.phase], TASK_PHASE_SCAN
    lea rbx, [r12 + TaskJob.names]
    xor r14d, r14d
.Ltw_scan_loop:
    cmp r14d, [r12 + TaskJob.count]
    jae .Ltw_run
    call task_worker_main__path_join
    cmp qword ptr [rsp + TW_DEV], -1
    je .Ltw_measure
    call task_worker_main__os_statat
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
    call task_worker_main__part5
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
    call task_worker_main__path_join_2
    test rax, rax
    js .Ltw_fail
    call task_worker_main__part7
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
    pop r12; pop rbx; ret

# task_worker_main step: os_signals_worker_mode (runs on the caller's frame)
task_worker_main__os_signals_worker_mode:
    lea rsp, [rsp - 8]
    mov [rip + g_fs_progress], r13
    call os_signals_worker_mode
    mov qword ptr [rsp + TW_RES + 16], 0
    mov qword ptr [rsp + TW_DEV + 16], -1
    xor eax, eax
    cmp dword ptr [r12 + TaskJob.op], TASK_OP_DELETE
    setne al
    mov [rip + g_measure_bytes], eax

.Ltask_worker_main__os_signals_worker_mode_ret:
    lea rsp, [rsp + 8]
    ret

# task_worker_main step: MOVE same device as destination dir (runs on the caller's frame)
task_worker_main__move_same_device_as:
    lea rsp, [rsp - 8]
    mov [rsp + TW_CUM + 16], rax

    # MOVE: same device as destination dir => atomic rename, skip the tree scan
    cmp dword ptr [r12 + TaskJob.op], TASK_OP_MOVE
    jne .Ltw_scan
    lea rsi, [r12 + TaskJob.dst]
    cmp dword ptr [r12 + TaskJob.join_dst], 0
    jne .Ltw_dev_stat
    lea rdi, [r12 + TaskJob.dst]
    lea rsi, [rsp + TW_DST + 16]
    mov edx, PATH_MAX
    call path_dirname
    lea rsi, [rsp + TW_DST + 16]
.Ltw_dev_stat:
    mov edi, AT_FDCWD
    lea rdx, [rsp + TW_ST + 16]
    mov ecx, 1
    call os_statat
    test rax, rax
    js .Ltw_scan
    mov rax, [rsp + TW_ST + FileStat.dev + 16]
    mov [rsp + TW_DEV + 16], rax

.Ltw_scan:
.Ltask_worker_main__move_same_device_as_ret:
    lea rsp, [rsp + 8]
    ret

# task_worker_main step: path_join (runs on the caller's frame)
task_worker_main__path_join:
    lea rsp, [rsp - 8]
    lea rdi, [rsp + TW_SRC + 16]
    lea rsi, [r12 + TaskJob.src_dir]
    mov rdx, rbx
    mov ecx, PATH_MAX
    call path_join

.Ltask_worker_main__path_join_ret:
    lea rsp, [rsp + 8]
    ret

# task_worker_main step: os_statat (runs on the caller's frame)
task_worker_main__os_statat:
    lea rsp, [rsp - 8]
    mov edi, AT_FDCWD
    lea rsi, [rsp + TW_SRC + 16]
    lea rdx, [rsp + TW_ST + 16]
    xor ecx, ecx
    call os_statat
    test rax, rax
.Ltask_worker_main__os_statat_ret:
    lea rsp, [rsp + 8]
    ret

# task_worker_main step (runs on the caller's frame)
task_worker_main__part5:
    lea rsp, [rsp - 8]
    mov rcx, [rsp + TW_CUM + 16]
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
.Ltask_worker_main__part5_ret:
    lea rsp, [rsp + 8]
    ret

# task_worker_main step: path_join (runs on the caller's frame)
task_worker_main__path_join_2:
    lea rsp, [rsp - 8]
    lea rdi, [rsp + TW_SRC + 16]
    lea rsi, [r12 + TaskJob.src_dir]
    mov rdx, rbx
    mov ecx, PATH_MAX
    call path_join
    cmp dword ptr [r12 + TaskJob.join_dst], 0
    je .Ltw_dst_verbatim
    lea rdi, [rsp + TW_DST + 16]
    lea rsi, [r12 + TaskJob.dst]
    mov rdx, rbx
    mov ecx, PATH_MAX
    call path_join
    jmp .Ltw_exec
.Ltw_dst_verbatim:
    lea rdi, [rsp + TW_DST + 16]
    lea rsi, [r12 + TaskJob.dst]
    mov edx, PATH_MAX
    call str_copy
.Ltw_exec:
    lea rdi, [rsp + TW_SRC + 16]
    call fs_progress_begin
    lea rdi, [rsp + TW_SRC + 16]
    lea rsi, [rsp + TW_DST + 16]
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
.Ltask_worker_main__path_join_2_ret:
    lea rsp, [rsp + 8]
    ret

# task_worker_main step (runs on the caller's frame)
task_worker_main__part7:
    lea rsp, [rsp - 8]
    mov rcx, [rsp + TW_CUM + 16]
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
.Ltask_worker_main__part7_ret:
    lea rsp, [rsp + 8]
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
