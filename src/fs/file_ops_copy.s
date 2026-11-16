# Filesystem Operations: mkdir, touch, rename, copy, move, delete (recursive), file read — file ops copy (split from file_ops.s)

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"
.equ CFR_CHUNK,     4194304
.equ COPY_BUF_SIZE, 262144
.equ DENTS_CAP,     32752       # 32 KiB slab block minus its 16-byte header

.section .bss
g_copy_root_dev: .space 8       # destination root of the running copy (never descend into it)
g_copy_root_ino: .space 8

.section .text
.global copy_subdir
.global fs_copy_file
.global fs_copy_recursive

# Internal: int copy_subdir(int sdir, const char *name, int ddir, int depth)
copy_subdir:
    cmp ecx, MAX_DIR_DEPTH; jae .Lcsd_depth_err
    push rbx; push rbp; push r12; push r13; push r14; push r15
    sub rsp, 64                       # [0..55]=FileStat, [56..63]=rc
    mov r12d, edi; mov r13, rsi; mov r14d, edx; mov r15d, ecx
    mov edi, r12d
    mov rsi, r13
    mov edx, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
    js .Lcsd_ret
    mov ebx, eax                      # sfd
    mov edi, ebx
    mov rsi, rsp
    call os_fstat
    test rax, rax
    js .Lcsd_close_s
    # Never recurse into the destination root itself (dst reachable inside src)
    mov rax, [rsp + FileStat.dev]
    cmp rax, [rip + g_copy_root_dev]
    jne .Lcsd_mk
    mov rax, [rsp + FileStat.ino]
    cmp rax, [rip + g_copy_root_ino]
    jne .Lcsd_mk
    xor eax, eax
    jmp .Lcsd_close_s
.Lcsd_mk:
    mov edi, r14d
    mov rsi, r13
    mov edx, [rsp + FileStat.mode]
    and edx, 0777
    or edx, 0700
    OS_MKDIRAT
    test rax, rax
    jns .Lcsd_made
    cmp rax, -EEXIST
    jne .Lcsd_close_s
.Lcsd_made:
    mov rdi, r13
    call fs_progress_begin
    call fs_progress_item
    mov edi, r14d
    mov rsi, r13
    mov edx, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
    js .Lcsd_close_s
    mov ebp, eax                      # dfd
    mov edi, ebx
    mov esi, ebp
    mov edx, r15d
    call copy_dir_fd
    mov [rsp + 56], rax
    mov edi, ebp
    OS_CLOSE
    mov rax, [rsp + 56]
.Lcsd_close_s:
    mov [rsp + 56], rax
    mov edi, ebx
    OS_CLOSE
    mov rax, [rsp + 56]
.Lcsd_ret:
    add rsp, 64; pop r15; pop r14; pop r13; pop r12; pop rbp; pop rbx; ret
.Lcsd_depth_err:
    mov rax, -ENAMETOOLONG; ret

# int fs_copy_file(const char *src_path, const char *dst_path)
fs_copy_file:
    mov rcx, rsi
    mov rsi, rdi
    mov edi, AT_FDCWD
    mov edx, AT_FDCWD
    jmp copy_reg_at

# int fs_copy_recursive(const char *src_path, const char *dst_path)
fs_copy_recursive:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 112                      # [0..55]=src FileStat, [56..111]=dst FileStat
    call fs_copy_recursive__part1
    jz .Lfcr_same

    call fs_copy_recursive__os_statat
    js .Lfcr_ret
    mov eax, [rsp + FileStat.mode]
    and eax, S_IFMT
    cmp eax, S_IFDIR
    je .Lfcr_dir
    mov edi, AT_FDCWD
    mov rsi, r12
    mov edx, AT_FDCWD
    mov rcx, r13
    cmp eax, S_IFLNK
    je .Lfcr_link
    call copy_reg_at
    jmp .Lfcr_ret
.Lfcr_link:
    call copy_link_at
    jmp .Lfcr_ret

