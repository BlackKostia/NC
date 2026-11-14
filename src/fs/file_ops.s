# Filesystem Operations: mkdir, touch, rename, copy, move, delete (recursive), file read
# fd-relative, d_type-driven, zero-copy (FICLONE / copy_file_range) copy & delete engine.
# Copy / delete report progress and honor cancellation through fs_progress_* hooks
# (src/fs/task.s); the hooks are no-ops outside a background worker.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .text
.global fs_mkdir
.global fs_touch
.global fs_rename
.global fs_copy_file
.global fs_copy_recursive
.global fs_delete_recursive
.global fs_move_recursive
.global fs_read_file_head
.global fs_read_file_alloc
.global fs_errno_message

# const char *fs_errno_message(int neg_errno)
fs_errno_message:
    call i18n_get             # rax = LangStrings * (clobbers only rax)
    neg edi
    cmp edi, EACCES
    je .Lem_perm
    cmp edi, EEXIST
    je .Lem_exists
    cmp edi, ENOENT
    je .Lem_noent
    cmp edi, ENOTEMPTY
    je .Lem_notempty
    cmp edi, EISDIR
    je .Lem_isdir
    cmp edi, ENOTDIR
    je .Lem_notdir
    cmp edi, 9999
    je .Lem_same
    cmp edi, ECANCELED
    je .Lem_canceled
    cmp edi, EBUSY
    je .Lem_busy
    mov rax, [rax + LangStrings.err_generic]
    ret
.Lem_canceled: mov rax, [rax + LangStrings.err_canceled]; ret
.Lem_busy:     mov rax, [rax + LangStrings.err_busy]; ret
.Lem_perm:     mov rax, [rax + LangStrings.err_perm]; ret
.Lem_exists:   mov rax, [rax + LangStrings.err_exists]; ret
.Lem_noent:    mov rax, [rax + LangStrings.err_noent]; ret
.Lem_notempty: mov rax, [rax + LangStrings.err_notempty]; ret
.Lem_isdir:    mov rax, [rax + LangStrings.err_isdir]; ret
.Lem_notdir:   mov rax, [rax + LangStrings.err_notdir]; ret
.Lem_same:     mov rax, [rax + LangStrings.err_same]; ret

# int fs_mkdir(const char *path)
fs_mkdir:
    mov rsi, rdi
    mov edi, AT_FDCWD
    mov edx, 0755
    OS_MKDIRAT
    ret

# int fs_touch(const char *path)
fs_touch:
    mov rsi, rdi
    mov edi, AT_FDCWD
    mov edx, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC
    mov r10d, 0644
    OS_OPENAT
    test rax, rax
    js .Lft_done
    mov edi, eax
    OS_CLOSE
    xor eax, eax
.Lft_done:
    ret

# int fs_rename(const char *old_path, const char *new_path)
fs_rename:
    mov r10, rsi              # new_path
    mov rsi, rdi              # old_path
    mov edi, AT_FDCWD
    mov edx, AT_FDCWD
    OS_RENAMEAT
    ret

# int path_is_same_or_descendant(const char *src, const char *dst)
# Returns 1 if dst == src (ignoring trailing '/') or dst is strictly inside src/
path_is_same_or_descendant:
    mov r8, rdi
    mov r9, rsi
    xor ecx, ecx
.Lpis_slen:
    cmp byte ptr [r8 + rcx], 0
    je .Lpis_strim
    inc rcx
    jmp .Lpis_slen
.Lpis_strim:
    cmp rcx, 1
    jbe .Lpis_slen_done
    cmp byte ptr [r8 + rcx - 1], '/'
    jne .Lpis_slen_done
    dec rcx
    jmp .Lpis_strim
.Lpis_slen_done:
    test rcx, rcx
    jz .Lpis_no

    xor edx, edx
.Lpis_cmp:
    cmp rdx, rcx
    jae .Lpis_prefix_ok
    mov al, [r8 + rdx]
    cmp al, [r9 + rdx]
    jne .Lpis_no
    inc rdx
    jmp .Lpis_cmp

.Lpis_prefix_ok:
    cmp rcx, 1
    jne .Lpis_boundary
    cmp byte ptr [r8], '/'
    je .Lpis_yes

.Lpis_boundary:
    mov al, [r9 + rcx]
    test al, al
    jz .Lpis_yes
    cmp al, '/'
    je .Lpis_yes
.Lpis_no:
    xor eax, eax
    ret
.Lpis_yes:
    mov eax, 1
    ret

