# Frozen reference oracle: the hand-written asm that src/fs/file_ops.c replaced (tests/test_c_file_ops.py diffs against it)
# Filesystem Operations: mkdir, touch, rename, copy, move, delete (recursive), file read
# fd-relative, d_type-driven, zero-copy (FICLONE / copy_file_range) copy & delete engine.
# Copy / delete report progress and honor cancellation through fs_progress_* hooks
# (src/fs/task.s); the hooks are no-ops outside a background worker.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"
.equ CFR_CHUNK,     4194304
.equ COPY_BUF_SIZE, 262144
.equ DENTS_CAP,     32752       # 32 KiB slab block minus its 16-byte header

.section .bss

# ==============================================================================
# Copy / delete engine
#   * fd-relative traversal: children are reached with openat/mkdirat/unlinkat/readlinkat
#     on the parent dirfd (no PATH_MAX joins, no repeated path resolution from the root);
#   * d_type driven: an entry is stat'ed only when the kernel reports DT_UNKNOWN;
#   * zero-copy data path: FICLONE reflink -> copy_file_range (4 MiB steps) ->
#     read/write through ONE shared 256 KiB buffer (no allocation per file);
#   * dirent frames come from the slab allocator (O(1), no syscalls after warm-up).
# ==============================================================================

.align 8
g_copy_buf:      .space 8

.section .text
.global fs_errno_message
.global fs_mkdir
.global fs_touch
.global fs_rename
.global fs_rename_noreplace
.global path_is_same_or_descendant
.global copy_data

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
    cmp edi, EOPNOTSUPP
    je .Lem_special
    mov rax, [rax + LangStrings.err_generic]
    ret
.Lem_special:  mov rax, [rax + LangStrings.err_special]; ret
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
    OS_RENAMEAT               # safe-overwrite
    test rax, rax
    ret

# int fs_rename_noreplace(const char *old_path, const char *new_path) -> 0, or -errno (-EEXIST: target exists)
# Uses renameat2(RENAME_NOREPLACE); on a kernel/filesystem without it the target is looked at first.
fs_rename_noreplace:
    push rbx; push r12
    sub rsp, FileStat._size
    mov rbx, rdi              # old_path
    mov r12, rsi              # new_path
    mov r10, rsi
    mov rsi, rdi
    mov edi, AT_FDCWD
    mov edx, AT_FDCWD
    mov r8d, RENAME_NOREPLACE
    OS_RENAMEAT2
    cmp rax, -EINVAL
    je .Lfrn_probe
    cmp rax, -ENOSYS
    jne .Lfrn_ret
.Lfrn_probe:
    mov edi, AT_FDCWD
    mov rsi, r12
    mov rdx, rsp
    xor ecx, ecx              # no-follow: a dangling symlink at the target counts as "exists"
    call os_statat
    test rax, rax
    jns .Lfrn_exists
    cmp rax, -ENOENT
    jne .Lfrn_ret
    mov r10, r12
    mov rsi, rbx
    mov edi, AT_FDCWD
    mov edx, AT_FDCWD
    OS_RENAMEAT               # safe-overwrite: the target was just verified absent
    jmp .Lfrn_ret
.Lfrn_exists:
    mov rax, -EEXIST
.Lfrn_ret:
    add rsp, FileStat._size
    pop r12; pop rbx
    test rax, rax
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
    sub rsp, 64                       # FileStat
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
    call copy_data__os_fstat
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
    call copy_data__sys_write_all
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
    add rsp, 64
    pop r15
    pop r14
    pop r13
    pop r12; pop rbx; ret

# copy_data step: os_fstat (runs on the caller's frame)
copy_data__os_fstat:
    lea rsp, [rsp - 8]
    mov edi, ebx
    lea rsi, [rsp + 16]
    call os_fstat
    test rax, rax
    js .Lcopy_data__os_fstat_ret
    mov rdi, [rsp + FileStat.size + 16]
    call fs_progress_bytes
.Lcopy_data__os_fstat_ret:
    lea rsp, [rsp + 8]
    ret

# copy_data step: sys_write_all (runs on the caller's frame)
copy_data__sys_write_all:
    lea rsp, [rsp - 8]
    mov r14, rax
    mov edi, r12d
    mov rsi, r15
    mov rdx, rax
    call sys_write_all
    test rax, rax
.Lcopy_data__sys_write_all_ret:
    lea rsp, [rsp + 8]
    ret
