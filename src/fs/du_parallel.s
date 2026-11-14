# src/fs/du_parallel.s - Multi-threaded Disk Usage subtree walker (PAL clone + futex).
# Walkers publish live DuProgress counters; with a progress callback registered (du_set_progress)
# every folder is walked by worker threads while the main thread runs the callback about every
# 100 ms (the app draws a progress window and polls Esc), and a non-zero return cancels the walk.
.intel_syntax noprefix

.include "pal.inc"
.include "config.inc"
.include "classes.inc"

.equ DUP_MAX_DEPTH, 24
.equ DUP_STRIDE,    32768     # getdents64 buffer per recursion level
.equ DUP_ARENA_SZ,  (DUP_MAX_DEPTH * DUP_STRIDE)
.equ DUP_STACK_SZ,  32768
.equ DUP_WORKERS,   4
.equ DUP_ARG_SZ,    32        # ctx(8), arena(8), ctid(4), pad(4), stack_base(8)
.equ DUP_ITEM_SZ,   24        # fe(8), name(8), size(8)

.section .bss
.align 8
g_dup_prog:     .space DuProgress._size
g_dup_cb:       .space 8              # int cb(void *ctx, DuProgress *p) -> 1 = cancel
g_dup_cb_ctx:   .space 8

.section .text
.global du_parallel_walk
.global du_set_progress
.global du_progress

.extern os_dir_read
.extern os_dir_next_ex
.extern os_statat
.extern os_fstat
.extern os_thread_spawn
.extern os_thread_join
.extern du_cache_init
.extern du_cache_get
.extern du_cache_put
.extern du_mtime_sig
.extern mem_alloc
.extern mem_free
.extern os_clock_ms

# void du_set_progress(int (*cb)(void *ctx, DuProgress *p), void *ctx) -- cb = 0: no progress UI
du_set_progress:
    mov [rip + g_dup_cb], rdi
    mov [rip + g_dup_cb_ctx], rsi
    ret

# DuProgress *du_progress(void) -- counters of the current / last walk (cancel is caller-reset)
du_progress:
    lea rax, [rip + g_dup_prog]
    ret

# uint64_t dup_walk_fd_mt(int dfd, void *lvl_buf, int depth)
dup_walk_fd_mt:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, FileStat._size + 56
    mov ebx, edi; mov r12, rsi; mov r13d, edx; xor r14d, r14d
    cmp r13d, DUP_MAX_DEPTH; jge .Lmt_ret
    mov dword ptr [rsp + FileStat._size + 48], 0
    mov edi, ebx; mov rsi, rsp; call os_fstat
    test rax, rax; js .Lmt_miss
    mov dword ptr [rsp + FileStat._size + 48], 1
    mov rdi, rsp; call du_mtime_sig
    mov [rsp + FileStat._size + 40], rax
    mov rdi, [rsp + FileStat.ino]; mov rsi, [rsp + FileStat.dev]
    mov rdx, rax; lea rcx, [rsp + FileStat._size + 24]
    call du_cache_get
    test eax, eax; jz .Lmt_miss
    mov r14, [rsp + FileStat._size + 24]
    lock add [rip + g_dup_prog + DuProgress.bytes], r14
    jmp .Lmt_ret
.Lmt_miss:
    lock inc qword ptr [rip + g_dup_prog + DuProgress.dirs]
.Lmt_read:
    mov edi, ebx; mov rsi, r12; mov edx, DUP_STRIDE; call os_dir_read
    test rax, rax; jle .Lmt_put
    mov [rsp + FileStat._size], rax
    mov qword ptr [rsp + FileStat._size + 8], 0
.Lmt_ent:
    cmp dword ptr [rip + g_dup_prog + DuProgress.cancel], 0
    jne .Lmt_ret                      # canceled: partial size, never cached
    mov rdi, r12; mov rsi, [rsp + FileStat._size]
    lea rdx, [rsp + FileStat._size + 8]; lea rcx, [rsp + FileStat._size + 16]
    lea r8, [rsp + FileStat._size + 24]; call os_dir_next_ex
    test rax, rax; jz .Lmt_read
    mov r15, rax
    cmp byte ptr [r15], '.'; jne .Lmt_type
    cmp byte ptr [r15 + 1], 0; je .Lmt_ent
    cmp word ptr [r15 + 1], '.'; je .Lmt_ent
.Lmt_type:
    movzx eax, byte ptr [rsp + FileStat._size + 16]
    cmp eax, PAL_DT_LNK; je .Lmt_ent
    cmp eax, PAL_DT_DIR; je .Lmt_dir
    mov edi, ebx; mov rsi, r15
    mov rdx, r12; mov ecx, r13d; call dup_stat_one_mt
    add r14, rax; jmp .Lmt_ent