# ==============================================================================
# Copy / delete engine
#   * fd-relative traversal: children are reached with openat/mkdirat/unlinkat/readlinkat
#     on the parent dirfd (no PATH_MAX joins, no repeated path resolution from the root);
#   * d_type driven: an entry is stat'ed only when the kernel reports DT_UNKNOWN;
#   * zero-copy data path: FICLONE reflink -> copy_file_range (4 MiB steps) ->
#     read/write through ONE shared 256 KiB buffer (no allocation per file);
#   * dirent frames come from the slab allocator (O(1), no syscalls after warm-up).
# ==============================================================================

.equ CFR_CHUNK,     4194304
.equ COPY_BUF_SIZE, 262144
.equ DENTS_CAP,     32752       # 32 KiB slab block minus its 16-byte header

.section .bss
.align 8
g_copy_buf:      .space 8
g_copy_root_dev: .space 8       # destination root of the running copy (never descend into it)
g_copy_root_ino: .space 8

.section .text

# Internal: void *get_copy_buf(void) -- lazily allocated, reused for every file
get_copy_buf:
    mov rax, [rip + g_copy_buf]
    test rax, rax
    jnz .Lgcb_ret
    sub rsp, 8
    mov edi, COPY_BUF_SIZE
    call mem_alloc
    add rsp, 8
    mov [rip + g_copy_buf], rax
.Lgcb_ret:
    ret

# Internal: int copy_data(int sfd, int dfd, int is_regular)
# Returns 0, -errno, or -ECANCELED. Reports bytes through fs_progress_bytes.
copy_data:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48                       # FileStat
    mov ebx, edi
    mov r12d, esi
    mov r13d, edx
    xor r14d, r14d                    # bytes moved by copy_file_range
    test r13d, r13d
    jz .Lcd_rw

    mov edi, ebx
    mov esi, r12d
    call os_clone_file                # Btrfs/XFS/bcachefs: O(1) CoW reflink
    test rax, rax
    jnz .Lcd_cfr
    mov edi, ebx
    mov rsi, rsp
    call os_fstat
    test rax, rax
    js .Lcd_ok
    mov rdi, [rsp + FileStat.size]
    call fs_progress_bytes
.Lcd_ok:
    xor eax, eax
    jmp .Lcd_ret

.Lcd_cfr:
    mov edi, ebx
    mov esi, r12d
    mov edx, CFR_CHUNK
    call os_copy_file_range
    test rax, rax
    jz .Lcd_ok
    js .Lcd_cfr_err
    add r14, rax
    mov rdi, rax
    call fs_progress_bytes
    call fs_progress_cancelled
    test eax, eax
    jnz .Lcd_cancel
    jmp .Lcd_cfr
.Lcd_cfr_err:
    cmp rax, -EINTR
    jne .Lcd_cfr_fail
    call fs_progress_cancelled
    test eax, eax
    jnz .Lcd_cancel
    jmp .Lcd_cfr
.Lcd_cfr_fail:
    test r14, r14
    jnz .Lcd_ret                      # failure after progress: genuine I/O error
    cmp rax, -EXDEV
    je .Lcd_rw
    cmp rax, -EOPNOTSUPP
    je .Lcd_rw
    cmp rax, -EINVAL
    je .Lcd_rw
    cmp rax, -ENOSYS
    je .Lcd_rw
    cmp rax, -EBADF
    je .Lcd_rw
    jmp .Lcd_ret

.Lcd_rw:
    call get_copy_buf
    test rax, rax
    jz .Lcd_nomem
    mov r15, rax
.Lcd_rw_loop:
    mov edi, ebx
    mov rsi, r15
    mov edx, COPY_BUF_SIZE
    OS_READ
    cmp rax, -EINTR
    jne .Lcd_rd
    call fs_progress_cancelled        # SIGTERM from a cancel request breaks blocking reads
    test eax, eax
    jnz .Lcd_cancel
    jmp .Lcd_rw_loop
.Lcd_rd:
    test rax, rax
    jz .Lcd_ok
    js .Lcd_ret
    mov r14, rax
    mov edi, r12d
    mov rsi, r15
    mov rdx, rax
    call sys_write_all
    test rax, rax
    js .Lcd_ret
    mov rdi, r14
    call fs_progress_bytes
    call fs_progress_cancelled
    test eax, eax
    jnz .Lcd_cancel
    jmp .Lcd_rw_loop
.Lcd_nomem:
    mov rax, -ENOMEM
    jmp .Lcd_ret
.Lcd_cancel:
    mov rax, -ECANCELED
