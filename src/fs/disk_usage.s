# src/fs/disk_usage.s - High-speed ncdu-style Disk Usage calculator (io_uring batch statx + dir cache)
.intel_syntax noprefix

.include "pal.inc"
.include "classes.inc"

.equ DU_MAX_DEPTH, 24
.equ DU_BATCH,     64
.equ DU_OFF_PTRS,  32768
.equ DU_OFF_ERRS,  33280      # 32768 + 64 * 8
.equ DU_OFF_STATS, 33536      # 33280 + 64 * 4
.equ DU_STRIDE,    40960      # 32768 + 8192 per recursion level

.section .text
.global du_calc_tree
.global dir_du_populate
.global du_toggle
.global du_mtime_sig

.extern DirModel_step_load
.extern DirModel_sort
.extern DirModel_reload
.extern DirModel_entry_name
.extern os_dir_read
.extern os_dir_next_ex
.extern os_statat
.extern os_fstat
.extern os_batch_stat
.extern du_cache_get
.extern du_cache_put
.extern du_parallel_walk
.extern mem_alloc
.extern mem_free

# int64_t du_mtime_sig(const FileStat *st)
du_mtime_sig:
    mov rax, [rdi + FileStat.mtime]
    mov ecx, [rdi + FileStat.mtime_nsec]
    shl rcx, 32
    xor rax, rcx
    ret

# uint64_t du_flush_batch(int dfd, void *lvl_buf, int count)
du_flush_batch:
    test edx, edx
    jz .Ldfb_zero
    push rbx
    push r12
    mov ebx, edx              # count
    mov r12, rsi              # lvl_buf
    lea rsi, [r12 + DU_OFF_PTRS]
    lea rdx, [r12 + DU_OFF_STATS]
    lea rcx, [r12 + DU_OFF_ERRS]
    mov r8d, ebx
    xor r9d, r9d              # follow = 0 (AT_SYMLINK_NOFOLLOW)
    call os_batch_stat
    xor eax, eax              # sum = 0
    xor ecx, ecx              # i = 0
    lea r8, [r12 + DU_OFF_ERRS]
    lea r9, [r12 + DU_OFF_STATS]
.Ldfb_sum:
    cmp ecx, ebx
    jge .Ldfb_done
    cmp dword ptr [r8 + rcx*4], 0
    jne .Ldfb_next
    imul r10, rcx, FileStat._size
    add rax, [r9 + r10 + FileStat.size]
.Ldfb_next:
    inc ecx
    jmp .Ldfb_sum
.Ldfb_done:
    pop r12
    pop rbx
    ret
.Ldfb_zero:
    xor eax, eax
    ret

# uint64_t du_walk_fd(int dfd, void *lvl_buf, int depth)
du_walk_fd:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, FileStat._size + 56
    mov ebx, edi; mov r12, rsi; mov r13d, edx; xor r14d, r14d
    cmp r13d, DU_MAX_DEPTH; jge .Ldwf_ret
    mov qword ptr [rsp + FileStat._size + 32], 0
    mov dword ptr [rsp + FileStat._size + 48], 0
    mov edi, ebx; mov rsi, rsp; call os_fstat
    test rax, rax; js .Ldwf_read
    mov dword ptr [rsp + FileStat._size + 48], 1
    mov rdi, rsp; call du_mtime_sig
    mov [rsp + FileStat._size + 40], rax
    mov rdi, [rsp + FileStat.ino]; mov rsi, [rsp + FileStat.dev]
    mov rdx, rax; lea rcx, [rsp + FileStat._size + 24]
    call du_cache_get
    test eax, eax; jz .Ldwf_read
    mov r14, [rsp + FileStat._size + 24]; jmp .Ldwf_ret
.Ldwf_read:
    mov edi, ebx; mov rsi, r12; mov edx, 32768; call os_dir_read
    test rax, rax; jle .Ldwf_cache_put
    mov [rsp + FileStat._size], rax
    mov qword ptr [rsp + FileStat._size + 8], 0