.Lmt_dir:
    mov edi, ebx; mov rsi, r15
    mov edx, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    xor r10d, r10d; OS_OPENAT
    test rax, rax; js .Lmt_ent
    mov [rsp + FileStat._size + 32], rax
    mov edi, eax; lea rsi, [r12 + DUP_STRIDE]; lea edx, [r13d + 1]
    call dup_walk_fd_mt
    add r14, rax
    mov rdi, [rsp + FileStat._size + 32]; OS_CLOSE
    jmp .Lmt_ent
.Lmt_put:
    cmp dword ptr [rsp + FileStat._size + 48], 0; je .Lmt_ret
    mov rdi, [rsp + FileStat.ino]; mov rsi, [rsp + FileStat.dev]
    mov rdx, [rsp + FileStat._size + 40]; mov rcx, r14; call du_cache_put
.Lmt_ret:
    mov rax, r14
    add rsp, FileStat._size + 56
    pop r15; pop r14; pop r13; pop r12; pop rbx; ret

# uint64_t dup_stat_one_mt(int dfd, const char *name, void *lvl_buf, int depth)
dup_stat_one_mt:
    push rbx; push r12; push r13; push r14; sub rsp, FileStat._size + 8
    mov ebx, edi; mov r12, rsi; mov r13, rdx; mov r14d, ecx
    mov rdx, rsp; xor ecx, ecx; call os_statat
    test rax, rax; js .Lso_zero
    mov eax, [rsp + FileStat.mode]; and eax, S_IFMT
    cmp eax, S_IFDIR; je .Lso_dir
    cmp eax, S_IFREG; jne .Lso_zero
    mov rax, [rsp + FileStat.size]
    lock inc qword ptr [rip + g_dup_prog + DuProgress.files]
    lock add [rip + g_dup_prog + DuProgress.bytes], rax
    jmp .Lso_ret
.Lso_dir:
    mov edi, ebx; mov rsi, r12
    mov edx, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    xor r10d, r10d; OS_OPENAT
    test rax, rax; js .Lso_zero
    mov [rsp], rax
    mov edi, eax; lea rsi, [r13 + DUP_STRIDE]; lea edx, [r14d + 1]
    call dup_walk_fd_mt
    mov rdi, [rsp]; push rax; OS_CLOSE; pop rax; jmp .Lso_ret
.Lso_zero:
    xor eax, eax
.Lso_ret:
    add rsp, FileStat._size + 8; pop r14; pop r13; pop r12; pop rbx; ret

# void dup_worker_fn(DuWorkerArg *arg)
dup_worker_fn:
    push rbx; push r12; push r13; push r14; sub rsp, 8
    mov rbx, [rdi]                    # ctx
    mov r12, [rdi + 8]                # arena
.Lwf_loop:
    cmp dword ptr [rip + g_dup_prog + DuProgress.cancel], 0
    jne .Lwf_done
    mov eax, 1
    lock xadd [rbx + 8], eax          # next_idx
    cmp eax, [rbx + 4]                # count
    jge .Lwf_done
    imul r13, rax, DUP_ITEM_SZ
    add r13, [rbx + 16]               # item
    mov edi, [rbx]                    # dfd
    mov rsi, [r13 + 8]                # name
    mov edx, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    xor r10d, r10d; OS_OPENAT
    test rax, rax; js .Lwf_loop
    mov r14, rax
    mov edi, eax; mov rsi, r12; xor edx, edx
    call dup_walk_fd_mt
    mov [r13 + 16], rax
    lock inc dword ptr [rip + g_dup_prog + DuProgress.done]
    mov rdi, r14; OS_CLOSE
    jmp .Lwf_loop
.Lwf_done:
    add rsp, 8; pop r14; pop r13; pop r12; pop rbx; ret

# void du_parallel_walk(int dfd, DuWorkItem *items, int count)
du_parallel_walk:
    cmp edx, 0; jle .Lpw_early
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, 48
    mov [rsp], edi                    # ctx.dfd
    mov [rsp + 4], edx                # ctx.count
    mov dword ptr [rsp + 8], 0        # ctx.next_idx
    mov [rsp + 16], rsi               # ctx.items
    mov r12d, DUP_WORKERS
    cmp edx, r12d; jge .Lpw_init
    mov r12d, edx                     # W = min(4, count)
.Lpw_init:
    call dup_prog_begin               # counters, total = count, start time
    call du_cache_init
    mov eax, r12d
    imul rax, DUP_ARENA_SZ + DUP_STACK_SZ + DUP_ARG_SZ
    mov rdi, rax; call mem_alloc
    test rax, rax; jz .Lpw_ret
    mov r13, rax                      # base block
    mov r14, r13                      # args array = base
    mov r15, r12; imul r15, DUP_ARG_SZ; add r15, r13 # arenas+stacks cursor
    xor ebx, ebx
