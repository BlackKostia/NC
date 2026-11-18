/* src/fs/task.c - the progress hooks of the background worker and the scan that sizes a job (freestanding C23; replaces task.s, kept
 * as tests/harness/task_reference.s).
 *
 * The UI forks one worker per batch (task_worker.c); it publishes progress into a MAP_SHARED page (TaskShared). Every hook is a
 * no-op in the UI process, where g_fs_progress is NULL. Cancellation is cooperative (TaskShared.cancel, polled per chunk / entry)
 * and also follows the death of the UI process. */
#include "duop_task.h"
#include "duop_pal.h"
#include "duop_string.h"

#define MAX_DIR_DEPTH 512
#define DENTS_CAP 32752

TaskShared *g_fs_progress;
int g_measure_bytes;

/* basename(path) becomes the current item: seq odd while writing, even when stable */
void fs_progress_begin(const char *path)
{
    TaskShared *s = g_fs_progress;
    if (!s) return;
    const char *base = path_basename(path);
    __atomic_add_fetch(&s->seq, 1, __ATOMIC_RELEASE);
    (void)str_copy(s->cur_name, base, TASK_NAME_MAX);
    __atomic_add_fetch(&s->seq, 1, __ATOMIC_RELEASE);
}

void fs_progress_bytes(uint64_t n)
{
    if (g_fs_progress) g_fs_progress->done_bytes += n;
}

void fs_progress_item(void)
{
    if (g_fs_progress) g_fs_progress->done_files++;
}

/* 1 when the UI asked for a cancel or has died */
int fs_progress_cancelled(void)
{
    const TaskShared *s = g_fs_progress;
    if (!s) return 0;
    if (__atomic_load_n(&s->cancel, __ATOMIC_RELAXED)) return 1;
    return g_task_parent_pid && !os_parent_alive(g_task_parent_pid);
}

/* d_type driven, fd-relative: entries counted, regular-file sizes added when the job copies; unreadable parts skipped */
static intptr_t measure_dir_fd(int dfd, int depth)
{
    if ((unsigned)depth >= MAX_DIR_DEPTH) return -ENAMETOOLONG;
    TaskShared *s = g_fs_progress;
    char *buf = mem_alloc(DENTS_CAP);
    if (!buf) return 0;
    intptr_t r = 0;
    for (intptr_t n; r >= 0 && (n = os_dir_read(dfd, buf, DENTS_CAP)) > 0;) {
        size_t pos = 0;
        uint8_t type;
        for (const char *name; r >= 0 && (name = os_dir_next_ex(buf, (size_t)n, &pos, &type));) {
            if (name[0] == '.' && (!name[1] || (name[1] == '.' && !name[2]))) continue;
            if (fs_progress_cancelled()) { r = -ECANCELED; break; }
            s->total_files++;
            if (type == PAL_DT_REG && !g_measure_bytes) continue;          /* delete: the count only, no stat per file */
            if (type != PAL_DT_DIR && type != PAL_DT_REG && type != PAL_DT_UNKNOWN) continue;
            if (type != PAL_DT_DIR) {
                FileStat st;
                if (os_statat(dfd, name, &st, 0) < 0) continue;
                if ((st.mode & S_IFMT) == S_IFREG) { s->total_bytes += (uint64_t)st.size; continue; }
                if ((st.mode & S_IFMT) != S_IFDIR) continue;
            }
            intptr_t sub = os_openat(dfd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC, 0);
            if (sub < 0) continue;
            r = measure_dir_fd((int)sub, depth + 1);
            (void)os_close((int)sub);
        }
    }
    mem_free(buf);
    return r;
}

/* entries / regular-file bytes of the tree at path (symlinks not followed) into the shared totals: 0 or -ECANCELED (or
 * -ENAMETOOLONG from a tree deeper than MAX_DIR_DEPTH) */
int task_measure(const char *path)
{
    if (fs_progress_cancelled()) return -ECANCELED;
    FileStat st;
    if (os_statat(AT_FDCWD, path, &st, 0) < 0) return 0;
    TaskShared *s = g_fs_progress;
    s->total_files++;
    if ((st.mode & S_IFMT) == S_IFREG) {
        s->total_bytes += (uint64_t)st.size;
        return 0;
    }
    if ((st.mode & S_IFMT) != S_IFDIR) return 0;
    fs_progress_begin(path);
    intptr_t fd = os_openat(AT_FDCWD, path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC, 0);
    if (fd < 0) return 0;
    intptr_t r = measure_dir_fd((int)fd, 0);
    (void)os_close((int)fd);
    return (int)r;
}
