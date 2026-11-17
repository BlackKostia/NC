/* src/core/string_format.c - human-readable size, permission string, cached timestamp (freestanding C23;
 * replaces string_format.s). */
#include "duop_string.h"

size_t format_size(int64_t bytes, char *buf)
{
    uint64_t q = bytes < 0 ? 0 : (uint64_t)bytes;
    if (q < 1024) {
        size_t n = u64_to_dec(q, buf);
        buf[n] = ' ';
        buf[n + 1] = 'B';
        buf[n + 2] = 0;
        return n + 2;
    }
    unsigned unit = 0;
    uint64_t rem = 0;
    while (q >= 1024 && unit < 6) {
        rem = q % 1024;
        q /= 1024;
        unit++;
    }
    uint64_t tenth = (rem * 10) >> 10;
    size_t n = u64_to_dec(q, buf);
    if (q < 100) {                                              /* "4.2 K"; from 100 up the decimal is dropped */
        buf[n++] = '.';
        buf[n++] = (char)('0' + tenth);
    }
    buf[n] = ' ';
    buf[n + 1] = "BKMGTPE"[unit];
    buf[n + 2] = 0;
    return n + 2;
}

void format_perms(uint32_t mode, char *buf)
{
    uint32_t type = mode & 0170000;
    buf[0] = type == 0040000 ? 'd' : type == 0120000 ? 'l' : '-';
    for (int i = 0; i < 9; i++)
        buf[1 + i] = (mode >> (8 - i)) & 1 ? "rwx"[i % 3] : '-';
    buf[10] = 0;
}

/* 64-slot direct-mapped cache keyed by the minute: one directory shares few distinct minutes, so redrawing a
 * pane skips the calendar arithmetic per visible row. */
static struct { int64_t minute; char text[16]; bool used; } g_dt_cache[64];

void format_datetime(int64_t epoch, char *buf)
{
    int64_t minute = epoch / 60;
    if (epoch % 60 < 0) minute--;                               /* floor for pre-1970 timestamps */
    unsigned slot = (unsigned)(((uint64_t)minute >> 7) ^ (uint64_t)minute) & 63;
    if (!g_dt_cache[slot].used || g_dt_cache[slot].minute != minute) {
        format_datetime_raw(epoch, buf);
        for (int i = 0; i < 16; i++) g_dt_cache[slot].text[i] = buf[i];
        g_dt_cache[slot].minute = minute;
        g_dt_cache[slot].used = true;
        return;
    }
    for (int i = 0; i < 16; i++) buf[i] = g_dt_cache[slot].text[i];
    buf[16] = 0;
}