.Lcd_ret:
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12; pop rbx; ret

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
    js .Lcra_ret
    mov ebx, eax                      # sfd
    mov edi, ebx
    mov rsi, rsp
    call os_fstat
    test rax, rax
    js .Lcra_close_src

    mov edi, r14d
    mov rsi, r15
    mov edx, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC
    mov r10d, [rsp + FileStat.mode]
    and r10d, 0777
    or r10d, 0600
    OS_OPENAT
    cmp rax, -EEXIST
    jne .Lcra_have_dst
    mov edi, r14d
    mov rsi, r15
    mov rdx, rsp
    lea rcx, [rsp + 96]
    call fo_resolve_eexist_open
    cmp rax, -2
    jne .Lcra_have_dst
    call fs_progress_item
    xor eax, eax
    jmp .Lcra_close_src
.Lcra_have_dst:
    test rax, rax
    js .Lcra_close_src
    mov [rsp + 48], eax               # dfd
    mov rdi, r13
    call fs_progress_begin
    mov edi, ebx
    mov esi, [rsp + 48]
    mov eax, [rsp + FileStat.mode]
    and eax, S_IFMT
    xor edx, edx
    cmp eax, S_IFREG
    sete dl
    call copy_data
    mov [rsp + 56], rax
    mov edi, [rsp + 48]
    OS_CLOSE
    mov edi, ebx
    OS_CLOSE
    mov rax, [rsp + 56]
    cmp rax, -ECANCELED
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
    push rax
    sub rsp, 8
    mov edi, ebx
    OS_CLOSE
    add rsp, 8
    pop rax
.Lcra_ret:
    add rsp, 96 + PATH_MAX
    pop r15
    pop r14
    pop r13
    pop r12; pop rbx; ret

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
    mov rdi, rbx
    mov rsi, r14
    mov rdx, rsp
    lea rcx, [rsp + 8]
    call os_dir_next_ex
    test rax, rax
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
    movzx eax, byte ptr [rsp + 8]
    cmp eax, PAL_DT_UNKNOWN
    jne .Lcdf_typed
    mov edi, r12d
    mov rsi, r15
    lea rdx, [rsp + 16]
    xor ecx, ecx
    call os_statat
    test rax, rax
    js .Lcdf_reg
    mov eax, [rsp + 16 + FileStat.mode]
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

# Internal: int copy_subdir(int sdir, const char *name, int ddir)
copy_subdir:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    sub rsp, 48                       # FileStat
    mov r12d, edi
    mov r13, rsi
    mov r14d, edx
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
    mov edx, O_RDONLY | O_DIRECTORY | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
    js .Lcsd_close_s
    mov ebp, eax                      # dfd
    mov edi, ebx
    mov esi, ebp
    call copy_dir_fd
    mov [rsp], rax
    mov edi, ebp
    OS_CLOSE
    mov rax, [rsp]
.Lcsd_close_s:
    mov [rsp], rax
    mov edi, ebx
    OS_CLOSE
    mov rax, [rsp]
.Lcsd_ret:
    add rsp, 48
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

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
    sub rsp, 96                       # [0]=src FileStat, [48]=dst FileStat
    mov r12, rdi
    mov r13, rsi

    mov rdi, r12
    mov rsi, r13
    call str_cmp
    test eax, eax
    jz .Lfcr_same

    mov edi, AT_FDCWD
    mov rsi, r12
    mov rdx, rsp
    xor ecx, ecx
    call os_statat
    test rax, rax
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
    mov edi, AT_FDCWD
    mov rsi, r13
    lea rdx, [rsp + 48]
    mov ecx, 1
    call os_statat
    test rax, rax
    js .Lfcr_mk
    mov rax, [rsp + FileStat.dev]
    cmp rax, [rsp + 48 + FileStat.dev]
    jne .Lfcr_mk
    mov rax, [rsp + FileStat.ino]
    cmp rax, [rsp + 48 + FileStat.ino]
    je .Lfcr_same
.Lfcr_mk:
    mov edi, AT_FDCWD
    mov rsi, r13
    mov edx, [rsp + FileStat.mode]
    and edx, 0777
    or edx, 0700
    OS_MKDIRAT
    test rax, rax
    jns .Lfcr_made
    cmp rax, -EEXIST
    jne .Lfcr_ret
