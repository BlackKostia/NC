/* include/duop_pkg.h - C view of the package-manager part of the filesystem layer (src/fs/pkg_*.c). */
#pragma once
#include "duop_abi.h"

#define PKG_FETCH_TIMEOUT_MS 60000   /* a download helper still running after this is killed */
#define PKG_FETCH_POLL_MS 50         /* wake-up interval while waiting for the helper */

/* Downloads url to dest_path with curl (falling back to wget), environment envp; at most PKG_FETCH_TIMEOUT_MS.
 * Returns 0 when the helper exited with status 0, -1 otherwise (fork/wait failure, non-zero exit, signal, timeout).
 * Asm callers test eax: the result is an int, not -errno. */
int pkg_fetch_url(char **envp, const char *url, const char *dest_path);
