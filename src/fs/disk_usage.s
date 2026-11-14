# src/fs/disk_usage.s - ncdu-style recursive Disk Usage calculator
.intel_syntax noprefix

.include "pal.inc"
.include "classes.inc"

.equ DU_MAX_DEPTH, 24

.section .text
.global du_calc_tree
.global dir_du_populate
.global du_toggle

.extern DirModel_step_load
.extern DirModel_sort
.extern DirModel_reload
.extern DirModel_entry_name
.extern os_dir_read
.extern os_dir_next_ex
.extern os_statat
.extern mem_alloc
.extern mem_free

# uint64_t du_walk_fd(int dfd, void *dbuf, int depth)
du_walk_fd:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, FileStat._size + 32
    mov ebx, edi              # dfd
    mov r12, rsi              # dbuf
    mov r13d, edx             # depth
    xor r14d, r14d            # total = 0
    cmp r13d, DU_MAX_DEPTH; jge .Ldwf_ret

.Ldwf_read:
    mov edi, ebx; mov rsi, r12; mov edx, 32768
    call os_dir_read
    test rax, rax; jle .Ldwf_ret
    mov [rsp + FileStat._size], rax
    mov qword ptr [rsp + FileStat._size + 8], 0

.Ldwf_ent:
    mov rdi, r12
    mov rsi, [rsp + FileStat._size]
    lea rdx, [rsp + FileStat._size + 8]
    lea rcx, [rsp + FileStat._size + 16]  # d_type (4)
    lea r8, [rsp + FileStat._size + 24]   # ino (8)
    call os_dir_next_ex
    test rax, rax; jz .Ldwf_read
    mov r15, rax
    cmp byte ptr [r15], '.'; jne .Ldwf_chk_type
    cmp byte ptr [r15 + 1], 0; je .Ldwf_ent
    cmp byte ptr [r15 + 1], '.'; jne .Ldwf_chk_type
    cmp byte ptr [r15 + 2], 0; je .Ldwf_ent

.Ldwf_chk_type:
    movzx eax, byte ptr [rsp + FileStat._size + 16]   # d_type is a byte
    cmp eax, PAL_DT_LNK; je .Ldwf_ent
    cmp eax, PAL_DT_DIR; je .Ldwf_dir
    mov edi, ebx; mov rsi, r15; mov rdx, rsp; xor ecx, ecx
    call os_statat
    test rax, rax; js .Ldwf_ent
    mov eax, [rsp + FileStat.mode]
    and eax, S_IFMT
    cmp eax, S_IFLNK; je .Ldwf_ent
    cmp eax, S_IFDIR; je .Ldwf_dir
    add r14, [rsp + FileStat.size]
    jmp .Ldwf_ent

.Ldwf_dir:
    mov edi, ebx; mov rsi, r15
    mov edx, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    xor r10d, r10d; OS_OPENAT
    test rax, rax; js .Ldwf_ent
    push rax
    mov edi, eax; mov rsi, r12; lea edx, [r13d + 1]
    call du_walk_fd
    add r14, rax
    pop rdi
    OS_CLOSE
    jmp .Ldwf_ent

.Ldwf_ret:
    mov rax, r14
    add rsp, FileStat._size + 32
    pop r15; pop r14; pop r13; pop r12; pop rbx; ret

# uint64_t du_calc_tree(int dfd, const char *name)
du_calc_tree:
    push rbx; push r12; push r13
    mov ebx, edi; mov r12, rsi
    mov edi, 32768; call mem_alloc
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

# void dir_du_populate(DirModel *model)
dir_du_populate:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, FileStat._size + 16
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
    mov edi, 32768; call mem_alloc
    mov [rsp + FileStat._size + 8], rax
    xor r12d, r12d            # total_bytes
    xor r13d, r13d            # i = 0
.Lddp_loop:
    cmp r13, [rbx + DirModel.raw_count]; jae .Lddp_done
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
    cmp qword ptr [rsp + FileStat._size + 8], 0; je .Lddp_next
    mov edi, [rsp + FileStat._size]; mov rsi, r15
    mov edx, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    xor r10d, r10d; OS_OPENAT
    test rax, rax; js .Lddp_next
    push rax
    mov edi, eax; mov rsi, [rsp + FileStat._size + 16]; xor edx, edx
    call du_walk_fd
    mov [r14 + FileEntry.size], rax
    or dword ptr [r14 + FileEntry.flags], FE_STAT_READY
    pop rdi; OS_CLOSE
.Lddp_add:
    add r12, [r14 + FileEntry.size]
.Lddp_next:
    inc r13; jmp .Lddp_loop
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
    add rsp, FileStat._size + 16
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