.Lfcr_made:
    mov rdi, r12
    call fs_progress_begin
    call fs_progress_item
    mov edi, AT_FDCWD
    mov rsi, r12
    mov edx, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
    js .Lfcr_ret
    mov r14d, eax                     # sfd
    mov edi, AT_FDCWD
    mov rsi, r13
    mov edx, O_RDONLY | O_DIRECTORY | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
    js .Lfcr_close_s
    mov r15d, eax                     # dfd
    mov edi, r15d
    lea rsi, [rsp + 48]
    call os_fstat
    mov rcx, -1
    mov rdx, -1
    test rax, rax
    js .Lfcr_root
    mov rcx, [rsp + 48 + FileStat.dev]
    mov rdx, [rsp + 48 + FileStat.ino]
.Lfcr_root:
    mov [rip + g_copy_root_dev], rcx
    mov [rip + g_copy_root_ino], rdx
    mov edi, r14d
    mov esi, r15d
    call copy_dir_fd
    mov rbx, rax
    mov edi, r15d
    OS_CLOSE
    mov rax, rbx
.Lfcr_close_s:
    mov rbx, rax
    mov edi, r14d
    OS_CLOSE
    mov rax, rbx
    jmp .Lfcr_ret
.Lfcr_same:
    mov rax, -9999
.Lfcr_ret:
    add rsp, 96
    pop r15
    pop r14
    pop r13
    pop r12; pop rbx; ret

# Internal: int delete_dir_fd(int dfd) -- removes every entry below dfd (not dfd itself)
delete_dir_fd:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 72                       # [0]=cursor, [8]=d_type, [16..63]=FileStat
    mov r12d, edi
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
    mov rdi, rbx
    mov rsi, r14
    mov rdx, rsp
    lea rcx, [rsp + 8]
    call os_dir_next_ex
    test rax, rax
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
    mov edi, r12d
    mov rsi, r15
    lea rdx, [rsp + 16]
    xor ecx, ecx
    call os_statat
    test rax, rax
    js .Lddf_file
    mov eax, [rsp + 16 + FileStat.mode]
    and eax, S_IFMT
    cmp eax, S_IFDIR
    jne .Lddf_file
.Lddf_dir:
    mov edi, r12d
    mov rsi, r15
    mov edx, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
    js .Lddf_err
    mov ebp, eax
    mov edi, ebp
    call delete_dir_fd
    mov [rsp + 64], rax
    mov edi, ebp
    OS_CLOSE
    mov rax, [rsp + 64]
    test rax, rax
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
    add rsp, 72
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
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
    mov rdi, rbx
    mov rsi, r12
    call fs_copy_recursive
    test rax, rax
    js .Lfmr_done
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
    mov edx, O_RDONLY | O_CLOEXEC
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

# int fs_read_file_alloc(const char *path, size_t max_bytes, void **out_buf, size_t *out_len)
fs_read_file_alloc:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    mov r12, rdi              # path
    mov r13, rsi              # max_bytes
    mov r14, rdx              # out_buf
    mov r15, rcx              # out_len
    mov qword ptr [r14], 0
    mov qword ptr [r15], 0

    mov edi, AT_FDCWD
    mov rsi, r12
    mov edx, O_RDONLY | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
    js .Lrfa_done
    mov ebx, eax              # fd

    mov edi, ebx
    mov rsi, rsp
    call os_fstat
    test rax, rax
    js .Lrfa_close_err

    mov rax, [rsp + FileStat.size]
    test rax, rax
    jns .Lrfa_nonneg
    xor eax, eax
.Lrfa_nonneg:
    cmp rax, r13
    jbe .Lrfa_size_ok
    mov rax, r13
.Lrfa_size_ok:
    mov r13, rax              # cap to read
    lea rdi, [rax + 1]
    call mem_alloc
    test rax, rax
    jz .Lrfa_close_nomem
    mov [r14], rax            # *out_buf

    xor ecx, ecx
.Lrfa_loop:
    cmp rcx, r13
    jae .Lrfa_ok
    push rcx
    mov edi, ebx
    mov rsi, [r14]
    add rsi, rcx
    mov rdx, r13
    sub rdx, rcx
    call sys_read_retry
    pop rcx
    test rax, rax
    jle .Lrfa_ok
    add rcx, rax
    jmp .Lrfa_loop

.Lrfa_ok:
    mov rax, [r14]
    mov byte ptr [rax + rcx], 0
    mov [r15], rcx
    mov edi, ebx
    OS_CLOSE
    xor eax, eax
    jmp .Lrfa_done

.Lrfa_close_nomem:
    mov rax, -ENOMEM
.Lrfa_close_err:
    push rax
    mov edi, ebx
    OS_CLOSE
    pop rax
.Lrfa_done:
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12; pop rbx; ret
