# src/os/linux/x86_64/pal_uring.s - Linux x86-64 io_uring parallel statx PAL adapter
.intel_syntax noprefix

.include "pal.inc"

.equ URING_DEPTH, 256           # in-flight window (rolling: refilled as completions arrive)
.equ URING_BATCH_MIN, 16
.equ STATX_ARENA_SZ, (URING_DEPTH * KSTATX_SIZE)

.section .bss
.align 8
g_uring_sq_sz:      .space 8
g_uring_cq_sz:      .space 8
g_uring_sqes_sz:    .space 8
g_uring_sq_ptr:     .space 8
g_uring_cq_ptr:     .space 8
g_uring_sqes_ptr:   .space 8
g_uring_statx_buf:  .space 8
g_uring_sq_head:    .space 8
g_uring_sq_tail:    .space 8
g_uring_sq_array:   .space 8
g_uring_cq_head:    .space 8
g_uring_cq_tail:    .space 8
g_uring_cqes:       .space 8
g_uring_state:      .space 4    # 0 = uninitialized, 1 = active, -1 = unavailable
g_uring_fd:         .space 4
g_uring_sq_mask:    .space 4
g_uring_cq_mask:    .space 4
g_uring_free:       .space URING_DEPTH   # stack of free statx arena slots

.section .text
.global os_batch_stat
.global os_uring_shutdown

.extern os_statat

# void copy_statx_to_filestat(FileStat *dst, const struct statx *src)
copy_statx_to_filestat:
    mov eax, [rsi + KSTATX_DEV_MAJOR]
    mov ecx, [rsi + KSTATX_DEV_MINOR]
    # gnu_dev_makedev(maj, min)
    mov r8d, eax
    and r8d, 0xfff
    shl r8, 8
    and eax, 0xfffff000
    mov edx, eax
    shl rdx, 32
    or r8, rdx
    mov r9d, ecx
    and r9d, 0xff
    or r8, r9
    and ecx, 0xffffff00
    mov edx, ecx
    shl rdx, 12
    or r8, rdx
    mov [rdi + FileStat.dev], r8

    mov rax, [rsi + KSTATX_INO]
    mov [rdi + FileStat.ino], rax
    mov rax, [rsi + KSTATX_ST_SIZE]
    mov [rdi + FileStat.size], rax
    mov rax, [rsi + KSTATX_MTIME]
    mov [rdi + FileStat.mtime], rax
    movzx eax, word ptr [rsi + KSTATX_MODE]
    mov [rdi + FileStat.mode], eax
    mov eax, [rsi + KSTATX_MTIME + 8]
    mov [rdi + FileStat.mtime_nsec], eax
    ret

# void os_uring_shutdown(void)
os_uring_shutdown:
    mov rdi, [g_uring_statx_buf]
    test rdi, rdi
    jz .Lous_sqes
    mov rsi, STATX_ARENA_SZ
    mov eax, OS_SYS_munmap
    syscall
    mov qword ptr [g_uring_statx_buf], 0
.Lous_sqes:
    mov rdi, [g_uring_sqes_ptr]
    test rdi, rdi
    jz .Lous_cq
    mov rsi, [g_uring_sqes_sz]
    mov eax, OS_SYS_munmap
    syscall
    mov qword ptr [g_uring_sqes_ptr], 0
.Lous_cq:
    mov rdi, [g_uring_cq_ptr]
    test rdi, rdi
    jz .Lous_sq
    mov rsi, [g_uring_cq_sz]
    test rsi, rsi
    jz .Lous_sq
    mov eax, OS_SYS_munmap
    syscall
    mov qword ptr [g_uring_cq_ptr], 0
.Lous_sq:
    mov rdi, [g_uring_sq_ptr]
    test rdi, rdi
    jz .Lous_fd
    mov rsi, [g_uring_sq_sz]
    mov eax, OS_SYS_munmap
    syscall
    mov qword ptr [g_uring_sq_ptr], 0
    mov qword ptr [g_uring_cq_ptr], 0
.Lous_fd:
    cmp dword ptr [g_uring_state], 1
    jne .Lous_done
    mov edi, [g_uring_fd]
    test edi, edi
    js .Lous_done
    mov eax, OS_SYS_close
    syscall
.Lous_done:
    mov dword ptr [g_uring_fd], -1
    mov dword ptr [g_uring_state], 0
    ret

# int os_uring_init(void) -> returns 0 on success, -1 on failure
os_uring_init:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 136

    # Zero params (120 bytes)
    xor eax, eax
    mov ecx, 15
    mov rdi, rsp
