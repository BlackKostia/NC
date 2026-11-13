# Filesystem Operations: mkdir, touch, rename, copy, move, delete (recursive), file read

.intel_syntax noprefix
.include "linux_sys.inc"
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
    mov rax, [rax + LangStrings.err_generic]
    ret
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
    mov rax, SYS_mkdirat
    syscall
    ret

# int fs_touch(const char *path)
fs_touch:
    mov rsi, rdi
    mov edi, AT_FDCWD
    mov edx, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC
    mov r10d, 0644
    mov rax, SYS_openat
    syscall
    test rax, rax
    js .Lft_done
    mov edi, eax
    mov rax, SYS_close
    syscall
    xor eax, eax
.Lft_done:
    ret

# int fs_rename(const char *old_path, const char *new_path)
fs_rename:
    mov r10, rsi              # new_path (4th syscall arg = r10)
    mov rsi, rdi              # old_path (2nd syscall arg = rsi)
    mov edi, AT_FDCWD         # 1st syscall arg = rdi
    mov edx, AT_FDCWD         # 3rd syscall arg = rdx
    xor r8d, r8d              # 5th syscall arg flags = r8
    mov rax, SYS_renameat2
    syscall
    ret

# int fs_copy_file(const char *src_path, const char *dst_path)
fs_copy_file:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 304              # [rsp..143]=st_src, [rsp+144..287]=st_dst
    mov r12, rdi              # src_path
    mov r13, rsi              # dst_path

    # stat src (nofollow already handled in recursive caller, follow or nofollow ok for reg file)
    mov edi, AT_FDCWD
    mov rsi, r12
    mov rdx, rsp
    mov r10d, AT_SYMLINK_NOFOLLOW
    mov rax, SYS_newfstatat
    syscall
    test rax, rax
    js .Lfcf_done

    # Check if dst exists and refers to the exact same inode+dev
    mov edi, AT_FDCWD
    mov rsi, r13
    lea rdx, [rsp + 144]
    mov r10d, AT_SYMLINK_NOFOLLOW
    mov rax, SYS_newfstatat
    syscall
    test rax, rax
    js .Lfcf_open_src
    mov rax, [rsp + 0]        # src st_dev
    cmp rax, [rsp + 144 + 0]
    jne .Lfcf_open_src
    mov rax, [rsp + 8]        # src st_ino
    cmp rax, [rsp + 144 + 8]
    jne .Lfcf_open_src
    mov rax, -9999            # same file safeguard
    jmp .Lfcf_done

.Lfcf_open_src:
    mov edi, AT_FDCWD
    mov rsi, r12
    mov edx, O_RDONLY | O_CLOEXEC
    xor r10d, r10d
    mov rax, SYS_openat
    syscall
    test rax, rax
    js .Lfcf_done
    mov r14d, eax             # src_fd

    mov edi, AT_FDCWD
    mov rsi, r13
    mov edx, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC
    mov r10d, [rsp + STAT_MODE]
    and r10d, 0777
    or r10d, 0600             # ensure user rw while writing
    mov rax, SYS_openat
    syscall
    test rax, rax
    js .Lfcf_close_src_err
    mov r15d, eax             # dst_fd

    # Allocate 32 KiB copy buffer
    mov edi, 32768
    call mem_alloc
    test rax, rax
    jz .Lfcf_mem_err
    mov rbx, rax

.Lfcf_loop:
    mov edi, r14d
    mov rsi, rbx
    mov edx, 32768
    call sys_read_retry
    test rax, rax
    js .Lfcf_io_err
    jz .Lfcf_copy_ok

    mov edi, r15d
    mov rsi, rbx
    mov rdx, rax
    call sys_write_all
    test rax, rax
    js .Lfcf_io_err
    jmp .Lfcf_loop

.Lfcf_copy_ok:
    mov rdi, rbx
    call mem_free
    mov edi, r15d
    mov rax, SYS_close
    syscall
    mov edi, r14d
    mov rax, SYS_close
    syscall
    xor eax, eax
    jmp .Lfcf_done

.Lfcf_io_err:
    push rax
    mov rdi, rbx
    call mem_free
    pop rax
    jmp .Lfcf_close_both
.Lfcf_mem_err:
    mov rax, -12
.Lfcf_close_both:
    push rax
    mov edi, r15d
    mov rax, SYS_close
    syscall
    pop rax
.Lfcf_close_src_err:
    push rax
    mov edi, r14d
    mov rax, SYS_close
    syscall
    pop rax
.Lfcf_done:
    add rsp, 304
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# int fs_copy_recursive(const char *src_path, const char *dst_path)
fs_copy_recursive:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 160              # stat buf
    mov r12, rdi              # src
    mov r13, rsi              # dst

    # Prevent copying into self
    mov rdi, r12
    mov rsi, r13
    call str_cmp
    test eax, eax
    jnz .Lfcr_stat
    mov rax, -9999
    jmp .Lfcr_done

