/* src/core/string_datetime.c - UTC calendar formatting (freestanding C23; replaces string_datetime.s). */
#include "duop_string.h"

/* "YYYY-MM-DD HH:MM" for floor-divided epoch seconds; the year is clamped to 0..9999 for four digits. */
void format_datetime_raw(int64_t epoch, char *buf)
{
    int64_t days = epoch / 86400, rem = epoch % 86400;
    if (rem < 0) { rem += 86400; days--; }
    int64_t z = days + 719468;                                  /* shift to 0000-03-01 */
    int64_t era = (z >= 0 ? z : z - 146096) / 146097;
    uint64_t doe = (uint64_t)(z - era * 146097);                /* 0..146096 */
    uint64_t yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    uint64_t doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    uint64_t mp = (5 * doy + 2) / 153;
    uint64_t day = doy - (153 * mp + 2) / 5 + 1;
    uint64_t month = mp < 10 ? mp + 3 : mp - 9;
    int64_t year = (int64_t)yoe + era * 400 + (month <= 2 ? 1 : 0);
    if (year < 0) year = 0;
    if (year > 9999) year = 9999;
    uint32_t y = (uint32_t)year, hh = (uint32_t)rem / 3600, mm = ((uint32_t)rem % 3600) / 60;
    buf[0] = (char)('0' + y / 1000);
    buf[1] = (char)('0' + y / 100 % 10);
    buf[2] = (char)('0' + y / 10 % 10);
    buf[3] = (char)('0' + y % 10);
    buf[4] = '-';
    buf[5] = (char)('0' + month / 10);
    buf[6] = (char)('0' + month % 10);
    buf[7] = '-';
    buf[8] = (char)('0' + day / 10);
    buf[9] = (char)('0' + day % 10);
    buf[10] = ' ';
    buf[11] = (char)('0' + hh / 10);
    buf[12] = (char)('0' + hh % 10);
    buf[13] = ':';
    buf[14] = (char)('0' + mm / 10);
    buf[15] = (char)('0' + mm % 10);
    buf[16] = 0;
}