.Loui_zero:
    mov [rdi], rax
    add rdi, 8
    dec ecx
    jnz .Loui_zero

    mov edi, URING_DEPTH
    mov rsi, rsp
    mov eax, OS_SYS_io_uring_setup
    syscall
    test eax, eax
    js .Loui_fail

    mov r12d, eax
    mov [g_uring_fd], eax

    # sring_sz = sq_off.array + sq_entries * 4
    mov r13d, [rsp + KIOU_P_SQ_OFF + KIOU_SQO_ARRAY]
    mov ecx, [rsp + KIOU_P_SQ_ENT]
    shl rcx, 2
    add r13, rcx

    # cring_sz = cq_off.cqes + cq_entries * 16
    mov r14d, [rsp + KIOU_P_CQ_OFF + KIOU_CQO_CQES]
    mov ecx, [rsp + KIOU_P_CQ_ENT]
    imul rcx, rcx, KCQE_SIZE
    add r14, rcx

    # Handle IORING_FEAT_SINGLE_MMAP
    mov eax, [rsp + KIOU_P_FEAT]
    test eax, IORING_FEAT_SINGLE_MMAP
    jz .Loui_map_sq
    cmp r14, r13
    cmova r13, r14
    mov r14, r13

.Loui_map_sq:
    xor edi, edi
    mov rsi, r13
    mov edx, PROT_READ | PROT_WRITE
    mov r10d, MAP_SHARED | MAP_POPULATE
    mov r8d, r12d
    mov r9, IORING_OFF_SQ_RING
    mov eax, OS_SYS_mmap
    syscall
    cmp rax, -4096
    jae .Loui_fail_cleanup
    mov [g_uring_sq_ptr], rax
    mov [g_uring_sq_sz], r13
    mov rbx, rax

    test dword ptr [rsp + KIOU_P_FEAT], IORING_FEAT_SINGLE_MMAP
    jz .Loui_map_cq
    mov [g_uring_cq_ptr], rax
    mov qword ptr [g_uring_cq_sz], 0
    mov rcx, rax
    jmp .Loui_setup_ptrs

.Loui_map_cq:
    xor edi, edi
    mov rsi, r14
    mov edx, PROT_READ | PROT_WRITE
    mov r10d, MAP_SHARED | MAP_POPULATE
    mov r8d, r12d
    mov r9, IORING_OFF_CQ_RING
    mov eax, OS_SYS_mmap
    syscall
    cmp rax, -4096
    jae .Loui_fail_cleanup
    mov [g_uring_cq_ptr], rax
    mov [g_uring_cq_sz], r14
    mov rcx, rax

.Loui_setup_ptrs:
    # SQ offsets relative to rbx
    mov eax, [rsp + KIOU_P_SQ_OFF + KIOU_SQO_HEAD]
    add rax, rbx
    mov [g_uring_sq_head], rax
    mov eax, [rsp + KIOU_P_SQ_OFF + KIOU_SQO_TAIL]
    add rax, rbx
    mov [g_uring_sq_tail], rax
    mov eax, [rsp + KIOU_P_SQ_OFF + KIOU_SQO_MASK]
    mov eax, [rbx + rax]
    mov [g_uring_sq_mask], eax
    mov eax, [rsp + KIOU_P_SQ_OFF + KIOU_SQO_ARRAY]
    add rax, rbx
    mov [g_uring_sq_array], rax

    # CQ offsets relative to rcx
    mov eax, [rsp + KIOU_P_CQ_OFF + KIOU_CQO_HEAD]
    add rax, rcx
    mov [g_uring_cq_head], rax
    mov eax, [rsp + KIOU_P_CQ_OFF + KIOU_CQO_TAIL]
    add rax, rcx
    mov [g_uring_cq_tail], rax
    mov eax, [rsp + KIOU_P_CQ_OFF + KIOU_CQO_MASK]
    mov eax, [rcx + rax]
    mov [g_uring_cq_mask], eax
    mov eax, [rsp + KIOU_P_CQ_OFF + KIOU_CQO_CQES]
    add rax, rcx
    mov [g_uring_cqes], rax

    # Map SQEs
    mov esi, [rsp + KIOU_P_SQ_ENT]
    imul rsi, rsi, KSQE_SIZE
    mov [g_uring_sqes_sz], rsi
    xor edi, edi
    mov edx, PROT_READ | PROT_WRITE
    mov r10d, MAP_SHARED | MAP_POPULATE
    mov r8d, r12d
    mov r9, IORING_OFF_SQES
    mov eax, OS_SYS_mmap
    syscall
    cmp rax, -4096
    jae .Loui_fail_cleanup
    mov [g_uring_sqes_ptr], rax

    # Map scratch statx arena
    xor edi, edi
    mov rsi, STATX_ARENA_SZ
    mov edx, PROT_READ | PROT_WRITE
    mov r10d, MAP_PRIVATE_ANON
    mov r8d, -1
    xor r9d, r9d
    mov eax, OS_SYS_mmap
    syscall
    cmp rax, -4096
    jae .Loui_fail_cleanup
    mov [g_uring_statx_buf], rax

    mov dword ptr [g_uring_state], 1
    xor eax, eax
    add rsp, 136
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.Loui_fail_cleanup:
    mov dword ptr [g_uring_state], 1
    call os_uring_shutdown
