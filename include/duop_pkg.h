/* include/duop_pkg.h - C view of the package-manager part of the filesystem layer (src/fs/pkg_*.c). */
#pragma once
#include "duop_fs.h"
#include "duop_arc.h"

#define PKG_FETCH_TIMEOUT_MS 60000   /* a download helper still running after this is killed */
#define PKG_FETCH_POLL_MS 50         /* wake-up interval while waiting for the helper */

/* Downloads url to dest_path with curl (falling back to wget), environment envp; at most PKG_FETCH_TIMEOUT_MS.
 * Returns 0 when the helper exited with status 0, -1 otherwise (fork/wait failure, non-zero exit, signal, timeout).
 * Asm callers test eax: the result is an int, not -errno. */
int pkg_fetch_url(char **envp, const char *url, const char *dest_path);

/* ---- file hashes of installed packages (pkg_verify.c) ---- */
/* files.list and hashes.sha256 of a package: one line per archive entry at most, so a whole archive always fits */
#define PKG_LIST_CAP ((uint64_t)ARC_MAX_ENTRIES * (PATH_MAX + 72))
void pkg_hashes_append(const char *file_path, char *buf, uint64_t *len_ptr);   /* "<sha256> <path>\n" while it fits PKG_LIST_CAP */
int pkg_hashes_write(const char *pkg_dir, const char *buf, uint64_t len);       /* <pkg_dir>/hashes.sha256: 0 / -1 */
int pkg_verify(char **envp, const char *name);                 /* every recorded file unchanged, manifest included: 0, else -1 */

/* ---- the registry (pkg_registry.c): <root>/registry.tsv, one tab-separated package per line ---- */
typedef struct PkgRegEntry { char name[64], version[32], kind[16], sha256[80], url[192], desc[128]; } PkgRegEntry;
_Static_assert(sizeof(PkgRegEntry) == 512, "PKGR_SIZE of the assembler");
int pkg_registry_update(char **envp);                          /* DUOP_PKG_REGISTRY (URL or file) -> registry.tsv: 0 / -1 */
int pkg_registry_list(char **envp, PkgRegEntry *out, int max); /* entries read */
int pkg_registry_find(char **envp, const char *name, PkgRegEntry *out);   /* 0 / -1 (among the first 64) */
int pkg_registry_upgrade(char **envp);                         /* installed packages with a newer version reinstalled: 0 / -1 */
int pkg_semver_cmp(const char *a, const char *b);              /* -1 / 0 / 1 over major.minor.patch */

/* ---- still in assembly (pkg_manager.s, pkg_archive.s) ---- */
typedef struct PkgEntry { char name[64], version[32], kind[16], desc[112], rest[72]; } PkgEntry;   /* an installed package */
_Static_assert(sizeof(PkgEntry) == 296, "PKG_ENTRY_SZ of the assembler");
int pkg_list(char **envp, PkgEntry *out, int max);             /* installed packages */
int pkg_install_archive(char **envp, const char *path_or_url, const char *expected_sha256);   /* 0, else < 0 */
void pkg_mkdir_p(const char *path);
void pkg_get_root(char **envp, char *out, int cap);
int pkm_safe_name(const char *s);                              /* 1: a plain package name */
const char *pkm_safe_relpath(const char *p);                  /* p without leading "./", or NULL: empty, absolute, ".." */
int pkg_remove(char **envp, const char *name);                 /* activated files and <root>/<name> deleted: 0 / -1 */
int pkg_cli_dispatch(int argc, char **argv, char **envp);       /* `duop pkg ...`: the exit code (0 / 1) */
int pkg_vfs_list_stdout(char **envp, const char *uri);          /* the entries of a VFS package's URI on stdout: 0 / -1 */
int pkg_write_file(const char *path, const void *buf, uint64_t len);   /* 0 / -1 */
int pkg_ensure_exec(const char *path);                         /* a regular file (not a symlink), made 0755 if no x bit: 0 / -1 */
void pkg_parse_manifest(const char *buf, int len, PkgEntry *out);   /* name / version / kind / description of "key = value" lines */
ArcCtx *pkg_load_archive(const char *path);                    /* read (<= ARC_MAX_FILE) and indexed, or NULL */
ArcCtx *pkg_load_archive_sha(const char *path, char *out_sha_hex65);   /* the same, with the SHA-256 of the bytes read */
void pkg_free_archive(ArcCtx *ctx);
int pkg_extract_entry_to(ArcCtx *ctx, ArcEntry *ent, const char *dest_path);   /* 0 / -1 */

/* a declarative action of a package manifest (layout of the assembler's PKGA_*: 576 bytes) */
typedef struct PkgAction {
    char name[64], exec[64], menu[64], args[128], scope[16], mode[16], dir[160], ext[64];
} PkgAction;
_Static_assert(sizeof(PkgAction) == 576 && offsetof(PkgAction, args) == 192 && offsetof(PkgAction, dir) == 352 &&
               offsetof(PkgAction, ext) == 512, "PkgAction layout of the assembler");
void pkg_action_parse(const char *buf, int len, PkgAction *out);
int pkg_action_find(char **envp, const char *name, PkgAction *out);   /* the action of an installed package: 0 / -1 */
int pkg_actions_scan(char **envp, PkgAction *out, int max);    /* installed packages with an exec: count */
int pkg_action_build_argv(PkgAction *act, const char **ctx, char *str_buf, int buf_cap, char **argv_out, int max_args);   /* argc / -1 */
int pkg_menu_refresh(char **envp);                             /* the cached menu-enabled actions (at most 16): count */
int pkg_menu_count(void);
PkgAction *pkg_menu_get(int idx);                              /* NULL outside 0 .. count - 1 */
/* a VFS provider package as a pane (virtual_mode 3) - src/fs/pkg_vfs_pane.c */
int pkg_vfs_find_by_uri(char **envp, const char *uri, char *exe_out);   /* exe_out: PATH_MAX bytes; 0 / -1 */
int pkg_vfs_load_dir(char **envp, DirModel *model, const char *uri);      /* the provider's LIST as the model: 0 / -1 */
int pkg_vfs_parent_uri(const char *uri, char *out, int cap);              /* 1: out is the parent; 0: leave the VFS */
int pkg_vfs_read_uri(char **envp, const char *uri, char *out_tmp_path, int cap);   /* the provider's READ into a temp file: 0 / -1 */
