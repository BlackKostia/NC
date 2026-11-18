# Frozen reference oracle: the hand-written asm that src/fs/task_conflict.c replaced (tests/test_c_task_conflict.py diffs against it)
# src/fs/task_conflict.s - Background task conflict detection, resolution & unique naming
.intel_syntax noprefix

.include "pal.inc"
.include "config.inc"
.include "types.inc"

.section .bss
.align 4
g_conflict_all_act: .space 4   # worker: cached CONFLICT_ACT_* when For all is set
g_cfl_seq:          .space 4

.section .bss
.global g_copy_had_skip
g_copy_had_skip: .space 4

.section .text
.global fs_task_resolve_conflict
.global fs_task_check_conflict
.global fs_task_reply_conflict
.global fo_resolve_eexist_open
.global fo_move_check_conflict

.extern g_fs_progress
.extern g_task_shm
.extern g_task_parent_pid
.extern os_parent_alive
.extern mem_copy
.extern str_copy
.extern u64_to_dec
.extern path_basename
.extern os_statat
.extern os_poll_in
.extern fo_open_overwrite

# Helper: generate unique path/name "<stem>_<n><ext>" in out_buf (cap PATH_MAX)
# void task_make_unique_name(int dfd, const char *orig, char *out_buf)
task_make_unique_name:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 64               # FileStat
    call task_make_unique_name__dfd
    call task_make_unique_name__os_statat
    add rsp, 64
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# task_make_unique_name step: dfd (runs on the caller's frame)
task_make_unique_name__dfd:
    lea rsp, [rsp - 8]
    mov r12d, edi             # dfd
    mov r13, rsi              # orig
    mov r14, rdx              # out_buf

    xor r15d, r15d            # dot_ptr = NULL
    mov rbx, r13
.Ltmun_scan:
    mov al, [rbx]
    test al, al
    jz .Ltmun_scan_done
    cmp al, '/'
    jne .Ltmun_chk_dot
    xor r15d, r15d
    jmp .Ltmun_next
.Ltmun_chk_dot:
    cmp al, '.'
    jne .Ltmun_next
    mov r15, rbx
.Ltmun_next:
    inc rbx
    jmp .Ltmun_scan
.Ltmun_scan_done:
    test r15, r15
    jz .Ltmun_no_dot
    cmp r15, r13
    je .Ltmun_clear_dot
    cmp byte ptr [r15 - 1], '/'
    jne .Ltmun_try
.Ltmun_clear_dot:
    xor r15d, r15d
.Ltmun_no_dot:
    mov r15, rbx
.Ltmun_try:
.Ltask_make_unique_name__dfd_ret:
    lea rsp, [rsp + 8]
    ret

# task_make_unique_name step: os_statat (runs on the caller's frame)
task_make_unique_name__os_statat:
    lea rsp, [rsp - 8]
    mov ebx, 1
.Ltmun_loop:
    cmp ebx, 1088
    jge .Ltmun_done
    mov rcx, r15
    sub rcx, r13
    cmp rcx, PATH_MAX - 16
    jbe 1f
    mov rcx, PATH_MAX - 16
1:  mov rdi, r14
    mov rsi, r13
    mov rdx, rcx
    push rcx
    call mem_copy
    pop rcx
    mov byte ptr [r14 + rcx], '_'
    inc rcx
    mov edi, ebx
    cmp ebx, 1024
    jb .Ltmun_dec
    mov byte ptr [r14 + rcx], 'x'
    inc rcx
    mov edi, 1
    lock xadd [rip + g_cfl_seq], edi
    inc edi
.Ltmun_dec:
    lea rsi, [r14 + rcx]
    push rcx
    call u64_to_dec
    pop rcx
    add rcx, rax
    lea rdi, [r14 + rcx]
    mov rsi, r15
    mov edx, PATH_MAX
    sub edx, ecx
    call str_copy
    mov edi, r12d
    mov rsi, r14
    lea rdx, [rsp + 16]
    xor ecx, ecx                      # OS_STAT_NOFOLLOW
    call os_statat
    cmp rax, -ENOENT
    je .Ltmun_done
    inc ebx
    jmp .Ltmun_loop
