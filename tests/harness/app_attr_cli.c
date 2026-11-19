/* tests/harness/app_attr_cli.c - A2.3 differential harness for src/app/app_attr.c. */
#include "duop_app.h"
#include "duop_app_int.h"
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_oop.h"
#include "duop_pal.h"
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
static FilePane g_lp, g_rp;
static DirModel g_lm, g_rm;
static FileEntry g_fe;
static int g_has_fe;
static char g_fe_name[128];
static int g_dlg_oom;
static int g_trash_rc;
static int g_undo_rc;

const LangStrings *i18n_get(void) { return &lang_en_table; }

FilePane *get_inactive_pane(App *app)
{
    return (FilePane *)(uintptr_t)app->active_pane == &g_lp ? &g_rp : &g_lp;
}

const char *fs_errno_message(int neg_errno)
{
    if (neg_errno == -ENOENT) return "E_NOENT";
    if (neg_errno == -EINVAL) return "E_INVAL";
    if (neg_errno == -EOPNOTSUPP) return "E_OPNOTSUPP";
    if (neg_errno == -EEXIST) return "E_EXIST";
    if (neg_errno == -EPERM) return "E_PERM";
    if (neg_errno == -ENOMEM) return "E_NOMEM";
    return "E_OTHER";
}

void App_set_status(App *app, const char *msg, int kind)
{
    sc_put("call App_set_status "); sc_num(app != nullptr); sc_put(" k="); sc_num(kind);
    sc_put(" m=|"); sc_put(msg ? msg : "(null)"); sc_put("|\n");
}

void App_reload_panes(App *app, const char *focus)
{
    sc_put("call App_reload_panes "); sc_num(app != nullptr); sc_put(" f="); sc_num(focus != nullptr); sc_nl();
}

void App_sync_preview(App *app) { sc_put("call App_sync_preview "); sc_num(app != nullptr); sc_nl(); }

InfoDialog *InfoDialog_new(App *app, const char *path)
{
    sc_put("call InfoDialog_new "); sc_num(app != nullptr); sc_put(" p=|"); sc_put(path); sc_put("|\n");
    return g_dlg_oom ? nullptr : (InfoDialog *)(uintptr_t)0x6001;
}

ChmodDialog *ChmodDialog_new(App *app, const char *path)
{
    sc_put("call ChmodDialog_new "); sc_num(app != nullptr); sc_put(" p=|"); sc_put(path); sc_put("|\n");
    return g_dlg_oom ? nullptr : (ChmodDialog *)(uintptr_t)0x6002;
}

InputDialog *InputDialog_new(App *app, const char *title, const char *prompt, const char *init, uint32_t tag)
{
    sc_put("call InputDialog_new "); sc_num(app != nullptr);
    sc_put(" t=|"); sc_put(title ? title : "-");
    sc_put("| p=|"); sc_put(prompt ? prompt : "-");
    sc_put("| i=|"); sc_put(init ? init : "-");
    sc_put("| tag="); sc_num(tag); sc_nl();
    return g_dlg_oom ? nullptr : (InputDialog *)(uintptr_t)(0x6000 + tag);
}

FileEntry *fake_FilePane_get_selected_entry(FilePane *fp) { (void)fp; return g_has_fe ? &g_fe : nullptr; }
const char *fake_DirModel_entry_name(const DirModel *m, const FileEntry *e) { (void)m; (void)e; return g_fe_name; }

int fake_trash_move_file(const char *src, const char *const *envp, char *out_t, char *out_i)
{
    sc_put("call trash_move_file s=|"); sc_put(src); sc_put("| env="); sc_num(envp != nullptr);
    sc_put(" rc="); sc_num(g_trash_rc); sc_nl();
    if (g_trash_rc < 0) return g_trash_rc;
    (void)str_copy(out_t, "/trash/files/f", PATH_MAX);
    (void)str_copy(out_i, "/trash/info/f.trashinfo", PATH_MAX);
    return 0;
}

void fake_undo_push(int kind, const char *orig, const char *cur, const char *info)
{
    sc_put("call undo_push k="); sc_num(kind);
    sc_put(" o=|"); sc_put(orig ? orig : "-");
    sc_put("| c=|"); sc_put(cur ? cur : "-");
    sc_put("| i=|"); sc_put(info ? info : "-"); sc_put("|\n");
}

int fake_undo_pop_and_apply(void)
{
    sc_put("call undo_pop_and_apply rc="); sc_num(g_undo_rc); sc_nl();
    return g_undo_rc;
}

#define FilePane_get_selected_entry fake_FilePane_get_selected_entry
#define DirModel_entry_name fake_DirModel_entry_name
#define trash_move_file fake_trash_move_file
#define undo_push fake_undo_push
#define undo_pop_and_apply fake_undo_pop_and_apply
#include ATTR_SRC
#undef FilePane_get_selected_entry
#undef DirModel_entry_name
#undef trash_move_file
#undef undo_push
#undef undo_pop_and_apply