.Lfcr_stat:
    mov edi, AT_FDCWD
    mov rsi, r12
    mov rdx, rsp
    mov r10d, AT_SYMLINK_NOFOLLOW
    mov rax, SYS_newfstatat
    syscall
    test rax, rax
    js .Lfcr_done

    mov eax, [rsp + STAT_MODE]
    and eax, S_IFMT
    cmp eax, S_IFDIR
    je .Lfcr_dir
    cmp eax, S_IFLNK
    je .Lfcr_symlink

    mov rdi, r12
    mov rsi, r13
    call fs_copy_file
    jmp .Lfcr_done

.Lfcr_symlink:
    # Read link target and create symlink at dst
    mov edi, PATH_MAX
    call mem_alloc
    test rax, rax
    jz .Lfcr_enomem
    mov rbx, rax
    mov edi, AT_FDCWD
    mov rsi, r12
    mov rdx, rbx
    mov r10d, PATH_MAX - 1
    mov rax, SYS_readlinkat
    syscall
    test rax, rax
    js .Lfcr_sym_free_err
    mov byte ptr [rbx + rax], 0

    mov rdi, rbx              # target
    mov esi, AT_FDCWD
    mov rdx, r13              # linkpath
    mov rax, SYS_symlinkat
    syscall
    push rax
    mov rdi, rbx
    call mem_free
    pop rax
    jmp .Lfcr_done

.Lfcr_sym_free_err:
    push rax
    mov rdi, rbx
    call mem_free
    pop rax
    jmp .Lfcr_done

.Lfcr_dir:
    # Create destination directory
    mov edi, AT_FDCWD
    mov rsi, r13
    mov edx, [rsp + STAT_MODE]
    and edx, 0777
    or edx, 0700
    mov rax, SYS_mkdirat
    syscall
    test rax, rax
    jns .Lfcr_open_dir
    cmp rax, -EEXIST
    jne .Lfcr_done

.Lfcr_open_dir:
    mov edi, AT_FDCWD
    mov rsi, r12
    mov edx, O_RDONLY | O_DIRECTORY | O_CLOEXEC
    xor r10d, r10d
    mov rax, SYS_openat
    syscall
    test rax, rax
    js .Lfcr_done
    mov r14d, eax             # dirfd

    # Allocate dents_buf (DIRENTS_BUF_SIZE) + child_src (PATH_MAX) + child_dst (PATH_MAX)
    mov edi, DIRENTS_BUF_SIZE + PATH_MAX * 2
    call mem_alloc
    test rax, rax
    jz .Lfcr_dir_close_nomem
    mov rbx, rax              # [rbx]=dents, [rbx+DIRENTS_BUF_SIZE]=csrc, [rbx+DIRENTS_BUF_SIZE+PATH_MAX]=cdst

.Lfcr_dents_loop:
    mov edi, r14d
    mov rsi, rbx
    mov edx, DIRENTS_BUF_SIZE
    mov rax, SYS_getdents64
    syscall
    test rax, rax
    js .Lfcr_dir_err
    jz .Lfcr_dir_ok
    mov r15, rax              # bytes read
    xor ecx, ecx              # pos

.Lfcr_entry_loop:
    cmp rcx, r15
    jae .Lfcr_dents_loop
    lea r8, [rbx + rcx]
    movzx r9d, word ptr [r8 + DIRENT_RECLEN]
    push rcx
    push r9
    lea r10, [r8 + DIRENT_NAME]

    # Skip "." and ".."
    cmp byte ptr [r10], '.'
    jne .Lfcr_recurse
    cmp byte ptr [r10 + 1], 0
    je .Lfcr_entry_next
    cmp byte ptr [r10 + 1], '.'
    jne .Lfcr_recurse
    cmp byte ptr [r10 + 2], 0
    je .Lfcr_entry_next

.Lfcr_recurse:
    push r10
    lea rdi, [rbx + DIRENTS_BUF_SIZE]
    mov rsi, r12
    mov rdx, r10
    mov ecx, PATH_MAX
    call path_join

    pop r10
    lea rdi, [rbx + DIRENTS_BUF_SIZE + PATH_MAX]
    mov rsi, r13
    mov rdx, r10
    mov ecx, PATH_MAX
    call path_join

    lea rdi, [rbx + DIRENTS_BUF_SIZE]
    lea rsi, [rbx + DIRENTS_BUF_SIZE + PATH_MAX]
    call fs_copy_recursive
    test rax, rax
    js .Lfcr_entry_fail

.Lfcr_entry_next:
    pop r9
    pop rcx
    add rcx, r9
    jmp .Lfcr_entry_loop

.Lfcr_entry_fail:
    pop r9
    pop rcx
.Lfcr_dir_err:
    push rax
    mov rdi, rbx
    call mem_free
    mov edi, r14d
    mov rax, SYS_close
    syscall
    pop rax
    jmp .Lfcr_done

.Lfcr_dir_ok:
    mov rdi, rbx
    call mem_free
    mov edi, r14d
    mov rax, SYS_close
    syscall
    xor eax, eax
    jmp .Lfcr_done

