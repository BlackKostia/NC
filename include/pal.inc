# Duop Platform Abstraction Layer (PAL) — OS/ISA-Neutral Binary Contracts
# Selected platform headers are resolved at assemble time via -I include/os/$(OS)/$(ARCH)

.ifndef PAL_INC_INCLUDED
.equ PAL_INC_INCLUDED, 1

.include "pal_target.inc"

# --- Portable FileStat Metadata Layout (40 bytes) ---
# Filled by os_statat / os_fstat so kernel struct stat never leaks above src/os/
.struct 0
FileStat.dev:    .space 8     # Device ID
FileStat.ino:    .space 8     # Inode number
FileStat.size:   .space 8     # File byte size
FileStat.mtime:  .space 8     # Modification time (seconds since epoch)
FileStat.mode:   .space 4     # POSIX file mode & type bits (S_IF* | perm)
FileStat.pad:    .space 4
FileStat._size:

# --- Portable Directory Entry Types (from OS d_type when available) ---
.equ PAL_DT_UNKNOWN, 0
.equ PAL_DT_FIFO,    1
.equ PAL_DT_CHR,     2
.equ PAL_DT_DIR,     4
.equ PAL_DT_BLK,     6
.equ PAL_DT_REG,     8
.equ PAL_DT_LNK,     10
.equ PAL_DT_SOCK,    12

# --- Process / Event-Loop ABI helpers (implemented in src/os/<os>/<arch>/pal_os.s) ---
#   int  os_poll_in2(int fd0, int fd1, int timeout_ms)
#        Waits until fd0 and/or fd1 is readable or hung up (fd1 < 0 is ignored).
#        Returns bitmask (bit0 = fd0 ready, bit1 = fd1 ready), 0 on timeout, or -errno.
#   int  os_pipe_cloexec(int fds[2])            -> 0 or -errno (fds[0] read end, fds[1] write end)
#   int  os_clone_file(int src_fd, int dst_fd)  -> 0 (CoW reflink) or -errno (e.g. -EOPNOTSUPP)
#   ssize_t os_copy_file_range(int src_fd, int dst_fd, size_t len) -> bytes copied in-kernel, 0 at EOF, -errno
#   SIMD primitives (src/os/<os>/<arch>/pal_simd.s; scalar fallbacks allowed per ISA):
#     os_mem_copy_fast / os_mem_move_fast / os_mem_set_fast / os_mem_cmp_fast  (memcpy/memmove/memset/memcmp ABI)
#     size_t os_str_len_fast(const char *s)                  -- preserves all GPRs except rax
#     int  os_str_contains_ci_fast(const char *hay, const char *needle_lc, size_t nlen) -- ASCII ci, 1/0
#     size_t os_mem_mismatch16(const void *a, const void *b, size_t n16) -- index of first differing
#          16-byte block (Cell) among n16 blocks, or n16 when equal
#   void os_signals_worker_mode(void)           -> background worker: ignore SIGWINCH/SIGINT,
#        SIGTERM interrupts blocking syscalls with -EINTR (no SA_RESTART) instead of terminating.

.endif