.Loui_fail:
    mov dword ptr [g_uring_state], -1
    mov eax, -1
    add rsp, 136
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# int os_batch_stat(int dirfd, const char * const *names, FileStat *out_stats,
#                   int32_t *out_errs, size_t count, int follow_symlinks)
# Populates out_stats[0..count-1] and optional out_errs[0..count-1] (0 or -errno).
# io_uring path keeps up to URING_DEPTH statx requests in flight as a rolling window: every
# io_uring_enter submits the newly prepared SQEs and returns as soon as >= 1 completes; each
# reaped CQE frees its arena slot, which is immediately reused (no drain barrier per batch).
# Returns 0 when the batch finishes.
os_batch_stat:
    test r8, r8
    jz .Lobs_ret_zero

    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 72
    # [rsp+0]=count [8]=next [16]=out_stats [24]=out_errs [32]=follow(d) [36]=statx_flags(d)
    # [40]=done [48]=dirfd(d) [52]=in_flight(d) [56]=unsubmitted [64]=free_top(d)
    mov [rsp + 0], r8
    mov [rsp + 16], rdx
    mov [rsp + 24], rcx
    mov [rsp + 32], r9d
    mov [rsp + 48], edi
    xor eax, eax
    mov [rsp + 8], rax
    mov [rsp + 40], rax
    mov [rsp + 52], eax
    mov [rsp + 56], rax
    test r9d, r9d
    jnz .Lobs_flags_ok
    mov eax, AT_SYMLINK_NOFOLLOW
.Lobs_flags_ok:
    mov [rsp + 36], eax
    mov r12, rsi                      # names**

    cmp r8, URING_BATCH_MIN
    jb .Lobs_fallback
    mov eax, [g_uring_state]
    cmp eax, -1
    je .Lobs_fallback
    test eax, eax
    jnz .Lobs_init_free
    call os_uring_init
    test eax, eax
    js .Lobs_fallback

.Lobs_init_free:
    xor ecx, ecx
    lea rdx, [g_uring_free]
.Lobs_free_init:
    mov [rdx + rcx], cl
    inc ecx
    cmp ecx, URING_DEPTH
    jb .Lobs_free_init
    mov dword ptr [rsp + 64], URING_DEPTH

.Lobs_roll:
    mov rax, [rsp + 40]
    cmp rax, [rsp + 0]
    jae .Lobs_done_ok

    # ---- fill free window slots with new SQEs ----
    mov rax, [g_uring_sq_tail]
    mov r14d, [rax]                   # local sq tail
    xor ebp, ebp                      # prepared this round
.Lobs_fill:
    mov rax, [rsp + 8]
    cmp rax, [rsp + 0]
    jae .Lobs_publish
    cmp dword ptr [rsp + 52], URING_DEPTH
    jae .Lobs_publish
    dec dword ptr [rsp + 64]
    mov ecx, [rsp + 64]
    lea rdx, [g_uring_free]
    movzx r13d, byte ptr [rdx + rcx]  # arena slot
    mov edx, r14d
    add edx, ebp
    and edx, [g_uring_sq_mask]        # sqe index
    mov eax, edx
    shl rax, 6
    mov rdi, [g_uring_sqes_ptr]
    add rdi, rax
    xor eax, eax
    mov [rdi + 0], rax
    mov [rdi + 8], rax
    mov [rdi + 16], rax
    mov [rdi + 24], rax
    mov [rdi + 32], rax
    mov [rdi + 40], rax
    mov [rdi + 48], rax
    mov [rdi + 56], rax
    mov byte ptr [rdi + KSQE_OP], IORING_OP_STATX
    mov eax, [rsp + 48]
    mov [rdi + KSQE_FD], eax
    mov rax, r13
    shl rax, 8                        # slot * KSTATX_SIZE
    add rax, [g_uring_statx_buf]
    mov [rdi + KSQE_OFF], rax
    mov rax, [rsp + 8]
    mov rcx, [r12 + rax * 8]
    mov [rdi + KSQE_ADDR], rcx
    mov dword ptr [rdi + KSQE_LEN], STATX_BASIC_STATS
    mov ecx, [rsp + 36]; or ecx, 0x4000 # AT_STATX_DONT_SYNC
    mov [rdi + KSQE_STATX_FLAGS], ecx
    shl rax, 8
    or rax, r13                       # udata = item << 8 | slot
    mov [rdi + KSQE_UDATA], rax
    mov rax, [g_uring_sq_array]
    mov [rax + rdx * 4], edx
    inc qword ptr [rsp + 8]
    inc dword ptr [rsp + 52]
    inc ebp
    jmp .Lobs_fill

