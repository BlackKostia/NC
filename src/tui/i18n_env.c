/* src/tui/i18n_env.c - registry of interface languages (freestanding C23; replaces i18n_env.s).
 * Index 0 = built-in English, then the *.lang packs sorted by id; current-language accessors, lookup by id / code and
 * POSIX locale detection. The packs themselves are loaded by i18n_pack.c. */
#include "duop_string.h"
#include "duop_sys.h"
#include "duop_tui.h"

static const LangStrings *g_lang_tbl[I18N_MAX];
static char g_lang_id[I18N_MAX][I18N_ID_LEN];          /* pack file name without .lang */
static int32_t g_lang_n;                               /* 0 until i18n_lang_reset: English only */
static int32_t g_cur_lang_idx;
static const LangStrings *g_cur_lang;

void i18n_lang_reset(void)
{
    g_lang_tbl[0] = &lang_en_table;
    str_copy(g_lang_id[0], "en", I18N_ID_LEN);
    g_lang_n = 1;
    g_cur_lang_idx = 0;
    g_cur_lang = nullptr;
}

int i18n_count(void) { return g_lang_n ? g_lang_n : 1; }

/* English for index 0 or an empty registry */
static const LangStrings *il_table(int idx) { return idx ? g_lang_tbl[idx] : &lang_en_table; }

/* z equals s[0..len) in any case (ASCII) */
static bool il_eq_ci(const char *s, int len, const char *z)
{
    for (int i = 0; i < len; i++) {
        if (!z[i] || ((uint8_t)s[i] | 0x20) != ((uint8_t)z[i] | 0x20)) return false;
    }
    return z[len] == 0;
}

/* length up to '_' '-' '.' '@' ' ' or NUL */
static int il_code_len(const char *s)
{
    int n = 0;
    while (s[n] && s[n] != '_' && s[n] != '-' && s[n] != '.' && s[n] != '@' && s[n] != ' ') n++;
    return n;
}

static int il_find_id(const char *s, int len)
{
    for (int i = 0; i < i18n_count(); i++)
        if (il_eq_ci(s, len, g_lang_id[i])) return i;
    return -1;
}

static int il_find_code(const char *s, int len)
{
    for (int i = 0; i < i18n_count(); i++)
        if (il_eq_ci(s, len, il_table(i)->s[0])) return i;
    return -1;
}

int i18n_has_id(const char *id) { return il_find_id(id, (int)str_len(id)) >= 0; }

void i18n_register(LangStrings *tbl, const char *id)
{
    int slot = i18n_count();
    if (slot >= I18N_MAX) return;
    int n = slot;
    while (slot > 1 && str_cmp(id, g_lang_id[slot - 1]) < 0) {         /* move down while id < the previous id */
        g_lang_tbl[slot] = g_lang_tbl[slot - 1];
        mem_copy(g_lang_id[slot], g_lang_id[slot - 1], I18N_ID_LEN);
        slot--;
    }
    g_lang_tbl[slot] = tbl;
    str_copy(g_lang_id[slot], id, I18N_ID_LEN);
    g_lang_n = n + 1;
}

/* s is an id, a code or a locale; ids win over codes, any case */
int i18n_find(const char *s)
{
    if (!s) return -1;
    int len = il_code_len(s);
    if (!len) return -1;
    int idx = il_find_id(s, len);
    return idx >= 0 ? idx : il_find_code(s, len);
}

int i18n_detect_env(char **envp)
{
    if (!envp) return 0;
    static const char *const vars[] = {"LC_ALL", "LC_MESSAGES", "LANG"};
    for (size_t i = 0; i < 3; i++) {
        const char *v = env_getenv(envp, vars[i]);
        if (v && *v) {
            int idx = i18n_find(v);
            return idx < 0 ? 0 : idx;
        }
    }
    return 0;
}

const LangStrings *i18n_get(void) { return g_cur_lang ? g_cur_lang : &lang_en_table; }

const LangStrings *i18n_set_lang(int idx)
{
    if ((uint32_t)idx >= (uint32_t)i18n_count()) idx = 0;
    g_cur_lang_idx = idx;
    g_cur_lang = il_table(idx);
    return g_cur_lang;
}

int i18n_get_idx(void) { return g_cur_lang_idx; }
