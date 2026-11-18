/* include/duop_pkg.h - C view of the package-manager part of the filesystem layer (src/fs/pkg_*.c). */
#pragma once
#include "duop_fs.h"

#define PKG_FETCH_TIMEOUT_MS 60000   /* a download helper still running after this is killed */
#define PKG_FETCH_POLL_MS 50         /* wake-up interval while waiting for the helper */

/* Downloads url to dest_path with curl (falling back to wget), environment envp; at most PKG_FETCH_TIMEOUT_MS.
 * Returns 0 when the helper exited with status 0, -1 otherwise (fork/wait failure, non-zero exit, signal, timeout).
 * Asm callers test eax: the result is an int, not -errno. */
int pkg_fetch_url(char **envp, const char *url, const char *dest_path);

/* ---- file hashes of installed packages (pkg_verify.c) ---- */
void pkg_hashes_append(const char *file_path, char *buf, uint64_t *len_ptr);   /* "<sha256> <path>\n" while it fits 8 KiB */
int pkg_hashes_write(const char *pkg_dir, const char *buf, uint64_t len);       /* <pkg_dir>/hashes.sha256: 0 / -1 */
int pkg_verify(char **envp, const char *name);                 /* every recorded file unchanged, manifest included: 0, else -1 */

/* ---- still in assembly (pkg_manager.s, pkg_archive.s) ---- */
void pkg_get_root(char **envp, char *out, int cap);
int pkm_safe_name(const char *s);                              /* 1: a plain package name */
int pkg_write_file(const char *path, const void *buf, uint64_t len);   /* 0 / -1 */
