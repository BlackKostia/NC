# src/fs/disk_usage.s - ncdu-style Disk Usage: allocated space like `du` (st_blocks, directories
# included, derived mounts skipped -- see du_parallel.s), io_uring batch statx + subtree cache
.intel_syntax noprefix

.include "pal.inc"
.include "classes.inc"

.equ DU_MAX_DEPTH, 64
.equ DU_BATCH,     64
.equ DU_OFF_PTRS,  32768
.equ DU_OFF_ERRS,  33280      # 32768 + 64 * 8
.equ DU_OFF_STATS, 33536      # 33280 + 64 * 4
.equ DU_STRIDE,    40960      # 32768 + 8192 per recursion level

.section .text
.global dir_du_populate
.global du_toggle
.global du_mtime_sig

.extern DirModel_step_load
.extern DirModel_sort
.extern DirModel_reload
.extern DirModel_entry_name
.extern os_du_usage
.extern os_batch_stat
.extern du_cache_get
.extern du_parallel_walk
.extern du_progress
.extern du_links_reset
.extern du_link_first
.extern mem_alloc
.extern mem_free

# int64_t du_mtime_sig(const FileStat *st)
du_mtime_sig:
    mov rax, [rdi + FileStat.mtime]
    mov ecx, [rdi + FileStat.mtime_nsec]
    shl rcx, 32
    xor rax, rcx
    ret

# uint64_t du_flush_dir_batch(int dfd, void *arena, int count, int *miss_cnt)
du_flush_dir_batch:
    test edx, edx
    jz .Lfdb_zero
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, 32
    mov ebx, edi; mov r12, rsi; mov r13d, edx; mov [rsp + 16], rcx; xor r14d, r14d
    lea rsi, [r12 + DU_OFF_PTRS]
    lea rdx, [r12 + DU_OFF_STATS]
    lea rcx, [r12 + DU_OFF_ERRS]
    mov r8d, r13d; xor r9d, r9d
    call os_batch_stat
    xor r15d, r15d
.Lfdb_loop:
    cmp r15d, r13d; jge .Lfdb_done
    lea rax, [r12 + DU_OFF_ERRS]
    cmp dword ptr [rax + r15 * 4], 0; jne .Lfdb_miss
    imul rax, r15, FileStat._size
    lea rdi, [r12 + DU_OFF_STATS]; add rdi, rax
    mov [rsp + 8], rdi; call du_mtime_sig
    mov r8, [rsp + 8]
    mov rdi, [r8 + FileStat.ino]; mov rsi, [r8 + FileStat.dev]
    mov rdx, rax; mov rcx, rsp; call du_cache_get
    test eax, eax; jz .Lfdb_miss
    mov rax, [rsp]
    mov rcx, [r12 + r15 * 8]
    mov [rcx + FileEntry.size], rax
    or dword ptr [rcx + FileEntry.flags], FE_STAT_READY
    add r14, rax; jmp .Lfdb_next
.Lfdb_miss:
    mov r8, [rsp + 16]
    mov eax, [r8]
    cmp eax, 32768; jge .Lfdb_next
    inc dword ptr [r8]
    imul rax, rax, 24
    lea r9, [r12 + DU_STRIDE]; add r9, rax
    mov rcx, [r12 + r15 * 8]; mov [r9], rcx
    lea rax, [r12 + DU_OFF_PTRS]; mov rsi, [rax + r15 * 8]; mov [r9 + 8], rsi
    mov qword ptr [r9 + 16], 0
.Lfdb_next:
    inc r15d; jmp .Lfdb_loop
.Lfdb_done:
    mov rax, r14
    add rsp, 32; pop r15; pop r14; pop r13; pop r12; pop rbx; ret
.Lfdb_zero:
    xor eax, eax; ret