.Ldwf_ent:
    mov rdi, r12; mov rsi, [rsp + FileStat._size]
    lea rdx, [rsp + FileStat._size + 8]; lea rcx, [rsp + FileStat._size + 16]
    lea r8, [rsp + FileStat._size + 24]; call os_dir_next_ex
    test rax, rax; jz .Ldwf_chunk_end
    mov r15, rax
    cmp byte ptr [r15], '.'; jne .Ldwf_chk_type
    cmp byte ptr [r15 + 1], 0; je .Ldwf_ent
    cmp word ptr [r15 + 1], '.'; je .Ldwf_ent
.Ldwf_chk_type:
    movzx eax, byte ptr [rsp + FileStat._size + 16]
    cmp eax, PAL_DT_LNK; je .Ldwf_ent
    cmp eax, PAL_DT_REG; je .Ldwf_batch_add
    cmp eax, PAL_DT_DIR; je .Ldwf_dir
    mov edi, ebx; mov rsi, r15; mov rdx, r12; mov ecx, r13d
    call du_stat_unknown
    add r14, rax; jmp .Ldwf_ent
.Ldwf_batch_add:
    mov ecx, [rsp + FileStat._size + 32]
    mov [r12 + DU_OFF_PTRS + rcx*8], r15
    inc ecx; mov [rsp + FileStat._size + 32], ecx
    cmp ecx, DU_BATCH; jl .Ldwf_ent
    mov edi, ebx; mov rsi, r12; mov edx, ecx; call du_flush_batch
    add r14, rax; mov dword ptr [rsp + FileStat._size + 32], 0; jmp .Ldwf_ent
.Ldwf_chunk_end:
    mov edx, [rsp + FileStat._size + 32]; test edx, edx; jz .Ldwf_read
    mov edi, ebx; mov rsi, r12; call du_flush_batch
    add r14, rax; mov dword ptr [rsp + FileStat._size + 32], 0; jmp .Ldwf_read
.Ldwf_dir:
    mov edi, ebx; mov rsi, r15
    mov edx, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW; xor r10d, r10d; OS_OPENAT
    test rax, rax; js .Ldwf_ent
    push rax
    mov edi, eax; lea rsi, [r12 + DU_STRIDE]; lea edx, [r13d + 1]; call du_walk_fd
    add r14, rax; pop rdi; OS_CLOSE; jmp .Ldwf_ent
.Ldwf_cache_put:
    cmp dword ptr [rsp + FileStat._size + 48], 0
    je .Ldwf_ret
    mov rdi, [rsp + FileStat.ino]; mov rsi, [rsp + FileStat.dev]
    mov rdx, [rsp + FileStat._size + 40]; mov rcx, r14; call du_cache_put
.Ldwf_ret:
    mov rax, r14
    add rsp, FileStat._size + 56
    pop r15; pop r14; pop r13; pop r12; pop rbx; ret

# Helper for PAL_DT_UNKNOWN entries: returns file size or recurses on dir
du_stat_unknown:
    push rbx; push r12; push r13; push r14; sub rsp, FileStat._size + 8
    mov ebx, edi; mov r12, rsi; mov r13, rdx; mov r14d, ecx
    mov rdx, rsp; xor ecx, ecx; call os_statat
    test rax, rax; js .Ldsu_zero
    mov eax, [rsp + FileStat.mode]; and eax, S_IFMT
    cmp eax, S_IFDIR; je .Ldsu_dir
    cmp eax, S_IFREG; jne .Ldsu_zero
    mov rax, [rsp + FileStat.size]; jmp .Ldsu_ret
.Ldsu_dir:
    mov edi, ebx; mov rsi, r12
    mov edx, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    xor r10d, r10d; OS_OPENAT
    test rax, rax; js .Ldsu_zero
    push rax
    mov edi, eax; lea rsi, [r13 + DU_STRIDE]; lea edx, [r14d + 1]
    call du_walk_fd
    pop rdi; push rax; OS_CLOSE; pop rax; jmp .Ldsu_ret