.Lpw_setup:
    cmp ebx, r12d; jge .Lpw_spawn
    imul rcx, rbx, DUP_ARG_SZ; add rcx, r14
    mov [rcx], rsp                    # ctx
    mov [rcx + 8], r15                # arena
    mov dword ptr [rcx + 16], 0       # ctid
    add r15, DUP_ARENA_SZ + DUP_STACK_SZ
    mov [rcx + 24], r15               # stack_top
    inc ebx; jmp .Lpw_setup
.Lpw_spawn:
    xor ebx, ebx                      # with a progress callback every worker is a thread
    cmp qword ptr [rip + g_dup_cb], 0
    jne .Lpw_sp_loop
    mov ebx, 1                        # otherwise the main thread is worker 0
.Lpw_sp_loop:
    cmp ebx, r12d; jge .Lpw_main
    imul rcx, rbx, DUP_ARG_SZ; add rcx, r14
    lea rdi, [rip + dup_worker_fn]
    mov rsi, rcx
    mov rdx, [rcx + 24]               # stack_top
    add rcx, 16                       # &ctid
    call os_thread_spawn
    test rax, rax; jns .Lpw_sp_next
    imul rcx, rbx, DUP_ARG_SZ; add rcx, r14
    mov dword ptr [rcx + 16], 0       # spawn failed -> skip join
.Lpw_sp_next:
    inc ebx; jmp .Lpw_sp_loop
.Lpw_main:
    cmp qword ptr [rip + g_dup_cb], 0
    je .Lpw_self
    mov rdi, r14
    mov esi, r12d
    call dup_pump                     # progress UI until every thread has exited
.Lpw_self:
    mov rdi, r14; call dup_worker_fn  # worker 0 / items left by failed spawns
    xor ebx, ebx
.Lpw_join:
    cmp ebx, r12d; jge .Lpw_free
    imul rdi, rbx, DUP_ARG_SZ; add rdi, r14; add rdi, 16
    call os_thread_join
    inc ebx; jmp .Lpw_join
.Lpw_free:
    call dup_prog_end
    mov rdi, r13; call mem_free
.Lpw_ret:
    add rsp, 48; pop r15; pop r14; pop r13; pop r12; pop rbx
.Lpw_early:
    ret

# Internal: void dup_prog_begin(void) -- rsp + 8 = du_parallel_walk ctx {dfd, count, ...}
dup_prog_begin:
    push rbx
    mov ebx, [rsp + 8 + 8 + 4]        # ctx.count (caller frame: ret + push)
    lea rdi, [rip + g_dup_prog]
    mov esi, DuProgress.cancel        # dirs/files/bytes/done/total; cancel stays caller-owned
    call mem_zero
    mov [rip + g_dup_prog + DuProgress.total], ebx
    mov dword ptr [rip + g_dup_prog + DuProgress.phase], DU_PHASE_RUN
    call os_clock_ms
    mov [rip + g_dup_prog + DuProgress.start_ms], rax
    pop rbx
    ret

# Internal: void dup_prog_end(void) -- final callback (phase DONE) so the UI can close its window
dup_prog_end:
    mov rax, [rip + g_dup_cb]
    test rax, rax
    jz .Lpe_ret
    sub rsp, 8
    mov dword ptr [rip + g_dup_prog + DuProgress.phase], DU_PHASE_DONE
    mov rdi, [rip + g_dup_cb_ctx]
    lea rsi, [rip + g_dup_prog]
    call rax
    add rsp, 8
.Lpe_ret:
    ret

# Internal: void dup_pump(DuWorkerArg *args, int workers) -- run the progress callback until all
# worker threads have exited (ctid cleared by the kernel); a non-zero return requests cancel
dup_pump:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov r13d, esi
.Lpp_check:
    xor ebx, ebx
.Lpp_scan:
    cmp ebx, r13d
    jge .Lpp_ret                      # every ctid is 0
    imul rax, rbx, DUP_ARG_SZ
    cmp dword ptr [r12 + rax + 16], 0
    jne .Lpp_tick
    inc ebx
    jmp .Lpp_scan
.Lpp_tick:
    mov rdi, [rip + g_dup_cb_ctx]
    lea rsi, [rip + g_dup_prog]
    call [rip + g_dup_cb]             # waits up to ~100 ms for input
    test eax, eax
    jz .Lpp_check
    mov dword ptr [rip + g_dup_prog + DuProgress.cancel], 1
    jmp .Lpp_check
.Lpp_ret:
    pop r13
    pop r12
    pop rbx
    ret