.Ltmun_done:
.Ltask_make_unique_name__os_statat_ret:
    lea rsp, [rsp + 8]
    ret

ft_wait_conflict_reply:
    push rbx; mov rbx, rdi
1:  cmp dword ptr [rbx + TaskShared.cancel], 0; jne 2f
    cmp dword ptr [rbx + TaskShared.conflict_state], 2; je 3f
    mov edi, [rip + g_task_parent_pid]; test edi, edi; jz 4f
    call os_parent_alive; test eax, eax; jz 2f
4:  mov edi, -1; mov esi, 50; call os_poll_in; jmp 1b
3:  xor eax, eax; pop rbx; ret
2:  mov eax, -1; pop rbx; ret

# int fs_task_resolve_conflict(int dst_dfd, const char *dst_rel, uint64_t src_sz, uint64_t dst_sz, char *out_name)
fs_task_resolve_conflict:
    mov rax, [rip + g_fs_progress]; test rax, rax; jnz .Lftrc_active
    mov eax, CONFLICT_ACT_OVERWRITE; ret
.Lftrc_active:
    push rbx; push r12; push r13; push r14; push r15
    mov rbx, rax; mov r12d, edi; mov r13, rsi; mov r14, rdx; mov r15, r8
    mov eax, [rip + g_conflict_all_act]; test eax, eax; jnz .Lftrc_have_act
    mov [rbx + TaskShared.conflict_src_sz], r14; mov [rbx + TaskShared.conflict_dst_sz], rcx
    mov rdi, r13; call path_basename
    lea rdi, [rbx + TaskShared.conflict_name]; mov rsi, rax; mov edx, NAME_MAX; call str_copy
    mov dword ptr [rbx + TaskShared.conflict_action], 0
    mov dword ptr [rbx + TaskShared.conflict_all], 0
    mov dword ptr [rbx + TaskShared.conflict_state], 1
    mov rdi, rbx; call ft_wait_conflict_reply
    test eax, eax; js .Lftrc_cancel
    mov eax, [rbx + TaskShared.conflict_action]
    mov ecx, [rbx + TaskShared.conflict_all]
    mov dword ptr [rbx + TaskShared.conflict_state], 0
    test ecx, ecx; jz .Lftrc_have_act
    mov [rip + g_conflict_all_act], eax
.Lftrc_have_act:
    cmp eax, CONFLICT_ACT_RENAME; jne .Lftrc_ret
    push rax; mov edi, r12d; mov rsi, r13; mov rdx, r15; call task_make_unique_name; pop rax
    jmp .Lftrc_ret
.Lftrc_cancel:
    mov dword ptr [rbx + TaskShared.conflict_state], 0
    mov rax, -ECANCELED
.Lftrc_ret:
    pop r15; pop r14; pop r13; pop r12; pop rbx; ret

# int fs_task_check_conflict(char *out_name, uint64_t *out_src_sz, uint64_t *out_dst_sz)
fs_task_check_conflict:
    mov rax, [rip + g_task_shm]
    test rax, rax
    jz .Lftcc_no
    cmp dword ptr [rax + TaskShared.conflict_state], 1
    jne .Lftcc_no
    test rsi, rsi
    jz .Lftcc_dst
    mov r8, [rax + TaskShared.conflict_src_sz]
    mov [rsi], r8
.Lftcc_dst:
    test rdx, rdx
    jz .Lftcc_nm
    mov r8, [rax + TaskShared.conflict_dst_sz]
    mov [rdx], r8
.Lftcc_nm:
    test rdi, rdi
    jz .Lftcc_yes
    lea rsi, [rax + TaskShared.conflict_name]
    mov edx, NAME_MAX
    call str_copy
.Lftcc_yes:
    mov eax, 1
    ret
.Lftcc_no:
    xor eax, eax
    ret

# void fs_task_reply_conflict(int action, int for_all)
fs_task_reply_conflict:
    mov rax, [rip + g_task_shm]
    test rax, rax
    jz .Lftrp_ret
    mov [rax + TaskShared.conflict_action], edi
    mov [rax + TaskShared.conflict_all], esi
    mov dword ptr [rax + TaskShared.conflict_state], 2
.Lftrp_ret:
    ret

