# Filesystem Operations: mkdir, touch, rename, copy, move, delete (recursive), file read — file ops delete (split from file_ops.s)

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"
.equ CFR_CHUNK,     4194304
.equ COPY_BUF_SIZE, 262144
.equ DENTS_CAP,     32752       # 32 KiB slab block minus its 16-byte header

.section .text
.global fs_delete_recursive
.global fs_move_recursive
.extern g_copy_had_skip
.global fs_read_file_head

# Internal: int delete_dir_fd(int dfd, int depth) -- removes every entry below dfd (not dfd itself)
delete_dir_fd:
    cmp esi, MAX_DIR_DEPTH; jae .Lddf_depth_err
    push rbx; push rbp; push r12; push r13; push r14; push r15
    sub rsp, 96                       # [0]=cursor, [8]=d_type, [16..71]=FileStat, [72]=rc, [80]=depth
    mov r12d, edi; mov [rsp + 80], esi
    mov edi, DENTS_CAP
    call mem_alloc
    test rax, rax
    jz .Lddf_nomem
    mov rbx, rax
.Lddf_read:
    mov edi, r12d
    mov rsi, rbx
    mov edx, DENTS_CAP
    call os_dir_read
    test rax, rax
    js .Lddf_err
    jz .Lddf_ok
    mov r14, rax
    mov qword ptr [rsp], 0
.Lddf_next:
    call delete_dir_fd__os_dir_next_ex
    jz .Lddf_read
    mov r15, rax
    cmp byte ptr [r15], '.'
    jne .Lddf_entry
    cmp byte ptr [r15 + 1], 0
    je .Lddf_next
    cmp byte ptr [r15 + 1], '.'
    jne .Lddf_entry
    cmp byte ptr [r15 + 2], 0
    je .Lddf_next
.Lddf_entry:
    call fs_progress_cancelled
    test eax, eax
    jnz .Lddf_cancel
    movzx eax, byte ptr [rsp + 8]
    cmp eax, PAL_DT_DIR
    je .Lddf_dir
    cmp eax, PAL_DT_UNKNOWN
    jne .Lddf_file
    call delete_dir_fd__os_statat
    js .Lddf_file
    mov eax, [rsp + 16 + FileStat.mode]
    and eax, S_IFMT
    cmp eax, S_IFDIR
    jne .Lddf_file
.Lddf_dir:
    call delete_dir_fd__part3
    js .Lddf_err
    call delete_dir_fd__delete_dir_fd
    js .Lddf_err
    mov edi, r12d
    mov rsi, r15
    mov edx, AT_REMOVEDIR
    OS_UNLINKAT
    jmp .Lddf_done_one
.Lddf_file:
    mov edi, r12d
    mov rsi, r15
    xor edx, edx
    OS_UNLINKAT
.Lddf_done_one:
    test rax, rax
    js .Lddf_err
    mov rdi, r15
    call fs_progress_begin
    call fs_progress_item
    jmp .Lddf_next
.Lddf_err:
    mov rbp, rax
    mov rdi, rbx
    call mem_free
    mov rax, rbp
    jmp .Lddf_ret
.Lddf_cancel:
    mov rax, -ECANCELED
    jmp .Lddf_err
.Lddf_ok:
    mov rdi, rbx
    call mem_free
    xor eax, eax
    jmp .Lddf_ret
.Lddf_nomem:
    mov rax, -ENOMEM
.Lddf_ret:
    add rsp, 96; pop r15; pop r14; pop r13; pop r12; pop rbp; pop rbx; ret
.Lddf_depth_err:
    mov rax, -ENAMETOOLONG; ret

# delete_dir_fd step: os_dir_next_ex (runs on the caller's frame)
delete_dir_fd__os_dir_next_ex:
    lea rsp, [rsp - 8]
    mov rdi, rbx
    mov rsi, r14
    lea rdx, [rsp + 16]
    lea rcx, [rsp + 8 + 16]
    call os_dir_next_ex
    test rax, rax
.Ldelete_dir_fd__os_dir_next_ex_ret:
    lea rsp, [rsp + 8]
    ret

# delete_dir_fd step: os_statat (runs on the caller's frame)
delete_dir_fd__os_statat:
    lea rsp, [rsp - 8]
    mov edi, r12d
    mov rsi, r15
    lea rdx, [rsp + 16 + 16]
    xor ecx, ecx
    call os_statat
    test rax, rax
.Ldelete_dir_fd__os_statat_ret:
    lea rsp, [rsp + 8]
    ret

# delete_dir_fd step (runs on the caller's frame)
delete_dir_fd__part3:
    lea rsp, [rsp - 8]
    mov edi, r12d
    mov rsi, r15
    mov edx, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
.Ldelete_dir_fd__part3_ret:
    lea rsp, [rsp + 8]
    ret

