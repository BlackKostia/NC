/* Freestanding harness: the frozen asm English table + key lookup (ref_ prefix, absent with -DNO_REF) next to the generated
 * lang_en_table (build/i18n_en.c) and src/tui/i18n_keys.c.
 *   <ref|c> table          every slot as "<index>:<escaped text>"
 *   <ref|c> keys <key>...  "<key>=<i18n_key_offset(key)>" per argument
 * Output is text so the test can diff the asm against the C byte for byte. */
#include "duop_string.h"
#include "duop_tui.h"

#ifndef NO_REF
extern const LangStrings ref_lang_en_table;
extern int ref_i18n_key_offset(const char *);
#endif

static char g_out[1 << 16];
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

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 3) return 2;
#ifndef NO_REF
    bool ref = !str_cmp(argv[1], "ref");
#else
    bool ref = false;
#endif
    if (!str_cmp(argv[2], "table")) {
        for (size_t k = 0; k < LANG_SLOTS; k++) {
#ifndef NO_REF
            const char *s = ref ? ref_lang_en_table.s[k] : lang_en_table.s[k];
#else
            const char *s = lang_en_table.s[k];
#endif
            num((int64_t)k); put(":"); esc(s); put("\n");
        }
    } else if (!str_cmp(argv[2], "keys")) {
        for (int i = 3; i < argc; i++) {
#ifndef NO_REF
            int off = ref ? ref_i18n_key_offset(argv[i]) : i18n_key_offset(argv[i]);
#else
            int off = i18n_key_offset(argv[i]);
#endif
            put(argv[i]); put("="); num(off); put("\n");
        }
    }
    (void)ref;
    flush();
    return 0;
}