# int fo_resolve_eexist_open(int dst_dfd, const char *dst_rel, const FileStat *src_st, char *out_ren)
# Returns: fd >= 0 (edx = 1: temp file to rename over the target), -2 = SKIP, -9999 = same file, or -errno.
fo_resolve_eexist_open:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, FileStat._size + 8
    mov r12d, edi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx

    mov edi, r12d
    mov rsi, r13
    mov rdx, rsp
    xor ecx, ecx                      # OS_STAT_NOFOLLOW
    call os_statat
    test rax, rax
    js .Lfro_cfl
    mov rax, [r14 + FileStat.dev]
    cmp rax, [rsp + FileStat.dev]
    jne .Lfro_cfl
    mov rax, [r14 + FileStat.ino]
    cmp rax, [rsp + FileStat.ino]
    jne .Lfro_cfl
    mov rax, -9999
    jmp .Lfro_ret
.Lfro_cfl:
    mov edi, r12d
    mov rsi, r13
    mov rdx, [r14 + FileStat.size]
    mov rcx, [rsp + FileStat.size]
    mov r8, r15
    call fs_task_resolve_conflict
    test rax, rax
    js .Lfro_ret
    cmp eax, CONFLICT_ACT_SKIP
    jne .Lfro_chk_ren
    mov dword ptr [rip + g_copy_had_skip], 1
    mov rax, -2
    jmp .Lfro_ret
.Lfro_chk_ren:
    mov r10d, [r14 + FileStat.mode]
    and r10d, 0777
    or r10d, 0600
    cmp eax, CONFLICT_ACT_RENAME
    jne .Lfro_trunc
    mov edi, r12d
    mov rsi, r15
    mov edx, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
    OS_OPENAT
    xor edx, edx                      # edx = 0: r15 is the final name, nothing to rename later
    test rax, rax
    jmp .Lfro_ret
.Lfro_trunc:
    mov edi, r12d                     # existing target: temp file + rename when it is a regular file
    mov rsi, r13
    mov edx, [rsp + FileStat.mode]
    mov ecx, r10d
    mov r8, r15
    call fo_open_overwrite            # edx = 1: r15 holds a temp name the caller renames over the target
    test rax, rax
.Lfro_ret:
    add rsp, FileStat._size + 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# int fo_move_check_conflict(const char *src, const char *dst, char *out_ren)
fo_move_check_conflict:
    push rbx
    push r12
    push r13
    sub rsp, FileStat._size * 2
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx

    mov edi, AT_FDCWD
    mov rsi, r12
    lea rdx, [rsp + FileStat._size]
    xor ecx, ecx                      # OS_STAT_NOFOLLOW
    call os_statat
    test rax, rax
    js .Lfmc_over
    mov edi, AT_FDCWD
    mov rsi, rbx
    mov rdx, rsp
    xor ecx, ecx                      # OS_STAT_NOFOLLOW
    call os_statat
    test rax, rax
    js .Lfmc_over
    mov eax, [rsp + FileStat.mode]
    and eax, S_IFMT
    cmp eax, S_IFDIR
    jne .Lfmc_chk_same
    mov eax, [rsp + FileStat._size + FileStat.mode]
    and eax, S_IFMT
    cmp eax, S_IFDIR
    jne .Lfmc_chk_same
    mov rax, [rsp + FileStat.dev]
    cmp rax, [rsp + FileStat._size + FileStat.dev]
    jne .Lfmc_over
.Lfmc_chk_same:
    mov rax, [rsp + FileStat.dev]
    cmp rax, [rsp + FileStat._size + FileStat.dev]
    jne .Lfmc_ask
    mov rax, [rsp + FileStat.ino]
    cmp rax, [rsp + FileStat._size + FileStat.ino]
    je .Lfmc_over
.Lfmc_ask:
    mov edi, AT_FDCWD
    mov rsi, r12
    mov rdx, [rsp + FileStat.size]
    mov rcx, [rsp + FileStat._size + FileStat.size]
    mov r8, r13
    call fs_task_resolve_conflict
    jmp .Lfmc_ret
.Lfmc_over:
    mov eax, CONFLICT_ACT_OVERWRITE
.Lfmc_ret:
    add rsp, FileStat._size * 2
    pop r13
    pop r12
    pop rbx
    ret