.Lfcr_dir_close_nomem:
    mov edi, r14d
    mov rax, SYS_close
    syscall
.Lfcr_enomem:
    mov rax, -12
.Lfcr_done:
    add rsp, 160
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# int fs_delete_recursive(const char *path)
fs_delete_recursive:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 160
    mov r12, rdi              # path

    mov edi, AT_FDCWD
    mov rsi, r12
    mov rdx, rsp
    mov r10d, AT_SYMLINK_NOFOLLOW
    mov rax, SYS_newfstatat
    syscall
    test rax, rax
    js .Lfdr_done

    mov eax, [rsp + STAT_MODE]
    and eax, S_IFMT
    cmp eax, S_IFDIR
    je .Lfdr_dir

    # Unlink non-directory
    mov edi, AT_FDCWD
    mov rsi, r12
    xor edx, edx
    mov rax, SYS_unlinkat
    syscall
    jmp .Lfdr_done

.Lfdr_dir:
    mov edi, AT_FDCWD
    mov rsi, r12
    mov edx, O_RDONLY | O_DIRECTORY | O_CLOEXEC
    xor r10d, r10d
    mov rax, SYS_openat
    syscall
    test rax, rax
    js .Lfdr_done
    mov r13d, eax             # dirfd

    mov edi, DIRENTS_BUF_SIZE + PATH_MAX
    call mem_alloc
    test rax, rax
    jz .Lfdr_close_nomem
    mov rbx, rax              # [rbx]=dents, [rbx+DIRENTS_BUF_SIZE]=child

.Lfdr_dents:
    mov edi, r13d
    mov rsi, rbx
    mov edx, DIRENTS_BUF_SIZE
    mov rax, SYS_getdents64
    syscall
    test rax, rax
    js .Lfdr_dir_err
    jz .Lfdr_rmdir
    mov r14, rax
    xor ecx, ecx

.Lfdr_entry:
    cmp rcx, r14
    jae .Lfdr_dents
    lea r8, [rbx + rcx]
    movzx r9d, word ptr [r8 + DIRENT_RECLEN]
    push rcx
    push r9
    lea r10, [r8 + DIRENT_NAME]

    cmp byte ptr [r10], '.'
    jne .Lfdr_del_child
    cmp byte ptr [r10 + 1], 0
    je .Lfdr_next
    cmp byte ptr [r10 + 1], '.'
    jne .Lfdr_del_child
    cmp byte ptr [r10 + 2], 0
    je .Lfdr_next

.Lfdr_del_child:
    lea rdi, [rbx + DIRENTS_BUF_SIZE]
    mov rsi, r12
    mov rdx, r10
    mov ecx, PATH_MAX
    call path_join

    lea rdi, [rbx + DIRENTS_BUF_SIZE]
    call fs_delete_recursive
    test rax, rax
    js .Lfdr_entry_fail

.Lfdr_next:
    pop r9
    pop rcx
    add rcx, r9
    jmp .Lfdr_entry

.Lfdr_entry_fail:
    pop r9
    pop rcx
.Lfdr_dir_err:
    push rax
    mov rdi, rbx
    call mem_free
    mov edi, r13d
    mov rax, SYS_close
    syscall
    pop rax
    jmp .Lfdr_done

.Lfdr_rmdir:
    mov rdi, rbx
    call mem_free
    mov edi, r13d
    mov rax, SYS_close
    syscall

    mov edi, AT_FDCWD
    mov rsi, r12
    mov edx, AT_REMOVEDIR
    mov rax, SYS_unlinkat
    syscall
    jmp .Lfdr_done

.Lfdr_close_nomem:
    mov edi, r13d
    mov rax, SYS_close
    syscall
    mov rax, -12
.Lfdr_done:
    add rsp, 160
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# int fs_move_recursive(const char *src_path, const char *dst_path)
fs_move_recursive:
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
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
    mov rdi, rbx
    call fs_delete_recursive
.Lfmr_done:
    pop r12
    pop rbx
    ret

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
    mov rax, SYS_openat
    syscall
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
    mov rax, SYS_close
    syscall
    xor eax, eax
.Lrfh_ret:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# int fs_read_file_alloc(const char *path, size_t max_bytes, void **out_buf, size_t *out_len)
fs_read_file_alloc:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 160
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
    mov rax, SYS_openat
    syscall
    test rax, rax
    js .Lrfa_done
    mov ebx, eax              # fd

    mov edi, ebx
    mov rsi, rsp
    mov rax, SYS_fstat
    syscall
    test rax, rax
    js .Lrfa_close_err

    mov rax, [rsp + STAT_ST_SIZE]
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
    mov rax, SYS_close
    syscall
    xor eax, eax
    jmp .Lrfa_done

.Lrfa_close_nomem:
    mov rax, -12
.Lrfa_close_err:
    push rax
    mov edi, ebx
    mov rax, SYS_close
    syscall
    pop rax
.Lrfa_done:
    add rsp, 160
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
