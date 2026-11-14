// src/os/linux/aarch64/pal_du.s - Disk Usage PAL (AArch64): allocated space (st_blocks * 512) and
// detection of filesystems whose files are no disk usage of their own (pseudo, FUSE, squashfs,
// overlay, network). struct stat: st_dev=0, st_ino=8, st_mode=16, st_size=48, st_blocks=64, st_mtime=88
.include "pal.inc"
.equ OS_SYS_fstatfs, 44

.section .rodata
.align 2
du_derived_fs:
    .word 0x00009fa0, 0x62656572, 0x00001cd1, 0x0027e0eb
    .word 0x63677270, 0x64626720, 0x74726163, 0x73636673
    .word 0x6165676c, 0xcafe4a11, 0x62656570, 0x19800202
    .word 0x958458f6, 0x42494e4d, 0x00000187, 0xf97cff8c
    .word 0x65735546, 0x65735543, 0xde5e81e4, 0x6e736673
    .word 0x73717368, 0x794c7630, 0x00006969, 0xff534d42
    .word 0xfe534d42, 0x0000517b, 0x00c36400, 0x5346414f
    .word 0x01021997, 0x67596969
.equ DU_DERIVED_N, (. - du_derived_fs) / 4

.section .text
.global os_du_usage
.global os_fstat_du
.global os_fs_is_derived

// int64_t os_du_usage(int dirfd, const char *name, FileStat *out) -> allocated bytes or -errno
os_du_usage:
    stp x29, x30, [sp, #-160]!
    mov x29, sp
    mov x10, x2
    add x2, sp, #16
    mov w3, #AT_SYMLINK_NOFOLLOW
    OS_SYSCALL OS_SYS_newfstatat
    cmp x0, #0
    blt 1f
    add x0, sp, #16
    mov x1, x10
    bl du_kstat_copy
1:  ldp x29, x30, [sp], #160
    ret

// int os_fstat_du(int fd, FileStat *out, int64_t *alloc_out) -> 0 or -errno
os_fstat_du:
    stp x29, x30, [sp, #-160]!
    mov x29, sp
    mov x10, x1
    mov x11, x2
    add x1, sp, #16
    OS_SYSCALL OS_SYS_fstat
    cmp x0, #0
    blt 1f
    add x0, sp, #16
    mov x1, x10
    bl du_kstat_copy
    str x0, [x11]
    mov x0, #0
1:  ldp x29, x30, [sp], #160
    ret

// Internal: int64_t du_kstat_copy(const struct stat *k [x0], FileStat *out [x1]) -> st_blocks * 512
du_kstat_copy:
    ldr x9, [x0, #0]
    str x9, [x1, #FileStat.dev]
    ldr x9, [x0, #8]
    str x9, [x1, #FileStat.ino]
    ldr w9, [x0, #16]
    str w9, [x1, #FileStat.mode]
    ldr w9, [x0, #20]
    str x9, [x1, #FileStat.nlink]
    ldr x9, [x0, #48]
    str x9, [x1, #FileStat.size]
    ldr x9, [x0, #88]
    str x9, [x1, #FileStat.mtime]
    ldr x0, [x0, #64]
    lsl x0, x0, #9
    ret

// int os_fs_is_derived(int fd) -> 1 when the filesystem type is in du_derived_fs or cannot be
// identified (the xdg document portal FUSE mount refuses fstatfs with EPERM)
os_fs_is_derived:
    stp x29, x30, [sp, #-144]!
    mov x29, sp
    add x1, sp, #16
    OS_SYSCALL OS_SYS_fstatfs
    cmp x0, #0
    blt 3f
    ldr x9, [sp, #16]                 // f_type
    adr x10, du_derived_fs
    mov x11, #0
1:  cmp x11, #DU_DERIVED_N
    b.ge 2f
    ldr w12, [x10, x11, lsl #2]
    cmp x9, x12
    b.eq 3f
    add x11, x11, #1
    b 1b
3:  mov x0, #1
    ldp x29, x30, [sp], #144
    ret
2:  mov x0, #0
    ldp x29, x30, [sp], #144
    ret
