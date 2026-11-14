# src/os/linux/x86_64/pal_du.s - Disk Usage PAL: allocated space (st_blocks * 512, like `du`) and
# detection of filesystems whose files are no disk usage of their own (pseudo, FUSE, squashfs,
# overlay, network), so walkers can skip such mount points.
.intel_syntax noprefix
.include "pal.inc"
.equ KSTAT_BLOCKS,   64               # struct stat st_blocks (512-byte units)
.equ OS_SYS_fstatfs, 138

.section .rodata
.align 4
# statfs f_type magics (linux/magic.h)
du_derived_fs:
    .long 0x00009fa0, 0x62656572, 0x00001cd1, 0x0027e0eb  # proc, sysfs, devpts, cgroup
    .long 0x63677270, 0x64626720, 0x74726163, 0x73636673  # cgroup2, debugfs, tracefs, securityfs
    .long 0x6165676c, 0xcafe4a11, 0x62656570, 0x19800202  # pstore, bpf, configfs, mqueue
    .long 0x958458f6, 0x42494e4d, 0x00000187, 0xf97cff8c  # hugetlbfs, binfmt_misc, autofs, selinuxfs
    .long 0x65735546, 0x65735543, 0xde5e81e4, 0x6e736673  # fuse, fusectl, efivarfs, nsfs
    .long 0x73717368, 0x794c7630, 0x00006969, 0xff534d42  # squashfs, overlay, nfs, cifs
    .long 0xfe534d42, 0x0000517b, 0x00c36400, 0x5346414f  # smb2, smb, ceph, afs
    .long 0x01021997, 0x67596969                          # 9p, rpc_pipefs
.equ DU_DERIVED_N, (. - du_derived_fs) / 4

.section .text
.global os_du_usage
.global os_fstat_du
.global os_fs_is_derived

# int64_t os_du_usage(int dirfd, const char *name, FileStat *out) -> allocated bytes or -errno
# (lstat semantics; out gets dev, ino, mode, nlink, ... for directory and hard-link checks)
os_du_usage:
    push rbx
    sub rsp, KSTAT_SIZE + 16
    mov rbx, rdx
    mov rdx, rsp
    mov r10d, AT_SYMLINK_NOFOLLOW
    mov eax, OS_SYS_newfstatat
    syscall
    test rax, rax
    js .Ldu_ret
    mov rdi, rbx
    mov rsi, rsp
    call du_kstat_copy                # rax = allocated bytes
.Ldu_ret:
    add rsp, KSTAT_SIZE + 16
    pop rbx
    ret

# int os_fstat_du(int fd, FileStat *out, int64_t *alloc_out) -> 0 or -errno
os_fstat_du:
    push rbx
    push r12
    sub rsp, KSTAT_SIZE + 8
    mov rbx, rsi
    mov r12, rdx
    mov rsi, rsp
    mov eax, OS_SYS_fstat
    syscall
    test rax, rax
    js .Lfd_ret
    mov rdi, rbx
    mov rsi, rsp
    call du_kstat_copy
    mov [r12], rax
    xor eax, eax
.Lfd_ret:
    add rsp, KSTAT_SIZE + 8
    pop r12
    pop rbx
    ret

# Internal: int64_t du_kstat_copy(FileStat *out [rdi], const struct stat *k [rsi]) -> st_blocks * 512
du_kstat_copy:
    mov rax, [rsi + KSTAT_DEV]
    mov [rdi + FileStat.dev], rax
    mov rax, [rsi + KSTAT_INO]
    mov [rdi + FileStat.ino], rax
    mov rax, [rsi + KSTAT_ST_SIZE]
    mov [rdi + FileStat.size], rax
    mov rax, [rsi + KSTAT_MTIME]
    mov [rdi + FileStat.mtime], rax
    mov eax, [rsi + KSTAT_MODE]
    mov [rdi + FileStat.mode], eax
    mov eax, [rsi + KSTAT_MTIME_NSEC]
    mov [rdi + FileStat.mtime_nsec], eax
    mov rax, [rsi + KSTAT_NLINK]
    mov [rdi + FileStat.nlink], rax
    mov eax, [rsi + KSTAT_UID]
    mov [rdi + FileStat.uid], eax
    mov eax, [rsi + KSTAT_GID]
    mov [rdi + FileStat.gid], eax
    mov rax, [rsi + KSTAT_BLOCKS]
    shl rax, 9
    ret

# int os_fs_is_derived(int fd) -> 1 when fd's filesystem type is in du_derived_fs, or cannot be
# identified at all (the xdg document portal FUSE mount refuses fstatfs with EPERM)
os_fs_is_derived:
    sub rsp, 136                      # struct statfs (120 bytes) + alignment
    mov rsi, rsp
    mov eax, OS_SYS_fstatfs
    syscall
    test rax, rax
    js .Lfs_yes
    mov rdx, [rsp]                    # f_type
    lea rcx, [rip + du_derived_fs]
    xor eax, eax
.Lfs_scan:
    cmp eax, DU_DERIVED_N
    jae .Lfs_no
    mov r8d, [rcx + rax * 4]
    cmp rdx, r8
    je .Lfs_yes
    inc eax
    jmp .Lfs_scan
.Lfs_yes:
    mov eax, 1
    add rsp, 136
    ret
.Lfs_no:
    xor eax, eax
    add rsp, 136
    ret
