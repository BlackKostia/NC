/* src/fs/trash_info.c - freedesktop.org Trash specification 1.0 ".trashinfo" writer (freestanding C23; replaces trash_info.s).
 *
 *   [Trash Info]\nPath=<percent-encoded absolute path>\nDeletionDate=YYYY-MM-DDThh:mm:ss\n
 *
 * Path= is escaped byte-wise (everything except A-Z a-z 0-9 - . _ ~ and "/" becomes %XX), so no file name can add keys or
 * lines. DeletionDate is the real UTC time of the deletion (other tools purge the trash by it) and the file is written
 * atomically (temp file + fsync + rename). */
#include "duop_fs.h"
#include "duop_oop.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_sys.h"

#define TI_BUF (3 * PATH_MAX + 96)             /* header + fully escaped path + date line */

static size_t ti_pct_encode(char *dst, const char *src)    /* bytes written (NUL added, not counted) */
{
    static const char hex[] = "0123456789ABCDEF";
    size_t n = 0;
    for (uint8_t c; (c = (uint8_t)*src++);) {
        bool plain = c == '/' || c == '-' || c == '.' || c == '_' || c == '~' || (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
        if (plain) { dst[n++] = (char)c; continue; }
        dst[n++] = '%';
        dst[n++] = hex[c >> 4];
        dst[n++] = hex[c & 15];
    }
    dst[n] = 0;
    return n;
}

static void ti_date(int64_t epoch, char *out32)             /* "YYYY-MM-DDThh:mm:ss" (UTC) + NUL */
{
    format_datetime_raw(epoch, out32);                      /* "YYYY-MM-DD hh:mm" */
    uint32_t sec = (uint32_t)((uint64_t)epoch % 60);
    out32[10] = 'T';
    out32[16] = ':';
    out32[17] = (char)('0' + sec / 10);
    out32[18] = (char)('0' + sec % 10);
    out32[19] = 0;
}

/* content length, or 0 when the path is too long; buf holds TI_BUF bytes plus 32 of date scratch right behind */
static size_t ti_build(char *buf, const char *orig)
{
    if (str_len(orig) >= PATH_MAX - 1) return 0;
    size_t n = str_copy(buf, "[Trash Info]\nPath=", TI_BUF);
    n += ti_pct_encode(buf + n, orig);
    n += str_copy(buf + n, "\nDeletionDate=", 64);
    ti_date(os_time_sec(), buf + TI_BUF);
    n += str_copy(buf + n, buf + TI_BUF, 32);
    buf[n++] = '\n';
    return n;
}

int tu_write_info(const char *info_path, const char *orig_path)
{
    char *tmp = mem_alloc(PATH_MAX + TI_BUF + 48);          /* temp path, content, date scratch: too big for the stack */
    if (!tmp) return -ENOMEM;
    char *buf = tmp + PATH_MAX;
    int rc;
    size_t len = ti_build(buf, orig_path);
    if (!len) {
        rc = -ENAMETOOLONG;
    } else {
        intptr_t fd = tmp_open_atomic(info_path, tmp, 0600);
        if (fd < 0) {
            rc = (int)fd;
        } else {
            intptr_t w = sys_write_all((int)fd, buf, len);
            rc = (int)tmp_commit_atomic((int)fd, tmp, info_path, w < 0 ? w : (size_t)w == len ? 0 : -EIO);
        }
    }
    mem_free(tmp);
    return rc;
}
