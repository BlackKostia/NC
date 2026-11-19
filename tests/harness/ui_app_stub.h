/* tests/harness/ui_app_stub.h - shared zeroed App, mutable English i18n_get(), optional DirModel loader and call logger
 * for UI differential harnesses (plan stage U0b, header-only, freestanding). */
#pragma once
#include "duop_classes.h"
#include "i18n_slots.h"
#include "ui_render.h"

/* Mutable copy of lang_en_table so tests can swap individual LangStrings slots (e.g. long/wide labels) without rebuilding. */
static LangStrings g_ui_ls;
const LangStrings *i18n_get(void);
const LangStrings *i18n_get(void)
{
    if (!g_ui_ls.s[0]) g_ui_ls = lang_en_table;
    return &g_ui_ls;
}

static inline LangStrings *ui_i18n_mut(void)
{
    (void)i18n_get();
    return &g_ui_ls;
}

static inline void ui_app_reset(App *app)
{
    mem_zero(app, sizeof *app);
}

/* Recording helper for stubbed App_* / sibling calls in differential harnesses */
static inline void ui_log_call2(const char *name, int64_t a, int64_t b)
{
    sc_put("call "); sc_put(name); sc_put(" "); sc_num(a); sc_put(" "); sc_num(b); sc_put("\n");
}

static inline void ui_log_call_bytes(const char *name, int64_t fd, const void *buf, size_t len)
{
    const char *p = buf;
    sc_put("call "); sc_put(name); sc_put(" fd="); sc_num(fd); sc_put(" n="); sc_num((int64_t)len); sc_put(" |");
    for (size_t i = 0; i < len; i++) {
        char c[2] = {p[i], 0};
        if (p[i]) sc_esc(c); else sc_put("\\x00");
    }
    sc_put("|\n");
}

#ifdef UI_STUB_DIRMODEL
#include "duop_fs.h"
static inline DirModel *ui_load_dir(const char *path)
{
    DirModel *m = DirModel_new(path);
    while (m && m->is_loading) (void)DirModel_step_load(m, 0);
    return m;
}
#endif