.Lfcr_dir:
    # Reject copying a directory into itself / a descendant (no infinite recursion)
    mov rdi, r12
    mov rsi, r13
    call path_is_same_or_descendant
    test eax, eax
    jnz .Lfcr_same
    call fs_copy_recursive__os_statat_2
    js .Lfcr_mk
    mov rax, [rsp + FileStat.dev]
    cmp rax, [rsp + 56 + FileStat.dev]
    jne .Lfcr_mk
    mov rax, [rsp + FileStat.ino]
    cmp rax, [rsp + 56 + FileStat.ino]
    je .Lfcr_same
.Lfcr_mk:
    call fs_copy_recursive__part4
    jns .Lfcr_made
    cmp rax, -EEXIST
    jne .Lfcr_ret
.Lfcr_made:
    call fs_copy_recursive__fs_progress_begin
    js .Lfcr_ret
    call fs_copy_recursive__sfd
    mov rbx, rax
    mov edi, r14d
    OS_CLOSE
    mov rax, rbx
    jmp .Lfcr_ret
.Lfcr_same:
    mov rax, -9999
.Lfcr_ret:
    add rsp, 112
    pop r15
    pop r14
    pop r13
    pop r12; pop rbx; ret

# fs_copy_recursive step (runs on the caller's frame)
fs_copy_recursive__part1:
    lea rsp, [rsp - 8]
    mov r12, rdi
    mov r13, rsi

    mov rdi, r12
    mov rsi, r13
    call str_cmp
    test eax, eax
.Lfs_copy_recursive__part1_ret:
    lea rsp, [rsp + 8]
    ret

# fs_copy_recursive step: os_statat (runs on the caller's frame)
fs_copy_recursive__os_statat:
    lea rsp, [rsp - 8]
    mov edi, AT_FDCWD
    mov rsi, r12
    lea rdx, [rsp + 16]
    xor ecx, ecx
    call os_statat
    test rax, rax
.Lfs_copy_recursive__os_statat_ret:
    lea rsp, [rsp + 8]
    ret

# fs_copy_recursive step: os_statat (runs on the caller's frame)
fs_copy_recursive__os_statat_2:
    lea rsp, [rsp - 8]
    mov edi, AT_FDCWD
    mov rsi, r13
    lea rdx, [rsp + 56 + 16]
    mov ecx, 1
    call os_statat
    test rax, rax
.Lfs_copy_recursive__os_statat_2_ret:
    lea rsp, [rsp + 8]
    ret

# fs_copy_recursive step (runs on the caller's frame)
fs_copy_recursive__part4:
    lea rsp, [rsp - 8]
    mov edi, AT_FDCWD
    mov rsi, r13
    mov edx, [rsp + FileStat.mode + 16]
    and edx, 0777
    or edx, 0700
    OS_MKDIRAT
    test rax, rax
.Lfs_copy_recursive__part4_ret:
    lea rsp, [rsp + 8]
    ret

# fs_copy_recursive step: fs_progress_begin (runs on the caller's frame)
fs_copy_recursive__fs_progress_begin:
    lea rsp, [rsp - 8]
    mov rdi, r12
    call fs_progress_begin
    call fs_progress_item
    mov edi, AT_FDCWD
    mov rsi, r12
    mov edx, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
.Lfs_copy_recursive__fs_progress_begin_ret:
    lea rsp, [rsp + 8]
    ret

# fs_copy_recursive step: sfd (runs on the caller's frame)
fs_copy_recursive__sfd:
    lea rsp, [rsp - 8]
    mov r14d, eax                     # sfd
    mov edi, AT_FDCWD
    mov rsi, r13
    mov edx, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
    js .Lfcr_close_s
    mov r15d, eax                     # dfd
    mov edi, r15d
    lea rsi, [rsp + 56 + 16]
    call os_fstat
    mov rcx, -1
    mov rdx, -1
    test rax, rax
    js .Lfcr_root
    mov rcx, [rsp + 56 + FileStat.dev + 16]
    mov rdx, [rsp + 56 + FileStat.ino + 16]
.Lfcr_root:
    mov [rip + g_copy_root_dev], rcx
    mov [rip + g_copy_root_ino], rdx
    mov edi, r14d
    mov esi, r15d
    xor edx, edx
    call copy_dir_fd
    mov rbx, rax
    mov edi, r15d
    OS_CLOSE
    mov rax, rbx
.Lfcr_close_s:
.Lfs_copy_recursive__sfd_ret:
    lea rsp, [rsp + 8]
    ret