# delete_dir_fd step: delete_dir_fd (runs on the caller's frame)
delete_dir_fd__delete_dir_fd:
    lea rsp, [rsp - 8]
    mov ebp, eax
    mov edi, ebp
    mov esi, [rsp + 80 + 16]
    inc esi
    call delete_dir_fd
    mov [rsp + 72 + 16], rax
    mov edi, ebp
    OS_CLOSE
    mov rax, [rsp + 72 + 16]
    test rax, rax
.Ldelete_dir_fd__delete_dir_fd_ret:
    lea rsp, [rsp + 8]
    ret

# int fs_delete_recursive(const char *path)
# Symlinks are removed, never followed (O_NOFOLLOW on every directory open).
fs_delete_recursive:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 56                       # FileStat
    mov r12, rdi
    mov edi, AT_FDCWD
    mov rsi, r12
    mov rdx, rsp
    xor ecx, ecx
    call os_statat
    test rax, rax
    js .Lfdr_ret
    mov rdi, r12
    call fs_progress_begin
    mov eax, [rsp + FileStat.mode]
    and eax, S_IFMT
    cmp eax, S_IFDIR
    je .Lfdr_dir
    mov edi, AT_FDCWD
    mov rsi, r12
    xor edx, edx
    OS_UNLINKAT
    jmp .Lfdr_counted
.Lfdr_dir:
    mov edi, AT_FDCWD
    mov rsi, r12
    mov edx, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
    js .Lfdr_ret
    mov r13d, eax
    mov edi, r13d
    xor esi, esi
    call delete_dir_fd
    mov rbx, rax
    mov edi, r13d
    OS_CLOSE
    mov rax, rbx
    test rax, rax
    js .Lfdr_ret
    mov edi, AT_FDCWD
    mov rsi, r12
    mov edx, AT_REMOVEDIR
    OS_UNLINKAT
.Lfdr_counted:
    test rax, rax
    js .Lfdr_ret
    call fs_progress_item
    xor eax, eax
.Lfdr_ret:
    add rsp, 56
    pop r14
    pop r13
    pop r12; pop rbx; ret

# int fs_move_recursive(const char *src_path, const char *dst_path)
fs_move_recursive:
    push rbx
    push r12
    sub rsp, 96 + PATH_MAX            # [0]=src st, [48]=dst st, [96]=rename buf
    mov rbx, rdi
    mov r12, rsi
    cmp qword ptr [rip + g_fs_progress], 0
    je .Lfmr_do
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rsp + 96]
    call fo_move_check_conflict
    test rax, rax
    js .Lfmr_done
    cmp eax, CONFLICT_ACT_SKIP
    jne .Lfmr_chk_ren
    call fs_progress_item
    xor eax, eax
    jmp .Lfmr_done
.Lfmr_chk_ren:
    cmp eax, CONFLICT_ACT_RENAME
    jne .Lfmr_do
    lea r12, [rsp + 96]
.Lfmr_do:
    mov rdi, rbx
    mov rsi, r12
    call fs_rename
    test rax, rax
    jns .Lfmr_done
    cmp rax, -EXDEV
    jne .Lfmr_done
    mov dword ptr [rip + g_copy_had_skip], 0
    mov rdi, rbx
    mov rsi, r12
    call fs_copy_recursive
    test rax, rax
    js .Lfmr_done
    cmp dword ptr [rip + g_copy_had_skip], 0
    jne .Lfmr_done
    # Copy is complete: finish removing the source atomically from the user's view
    # (no cancel, no double counting) so a move never ends half-deleted.
    push qword ptr [rip + g_fs_progress]
    mov qword ptr [rip + g_fs_progress], 0
    mov rdi, rbx
    call fs_delete_recursive
    pop qword ptr [rip + g_fs_progress]
.Lfmr_done:
    add rsp, 96 + PATH_MAX
    pop r12; pop rbx; ret

# int fs_read_file_head(const char *path, void *buf, size_t max_bytes, size_t *out_read)
fs_read_file_head:
    push rbx
    push r12
    push r13
    push r14
    mov rbx, rsi              # buf
    mov r12, rdx              # max_bytes
    mov r13, rcx              # out_read
    test r13, r13
    jz .Lrfh_open
    mov qword ptr [r13], 0
.Lrfh_open:
    mov rsi, rdi
    mov edi, AT_FDCWD
    mov edx, O_RDONLY | O_NONBLOCK | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
    js .Lrfh_ret
    mov r14d, eax

    xor ecx, ecx              # total read
.Lrfh_loop:
    cmp rcx, r12
    jae .Lrfh_ok
    push rcx
    mov edi, r14d
    lea rsi, [rbx + rcx]
    mov rdx, r12
    sub rdx, rcx
    call sys_read_retry
    pop rcx
    test rax, rax
    jle .Lrfh_ok
    add rcx, rax
    jmp .Lrfh_loop
.Lrfh_ok:
    test r13, r13
    jz .Lrfh_close
    mov [r13], rcx
.Lrfh_close:
    mov edi, r14d
    OS_CLOSE
    xor eax, eax
.Lrfh_ret:
    pop r14
    pop r13
    pop r12; pop rbx; ret
