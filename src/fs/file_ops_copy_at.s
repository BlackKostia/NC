# Filesystem Operations: mkdir, touch, rename, copy, move, delete (recursive), file read — file ops copy at (split from file_ops.s)

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"
.equ CFR_CHUNK,     4194304
.equ COPY_BUF_SIZE, 262144
.equ DENTS_CAP,     32752       # 32 KiB slab block minus its 16-byte header

.section .text
.global copy_reg_at
.global copy_dir_fd

# Internal: int copy_reg_at(int sdir, const char *sname, int ddir, const char *dname)
# Copies one non-directory, non-symlink entry. An existing destination that is the very
# same inode as the source (hardlink / symlink to it) is rejected with -9999 instead of
# being truncated. A canceled copy unlinks its partial destination.
copy_reg_at:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 128 + PATH_MAX           # [0..55]=src FileStat, [56..111]=dst FileStat, [112]=dfd, [120]=rc, [128]=rename buf
    call copy_reg_at__part1
    js .Lcra_ret
    mov ebx, eax                      # sfd
    mov edi, ebx
    mov rsi, rsp
    call os_fstat
    test rax, rax
    js .Lcra_close_src
    mov eax, [rsp + FileStat.mode]
    and eax, S_IFMT
    cmp eax, S_IFREG
    je .Lcra_isreg
    cmp eax, S_IFIFO
    jne .Lcra_special
    cmp qword ptr [rip + g_fs_progress], 0
    jne .Lcra_isreg           # background worker: a FIFO is streamed (cancelable)
.Lcra_special:
    mov rax, -EOPNOTSUPP      # UI thread / device / socket: never read from it
    jmp .Lcra_close_src
.Lcra_isreg:

    call copy_reg_at__part2
    jne .Lcra_have_dst
    call copy_reg_at__fo_resolve_eexist_open
    jne .Lcra_have_dst
    call fs_progress_item
    xor eax, eax
    jmp .Lcra_close_src
.Lcra_have_dst:
    test rax, rax
    js .Lcra_close_src
    call copy_reg_at__dfd
    test rax, rax
    jns .Lcra_ok
.Lcra_unlink:
    cmp dword ptr [rsp + 116], 0
    je .Lcra_ret
    push rax
    mov edi, r14d
    lea rsi, [rsp + 128 + 8]
    xor edx, edx
    OS_UNLINKAT                       # fault-checked: clean newly created partial target / temp file
    pop rax
    jmp .Lcra_ret
.Lcra_ok:
    jnz .Lcra_ret
    cmp dword ptr [rsp + 116], 2
    jne .Lcra_done
    call copy_reg_at__commit          # temp overwrite: swap the finished copy in atomically
    test rax, rax
    js .Lcra_unlink
.Lcra_done:
    call fs_progress_item
    xor eax, eax
    jmp .Lcra_ret
.Lcra_close_src:
    call copy_reg_at__part5
.Lcra_ret:
    add rsp, 128 + PATH_MAX
    pop r15
    pop r14
    pop r13
    pop r12; pop rbx; ret

# copy_reg_at step (runs on the caller's frame)
copy_reg_at__part1:
    lea rsp, [rsp - 8]
    mov r12d, edi
    mov r13, rsi
    mov r14d, edx
    mov r15, rcx

    mov edi, r12d
    mov rsi, r13
    mov edx, O_RDONLY | O_CLOEXEC | O_NOFOLLOW
    cmp qword ptr [rip + g_fs_progress], 0
    jne 1f
    or edx, O_NONBLOCK        # UI thread: opening a FIFO/device must never block the interface
1:  xor r10d, r10d
    OS_OPENAT
    test rax, rax
.Lcopy_reg_at__part1_ret:
    lea rsp, [rsp + 8]
    ret