#ifdef __x86_64__
void ref_App_cmd_info(App *app);
void ref_App_cmd_chmod(App *app);
void ref_App_cmd_link(App *app, int is_hard);
void ref_App_cmd_trash(App *app);
void ref_App_cmd_undo(App *app);
void ref_App_apply_chmod(App *app, ChmodDialog *dlg);
void ref_App_apply_link(App *app, InputDialog *dlg, int is_hard);
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
    mem_zero(&g_lp, sizeof g_lp);
    mem_zero(&g_rp, sizeof g_rp);
    mem_zero(&g_lm, sizeof g_lm);
    mem_zero(&g_rm, sizeof g_rm);
    mem_zero(&g_fe, sizeof g_fe);
    static char *fake_env[] = { "HOME=/tmp", nullptr };
    g_app.envp = (uint64_t)(uintptr_t)fake_env;
    g_app.left_pane = (uint64_t)(uintptr_t)&g_lp;
    g_app.right_pane = (uint64_t)(uintptr_t)&g_rp;
    g_app.active_pane = (uint64_t)(uintptr_t)&g_lp;
    g_lp.model = (uint64_t)(uintptr_t)&g_lm;
    g_rp.model = (uint64_t)(uintptr_t)&g_rm;
    (void)str_copy(g_lm.path, "/act", sizeof g_lm.path);
    (void)str_copy(g_rm.path, "/inact", sizeof g_rm.path);
    g_has_fe = 1;
    (void)str_copy(g_fe_name, "target.txt", sizeof g_fe_name);
    g_dlg_oom = 0; g_trash_rc = 0; g_undo_rc = 0;
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
        if (tag == 'I' || tag == 'M') {
            g_has_fe = (int)sc_tok_i64(&p);
            g_fe.flags = (uint32_t)sc_tok_i64(&p);
            g_dlg_oom = (int)sc_tok_i64(&p);
            if (tag == 'I') CALL(App_cmd_info, &g_app);
            else CALL(App_cmd_chmod, &g_app);
            sc_put(tag == 'I' ? "IN d=" : "CH d="); sc_num((int64_t)g_app.active_dialog);
            sc_put(" rd="); sc_num(g_app.need_redraw); sc_nl();
        } else if (tag == 'L') {
            int is_hard = (int)sc_tok_i64(&p);
            g_has_fe = (int)sc_tok_i64(&p);
            g_fe.flags = (uint32_t)sc_tok_i64(&p);
            g_dlg_oom = (int)sc_tok_i64(&p);
            CALL(App_cmd_link, &g_app, is_hard);
            sc_put("LK d="); sc_num((int64_t)g_app.active_dialog);
            sc_put(" rd="); sc_num(g_app.need_redraw); sc_nl();
        } else if (tag == 'T') {
            g_has_fe = (int)sc_tok_i64(&p);
            g_fe.flags = (uint32_t)sc_tok_i64(&p);
            g_trash_rc = (int)sc_tok_i64(&p);
            CALL(App_cmd_trash, &g_app);
        } else if (tag == 'U') {
            g_undo_rc = (int)sc_tok_i64(&p);
            CALL(App_cmd_undo, &g_app);
        } else if (tag == 'A') {
            /* A <path> <mode_oct_dec> <orig_uid> <orig_gid> <owner_str> */
            static ChmodDialog cd;
            mem_zero(&cd, sizeof cd);
            char path[256], own[32];
            sc_tok_str(&p, path, sizeof path);
            cd.mode = (uint32_t)sc_tok_i64(&p);
            cd.uid = (uint32_t)sc_tok_i64(&p);
            cd.gid = (uint32_t)sc_tok_i64(&p);
            sc_tok_str(&p, own, sizeof own);
            (void)str_copy((char *)cd.target_path, path, sizeof cd.target_path);
            if (!(own[0] == '!' && own[1] == '\0')) (void)str_copy((char *)cd.owner_buf, own, sizeof cd.owner_buf);
            CALL(App_apply_chmod, &g_app, &cd);
            FileStat st;
            if (os_statat(AT_FDCWD, path, &st, 0) == 0) {
                sc_put("AC mode="); sc_num(st.mode & 07777); sc_nl();
            }
        } else if (tag == 'K') {
            /* K <is_hard> <dir> <name> <dst_path> */
            static InputDialog idlg;
            mem_zero(&idlg, sizeof idlg);
            int is_hard = (int)sc_tok_i64(&p);
            char dir[256], dst[256];
            sc_tok_str(&p, dir, sizeof dir);
            sc_tok_str(&p, g_fe_name, sizeof g_fe_name);
            sc_tok_str(&p, dst, sizeof dst);
            (void)str_copy(g_lm.path, dir, sizeof g_lm.path);
            (void)str_copy((char *)idlg.buf, dst, sizeof idlg.buf);
            CALL(App_apply_link, &g_app, &idlg, is_hard);
            FileStat st;
            intptr_t sr = os_statat(AT_FDCWD, dst, &st, 0);
            sc_put("AK sr="); sc_num(sr == 0); sc_put(" lnk=");
            sc_num(sr == 0 && (st.mode & S_IFMT) == S_IFLNK); sc_nl();
        }
    }
    sc_flush();
    return 0;
}
