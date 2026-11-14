# src/fs/task_conflict.s - Background task conflict detection, resolution & unique naming
.intel_syntax noprefix

.include "pal.inc"
.include "config.inc"
.include "types.inc"

.section .bss
.align 4
g_conflict_all_act: .space 4   # worker: cached CONFLICT_ACT_* when For all is set

.section .text
.global fs_task_resolve_conflict
.global fs_task_check_conflict
.global fs_task_reply_conflict
.global fo_resolve_eexist_open
.global fo_move_check_conflict

.extern g_fs_progress
.extern g_task_shm
.extern mem_copy
.extern str_copy
.extern path_basename
.extern os_statat
.extern os_poll_in

# Helper: generate unique path/name "<stem>_<n><ext>" in out_buf (cap PATH_MAX)
# void task_make_unique_name(int dfd, const char *orig, char *out_buf)
task_make_unique_name:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48               # FileStat
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
    mov ebx, 1
.Ltmun_loop:
    cmp ebx, 100
    jge .Ltmun_fallback
    mov rcx, r15
    sub rcx, r13
    cmp rcx, PATH_MAX - 16
    jbe .Ltmun_pfx_ok
    mov rcx, PATH_MAX - 16
.Ltmun_pfx_ok:
    mov rdi, r14
    mov rsi, r13
    mov rdx, rcx
    push rcx
    call mem_copy
    pop rcx
    mov byte ptr [r14 + rcx], '_'
    inc rcx
    mov eax, ebx
    cmp eax, 10
    jl .Ltmun_1d
    xor edx, edx
    mov r8d, 10
    div r8d
    add al, '0'
    mov [r14 + rcx], al
    inc rcx
    add dl, '0'
    mov [r14 + rcx], dl
    inc rcx
    jmp .Ltmun_ext
.Ltmun_1d:
    add al, '0'
    mov [r14 + rcx], al
    inc rcx
.Ltmun_ext:
    lea rdi, [r14 + rcx]
    mov rsi, r15
    mov edx, PATH_MAX
    sub edx, ecx
    call str_copy

    mov edi, r12d
    mov rsi, r14
    mov rdx, rsp
    mov ecx, 1
    call os_statat
    cmp rax, -ENOENT
    je .Ltmun_done
    inc ebx
    jmp .Ltmun_loop

.Ltmun_fallback:
    mov rdi, r14
    mov rsi, r13
    mov edx, PATH_MAX
    call str_copy
.Ltmun_done:
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# int fs_task_resolve_conflict(int dst_dfd, const char *dst_rel, uint64_t src_sz, uint64_t dst_sz, char *out_name)
fs_task_resolve_conflict:
    mov rax, [rip + g_fs_progress]
    test rax, rax
    jnz .Lftrc_active
    mov eax, CONFLICT_ACT_OVERWRITE
    ret
.Lftrc_active:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rax
    mov r12d, edi
    mov r13, rsi
    mov r14, rdx
    mov r15, r8

    mov eax, [rip + g_conflict_all_act]
    test eax, eax
    jnz .Lftrc_have_act

    mov [rbx + TaskShared.conflict_src_sz], r14
    mov [rbx + TaskShared.conflict_dst_sz], rcx
    mov rdi, r13
    call path_basename
    lea rdi, [rbx + TaskShared.conflict_name]
    mov rsi, rax
    mov edx, NAME_MAX
    call str_copy
    mov dword ptr [rbx + TaskShared.conflict_action], 0
    mov dword ptr [rbx + TaskShared.conflict_all], 0
    mov dword ptr [rbx + TaskShared.conflict_state], 1

.Lftrc_wait:
    cmp dword ptr [rbx + TaskShared.cancel], 0
    jne .Lftrc_cancel
    mov eax, [rbx + TaskShared.conflict_state]
    cmp eax, 2
    je .Lftrc_got
    mov edi, -1
    mov esi, 10
    call os_poll_in
    jmp .Lftrc_wait

.Lftrc_got:
    mov eax, [rbx + TaskShared.conflict_action]
    mov ecx, [rbx + TaskShared.conflict_all]
    mov dword ptr [rbx + TaskShared.conflict_state], 0
    test ecx, ecx
    jz .Lftrc_have_act
    mov [rip + g_conflict_all_act], eax

.Lftrc_have_act:
    cmp eax, CONFLICT_ACT_RENAME
    jne .Lftrc_ret
    push rax
    mov edi, r12d
    mov rsi, r13
    mov rdx, r15
    call task_make_unique_name
    pop rax
    jmp .Lftrc_ret

.Lftrc_cancel:
    mov dword ptr [rbx + TaskShared.conflict_state], 0
    mov rax, -ECANCELED
.Lftrc_ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

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
# Returns: fd >= 0, -2 = SKIP, -9999 = same file, or -errno.
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
    mov ecx, 1
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
    mov edx, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC
    OS_OPENAT
    jmp .Lfro_ret
.Lfro_trunc:
    mov edi, r12d
    mov rsi, r13
    mov edx, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC
    OS_OPENAT
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
    mov ecx, 1
    call os_statat
    test rax, rax
    js .Lfmc_over
    mov eax, [rsp + FileStat._size + FileStat.mode]
    and eax, S_IFMT
    cmp eax, S_IFDIR
    je .Lfmc_over
    mov edi, AT_FDCWD
    mov rsi, rbx
    mov rdx, rsp
    mov ecx, 1
    call os_statat
    test rax, rax
    js .Lfmc_over
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
