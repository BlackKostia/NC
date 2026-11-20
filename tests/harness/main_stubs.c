/* tests/harness/main_stubs.c - shared stub layer for differential testing of src/app/main.c vs main_reference.s. */
#include "duop_abi.h"
#include "duop_app_int.h"
#include "duop_classes.h"
#include "duop_oop.h"
#include "duop_pkg.h"
#include "duop_string.h"
#include "duop_sys.h"
#include "duop_tui.h"
#include "i18n_slots.h"

char **g_envp;

static LangStrings g_lang_en;
static LangStrings g_lang_uk;
static char g_usage_en[] = "USAGE_EN\n";
static char g_ver_en[] = "VER_EN\n";
static char g_usage_uk[] = "USAGE_UK\n";
static char g_ver_uk[] = "VER_UK\n";
static App g_app_dummy;

static void out_str(const char *s)
{
    (void)os_write(1, s, str_len(s));
}

static void out_num(int64_t v)
{
    char buf[24];
    if (v < 0) { out_str("-"); v = -v; }
    size_t n = u64_to_dec((uint64_t)v, buf);
    buf[n] = 0;
    out_str(buf);
}

static const char *env_val(char **envp, const char *prefix)
{
    if (!envp) return nullptr;
    size_t plen = str_len(prefix);
    for (int i = 0; envp[i]; i++) {
        if (str_starts_with(envp[i], prefix)) return envp[i] + plen;
    }
    return nullptr;
}

static int env_int(const char *prefix)
{
    const char *v = env_val(g_envp, prefix);
    if (!v || !*v) return 0;
    int r = 0;
    for (; *v >= '0' && *v <= '9'; v++) r = r * 10 + (*v - '0');
    return r;
}

void mc_init(char **envp)
{
    out_str("mc_init env="); out_num(envp == g_envp && envp != nullptr); out_str("\n");
}

void mc_report(void)
{
    out_str("mc_report\n");
}

intptr_t sys_write_all(int fd, const void *buf, size_t len)
{
    out_str("write fd="); out_num(fd); out_str(" len="); out_num((int64_t)len); out_str("\n");
    return os_write(fd, buf, len);
}

void i18n_load(char **envp)
{
    g_lang_en.s[LS_cli_usage] = g_usage_en;
    g_lang_en.s[LS_cli_version] = g_ver_en;
    g_lang_uk.s[LS_cli_usage] = g_usage_uk;
    g_lang_uk.s[LS_cli_version] = g_ver_uk;
    out_str("i18n_load env="); out_num(envp == g_envp && envp != nullptr); out_str("\n");
}

int i18n_find(const char *id)
{
    if (!str_cmp(id, "en")) return 0;
    if (!str_cmp(id, "uk") || !str_cmp(id, "UA")) return 1;
    return -1;
}

int i18n_detect_env(char **envp)
{
    const char *v = env_val(envp, "LANG=");
    return (v && str_starts_with(v, "uk")) ? 1 : 0;
}

const LangStrings *i18n_set_lang(int idx)
{
    out_str("i18n_set_lang "); out_num(idx); out_str("\n");
    return idx == 1 ? &g_lang_uk : &g_lang_en;
}

int pkg_cli_dispatch(int argc, char **argv, char **envp)
{
    out_str("pkg_cli_dispatch argc="); out_num(argc);
    for (int i = 1; i < argc; i++) { out_str(" "); out_str(argv[i]); }
    out_str(" env="); out_num(envp == g_envp && envp != nullptr); out_str("\n");
    return env_int("DUOP_TEST_PKG_RC=");
}

int input_probe_eof(void)
{
    int e = env_int("DUOP_TEST_EOF=");
    out_str("input_probe_eof -> "); out_num(e); out_str("\n");
    return e;
}

void signals_install(void) { out_str("signals_install\n"); }
int term_enter_raw(void) { out_str("term_enter_raw\n"); return 0; }
void term_exit_raw(void) { out_str("term_exit_raw\n"); }

App *App_new(const char *left, const char *right, char **envp, int lang_override)
{
    out_str("App_new l="); out_str(left ? left : "null");
    out_str(" r="); out_str(right ? right : "null");
    out_str(" env="); out_num(envp == g_envp && envp != nullptr);
    out_str(" lang="); out_num(lang_override); out_str("\n");
    if (env_int("DUOP_TEST_OOM=")) return nullptr;
    return &g_app_dummy;
}

void App_run(App *app)
{
    out_str("App_run "); out_num(app == &g_app_dummy); out_str("\n");
}

void App_write_choosedir(App *app, const char *path)
{
    out_str("App_write_choosedir "); out_num(app == &g_app_dummy);
    out_str(" p="); out_str(path ? path : "null"); out_str("\n");
}

void Object_free(Object *obj)
{
    out_str("Object_free "); out_num(obj == (Object *)&g_app_dummy); out_str("\n");
}