.Lobs_publish:
    sfence
    add r14d, ebp
    mov rax, [g_uring_sq_tail]
    mov [rax], r14d
    add [rsp + 56], rbp

    # ---- submit pending SQEs, wait for at least one completion ----
.Lobs_enter:
    mov edi, [g_uring_fd]
    mov esi, [rsp + 56]               # to_submit
    xor edx, edx
    cmp dword ptr [rsp + 52], 0
    je .Lobs_enter_go
    mov edx, 1                        # min_complete
.Lobs_enter_go:
    mov r10d, IORING_ENTER_GETEVENTS
    xor r8d, r8d
    xor r9d, r9d
    mov eax, OS_SYS_io_uring_enter
    syscall
    cmp rax, -EINTR
    je .Lobs_reap
    test rax, rax
    js .Lobs_uring_err
    sub [rsp + 56], rax

    # ---- reap every available completion, recycle slots ----
.Lobs_reap:
    mov rax, [g_uring_cq_head]
    mov r13d, [rax]                   # head
    mov rax, [g_uring_cq_tail]
    mov r15d, [rax]                   # tail
    lfence
.Lobs_cq_loop:
    cmp r13d, r15d
    je .Lobs_cq_done
    mov eax, r13d
    and eax, [g_uring_cq_mask]
    shl rax, 4
    add rax, [g_uring_cqes]
    mov rbx, [rax + KCQE_UDATA]
    movsxd rbp, dword ptr [rax + KCQE_RES]
    mov r14, rbx
    shr r14, 8                        # item index
    and ebx, 0xFF                     # slot
    mov rax, [rsp + 24]
    test rax, rax
    jz .Lobs_no_err
    mov [rax + r14 * 4], ebp
.Lobs_no_err:
    test ebp, ebp
    jnz .Lobs_slot_free
    imul rdi, r14, FileStat._size
    add rdi, [rsp + 16]
    mov rsi, rbx
    shl rsi, 8
    add rsi, [g_uring_statx_buf]
    call copy_statx_to_filestat
.Lobs_slot_free:
    mov ecx, [rsp + 64]
    lea rdx, [g_uring_free]
    mov [rdx + rcx], bl
    inc dword ptr [rsp + 64]
    dec dword ptr [rsp + 52]
    inc qword ptr [rsp + 40]
    inc r13d
    jmp .Lobs_cq_loop
.Lobs_cq_done:
    sfence
    mov rax, [g_uring_cq_head]
    mov [rax], r13d
    jmp .Lobs_roll

.Lobs_uring_err:
    # Disable the ring and redo the whole batch synchronously (always correct)
    call os_uring_shutdown
    mov dword ptr [g_uring_state], -1
    mov qword ptr [rsp + 8], 0

.Lobs_fallback:
    mov rbx, [rsp + 8]
    mov r13, [rsp + 0]
    cmp rbx, r13
    jae .Lobs_done_ok
    imul r14, rbx, FileStat._size
    add r14, [rsp + 16]
    mov r15, [rsp + 24]
.Lobs_fb_loop:
    mov edi, [rsp + 48]
    mov rsi, [r12 + rbx * 8]
    mov rdx, r14
    mov ecx, [rsp + 32]
    call os_statat
    test r15, r15
    jz .Lobs_fb_next
    mov [r15 + rbx * 4], eax
.Lobs_fb_next:
    add r14, FileStat._size
    inc rbx
    cmp rbx, r13
    jb .Lobs_fb_loop

.Lobs_done_ok:
    add rsp, 72
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
.Lobs_ret_zero:
    xor eax, eax
    ret
