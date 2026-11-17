/* Freestanding harness for oop_rt.c, hash_file.c and tmpfile.c. argv[1] selects the scenario; output is "key=value" lines. */
#include "duop_hash.h"
#include "duop_config.h"
#include "duop_oop.h"
#include "duop_pal.h"
#include "duop_string.h"

int tmp_ensure_dir(char *out_dir, int cap);
intptr_t tmp_open_unique(const char *prefix, const char *suffix, char *out_path, int cap);
int tmp_make_path(const char *prefix, const char *suffix, char *out_path, int cap);
intptr_t tmp_open_atomic(const char *final_path, char *tmp_buf, int mode);
intptr_t tmp_commit_atomic(int fd, const char *tmp_buf, const char *final_path, int64_t write_rc);

static void line(const char *k, const char *v)
{
    char b[600];
    size_t n = 0;
    while (*k) b[n++] = *k++;
    b[n++] = '=';
    while (*v && n < 590) b[n++] = *v++;
    b[n++] = '\n';
    (void)os_write(1, b, n);
}
static void num(const char *k, int64_t v)
{
    char t[24];
    size_t n = 0;
    if (v < 0) t[n++] = '-';
    u64_to_dec(v < 0 ? (uint64_t)-v : (uint64_t)v, t + n);
    line(k, t);
}

static int dtor_calls;
static void counting_dtor(Object *o) { (void)o; dtor_calls++; }
static const WidgetVtbl k_child = {
    {&Widget_vtbl.base, "Child", sizeof(Widget), counting_dtor},
    Widget_layout, Widget_render, Widget_on_key, Widget_on_mouse, Widget_on_focus, Widget_hit_test,
};

static void scenario_oop(void)
{
    Widget *w = Object_alloc(&k_child.base, sizeof(Widget));
    num("alloc_ok", w != nullptr);
    Widget_init(w, w, 7);
    num("flags_after_init", w->flags);
    Widget_layout(w, 2, 3, 10, 4);
    num("layout_dirty", (w->flags & WF_DIRTY) != 0);
    w->flags &= ~WF_DIRTY;
    Widget_on_focus(w, 1);
    num("focused", (w->flags & WF_FOCUSED) != 0);
    Widget_on_focus(w, 0);
    num("blurred", (w->flags & WF_FOCUSED) == 0 && (w->flags & WF_DIRTY));
    num("hit_in", Widget_hit_test(w, 2, 3) == 1 && Widget_hit_test(w, 11, 6) == 1);
    num("hit_out", Widget_hit_test(w, 1, 3) == 0 && Widget_hit_test(w, 12, 3) == 0 && Widget_hit_test(w, 5, 7) == 0);
    w->flags &= ~WF_VISIBLE;
    num("hit_hidden", Widget_hit_test(w, 3, 4) == 0);
    line("class", Object_get_class_name(&w->base));
    num("is_widget", Object_is_instance(&w->base, &Widget_vtbl.base));
    num("is_object", Object_is_instance(&w->base, &Object_vtbl));
    num("is_child", Object_is_instance(&w->base, &k_child.base));
    num("not_other", Object_is_instance(&w->base, &(ObjectVtbl){0}) == 0 && Object_is_instance(nullptr, &Object_vtbl) == 0);
    num("null_name", Object_get_class_name(nullptr) == nullptr);
    Object_free(&w->base);
    Object_free(nullptr);
    num("dtor_calls", dtor_calls);
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    const char *cmd = argv[1];
    if (cmd[0] == 'o') { scenario_oop(); return 0; }
    if (cmd[0] == 'h') {                                            /* hash <path> */
        uint32_t crc = 0;
        char hex[65] = "";
        intptr_t rc = hash_file(argv[2], &crc, hex);
        num("rc", rc);
        if (rc == 0) {
            char c[9];
            for (int i = 0; i < 8; i++) c[i] = "0123456789abcdef"[(crc >> (28 - 4 * i)) & 15];
            c[8] = 0;
            line("crc", c);
            line("sha", hex);
        }
        return 0;
    }
    if (cmd[0] == 'a') {                                            /* atomic <final> <text> <write_rc> */
        char tmp[PATH_MAX];
        intptr_t fd = tmp_open_atomic(argv[2], tmp, 0640);
        num("open_rc_ok", fd >= 0);
        if (fd < 0) { num("open_rc", fd); return 0; }
        line("tmp", tmp);
        int64_t wrc = argv[4][0] == '-' ? -5 : (int64_t)os_write((int)fd, argv[3], str_len(argv[3]));
        num("commit_rc", tmp_commit_atomic((int)fd, tmp, argv[2], wrc));
        return 0;
    }
    if (cmd[0] == 't') {                                            /* tmp <prefix> <suffix> */
        char dir[128], path[256];
        num("dir_rc", tmp_ensure_dir(dir, sizeof dir));
        line("dir", dir);
        intptr_t fd = tmp_open_unique(argv[2], argv[3], path, sizeof path);
        num("open_ok", fd >= 0);
        line("path", path);
        num("write", os_write((int)fd, "x", 1));
        char p2[256];
        num("make_path", tmp_make_path(argv[2], argv[3], p2, sizeof p2));
        line("path2", p2);
        char small[40];
        num("small_cap", tmp_open_unique(argv[2], argv[3], small, sizeof small));
    }
    return 0;
}
