/* src/tui/kbd_map.c - keyboard layout table (freestanding C23; replaces kbd_map.s).
 *
 * Parses *.layout text into {codepoint -> Latin key} pairs and answers kbd_latin(key) for hotkey matching
 * (Event.lat). File syntax (UTF-8, one setting per line):
 *   # comment
 *   name  = Українська      -- ignored, for people
 *   keys  = qwertyuiop[]    -- Latin keys of one keyboard row, left to right
 *   chars = йцукенгшщзхї    -- what the layout types on the same keys, in the same order
 * Each `chars` line pairs with the nearest preceding `keys` line. ASCII chars are skipped (ordinary keys never change
 * meaning), targets must be printable ASCII, special keys are never shadowed and the first mapping of a codepoint wins.
 * Where the files are found: kbd_layout.c. */
#include "duop_config.h"
#include "duop_string.h"
#include "duop_tui.h"

typedef struct { uint64_t cp, len; } Utf8Dec;
Utf8Dec utf8_decode(const char *s);

static struct { uint32_t cp, key; } g_kbd_map[KBD_MAP_MAX];
static uint32_t g_kbd_n;

void kbd_map_reset(void) { g_kbd_n = 0; }

int kbd_latin(int key)
{
    if ((uint32_t)key < 0x80u) return key;
    for (uint32_t i = 0; i < g_kbd_n; i++)
        if (g_kbd_map[i].cp == (uint32_t)key) return (int)g_kbd_map[i].key;
    return key;
}

static void kp_insert(uint32_t cp, uint32_t key)
{
    for (uint32_t i = 0; i < g_kbd_n; i++)
        if (g_kbd_map[i].cp == cp) return;
    if (g_kbd_n >= KBD_MAP_MAX) return;
    g_kbd_map[g_kbd_n].cp = cp;
    g_kbd_map[g_kbd_n].key = key;
    g_kbd_n++;
}

/* Every valid column pair of one keys/chars line couple. */
static void kp_pair(const char *keys, const char *chars)
{
    for (;;) {
        Utf8Dec k = utf8_decode(keys);
        if (!k.len) return;
        keys += k.len;
        Utf8Dec c = utf8_decode(chars);
        if (!c.len) return;
        chars += c.len;
        uint32_t latin = (uint32_t)k.cp, cp = (uint32_t)c.cp;
        if (latin <= 0x20 || latin >= 0x7F) continue;        /* the target must be a printable ASCII key */
        if (cp < 0x80 || cp == 0xFFFD || cp >= KEY_UP) continue;   /* ASCII keeps its meaning; malformed; special keys */
        kp_insert(cp, latin);
    }
}

/* NUL-terminates the line at '\n'; returns the start of the next one (the terminator when this was the last). */
static char *kp_cut_line(char *p)
{
    while (*p) {
        if (*p++ == '\n') { p[-1] = 0; break; }
    }
    return p;
}

/* "keys = v" -> 1, "chars = v" -> 2 (value trimmed of trailing blanks/CR in place), anything else -> 0 */
static char *kp_value(char *line, int *kind)
{
    char *p = skip_ws(line);
    int k = 1;
    size_t kwlen = 4;
    if (!str_starts_with(p, "keys")) {
        k = 2;
        kwlen = 5;
        if (!str_starts_with(p, "chars")) { *kind = 0; return nullptr; }
    }
    p = skip_ws(p + kwlen);
    if (*p != '=') { *kind = 0; return nullptr; }
    char *v = skip_ws(p + 1);
    char *end = v + str_len(v);
    while (end > v && (end[-1] == ' ' || end[-1] == '\t' || end[-1] == '\r')) *--end = 0;
    *kind = k;
    return v;
}

void kbd_layout_parse(char *text)
{
    char *keys = nullptr;
    while (*text) {
        char *next = kp_cut_line(text);
        int kind;
        char *v = kp_value(text, &kind);
        if (kind == 1) keys = v;
        else if (kind == 2 && keys) kp_pair(keys, v);
        text = next;
    }
}
