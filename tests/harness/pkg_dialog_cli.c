/* Freestanding differential harness for src/ui/pkg_dialog.c versus frozen x86_64 asm
 * (tests/harness/pkg_dialog_reference.s, ref_ prefix). argv[1] = ref | c | fix | oom. */
#include "duop_app.h"
#include "duop_classes.h"
#include "duop_keys.h"
#include "duop_pkg.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "ui_app_stub.h"
#include "ui_event.h"

static App g_app;
static int g_fail_alloc;
static int g_inst_count = 2;
static int g_avail_count = 2;
static int g_action_ok = 0;
static int g_verify_rc = 0;
static int g_remove_rc = 0;
static int g_install_rc = 0;
static int g_regfind_rc = 0;
static int g_upgrade_rc = 0;
static int g_update_rc = 0;
static int g_poison_on_close = 0;
static void *g_cur_dlg = nullptr;

void App_close_dialog(App *app, int result)
{
    ui_log_call2("App_close_dialog", app == &g_app, result);
    if (g_poison_on_close && g_cur_dlg) {
        ((Dialog *)g_cur_dlg)->app = 0; /* simulates freed/zeroed Dialog */
    }
}

void App_run_pkg_action(App *app, PkgAction *action)
{
    sc_put("call App_run_pkg_action "); sc_num(app == &g_app);
    sc_put(" name="); sc_esc(action->name); sc_put(" exec="); sc_esc(action->exec); sc_put("\n");
}

void App_set_status(App *app, const char *msg, int kind)
{
    sc_put("call App_set_status "); sc_num(app == &g_app);
    sc_put(" k="); sc_num(kind); sc_put(" |"); sc_esc(msg ? msg : ""); sc_put("|\n");
}

int pkg_list(char **envp, PkgEntry *out, int max)
{
    (void)envp;
    int n = g_inst_count < max ? g_inst_count : max;
    for (int i = 0; i < n; i++) {
        mem_zero(&out[i], sizeof out[i]);
        (void)str_copy(out[i].name, i == 0 ? "alpha-pkg" : "beta-pkg", sizeof out[i].name);
        (void)str_copy(out[i].version, i == 0 ? "1.2.3" : "2.0.0", sizeof out[i].version);
        (void)str_copy(out[i].kind, i == 0 ? "tool" : "theme", sizeof out[i].kind);
        (void)str_copy(out[i].desc, i == 0 ? "Alpha helper" : "Beta colors", sizeof out[i].desc);
    }
    return n;
}

int pkg_registry_list(char **envp, PkgRegEntry *out, int max)
{
    (void)envp;
    int n = g_avail_count < max ? g_avail_count : max;
    for (int i = 0; i < n; i++) {
        mem_zero(&out[i], sizeof out[i]);
        (void)str_copy(out[i].name, i == 0 ? "gamma-vfs" : "delta-ext", sizeof out[i].name);
        (void)str_copy(out[i].version, i == 0 ? "0.9.1" : "3.1.4", sizeof out[i].version);
        (void)str_copy(out[i].kind, i == 0 ? "vfs" : "action", sizeof out[i].kind);
        (void)str_copy(out[i].sha256, "deadbeef", sizeof out[i].sha256);
        (void)str_copy(out[i].url, "https://example.invalid/p.tgz", sizeof out[i].url);
        (void)str_copy(out[i].desc, i == 0 ? "Gamma provider" : "Delta ext", sizeof out[i].desc);
    }
    return n;
}

int pkg_registry_find(char **envp, const char *name, PkgRegEntry *out)
{
    (void)envp;
    sc_put("call pkg_registry_find "); sc_esc(name); sc_put("\n");
    if (g_regfind_rc != 0) return -1;
    mem_zero(out, sizeof *out);
    (void)str_copy(out->name, name, sizeof out->name);
    (void)str_copy(out->sha256, "sha_abc", sizeof out->sha256);
    (void)str_copy(out->url, "https://example.invalid/pkg.tgz", sizeof out->url);
    return 0;
}

int pkg_install_archive(char **envp, const char *path_or_url, const char *expected_sha256)
{
    (void)envp;
    sc_put("call pkg_install_archive "); sc_esc(path_or_url ? path_or_url : "");
    sc_put(" sha="); sc_esc(expected_sha256 ? expected_sha256 : "NULL"); sc_put("\n");
    return g_install_rc;
}

int pkg_action_find(char **envp, const char *name, PkgAction *out)
{
    (void)envp;
    sc_put("call pkg_action_find "); sc_esc(name); sc_put("\n");
    if (!g_action_ok) return -1;
    mem_zero(out, sizeof *out);
    (void)str_copy(out->name, name, sizeof out->name);
    (void)str_copy(out->exec, "run.sh", sizeof out->exec);
    return 0;
}

int pkg_registry_upgrade(char **envp) { (void)envp; sc_put("call pkg_registry_upgrade\n"); return g_upgrade_rc; }
int pkg_registry_update(char **envp) { (void)envp; sc_put("call pkg_registry_update\n"); return g_update_rc; }

