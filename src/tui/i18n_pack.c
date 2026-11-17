/* src/tui/i18n_pack.c - interface language packs (freestanding C23; replaces i18n_pack.s).
 *
 * Every "*.lang" file on the data path (data_dirs.c: $DUOP_LANGS, ~/.config/duop/lang, lang/ beside the binary,
 * share/duop/lang) becomes one language, so new interface languages need no rebuild. A pack is "key = value" lines
 * over the LangStrings slots (i18n_keys.c); missing keys keep the built-in English text. Values may be "quoted" to
 * keep outer spaces and use \n \t \" \\ escapes; {version} expands to the Duop version. A pack must set `code`; the
 * first file of an id (file name without .lang) on the path wins. Packs live in a static arena for the whole run
 * (no heap, nothing to free). */
#include "duop_config.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "version.h"

#define VERSION_LEN (sizeof DUOP_VERSION - 1)
_Static_assert(VERSION_LEN <= 9, "{version} expands in place: the version string must fit in 9 bytes");

static uint8_t g_ip_arena[I18N_ARENA] __attribute__((aligned(16)));
static size_t g_ip_used;

/* byte for "\c", or -1 to keep the backslash literally */
static int ip_escape(char c)
{
    return c == 'n' ? '\n' : c == 't' ? '\t' : c == '\\' ? '\\' : c == '"' ? '"' : -1;
}

/* decode a value in place (quotes, escapes, {version}); the result starts where the value started */
static char *ip_value(char *v)
{
    char *end = v + str_len(v);
    while (end > v && (end[-1] == ' ' || end[-1] == '\t' || end[-1] == '\r')) *--end = 0;
    char *r = v, *w = v;
    bool quoted = *v == '"';
    if (quoted) r++;
    for (; *r; ) {
        if (*r == '"' && quoted) break;                       /* closing quote */
        if (*r == '\\') {
            int e = ip_escape(r[1]);
            if (e >= 0) { *w++ = (char)e; r += 2; continue; }
        } else if (*r == '{' && str_starts_with(r, "{version}")) {
            mem_copy(w, DUOP_VERSION, VERSION_LEN);
            w += VERSION_LEN;
            r += 9;                                           /* strlen("{version}") >= VERSION_LEN */
            continue;
        }
        *w++ = *r++;
    }
    *w = 0;
    return v;
}

static bool ip_key_char(uint8_t c) { return c == '_' || c == '.' || (uint8_t)(c - '0') <= 9 || (uint8_t)((c | 0x20) - 'a') <= 25; }

/* one "key = value" line; unknown keys, comments and junk are ignored */
static void ip_line(char *line, LangStrings *tbl)
{
    char *key = skip_ws(line), *p = key;
    while (ip_key_char((uint8_t)*p)) p++;
    if (p == key) return;
    char *eq = skip_ws(p);
    if (*eq != '=') return;
    *p = 0;
    int off = i18n_key_offset(key);
    if (off < 0 || (size_t)off % sizeof(char *) || (size_t)off / sizeof(char *) >= LANG_SLOTS) return;
    tbl->s[(size_t)off / sizeof(char *)] = ip_value(skip_ws(eq + 1));
}

/* NUL-terminated text, rewritten in place */
static void ip_parse(char *text, LangStrings *tbl)
{
    while (*text) {
        char *eol = text;
        while (*eol && *eol != '\n') eol++;
        char *next = eol;
        if (*eol) { *eol = 0; next++; }
        ip_line(text, tbl);
        text = next;
    }
}

/* id = name without ".lang"; false when it does not fit */
static bool ip_stem(const char *name, char *id)
{
    size_t n = str_len(name);
    if (n <= 5 || n - 5 >= I18N_ID_LEN) return false;
    str_copy(id, name, n - 5 + 1);
    return true;
}

/* next free arena slot and the capacity left for the file text (0 = arena full) */
static LangStrings *ip_reserve(size_t *cap)
{
    size_t room = I18N_ARENA - sizeof(LangStrings);
    *cap = 0;
    if (g_ip_used >= room) return nullptr;
    room -= g_ip_used;
    if (room > I18N_FILE_MAX) room = I18N_FILE_MAX;
    if (room < 256) return nullptr;
    *cap = room;
    return (LangStrings *)(g_ip_arena + g_ip_used);
}

static void ip_load_file(const char *path, const char *name)
{
    char id[I18N_ID_LEN];
    if (!ip_stem(name, id) || i18n_has_id(id)) return;        /* an earlier directory already provided this language */
    size_t cap;
    LangStrings *slot = ip_reserve(&cap);
    if (!cap) return;
    mem_copy(slot, &lang_en_table, sizeof *slot);              /* every key starts as English */
    char *text = (char *)(slot + 1);
    intptr_t n = data_read_file(path, text, cap);
    if (n < 0) return;
    ip_parse(text, slot);
    if (slot->s[0] == lang_en_table.s[0]) return;             /* no `code`: not a language pack */
    g_ip_used += ((size_t)n + sizeof(LangStrings) + 8) & ~(size_t)7;
    i18n_register(slot, id);
}

static const DataSpec ip_spec = { "DUOP_LANGS=", "lang", ".lang", ip_load_file };

void i18n_load(char **envp)
{
    i18n_lang_reset();
    g_ip_used = 0;
    data_dirs_scan(envp, &ip_spec);
}
