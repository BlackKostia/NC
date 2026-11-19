/* Freestanding differential harness for src/ui/progress_dialog.c versus frozen x86_64 asm
 * (tests/harness/progress_dialog{,_render,_input}_reference.s, ref_ prefix). argv[1] = ref | c | oom. */
#include "duop_app.h"
#include "duop_classes.h"
#include "duop_keys.h"
#include "duop_string.h"
#include "duop_task.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "ui_app_stub.h"
#include "ui_event.h"

static App g_app;
static int g_fail_alloc;

void App_close_dialog(App *app, int result) { ui_log_call2("App_close_dialog", app == &g_app, result); }
void App_task_hide(App *app) { ui_log_call2("App_task_hide", app == &g_app, 0); }
void App_task_toggle_pause(App *app) { ui_log_call2("App_task_toggle_pause", app == &g_app, 0); }
void App_task_cancel(App *app) { ui_log_call2("App_task_cancel", app == &g_app, 0); }

void *fake_object_alloc(const ObjectVtbl *vtbl, size_t size);
void *fake_object_alloc(const ObjectVtbl *vtbl, size_t size)
{
    if (g_fail_alloc > 0 && --g_fail_alloc == 0) return nullptr;
    return Object_alloc(vtbl, size);
}

#define Object_alloc fake_object_alloc
#include PD_SRC
#undef Object_alloc

#ifdef __x86_64__
extern const DialogVtbl ref_ProgressDialog_vtbl;
extern ProgressDialog *ref_ProgressDialog_new(App *app);
extern const char *ref_ProgressDialog_title_for(int op);
extern void ref_ProgressDialog_format_summary(const void *snap, char *buf);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#define PD_VTBL (g_ref ? &ref_ProgressDialog_vtbl : &ProgressDialog_vtbl)
#else
#define CALL(f, ...) f(__VA_ARGS__)
#define PD_VTBL (&ProgressDialog_vtbl)
#endif

static bool g_ref;

static void dump_state(const char *tag, const ProgressDialog *d)
{
    const Dialog *b = &d->base;
    const HitZone *z = (const HitZone *)(const void *)b->btns;
    sc_put(tag);
    sc_put(" rect="); sc_num(b->base.x); sc_put(","); sc_num(b->base.y);
    sc_put(","); sc_num(b->base.w); sc_put(","); sc_num(b->base.h);
    sc_put(" fb="); sc_num((int32_t)b->focus_btn);
    sc_put(" hb="); sc_num((int32_t)b->hovered_btn);
    sc_put(" bc="); sc_num(b->btn_count);
    sc_put(" rd="); sc_num(g_app.need_redraw);
    for (uint32_t i = 0; i < b->btn_count && i < 3; i++) {
        sc_put(" z"); sc_num(i); sc_put("=["); sc_num((int16_t)z[i].x1);
        sc_put(".."); sc_num((int16_t)z[i].x2); sc_put("@"); sc_num((int16_t)z[i].y);
        sc_put("#"); sc_num((int16_t)z[i].id); sc_put("]");
    }
    sc_put("\n");
}

static void parse_snap(TaskSnap *s, const char *p)
{
    mem_zero(s, sizeof *s);
    s->op = (uint32_t)ui_parse_num(&p);
    s->phase = (uint32_t)ui_parse_num(&p);
    s->paused = (uint32_t)ui_parse_num(&p);
    s->canceling = (uint32_t)ui_parse_num(&p);
    s->percent = (uint32_t)ui_parse_num(&p);
    s->done_bytes = (uint64_t)ui_parse_num(&p);
    s->total_bytes = (uint64_t)ui_parse_num(&p);
    s->done_files = (uint64_t)ui_parse_num(&p);
    s->total_files = (uint64_t)ui_parse_num(&p);
    s->speed_bps = (uint64_t)ui_parse_num(&p);
    s->eta_sec = (uint64_t)ui_parse_num(&p);
    while (*p == ' ') p++;
    (void)str_copy(s->cur_name, p, sizeof s->cur_name);
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    if (argv[1][0] == 'o') {
        ui_app_reset(&g_app);
        g_app.term_w = 80;
        g_app.term_h = 24;
        g_fail_alloc = 1;
        ProgressDialog *d = ProgressDialog_new(&g_app);
        sc_put("OOM ok="); sc_num(d == nullptr); sc_put("\n");
        sc_flush();
        return d == nullptr ? 0 : 1;
    }
    g_ref = argv[1][0] == 'r';
    const Theme *theme = ui_theme();
    ScreenBuffer *scr = ScreenBuffer_new(100, 30);
    if (!scr) return 3;

    ui_app_reset(&g_app);
    g_app.theme = (uintptr_t)theme;
    ProgressDialog *d = nullptr;

    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        const char *a = line + (line[0] ? 1 : 0);
        Event evt;
        switch (line[0]) {
        case 'N': {
            if (d) { DUOP_DELETE(d); d = nullptr; }
            g_app.term_w = (uint32_t)ui_parse_num(&a);
            g_app.term_h = (uint32_t)ui_parse_num(&a);
            g_app.need_redraw = 0;
            d = CALL(ProgressDialog_new, &g_app);
            sc_put("N ok="); sc_num(d != nullptr);
            if (d) {
                sc_put(" is_pd="); sc_num(Object_is_instance((const Object *)d, (const ObjectVtbl *)PD_VTBL));
                sc_put(" is_d="); sc_num(DUOP_IS_INSTANCE(d, Dialog_vtbl));
                sc_put(" tag="); sc_num(d->base.op_tag);
                sc_put(" fb="); sc_num((int32_t)d->base.focus_btn);
            }
            sc_put("\n");
            if (d) dump_state("N", d);
            break;
        }
        case 'T': {
            int op = (int)ui_parse_num(&a);
            sc_put("T "); sc_num(op); sc_put(" |"); sc_esc(CALL(ProgressDialog_title_for, op)); sc_put("|\n");
            break;
        }
        case 'S': {
            TaskSnap *s = (TaskSnap *)(void *)g_app.task_snap;
            parse_snap(s, a);
            char buf[256];
            CALL(ProgressDialog_format_summary, s, buf);
            sc_put("S |"); sc_esc(buf); sc_put("|\n");
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
                g_app.need_redraw = 0;
                int rc = WIDGET_CALL(&d->base.base, on_key, &evt);
                sc_put("K rc="); sc_num(rc); sc_put(" ");
                dump_state("K", d);
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
        case 'C': {
            if (!d) break;
            int which = (int)ui_parse_num(&a);
            if (which == 0) DIALOG_CALL(&d->base, on_confirm);
            else DIALOG_CALL(&d->base, on_cancel);
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
