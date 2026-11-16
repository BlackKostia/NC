/* include/duop_abi.h - freestanding C23 view of the Duop PAL ABI (Етап 0.1).
 *
 * Only compiler headers (<stdint.h>, <stddef.h>, <stdbool.h>) -- never libc. Kernel structs stay in
 * src/os/; portable code sees FileStat and the os_* functions below. Every os_* that can fail returns
 * a non-negative result or -errno (see os_is_err); there is no errno global.
 */
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define DUOP_NORETURN    [[noreturn]]
#define DUOP_NODISCARD   [[nodiscard]]
#define DUOP_UNUSED      [[maybe_unused]]
#define DUOP_RETURNS_TWICE __attribute__((returns_twice))
#define DUOP_RODATA      __attribute__((section(".rodata")))
#define DUOP_PACKED      __attribute__((packed))

/* Fixed-width mirror of the `.struct FileStat` in include/pal.inc (56 bytes on every target). */
typedef struct FileStat {
    uint64_t dev, ino;
    int64_t  size, mtime;
    uint32_t mode, mtime_nsec;
    uint64_t nlink;
    uint32_t uid, gid;
} FileStat;
_Static_assert(sizeof(FileStat) == 56, "FileStat must match include/pal.inc");
_Static_assert(offsetof(FileStat, mode) == 32 && offsetof(FileStat, uid) == 48, "FileStat layout");

/* Error contract: results in [-4095, -1] are -errno. */
static inline bool os_is_err(intptr_t r) { return (uintptr_t)r > (uintptr_t)-4096; }

/* Unaligned little-endian loads for parsers (ARMv7 faults on unaligned LDM/LDRD; C aliasing is UB). */
static inline uint16_t load_le16(const void *p) { uint16_t v; __builtin_memcpy(&v, p, 2); return __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__ ? v : __builtin_bswap16(v); }
static inline uint32_t load_le32(const void *p) { uint32_t v; __builtin_memcpy(&v, p, 4); return __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__ ? v : __builtin_bswap32(v); }
static inline uint64_t load_le64(const void *p) { uint64_t v; __builtin_memcpy(&v, p, 8); return __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__ ? v : __builtin_bswap64(v); }

/* ---- Raw syscall wrappers (src/os/<os>/<arch>/pal_sys_*.s) ---- */
intptr_t os_read(int fd, void *buf, size_t n);
intptr_t os_write(int fd, const void *buf, size_t n);
intptr_t os_close(int fd);
intptr_t os_fsync(int fd);
intptr_t os_ftruncate(int fd, int64_t len);
intptr_t os_lseek(int fd, int64_t off, int whence);
intptr_t os_ioctl(int fd, uintptr_t req, void *arg);
intptr_t os_fcntl(int fd, int cmd, uintptr_t arg);
intptr_t os_pipe2(int fds[2], int flags);
intptr_t os_openat(int dirfd, const char *path, int flags, unsigned mode);
intptr_t os_dup2(int oldfd, int newfd);
intptr_t os_mkdirat(int dirfd, const char *path, unsigned mode);
intptr_t os_unlinkat(int dirfd, const char *path, int flags);
intptr_t os_renameat2(int olddir, const char *old, int newdir, const char *new_, unsigned flags);
intptr_t os_symlinkat(const char *target, int newdirfd, const char *linkpath);
intptr_t os_readlinkat(int dirfd, const char *path, char *buf, size_t n);
intptr_t os_linkat(int olddir, const char *old, int newdir, const char *new_, int flags);
intptr_t os_fchmodat(int dirfd, const char *path, unsigned mode);
intptr_t os_fchownat(int dirfd, const char *path, unsigned uid, unsigned gid, int flags);
intptr_t os_getcwd(char *buf, size_t n);
intptr_t os_chdir(const char *path);
intptr_t os_fork(void);
intptr_t os_execve(const char *path, char *const argv[], char *const envp[]);
intptr_t os_wait4(int pid, int *status, int options, void *rusage);
intptr_t os_kill(int pid, int sig);
DUOP_NORETURN void os_exit(int code);
intptr_t os_getpid(void);
intptr_t os_getppid(void);
intptr_t os_gettid(void);
intptr_t os_setsid(void);
intptr_t os_getuid(void);
intptr_t os_prctl(int op, uintptr_t a2, uintptr_t a3, uintptr_t a4, uintptr_t a5);
intptr_t os_prlimit64(int pid, int resource, const void *new_limit, void *old_limit);
intptr_t os_tgkill(int tgid, int tid, int sig);
intptr_t os_mmap(void *addr, size_t len, int prot, int flags, int fd, int64_t off);
intptr_t os_sigaltstack(const void *ss, void *old_ss);
intptr_t os_rt_sigaction(int sig, const void *act, void *old, size_t sigsetsize);
intptr_t os_rt_sigprocmask(int how, const void *set, void *old, size_t sigsetsize);

/* ---- Normalised PAL (src/os/<os>/<arch>/pal_os.s and siblings) ---- */
int       os_statat(int dirfd, const char *path, FileStat *out, int follow_symlinks);
int       os_fstat(int fd, FileStat *out);
intptr_t  os_dir_read(int dirfd, void *buf, size_t cap);
const char *os_dir_next(void *buf, size_t bytes, size_t *pos);
const char *os_dir_next_ex(void *buf, size_t bytes, size_t *pos, uint8_t *out_type);
void     *os_mem_remap(void *old_base, size_t old_mapped, size_t new_mapped);
int       os_poll_in(int fd, int timeout_ms);
int       os_poll_in2(int fd0, int fd1, int timeout_ms);
int       os_poll_many(const int *fds, int n, int timeout_ms);
int       os_set_nonblock(int fd);
int       os_pipe_cloexec(int fds[2]);
int       os_clone_file(int src_fd, int dst_fd);
intptr_t  os_copy_file_range(int src_fd, int dst_fd, size_t len);
void     *os_mmap_file_ro(int fd, size_t len);
void      os_munmap(void *addr, size_t len);
void      os_sigbus_guard_install(void);
int64_t   os_clock_ms(void);
void      os_get_winsize(int *cols, int *rows);
void      os_term_save_and_raw(void);
int       os_term_restore(void);
void      os_signals_worker_mode(void);
int       os_watch_init(void);
int       os_watch_add(int fd, const char *path, uint32_t pal_in_mask);
int       os_watch_rm(int fd, int wd);
intptr_t  os_watch_read(int fd, void *buf, size_t cap);
int       os_watch_next(const void *buf, size_t len, size_t *pos, int *wd, uint32_t *mask);

/* ---- SIMD/scalar primitives (pal_simd.s) ---- */
size_t os_mem_mismatch16(const void *a, const void *b, size_t n16);
size_t os_mem_find_byte(const void *p, size_t len, int byte);
size_t os_mem_count_byte(const void *p, size_t len, int byte);

/* ---- Entry (pal_start.s -> application) ---- */
int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv);
