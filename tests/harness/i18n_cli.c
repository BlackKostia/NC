/* Freestanding harness: frozen asm i18n registry + pack loader (ref_ prefix) next to src/tui/i18n_{env,pack}.c.
 *   <ref|c> dump [id...]  i18n_load(envp); the count, i18n_find of each id, then per language every slot that
 *                         differs from English (index + escaped text)
 *   <ref|c> find <s> | detect | idx
 * Output is text so the test can diff the asm against the C byte for byte. */
#include "duop_string.h"
#include "duop_tui.h"

extern void ref_i18n_load(char **);
extern int ref_i18n_find(const char *);
extern int ref_i18n_detect_env(char **);
extern const LangStrings *ref_i18n_set_lang(int);
extern const LangStrings *ref_i18n_get(void);
extern int ref_i18n_count(void);
extern int ref_i18n_get_idx(void);

static bool g_ref;
static char g_out[1 << 20];
static size_t g_n;

static void flush(void) { (void)os_write(1, g_out, g_n); g_n = 0; }
static void put(const char *s)
{
    while (*s) {
        if (g_n >= sizeof g_out - 8) flush();
        g_out[g_n++] = *s++;
    }
}
static void num(int64_t v)
{
    char t[24];
    if (v < 0) { put("-"); v = -v; }
    t[u64_to_dec((uint64_t)v, t)] = 0;
    put(t);
}
static void esc(const char *s)
{
    static const char hexd[] = "0123456789abcdef";
    for (; *s; s++) {
        uint8_t c = (uint8_t)*s;
        if (c >= 0x20 && c < 0x7F && c != '\\') { char t[2] = {(char)c, 0}; put(t); }
        else { char t[5] = {'\\', 'x', hexd[c >> 4], hexd[c & 15], 0}; put(t); }
    }
}

static void dump(int argc, char **argv, char **envp)
{
    if (g_ref) ref_i18n_load(envp); else i18n_load(envp);
    int n = g_ref ? ref_i18n_count() : i18n_count();
    put("count="); num(n); put("\n");
    for (int i = 3; i < argc; i++) { put("find "); put(argv[i]); put("="); num(g_ref ? ref_i18n_find(argv[i]) : i18n_find(argv[i])); put("\n"); }
    for (int l = 0; l < n; l++) {
        const LangStrings *t = g_ref ? ref_i18n_set_lang(l) : i18n_set_lang(l);
        const LangStrings *g = g_ref ? ref_i18n_get() : i18n_get();
        put("lang "); num(l); put(t == g ? " ok\n" : " get-mismatch\n");
        for (size_t k = 0; k < LANG_SLOTS; k++) {
            if (l && t->s[k] == lang_en_table.s[k]) continue;
            num((int64_t)k); put(":"); esc(t->s[k]); put("\n");
        }
    }
    put("idx="); num(g_ref ? ref_i18n_get_idx() : i18n_get_idx()); put("\n");
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)auxv;
    if (argc < 3) return 2;
    g_ref = !str_cmp(argv[1], "ref");
    if (!str_cmp(argv[2], "dump")) dump(argc, argv, envp);
    else if (!str_cmp(argv[2], "find") || !str_cmp(argv[2], "detect")) {
        if (g_ref) ref_i18n_load(envp); else i18n_load(envp);
        int r = !str_cmp(argv[2], "find") ? (g_ref ? ref_i18n_find(argc > 3 ? argv[3] : nullptr) : i18n_find(argc > 3 ? argv[3] : nullptr))
                                          : (g_ref ? ref_i18n_detect_env(envp) : i18n_detect_env(envp));
        num(r); put("\n");
    }
    flush();
    return 0;
}
