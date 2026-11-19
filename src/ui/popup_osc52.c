/* src/ui/popup_osc52.c - OSC 52 terminal clipboard copy helper (freestanding C23; replaces src/ui/popup_osc52.s,
 * kept as tests/harness/popup_osc52_reference.s). Fixes the asm's unchecked mem_alloc on OOM. */
#include "duop_string.h"
#include "duop_sys.h"
#include "duop_ui.h"

static const char b64_tab[64] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

void osc52_copy_text(const char *str)
{
    if (!str) return;
    size_t len = str_len(str);
    if (len > (SIZE_MAX - 64) / 2) return;
    char *buf = mem_alloc(len * 2 + 64);
    if (!buf) return;
    static const char pfx[7] = "\x1b]52;c;";
    size_t pos = 0;
    for (size_t i = 0; i < sizeof pfx; i++) buf[pos++] = pfx[i];
    for (size_t i = 0; i < len; i += 3) {
        uint32_t v = (uint32_t)(uint8_t)str[i] << 16;
        int n = 1;
        if (i + 1 < len) { v |= (uint32_t)(uint8_t)str[i + 1] << 8; n++; }
        if (i + 2 < len) { v |= (uint32_t)(uint8_t)str[i + 2]; n++; }
        buf[pos++] = b64_tab[(v >> 18) & 0x3F];
        buf[pos++] = b64_tab[(v >> 12) & 0x3F];
        buf[pos++] = n >= 2 ? b64_tab[(v >> 6) & 0x3F] : '=';
        buf[pos++] = n >= 3 ? b64_tab[v & 0x3F] : '=';
    }
    buf[pos++] = 7;
    (void)sys_write_all(1, buf, pos);
    mem_free(buf);
}
