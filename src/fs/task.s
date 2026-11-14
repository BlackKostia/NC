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

# Worker stack frame layout

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
.align 8
g_fs_progress:    .space 8     # worker: TaskShared* receiving fs_progress_* hooks (UI: NULL)
g_measure_bytes:  .space 4     # worker: 1 = scan needs regular-file sizes (copy/move)

.section .text
.global fs_progress_begin
.global fs_progress_bytes
.global fs_progress_item
.global fs_progress_cancelled
.global task_measure
.global g_fs_progress
.global g_measure_bytes

# g_conflict_all_act moved to src/fs/task_conflict.s

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
    sub rsp, 56                       # FileStat
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
    mov edx, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
    js .Ltm_ok
    mov ebx, eax
    mov edi, ebx
    call measure_dir_fd
    mov r12, rax
    mov edi, ebx
    OS_CLOSE
    mov rax, r12
    jmp .Ltm_done
.Ltm_ok:
    xor eax, eax
    jmp .Ltm_done
.Ltm_cancel:
    mov rax, -ECANCELED
.Ltm_done:
    add rsp, 56
    pop r12; pop rbx; ret

# Internal: int measure_dir_fd(int dfd) -- fd-relative, d_type-driven tree measurement
measure_dir_fd:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 80                       # [0]=cursor, [8]=d_type, [16..71]=FileStat, [72]=rc
    mov r12d, edi
    mov r13, [rip + g_fs_progress]
    mov edi, 32752
    call mem_alloc
    test rax, rax
    jz .Lmd_ok_nofree
    mov rbx, rax
.Lmd_read:
    mov edi, r12d
    mov rsi, rbx
    mov edx, 32752
    call os_dir_read
    test rax, rax
    jle .Lmd_ok
    mov r14, rax
    mov qword ptr [rsp], 0
.Lmd_next:
    call measure_dir_fd__os_dir_next_ex
    jz .Lmd_read
    mov r15, rax
    cmp byte ptr [r15], '.'
    jne .Lmd_entry
    cmp byte ptr [r15 + 1], 0
    je .Lmd_next
    cmp byte ptr [r15 + 1], '.'
    jne .Lmd_entry
    cmp byte ptr [r15 + 2], 0
    je .Lmd_next
.Lmd_entry:
    call fs_progress_cancelled
    test eax, eax
    jnz .Lmd_cancel
    inc qword ptr [r13 + TaskShared.total_files]
    movzx eax, byte ptr [rsp + 8]
    cmp eax, PAL_DT_DIR
    je .Lmd_dir
    cmp eax, PAL_DT_REG
    jne .Lmd_chk_unk
    cmp dword ptr [rip + g_measure_bytes], 0
    je .Lmd_next                      # delete: entry count only, no stat per file
    jmp .Lmd_stat
.Lmd_chk_unk:
    cmp eax, PAL_DT_UNKNOWN
    jne .Lmd_next
.Lmd_stat:
    call measure_dir_fd__os_statat
    js .Lmd_next
    mov eax, [rsp + 16 + FileStat.mode]
    and eax, S_IFMT
    cmp eax, S_IFDIR
    je .Lmd_dir
    cmp eax, S_IFREG
    jne .Lmd_next
    mov rax, [rsp + 16 + FileStat.size]
    add [r13 + TaskShared.total_bytes], rax
    jmp .Lmd_next
.Lmd_dir:
    call measure_dir_fd__part3
    js .Lmd_next
    call measure_dir_fd__measure_dir_fd
    jns .Lmd_next
    jmp .Lmd_free_ret
.Lmd_cancel:
    mov rax, -ECANCELED
    jmp .Lmd_free_ret
.Lmd_ok:
    xor eax, eax
.Lmd_free_ret:
    mov rbp, rax
    mov rdi, rbx
    call mem_free
    mov rax, rbp
    jmp .Lmd_ret
.Lmd_ok_nofree:
    xor eax, eax
.Lmd_ret:
    add rsp, 80
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

# measure_dir_fd step: os_dir_next_ex (runs on the caller's frame)
measure_dir_fd__os_dir_next_ex:
    lea rsp, [rsp - 8]
    mov rdi, rbx
    mov rsi, r14
    lea rdx, [rsp + 16]
    lea rcx, [rsp + 8 + 16]
    call os_dir_next_ex
    test rax, rax
.Lmeasure_dir_fd__os_dir_next_ex_ret:
    lea rsp, [rsp + 8]
    ret

# measure_dir_fd step: os_statat (runs on the caller's frame)
measure_dir_fd__os_statat:
    lea rsp, [rsp - 8]
    mov edi, r12d
    mov rsi, r15
    lea rdx, [rsp + 16 + 16]
    xor ecx, ecx
    call os_statat
    test rax, rax
.Lmeasure_dir_fd__os_statat_ret:
    lea rsp, [rsp + 8]
    ret

# measure_dir_fd step (runs on the caller's frame)
measure_dir_fd__part3:
    lea rsp, [rsp - 8]
    mov edi, r12d
    mov rsi, r15
    mov edx, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
.Lmeasure_dir_fd__part3_ret:
    lea rsp, [rsp + 8]
    ret

# measure_dir_fd step: measure_dir_fd (runs on the caller's frame)
measure_dir_fd__measure_dir_fd:
    lea rsp, [rsp - 8]
    mov ebp, eax
    mov edi, ebp
    call measure_dir_fd
    mov [rsp + 72 + 16], rax
    mov edi, ebp
    OS_CLOSE
    mov rax, [rsp + 72 + 16]
    test rax, rax
.Lmeasure_dir_fd__measure_dir_fd_ret:
    lea rsp, [rsp + 8]
    ret