# copy_reg_at step (runs on the caller's frame)
copy_reg_at__part2:
    lea rsp, [rsp - 8]
    lea rdi, [rsp + 128 + 16]
    mov rsi, r15
    mov edx, PATH_MAX
    call str_copy
    mov dword ptr [rsp + 116 + 16], 1
    mov edi, r14d
    mov rsi, r15
    mov edx, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC
    mov r10d, [rsp + FileStat.mode + 16]
    and r10d, 0777
    or r10d, 0600
    OS_OPENAT
    cmp rax, -EEXIST
.Lcopy_reg_at__part2_ret:
    lea rsp, [rsp + 8]
    ret

# copy_reg_at step: fo_resolve_eexist_open (runs on the caller's frame)
copy_reg_at__fo_resolve_eexist_open:
    lea rsp, [rsp - 8]
    mov dword ptr [rsp + 116 + 16], 0
    mov byte ptr [rsp + 128 + 16], 0
    mov edi, r14d
    mov rsi, r15
    lea rdx, [rsp + 16]
    lea rcx, [rsp + 128 + 16]
    call fo_resolve_eexist_open
    test rax, rax
    js .Lcr_ee_done
    cmp byte ptr [rsp + 128 + 16], 0
    je .Lcr_ee_done
    mov dword ptr [rsp + 116 + 16], 1
    cmp edx, 1
    jne .Lcr_ee_done
    mov dword ptr [rsp + 116 + 16], 2     # 2 = the fd belongs to a temp file that must replace the target
.Lcr_ee_done:
    cmp rax, -2
.Lcopy_reg_at__fo_resolve_eexist_open_ret:
    lea rsp, [rsp + 8]
    ret

# copy_reg_at step: commit (runs on the caller's frame) -- rename the finished temp file over the target
copy_reg_at__commit:
    lea rsp, [rsp - 8]
    mov edi, r14d
    lea rsi, [rsp + 128 + 16]
    mov rdx, r15
    call fo_overwrite_commit
.Lcopy_reg_at__commit_ret:
    lea rsp, [rsp + 8]
    ret

# copy_reg_at step: dfd (runs on the caller's frame)
copy_reg_at__dfd:
    lea rsp, [rsp - 8]
    mov [rsp + 112 + 16], eax # dfd
    mov rdi, r13
    call fs_progress_begin
    mov edi, ebx
    mov esi, [rsp + 112 + 16]
    mov eax, [rsp + FileStat.mode + 16]
    and eax, S_IFMT
    xor edx, edx
    cmp eax, S_IFREG
    sete dl
    call copy_data
    mov [rsp + 120 + 16], rax
    test rax, rax
    js .Ldfd_close_dst
.Ldfd_fsync:
    mov edi, [rsp + 112 + 16]
    OS_FSYNC
    cmp rax, -EINTR
    je .Ldfd_fsync
    test rax, rax
    jns .Ldfd_close_dst
    cmp rax, -EINVAL
    je .Ldfd_close_dst
    mov [rsp + 120 + 16], rax
.Ldfd_close_dst:
    mov edi, [rsp + 112 + 16]
    OS_CLOSE
    test rax, rax
    jns .Ldfd_close_src
    cmp qword ptr [rsp + 120 + 16], 0
    jl .Ldfd_close_src
    mov [rsp + 120 + 16], rax
.Ldfd_close_src:
    mov edi, ebx
    OS_CLOSE                  # fault-checked: source fd read-only cleanup
    mov rax, [rsp + 120 + 16]
    cmp rax, -ECANCELED
.Lcopy_reg_at__dfd_ret:
    lea rsp, [rsp + 8]
    ret

# copy_reg_at step (runs on the caller's frame)
copy_reg_at__part5:
    lea rsp, [rsp - 8]
    push rax
    sub rsp, 8
    mov edi, ebx
    OS_CLOSE
    add rsp, 8
    pop rax
.Lcopy_reg_at__part5_ret:
    lea rsp, [rsp + 8]
    ret