int pkg_remove(char **envp, const char *name)
{
    (void)envp;
    sc_put("call pkg_remove "); sc_esc(name); sc_put("\n");
    if (g_remove_rc == 0 && g_inst_count > 0) g_inst_count--;
    return g_remove_rc;
}

int pkg_verify(char **envp, const char *name)
{
    (void)envp;
    sc_put("call pkg_verify "); sc_esc(name); sc_put("\n");
    return g_verify_rc;
}

void *fake_mem_alloc(uint64_t size);
void *fake_mem_alloc(uint64_t size)
{
    if (g_fail_alloc > 0 && --g_fail_alloc == 0) return nullptr;
    return mem_alloc(size);
}

void *fake_object_alloc(const ObjectVtbl *vtbl, size_t size);
void *fake_object_alloc(const ObjectVtbl *vtbl, size_t size)
{
    if (g_fail_alloc > 0 && --g_fail_alloc == 0) return nullptr;
    return Object_alloc(vtbl, size);
}

#define mem_alloc fake_mem_alloc
#define Object_alloc fake_object_alloc
#include PKD_SRC
#undef Object_alloc
#undef mem_alloc

#ifdef __x86_64__
extern const DialogVtbl ref_PkgDialog_vtbl;
extern PkgDialog *ref_PkgDialog_new(App *app);
extern int ref_App_cmd_packages(App *app);
extern void ref_App_pkg_install_confirm(App *app, InputDialog *dlg);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#define PKD_VTBL (g_ref ? &ref_PkgDialog_vtbl : &PkgDialog_vtbl)
#else
#define CALL(f, ...) f(__VA_ARGS__)
#define PKD_VTBL (&PkgDialog_vtbl)
#endif

static bool g_ref;

static void dump_state(const char *tag, const PkgDialog *d)
{
    const Dialog *b = &d->base;
    sc_put(tag);
    sc_put(" rect="); sc_num(b->base.x); sc_put(","); sc_num(b->base.y);
    sc_put(","); sc_num(b->base.w); sc_put(","); sc_num(b->base.h);
    sc_put(" tab="); sc_num(d->tab);
    sc_put(" cnt="); sc_num(d->count);
    sc_put(" cur="); sc_num(d->cursor);
    sc_put(" sc="); sc_num(d->scroll);
    sc_put(" rd="); sc_num(g_app.need_redraw);
    sc_put("\n");
}

static int run_fix_tests(void)
{
    const Theme *theme = ui_theme();
    ScreenBuffer *scr = ScreenBuffer_new(90, 26);
    if (!scr) return 3;
    ui_app_reset(&g_app);
    g_app.term_w = 90; g_app.term_h = 26;
    g_app.theme = (uintptr_t)theme;
    g_inst_count = 2; g_avail_count = 2; g_action_ok = 1;

    PkgDialog *d = PkgDialog_new(&g_app);
    if (!d) return 4;
    g_cur_dlg = d;
    ScreenBuffer_clear(scr, 0x01010101, 0x01020202);
    WIDGET_CALL(&d->base.base, render, scr, (void *)theme);
    ui_dump(scr, d->base.base.y, d->base.base.h);

    /* Move cursor down and re-render to verify row 1 selected fill */
    Event ev = ui_evt_key(KEY_DOWN, 0, KEY_DOWN);
    (void)WIDGET_CALL(&d->base.base, on_key, &ev);
    ScreenBuffer_clear(scr, 0x01010101, 0x01020202);
    WIDGET_CALL(&d->base.base, render, scr, (void *)theme);
    ui_dump(scr, d->base.base.y, d->base.base.h);

    /* Fix 2: Enter on installed pkg with action closes dialog & must NOT UAF d->base.app */
    g_poison_on_close = 1;
    ev = ui_evt_key(KEY_ENTER, 0, KEY_ENTER);
    int rc = WIDGET_CALL(&d->base.base, on_key, &ev);
    g_poison_on_close = 0;
    sc_put("FIX_UAF rc="); sc_num(rc); sc_put(" app_poisoned="); sc_num(d->base.app == 0); sc_put("\n");
    DUOP_DELETE(d);
    sc_flush();
    return 0;
}

