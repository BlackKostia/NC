/* tests/harness/app_close_dialog_cli.c - A2.5 differential harness for src/app/app_close_dialog.c. */
#include "duop_app.h"
#include "duop_app_int.h"
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_oop.h"
#include "duop_pal.h"
#include "duop_pkg.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "script_cli.h"

static void sc_nl(void) { sc_put("\n"); }

static int64_t sc_tok_i64(char **pp)
{
    char *p = *pp;
    while (*p == ' ') p++;
    int neg = (*p == '-');
    if (neg) p++;
    int64_t v = 0;
    while (*p >= '0' && *p <= '9') v = v * 10 + (*p++ - '0');
    *pp = p;
    return neg ? -v : v;
}

static void sc_tok_str(char **pp, char *dst, size_t cap)
{
    char *p = *pp;
    while (*p == ' ') p++;
    size_t i = 0;
    while (*p && *p != ' ') {
        if (i + 1 < cap) dst[i++] = *p;
        p++;
    }
    dst[i] = '\0';
    *pp = p;
}

static App g_app;
static FilePane g_pane;
static DirModel g_model;
static StatusBar g_sb;
static FileEntry g_fe;
static int g_has_fe;
static intptr_t g_mkdir_rc, g_touch_rc, g_ren_rc, g_chdir_rc, g_ext_rc;
static int g_vfs_rc;

const LangStrings *i18n_get(void) { return &lang_en_table; }

const char *fs_errno_message(int neg_errno)
{
    if (neg_errno == -EEXIST) return "E_EXIST";
    if (neg_errno == -ENOENT) return "E_NOENT";
    if (neg_errno == -EACCES) return "E_ACCES";
    if (neg_errno == -ENAMETOOLONG) return "E_NAMETOOLONG";
    return "E_OTHER";
}

void App_set_status(App *app, const char *msg, int kind)
{
    sc_put("call App_set_status "); sc_num(app != nullptr); sc_put(" k="); sc_num(kind);
    sc_put(" m=|"); sc_put(msg ? msg : "-"); sc_put("|\n");
}

void reload_both_panes(App *app, const char *focus)
{
    sc_put("call reload_both_panes "); sc_num(app != nullptr);
    sc_put(" f=|"); sc_put(focus ? focus : "-"); sc_put("|\n");
}

void App_sync_preview(App *app) { sc_put("call App_sync_preview "); sc_num(app != nullptr); sc_nl(); }

void App_task_start(App *app, int op, const char *dst)
{
    sc_put("call App_task_start "); sc_num(app != nullptr); sc_put(" op="); sc_num(op);
    sc_put(" dst=|"); sc_put(dst ? dst : "-"); sc_put("|\n");
}

void App_pkg_install_confirm(App *app, InputDialog *dlg)
{
    sc_put("call App_pkg_install_confirm "); sc_num(app != nullptr && dlg != nullptr); sc_nl();
}

intptr_t App_close_dialog_ext(App *app, Dialog *dlg, FilePane *pane, DirModel *model, int res)
{
    sc_put("call App_close_dialog_ext "); sc_num(app != nullptr && dlg != nullptr && pane != nullptr && model != nullptr);
    sc_put(" tag="); sc_num(dlg->op_tag); sc_put(" r="); sc_num(res); sc_nl();
    return g_ext_rc;
}

HelpDialog *HelpDialog_new(App *app)
{
    sc_put("call HelpDialog_new "); sc_num(app != nullptr); sc_nl();
    return (HelpDialog *)(uintptr_t)0x8001;
}

InputDialog *InputDialog_new(App *app, const char *t, const char *p, const char *init, uint32_t tag)
{
    sc_put("call InputDialog_new "); sc_num(app != nullptr);
    sc_put(" t=|"); sc_put(t); sc_put("| p=|"); sc_put(p);
    sc_put("| i=|"); sc_put(init ? init : "-"); sc_put("| tag="); sc_num(tag); sc_nl();
    return (InputDialog *)(uintptr_t)(0x8000 + tag);
}

FileEntry *fake_FilePane_get_selected_entry(FilePane *fp) { (void)fp; return g_has_fe ? &g_fe : nullptr; }
const char *fake_DirModel_entry_name(const DirModel *m, const FileEntry *e) { (void)m; (void)e; return "old.txt"; }
void fake_FilePane_ensure_visible(FilePane *fp) { sc_put("call FilePane_ensure_visible "); sc_num(fp != nullptr); sc_nl(); }
void fake_DirModel_apply_filter(DirModel *m) { sc_put("call DirModel_apply_filter |"); sc_put(m->filter); sc_put("|\n"); }

intptr_t fake_DirModel_chdir(DirModel *m, const char *target)
{
    (void)m;
    sc_put("call DirModel_chdir |"); sc_put(target); sc_put("| rc="); sc_num(g_chdir_rc); sc_nl();
    return g_chdir_rc;
}

int fake_pkg_vfs_load_dir(char **envp, DirModel *m, const char *uri)
{
    sc_put("call pkg_vfs_load_dir env="); sc_num(envp != nullptr); sc_put(" m="); sc_num(m != nullptr);
    sc_put(" u=|"); sc_put(uri); sc_put("| rc="); sc_num(g_vfs_rc); sc_nl();
    return g_vfs_rc;
}

intptr_t fake_fs_mkdir(const char *p) { sc_put("call fs_mkdir |"); sc_put(p); sc_put("|\n"); return g_mkdir_rc; }
intptr_t fake_fs_touch(const char *p) { sc_put("call fs_touch |"); sc_put(p); sc_put("|\n"); return g_touch_rc; }

intptr_t fake_fs_rename_noreplace(const char *o, const char *n)
{
    sc_put("call fs_rename_noreplace o=|"); sc_put(o); sc_put("| n=|"); sc_put(n); sc_put("|\n");
    return g_ren_rc;
}

