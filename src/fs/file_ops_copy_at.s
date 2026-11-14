# Filesystem Operations: mkdir, touch, rename, copy, move, delete (recursive), file read — file ops copy at (split from file_ops.s)

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"
.equ CFR_CHUNK,     4194304
.equ COPY_BUF_SIZE, 262144
.equ DENTS_CAP,     32752       # 32 KiB slab block minus its 16-byte header

.section .text
.global copy_reg_at
.global copy_link_at
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
    sub rsp, 96 + PATH_MAX            # [0]=src FileStat, [48]=dst FileStat, [96]=rename buf
    call copy_reg_at__part1
    js .Lcra_ret
    mov ebx, eax                      # sfd
    mov edi, ebx
    mov rsi, rsp
    call os_fstat
    test rax, rax
    js .Lcra_close_src

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
    jne .Lcra_chk
    mov edi, r14d
    mov rsi, r15
    xor edx, edx
    OS_UNLINKAT
    mov rax, -ECANCELED
    jmp .Lcra_ret
.Lcra_chk:
    test rax, rax
    jnz .Lcra_ret
    call fs_progress_item
    xor eax, eax
    jmp .Lcra_ret
.Lcra_close_src:
    call copy_reg_at__part5
.Lcra_ret:
    add rsp, 96 + PATH_MAX
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
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
.Lcopy_reg_at__part1_ret:
    lea rsp, [rsp + 8]
    ret

# copy_reg_at step (runs on the caller's frame)
copy_reg_at__part2:
    lea rsp, [rsp - 8]
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
    mov edi, r14d
    mov rsi, r15
    lea rdx, [rsp + 16]
    lea rcx, [rsp + 96 + 16]
    call fo_resolve_eexist_open
    cmp rax, -2
.Lcopy_reg_at__fo_resolve_eexist_open_ret:
    lea rsp, [rsp + 8]
    ret

# copy_reg_at step: dfd (runs on the caller's frame)
copy_reg_at__dfd:
    lea rsp, [rsp - 8]
    mov [rsp + 48 + 16], eax  # dfd
    mov rdi, r13
    call fs_progress_begin
    mov edi, ebx
    mov esi, [rsp + 48 + 16]
    mov eax, [rsp + FileStat.mode + 16]
    and eax, S_IFMT
    xor edx, edx
    cmp eax, S_IFREG
    sete dl
    call copy_data
    mov [rsp + 56 + 16], rax
    mov edi, [rsp + 48 + 16]
    OS_CLOSE
    mov edi, ebx
    OS_CLOSE
    mov rax, [rsp + 56 + 16]
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

# Internal: int copy_link_at(int sdir, const char *sname, int ddir, const char *dname)
copy_link_at:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi
    mov r13, rsi
    mov r14d, edx
    mov r15, rcx
    mov edi, PATH_MAX
    call mem_alloc
    test rax, rax
    jz .Lcla_nomem
    mov rbx, rax
    mov edi, r12d
    mov rsi, r13
    mov rdx, rbx
    mov r10d, PATH_MAX - 1
    OS_READLINKAT
    test rax, rax
    js .Lcla_free
    mov byte ptr [rbx + rax], 0
    mov rdi, rbx
    mov esi, r14d
    mov rdx, r15
    OS_SYMLINKAT
.Lcla_free:
    mov r12, rax
    mov rdi, rbx
    call mem_free
    mov rax, r12
    test rax, rax
    js .Lcla_ret
    call fs_progress_item
    xor eax, eax
    jmp .Lcla_ret
.Lcla_nomem:
    mov rax, -ENOMEM
.Lcla_ret:
    pop r15
    pop r14
    pop r13
    pop r12; pop rbx; ret

# Internal: int copy_dir_fd(int sfd, int dfd) -- copies every entry of sfd into dfd
copy_dir_fd:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 72                       # [0]=dirent cursor, [8]=d_type, [16..63]=FileStat
    mov r12d, edi
    mov r13d, esi
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
    add rsp, 72
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
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
    call copy_subdir
.Lcdf_chk:
.Lcopy_dir_fd__os_statat_ret:
    lea rsp, [rsp + 8]
    ret