static int run_oom_tests(void)
{
    ui_app_reset(&g_app);
    g_app.term_w = 80; g_app.term_h = 24;
    g_fail_alloc = 1;
    PkgDialog *d1 = PkgDialog_new(&g_app);
    g_fail_alloc = 0;
    sc_put("OOM1 ok="); sc_num(d1 == nullptr); sc_put("\n");

    g_fail_alloc = 2; /* Object_alloc succeeds, entries mem_alloc fails */
    PkgDialog *d2 = PkgDialog_new(&g_app);
    g_fail_alloc = 0;
    int ok2 = (d2 != nullptr && d2->entries == nullptr && d2->count == 0);
    if (d2) {
        Event ev = ui_evt_key(KEY_TAB, 0, KEY_TAB);
        (void)WIDGET_CALL(&d2->base.base, on_key, &ev);
        ok2 = ok2 && d2->count == 0;
        DUOP_DELETE(d2);
    }
    sc_put("OOM2 ok="); sc_num(ok2); sc_put("\n");
    sc_flush();
    return (d1 == nullptr && ok2) ? 0 : 1;
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    if (argv[1][0] == 'o') return run_oom_tests();
    if (argv[1][0] == 'f') return run_fix_tests();

    g_ref = argv[1][0] == 'r';
    const Theme *theme = ui_theme();
    ScreenBuffer *scr = ScreenBuffer_new(90, 26);
    if (!scr) return 3;

    ui_app_reset(&g_app);
    g_app.theme = (uintptr_t)theme;
    PkgDialog *d = nullptr;

    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        const char *a = line + (line[0] ? 1 : 0);
        Event evt;
        switch (line[0]) {
        case 'F': {
            g_inst_count = (int)ui_parse_num(&a);
            g_avail_count = (int)ui_parse_num(&a);
            g_action_ok = (int)ui_parse_num(&a);
            g_verify_rc = (int)ui_parse_num(&a);
            g_remove_rc = (int)ui_parse_num(&a);
            g_install_rc = (int)ui_parse_num(&a);
            g_regfind_rc = (int)ui_parse_num(&a);
            g_upgrade_rc = (int)ui_parse_num(&a);
            g_update_rc = (int)ui_parse_num(&a);
            break;
        }
        case 'N': {
            if (d) { DUOP_DELETE(d); d = nullptr; }
            g_app.term_w = (uint32_t)ui_parse_num(&a);
            g_app.term_h = (uint32_t)ui_parse_num(&a);
            g_app.need_redraw = 0;
            d = CALL(PkgDialog_new, &g_app);
            sc_put("N ok="); sc_num(d != nullptr);
            if (d) {
                sc_put(" is_pkd="); sc_num(Object_is_instance((const Object *)d, (const ObjectVtbl *)PKD_VTBL));
                sc_put(" is_d="); sc_num(DUOP_IS_INSTANCE(d, Dialog_vtbl));
            }
            sc_put("\n");
            if (d) dump_state("N", d);
            break;
        }
        case 'A': {
            g_app.active_dialog = 0; g_app.need_redraw = 0;
            int rc = CALL(App_cmd_packages, &g_app);
            sc_put("A rc="); sc_num(rc); sc_put(" ad="); sc_num(g_app.active_dialog != 0);
            sc_put(" rd="); sc_num(g_app.need_redraw); sc_put("\n");
            if (g_app.active_dialog) {
                DUOP_DELETE((Object *)(uintptr_t)g_app.active_dialog);
                g_app.active_dialog = 0;
            }
            break;
        }
        case 'I': {
            while (*a == ' ') a++;
            InputDialog *id = InputDialog_new(&g_app, "T", "P", a, 25);
            if (id) {
                CALL(App_pkg_install_confirm, &g_app, id);
                DUOP_DELETE(id);
            }
            break;
        }
        case 'L': {
            if (!d) break;
            int x = (int)ui_parse_num(&a), y = (int)ui_parse_num(&a);
            int w = (int)ui_parse_num(&a), h = (int)ui_parse_num(&a);
            WIDGET_CALL(&d->base.base, layout, x, y, w, h);
            dump_state("L", d);
            break;
        }
        case 'R': {
            if (!d) break;
            ScreenBuffer_clear(scr, 0x01010101, 0x01020202);
            WIDGET_CALL(&d->base.base, render, scr, (void *)theme);
            dump_state("R", d);
            ui_dump(scr, d->base.base.y, d->base.base.h);
            break;
        }
        case 'K': {
            if (!d) break;
            if (ui_parse_event(line, &evt)) {
                g_app.need_redraw = 0; g_app.active_dialog = 0;
                int rc = WIDGET_CALL(&d->base.base, on_key, &evt);
                sc_put("K rc="); sc_num(rc); sc_put(" ad="); sc_num(g_app.active_dialog != 0); sc_put(" ");
                dump_state("K", d);
                if (g_app.active_dialog) {
                    DUOP_DELETE((Object *)(uintptr_t)g_app.active_dialog);
                    g_app.active_dialog = 0;
                }
            }
            break;
        }
        case 'M': {
            if (!d) break;
            if (ui_parse_event(line, &evt)) {
                g_app.need_redraw = 0;
                int rc = WIDGET_CALL(&d->base.base, on_mouse, &evt);
                sc_put("M rc="); sc_num(rc); sc_put(" ");
                dump_state("M", d);
            }
            break;
        }
        default: continue;
        }
        sc_flush();
    }
    if (d) DUOP_DELETE(d);
    sc_flush();
    return 0;
}