# Internal: int copy_dir_fd(int sfd, int dfd, int depth) -- copies every entry of sfd into dfd
copy_dir_fd:
    cmp edx, MAX_DIR_DEPTH
    jae .Lcdf_depth_err
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 88                       # [0]=dirent cursor, [8]=d_type, [16..71]=FileStat, [72]=depth
    mov r12d, edi
    mov r13d, esi
    mov [rsp + 72], edx
    mov edi, DENTS_CAP
    call mem_alloc
    test rax, rax
    jz .Lcdf_nomem
    mov rbx, rax
.Lcdf_read:
    mov edi, r12d
    mov rsi, rbx
    mov edx, DENTS_CAP
    call os_dir_read
    test rax, rax
    js .Lcdf_err
    jz .Lcdf_ok
    mov r14, rax
    mov qword ptr [rsp], 0
.Lcdf_next:
    call copy_dir_fd__os_dir_next_ex
    jz .Lcdf_read
    mov r15, rax
    cmp byte ptr [r15], '.'
    jne .Lcdf_entry
    cmp byte ptr [r15 + 1], 0
    je .Lcdf_next
    cmp byte ptr [r15 + 1], '.'
    jne .Lcdf_entry
    cmp byte ptr [r15 + 2], 0
    je .Lcdf_next
.Lcdf_entry:
    call fs_progress_cancelled
    test eax, eax
    jnz .Lcdf_cancel
    call copy_dir_fd__os_statat
    test rax, rax
    jns .Lcdf_next
.Lcdf_err:
    mov rbp, rax
    mov rdi, rbx
    call mem_free
    mov rax, rbp
    jmp .Lcdf_ret
.Lcdf_cancel:
    mov rax, -ECANCELED
    jmp .Lcdf_err
.Lcdf_ok:
    mov rdi, rbx
    call mem_free
    xor eax, eax
    jmp .Lcdf_ret
.Lcdf_nomem:
    mov rax, -ENOMEM
.Lcdf_ret:
    add rsp, 88
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret
.Lcdf_depth_err:
    mov rax, -ENAMETOOLONG
    ret

# copy_dir_fd step: os_dir_next_ex (runs on the caller's frame)
copy_dir_fd__os_dir_next_ex:
    lea rsp, [rsp - 8]
    mov rdi, rbx
    mov rsi, r14
    lea rdx, [rsp + 16]
    lea rcx, [rsp + 8 + 16]
    call os_dir_next_ex
    test rax, rax
.Lcopy_dir_fd__os_dir_next_ex_ret:
    lea rsp, [rsp + 8]
    ret

# copy_dir_fd step: os_statat (runs on the caller's frame)
copy_dir_fd__os_statat:
    lea rsp, [rsp - 8]
    movzx eax, byte ptr [rsp + 8 + 16]
    cmp eax, PAL_DT_UNKNOWN
    jne .Lcdf_typed
    mov edi, r12d
    mov rsi, r15
    lea rdx, [rsp + 16 + 16]
    xor ecx, ecx
    call os_statat
    test rax, rax
    js .Lcdf_reg
    mov eax, [rsp + 16 + FileStat.mode + 16]
    and eax, S_IFMT
    cmp eax, S_IFDIR
    je .Lcdf_dir
    cmp eax, S_IFLNK
    je .Lcdf_lnk
    jmp .Lcdf_reg
.Lcdf_typed:
    cmp eax, PAL_DT_DIR
    je .Lcdf_dir
    cmp eax, PAL_DT_LNK
    je .Lcdf_lnk
.Lcdf_reg:
    mov edi, r12d
    mov rsi, r15
    mov edx, r13d
    mov rcx, r15
    call copy_reg_at
    jmp .Lcdf_chk
.Lcdf_lnk:
    mov edi, r12d
    mov rsi, r15
    mov edx, r13d
    mov rcx, r15
    call copy_link_at
    jmp .Lcdf_chk
.Lcdf_dir:
    mov edi, r12d
    mov rsi, r15
    mov edx, r13d
    mov ecx, [rsp + 72 + 16]
    inc ecx
    call copy_subdir
.Lcdf_chk:
.Lcopy_dir_fd__os_statat_ret:
    lea rsp, [rsp + 8]
    ret