# uint64_t du_resolve_misses(int dfd, void *arena, int miss_cnt)
du_resolve_misses:
    test edx, edx; jz .Lrm_zero
    push rbx; push r12; push r13; sub rsp, 8
    mov ebx, edi; mov r12, rsi; mov r13d, edx
    lea rsi, [r12 + DU_STRIDE]        # even one folder goes to a worker: the UI shows progress
    mov edi, ebx; mov edx, r13d; call du_parallel_walk
    xor eax, eax; xor ecx, ecx
    lea r8, [r12 + DU_STRIDE]
.Lrm_sum:
    cmp ecx, r13d; jge .Lrm_ret
    imul rdx, rcx, 24; add rdx, r8
    mov r9, [rdx]; mov r10, [rdx + 16]
    mov [r9 + FileEntry.size], r10
    or dword ptr [r9 + FileEntry.flags], FE_STAT_READY
    add rax, r10; inc ecx; jmp .Lrm_sum
.Lrm_ret:
    add rsp, 8; pop r13; pop r12; pop rbx; ret
.Lrm_zero:
    xor eax, eax; ret

# int dir_du_populate(DirModel *model) -> 1 done, 0 canceled from the progress UI (Esc): the
# model is then back in the normal listing
dir_du_populate:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, FileStat._size + 32
    mov rbx, rdi
    call du_progress
    mov dword ptr [rax + DuProgress.cancel], 0
    call du_links_reset               # hard links count once per scan
.Lddp_drain:
    cmp dword ptr [rbx + DirModel.is_loading], 0
    je .Lddp_open
    mov rdi, rbx; mov esi, 4096; call DirModel_step_load; jmp .Lddp_drain
.Lddp_open:
    mov edi, AT_FDCWD; lea rsi, [rbx + DirModel.path]
    mov edx, O_RDONLY | O_DIRECTORY | O_CLOEXEC; xor r10d, r10d; OS_OPENAT
    test rax, rax; js .Lddp_ret
    mov [rsp + FileStat._size], eax
    mov dword ptr [rsp + FileStat._size + 4], 0
    mov dword ptr [rsp + FileStat._size + 16], 0
    mov edi, DU_MAX_DEPTH * DU_STRIDE; call mem_alloc
    mov [rsp + FileStat._size + 8], rax
    xor r12d, r12d            # total_bytes
    xor r13d, r13d            # i = 0
.Lddp_loop:
    cmp r13, [rbx + DirModel.raw_count]; jae .Lddp_flush
    mov rax, r13; imul rax, FileEntry._size; add rax, [rbx + DirModel.entries]
    mov r14, rax
    test dword ptr [r14 + FileEntry.flags], FE_IS_PARENT; jnz .Lddp_next
    mov rdi, rbx; mov rsi, r14; call DirModel_entry_name
    mov r15, rax
    test dword ptr [r14 + FileEntry.flags], FE_IS_DIR; jnz .Lddp_dir
    mov edi, [rsp + FileStat._size]; mov rsi, r15; mov rdx, r14; mov rcx, rsp
    call du_top_file
    add r12, rax; jmp .Lddp_next
.Lddp_dir:
    mov rcx, [rsp + FileStat._size + 8]; test rcx, rcx; jz .Lddp_next
    mov edx, [rsp + FileStat._size + 4]
    mov [rcx + rdx * 8], r14
    lea rax, [rcx + DU_OFF_PTRS]; mov [rax + rdx * 8], r15
    inc edx; mov [rsp + FileStat._size + 4], edx
    cmp edx, DU_BATCH; jl .Lddp_next
    mov edi, [rsp + FileStat._size]; mov rsi, rcx
    lea rcx, [rsp + FileStat._size + 16]; call du_flush_dir_batch
    add r12, rax; mov dword ptr [rsp + FileStat._size + 4], 0; jmp .Lddp_next
.Lddp_next:
    inc r13; jmp .Lddp_loop
.Lddp_flush:
    mov edx, [rsp + FileStat._size + 4]; test edx, edx; jz .Lddp_misses
    mov rsi, [rsp + FileStat._size + 8]; test rsi, rsi; jz .Lddp_misses
    mov edi, [rsp + FileStat._size]; lea rcx, [rsp + FileStat._size + 16]
    call du_flush_dir_batch; add r12, rax