.Ldsu_zero:
    xor eax, eax
.Ldsu_ret:
    add rsp, FileStat._size + 8; pop r14; pop r13; pop r12; pop rbx; ret

# uint64_t du_calc_tree(int dfd, const char *name)
du_calc_tree:
    push rbx; push r12; push r13
    mov ebx, edi; mov r12, rsi
    mov edi, DU_MAX_DEPTH * DU_STRIDE; call mem_alloc
    test rax, rax; jz .Ldct_zero
    mov r13, rax
    mov edi, ebx; mov rsi, r12
    mov edx, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    xor r10d, r10d; OS_OPENAT
    test rax, rax; js .Ldct_free
    push rax
    mov edi, eax; mov rsi, r13; xor edx, edx
    call du_walk_fd
    mov rbx, rax
    pop rdi; OS_CLOSE
    mov rdi, r13; call mem_free
    mov rax, rbx; pop r13; pop r12; pop rbx; ret
.Ldct_free:
    mov rdi, r13; call mem_free
.Ldct_zero:
    xor eax, eax; pop r13; pop r12; pop rbx; ret

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
    lea rsi, [r12 + DU_STRIDE]
    cmp r13d, 1; jne .Lrm_par
    mov rdi, [rsi + 8]                # name
    mov r13, [rsi]                    # save FileEntry* before du_walk_fd overwrites arena+DU_STRIDE
    mov rsi, rdi; mov edi, ebx
    mov edx, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    xor r10d, r10d; OS_OPENAT
    test rax, rax; js .Lrm_zero_pop
    push rax
    mov edi, eax; mov rsi, r12; xor edx, edx; call du_walk_fd
    mov [r13 + FileEntry.size], rax
    or dword ptr [r13 + FileEntry.flags], FE_STAT_READY
    mov r12, rax
    pop rdi; OS_CLOSE
    mov rax, r12; jmp .Lrm_ret
.Lrm_par:
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
.Lrm_zero_pop:
    xor eax, eax
.Lrm_ret:
    add rsp, 8; pop r13; pop r12; pop rbx; ret
.Lrm_zero:
    xor eax, eax; ret

# void dir_du_populate(DirModel *model)
dir_du_populate:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, FileStat._size + 32
    mov rbx, rdi
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
    test dword ptr [r14 + FileEntry.flags], FE_STAT_READY; jnz .Lddp_add
    mov edi, [rsp + FileStat._size]; mov rsi, r15; mov rdx, rsp; xor ecx, ecx
    call os_statat
    test rax, rax; js .Lddp_next
    mov rax, [rsp + FileStat.size]; mov [r14 + FileEntry.size], rax
    or dword ptr [r14 + FileEntry.flags], FE_STAT_READY
    jmp .Lddp_add
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
.Lddp_add:
    add r12, [r14 + FileEntry.size]
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
    mov [rbx + DirModel.du_total], r12
    mov dword ptr [rbx + DirModel.du_mode], 1
    mov dword ptr [rbx + DirModel.sort_mode], SORT_SIZE
    mov dword ptr [rbx + DirModel.sort_desc], 1
    mov dword ptr [rbx + DirModel.stats_complete], 1
    mov dword ptr [rbx + DirModel.is_unsorted], 0
    mov rdi, rbx; call DirModel_sort
.Lddp_ret:
    add rsp, FileStat._size + 32
    pop r15; pop r14; pop r13; pop r12; pop rbx; ret

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
    mov dword ptr [r12 + DirModel.du_mode], 0
    mov dword ptr [r12 + DirModel.sort_mode], SORT_NAME
    mov dword ptr [r12 + DirModel.sort_desc], 0
    mov rdi, r12; call DirModel_reload
.Ldut_done:
    mov dword ptr [rbx + App.need_redraw], 1
    pop r12; pop rbx; ret