void fake_undo_push(int kind, const char *o, const char *c, const char *i)
{
    sc_put("call undo_push k="); sc_num(kind); sc_put(" o=|"); sc_put(o);
    sc_put("| c=|"); sc_put(c); sc_put("| i="); sc_num(i != nullptr); sc_nl();
}

static void fake_dlg_dtor(Object *self)
{
    Dialog *d = (Dialog *)self;
    sc_put("call dlg_dtor tag="); sc_num(d->op_tag); sc_nl();
}
static const ObjectVtbl g_fake_vtbl = { .super = nullptr, .class_name = "FakeInputDlg", .inst_size = sizeof(InputDialog), .dtor = fake_dlg_dtor };

#define FilePane_get_selected_entry fake_FilePane_get_selected_entry
#define DirModel_entry_name fake_DirModel_entry_name
#define FilePane_ensure_visible fake_FilePane_ensure_visible
#define DirModel_apply_filter fake_DirModel_apply_filter
#define DirModel_chdir fake_DirModel_chdir
#define pkg_vfs_load_dir fake_pkg_vfs_load_dir
#define fs_mkdir fake_fs_mkdir
#define fs_touch fake_fs_touch
#define fs_rename_noreplace fake_fs_rename_noreplace
#define undo_push fake_undo_push
#include CD_SRC
#undef FilePane_get_selected_entry
#undef DirModel_entry_name
#undef FilePane_ensure_visible
#undef DirModel_apply_filter
#undef DirModel_chdir
#undef pkg_vfs_load_dir
#undef fs_mkdir
#undef fs_touch
#undef fs_rename_noreplace
#undef undo_push

#ifdef __x86_64__
void ref_App_close_dialog(App *app, int result);
void ref_App_cmd_help(App *app);
void ref_App_cmd_mkdir(App *app);
#endif

static int g_use_ref;
#ifdef __x86_64__
#define CALL(fn, ...) (g_use_ref ? ref_##fn(__VA_ARGS__) : fn(__VA_ARGS__))
#else
#define CALL(fn, ...) fn(__VA_ARGS__)
#endif

static void init_state(void)
{
    mem_zero(&g_app, sizeof g_app);
    mem_zero(&g_pane, sizeof g_pane);
    mem_zero(&g_model, sizeof g_model);
    mem_zero(&g_sb, sizeof g_sb);
    mem_zero(&g_fe, sizeof g_fe);
    static char *fake_env[] = { "HOME=/tmp", nullptr };
    g_app.envp = (uint64_t)(uintptr_t)fake_env;
    g_app.active_pane = (uint64_t)(uintptr_t)&g_pane;
    g_app.status_bar = (uint64_t)(uintptr_t)&g_sb;
    g_app.running = 1;
    g_pane.model = (uint64_t)(uintptr_t)&g_model;
    g_pane.cursor = 5; g_pane.scroll = 2;
    g_sb.msg_expire_ms = 9999;
    (void)str_copy(g_model.path, "/work", sizeof g_model.path);
    g_has_fe = 1;
    g_mkdir_rc = 0; g_touch_rc = 0; g_ren_rc = 0; g_chdir_rc = 0; g_ext_rc = 0; g_vfs_rc = -1;
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    g_use_ref = (argc >= 2 && argv[1][0] == 'r');
    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        char *p = line;
        char tag = *p++;
        init_state();
        if (tag == 'H') {
            CALL(App_cmd_help, &g_app);
            sc_put("HP d="); sc_num((int64_t)g_app.active_dialog); sc_put(" rd="); sc_num(g_app.need_redraw); sc_nl();
        } else if (tag == 'M') {
            CALL(App_cmd_mkdir, &g_app);
            sc_put("MK d="); sc_num((int64_t)g_app.active_dialog); sc_put(" rd="); sc_num(g_app.need_redraw); sc_nl();
        } else if (tag == 'C') {
            /* C <has_dlg> <res> <op_tag> <aux1> <aux2> <buf_or_!> */
            int has_d = (int)sc_tok_i64(&p);
            int res = (int)sc_tok_i64(&p);
            uint32_t op = (uint32_t)sc_tok_i64(&p);
            int64_t a1 = sc_tok_i64(&p), a2 = sc_tok_i64(&p);
            char buf[64]; sc_tok_str(&p, buf, sizeof buf);
            if (has_d) {
                InputDialog *d = Object_alloc(&g_fake_vtbl, sizeof(InputDialog));
                if (d) {
                    d->base.op_tag = op;
                    if (!(buf[0] == '!' && buf[1] == '\0')) (void)str_copy((char *)d->buf, buf, sizeof d->buf);
                    g_app.active_dialog = (uint64_t)(uintptr_t)d;
                }
            }
            if (op == OP_MKDIR) g_mkdir_rc = a1;
            else if (op == OP_NEWFILE) g_touch_rc = a1;
            else if (op == OP_RENAME) { g_has_fe = (int)a1; g_ren_rc = a2; }
            else if (op == OP_GOTO) { g_vfs_rc = (int)a1; g_chdir_rc = a2; }
            else g_ext_rc = a1;
            CALL(App_close_dialog, &g_app, res);
            sc_put("CD ad="); sc_num(g_app.active_dialog != 0); sc_put(" run="); sc_num(g_app.running);
            sc_put(" rd="); sc_num(g_app.need_redraw); sc_put(" cur="); sc_num(g_pane.cursor);
            sc_put(" scr="); sc_num(g_pane.scroll); sc_put(" exp="); sc_num((int64_t)g_sb.msg_expire_ms); sc_nl();
        }
    }
    sc_flush();
    return 0;
}