.Lddp_misses:
    mov edx, [rsp + FileStat._size + 16]; test edx, edx; jz .Lddp_done
    mov rsi, [rsp + FileStat._size + 8]; test rsi, rsi; jz .Lddp_done
    mov edi, [rsp + FileStat._size]; call du_resolve_misses; add r12, rax
.Lddp_done:
    mov rdi, [rsp + FileStat._size + 8]; test rdi, rdi; jz .Lddp_close
    call mem_free
.Lddp_close:
    mov edi, [rsp + FileStat._size]; OS_CLOSE
    mov rdi, rbx; mov rsi, r12; call du_finish
    jmp .Lddp_out
.Lddp_ret:
    xor eax, eax
.Lddp_out:
    add rsp, FileStat._size + 32
    pop r15; pop r14; pop r13; pop r12; pop rbx; ret

# Internal: uint64_t du_top_file(int dfd, const char *name, FileEntry *e, FileStat *st) -- shows the
# allocated size of a listed non-directory (sparse files, symlinks) and returns what it adds to the
# total: 0 for another name of a hard-linked inode already counted
du_top_file:
    push rbx
    push r12
    push r13
    mov rbx, rdx
    mov r12, rcx
    mov rdx, rcx
    call os_du_usage
    test rax, rax
    js .Ltf_zero
    mov [rbx + FileEntry.size], rax
    or dword ptr [rbx + FileEntry.flags], FE_STAT_READY
    cmp qword ptr [r12 + FileStat.nlink], 1
    jbe .Ltf_ret
    mov r13, rax
    mov rdi, [r12 + FileStat.dev]
    mov rsi, [r12 + FileStat.ino]
    call du_link_first
    test eax, eax
    jz .Ltf_zero
    mov rax, r13
    jmp .Ltf_ret
.Ltf_zero:
    xor eax, eax
.Ltf_ret:
    pop r13
    pop r12
    pop rbx
    ret

# Internal: int du_finish(DirModel *model, uint64_t total) -> 1: size-sorted Disk Usage view;
# 0 when the walk was canceled from the progress UI (back to the normal listing)
du_finish:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    call du_progress
    cmp dword ptr [rax + DuProgress.cancel], 0
    jne .Ldf_canceled
    mov [rbx + DirModel.du_total], r12
    mov [rbx + DirModel.total_bytes], r12     # pane summary: allocated space too
    mov dword ptr [rbx + DirModel.du_mode], 1
    mov dword ptr [rbx + DirModel.sort_mode], SORT_SIZE
    mov dword ptr [rbx + DirModel.sort_desc], 1
    mov dword ptr [rbx + DirModel.stats_complete], 1
    mov dword ptr [rbx + DirModel.is_unsorted], 0
    mov rdi, rbx; call DirModel_sort
    mov eax, 1
    jmp .Ldf_ret
.Ldf_canceled:
    mov rdi, rbx; call du_leave
    xor eax, eax
.Ldf_ret:
    add rsp, 8
    pop r12
    pop rbx
    ret

# Internal: void du_leave(DirModel *model) -- back to the normal name-sorted listing
du_leave:
    mov dword ptr [rdi + DirModel.du_mode], 0
    mov dword ptr [rdi + DirModel.sort_mode], SORT_NAME
    mov dword ptr [rdi + DirModel.sort_desc], 0
    jmp DirModel_reload

# void du_toggle(App *app)
du_toggle:
    push rbx; push r12
    mov rbx, rdi
    mov rax, [rbx + App.active_pane]
    mov r12, [rax + FilePane.model]
    cmp dword ptr [r12 + DirModel.du_mode], 0
    jne .Ldut_off
    mov rdi, r12; call dir_du_populate
    jmp .Ldut_done
.Ldut_off:
    mov rdi, r12; call du_leave
.Ldut_done:
    mov dword ptr [rbx + App.need_redraw], 1
    pop r12; pop rbx; ret
