/* Freestanding self-check of include/duop_ui.h: the C forms of the assembler OOP macros (VCALL, SUPER_CALL, NEW_OBJ, DELETE_OBJ,
 * IS_INSTANCE, WIDGET_VTBL_SLOTS / DIALOG_VTBL_SLOTS) and of TRY_BEGIN / TRY_END. Prints one `ok <name>` or `FAIL <name>` line per
 * check; tests/test_c_ui_oop.py runs it on x86_64 and under qemu-aarch64. The asm-only Dialog_* defaults are stubbed here. */
#include "script_cli.h"
#include "duop_ui.h"
#include "duop_pal.h"

/* a recording bump allocator instead of src/core/memory.c: the exact size DUOP_NEW asked for and the frees DUOP_DELETE performed */
static unsigned char g_heap[1 << 16] __attribute__((aligned(16)));
static size_t g_heap_used, g_last_req;
static int g_frees;
void *mem_alloc(size_t n)
{
    g_last_req = n;
    n = (n + 15) & ~(size_t)15;
    if (g_heap_used + n > sizeof g_heap) return nullptr;
    void *p = g_heap + g_heap_used;
    g_heap_used += n;
    return p;
}
void mem_free(void *p) { if (p) g_frees++; }
void *mem_realloc(void *p, size_t n) { (void)p; return mem_alloc(n); }

static int g_dtor_calls, g_confirm_calls, g_cancel_calls, g_default_confirm;

typedef struct Foo { Widget base; int counter; uint64_t big; } Foo;
typedef struct Foo2 { Foo base; int extra; } Foo2;
typedef struct Sib { Widget base; } Sib;
typedef struct Dlg { Widget base; void *app; int confirmed; } Dlg;

extern const WidgetVtbl Foo_vtbl;

static int Foo_on_key(Widget *self, void *ev) { (void)ev; ((Foo *)self)->counter++; return 42; }
static void Foo_dtor(Widget *self) { (void)self; g_dtor_calls += 1; }
static int Foo2_on_key(Widget *self, void *ev) { return DUOP_SUPER_CALL(WidgetVtbl, Widget, Foo_vtbl, self, on_key, ev) + 1; }
static void Foo2_dtor(Widget *self) { g_dtor_calls += 10; Foo_dtor(self); }

WIDGET_VTBL(Foo_vtbl, "Foo", Widget_vtbl, sizeof(Foo), .base.dtor = (void (*)(Object *))Foo_dtor, .on_key = Foo_on_key);
WIDGET_VTBL(Foo2_vtbl, "Foo2", Foo_vtbl, sizeof(Foo2), .base.dtor = (void (*)(Object *))Foo2_dtor, .on_key = Foo2_on_key);
WIDGET_VTBL(Sib_vtbl, "Sib", Widget_vtbl, sizeof(Sib));

/* stand-ins for the assembly Dialog defaults (src/ui/dialogs*.s) */
void Dialog_dtor(Widget *self) { (void)self; }
void Dialog_layout(Widget *self, int x, int y, int w, int h) { Widget_layout(self, x, y, w, h); }
void Dialog_render(Widget *self, void *screen, void *theme) { (void)self; (void)screen; (void)theme; }
int Dialog_on_key(Widget *self, void *ev) { (void)self; (void)ev; return 7; }
int Dialog_on_mouse(Widget *self, void *ev) { (void)self; (void)ev; return 8; }
void Dialog_on_confirm(Dialog *self) { (void)self; g_default_confirm++; }
void Dialog_on_cancel(Dialog *self) { (void)self; g_cancel_calls++; }

static void Dlg_on_confirm(Dialog *self) { (void)self; g_confirm_calls++; }
DIALOG_VTBL(Dialog_vtbl, "Dialog", Widget_vtbl, sizeof(Widget));
DIALOG_VTBL(Dlg_vtbl, "Dlg", Dialog_vtbl, sizeof(Dlg), .on_confirm = Dlg_on_confirm);

static int g_fail;
static void check(const char *name, int cond)
{
    sc_put(cond ? "ok " : "FAIL ");
    sc_put(name);
    sc_put("\n");
    g_fail += !cond;
}

static void check_objects(void)
{
    Foo *f = DUOP_NEW(Foo, Foo_vtbl);
    check("new_alloc", f != nullptr);
    if (!f) return;
    check("new_size", g_last_req == sizeof(Foo) && Foo_vtbl.base.inst_size == sizeof(Foo));
    check("new_vptr", (const void *)f->base.base.vptr == (const void *)&Foo_vtbl);
    check("new_zeroed", f->counter == 0 && f->big == 0 && f->base.x == 0 && f->base.flags == 0);
    check("class_name", Object_get_class_name((Object *)f)[0] == 'F' && Object_get_class_name((Object *)f)[2] == 'o');
    check("slot_override", WIDGET_CALL(f, on_key, nullptr) == 42 && f->counter == 1);
    check("slot_default_mouse", WIDGET_CALL(f, on_mouse, nullptr) == 0);
    WIDGET_CALL(f, layout, 1, 2, 30, 4);
    check("slot_default_layout", f->base.x == 1 && f->base.y == 2 && f->base.w == 30 && f->base.h == 4 && (f->base.flags & WF_DIRTY));
    check("hit_test_default", (f->base.flags |= WF_VISIBLE, WIDGET_CALL(f, hit_test, 5, 3)) == 1 && WIDGET_CALL(f, hit_test, 40, 3) == 0);
    DUOP_DELETE(f);
    check("dtor_once", g_dtor_calls == 1 && g_frees == 1);
    DUOP_DELETE((Foo *)nullptr);
    check("delete_null", g_dtor_calls == 1 && g_frees == 1);
}

static void check_inheritance(void)
{
    Foo2 *c = DUOP_NEW(Foo2, Foo2_vtbl);
    Sib *s = DUOP_NEW(Sib, Sib_vtbl);
    if (!c || !s) { check("alloc_inheritance", 0); return; }
    check("inst_sizes", Foo2_vtbl.base.inst_size == sizeof(Foo2) && Sib_vtbl.base.inst_size == sizeof(Sib) && Dlg_vtbl.base.base.inst_size == sizeof(Dlg));
    check("super_call", WIDGET_CALL(c, on_key, nullptr) == 43 && c->base.counter == 1);
    check("is_self", DUOP_IS_INSTANCE(c, Foo2_vtbl));
    check("is_parent", DUOP_IS_INSTANCE(c, Foo_vtbl));
    check("is_widget", DUOP_IS_INSTANCE(c, Widget_vtbl));
    check("is_object", DUOP_IS_INSTANCE(c, Object_vtbl));
    Foo *plain = DUOP_NEW(Foo, Foo_vtbl);
    check("not_child", plain && !DUOP_IS_INSTANCE(plain, Foo2_vtbl) && DUOP_IS_INSTANCE(plain, Foo_vtbl));
    check("not_sibling", !DUOP_IS_INSTANCE(s, Foo_vtbl));
    check("null_not_instance", !DUOP_IS_INSTANCE((Foo *)nullptr, Object_vtbl));
    g_dtor_calls = 0;
    DUOP_DELETE(c);
    check("dtor_chain", g_dtor_calls == 11);
    DUOP_DELETE(s);
    DUOP_DELETE(plain);
}

static void check_dialog(void)
{
    Dlg *d = DUOP_NEW(Dlg, Dlg_vtbl);
    if (!d) { check("alloc_dialog", 0); return; }
    DIALOG_CALL(d, on_confirm);
    DIALOG_CALL(d, on_cancel);
    check("dialog_override", g_confirm_calls == 1 && g_default_confirm == 0);
    check("dialog_default", g_cancel_calls == 1);
    check("dialog_widget_slots", WIDGET_CALL(d, on_key, nullptr) == 7 && WIDGET_CALL(d, on_mouse, nullptr) == 8);
    check("dialog_is_widget", DUOP_IS_INSTANCE(d, Widget_vtbl) && DUOP_IS_INSTANCE(d, Dialog_vtbl));
    DUOP_DELETE(d);
}

static void check_try(void)
{
    volatile int phase = 0;
    DUOP_TRY_BEGIN(f1, sig1) { phase = 1; DUOP_TRY_END(f1); }
    check("try_clean", sig1 == 0 && phase == 1);
    volatile int after = 0;
    DUOP_TRY_BEGIN(f2, sig2) {
        (void)os_tgkill((int)os_getpid(), (int)os_gettid(), 11);
        after = 1;
        DUOP_TRY_END(f2);
    }
    check("try_fault", sig2 == 11 && after == 0);
    DUOP_TRY_BEGIN(f3, sig3) { phase = 3; DUOP_TRY_END(f3); }
    check("try_after_fault", sig3 == 0 && phase == 3);
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)argc; (void)argv; (void)envp; (void)auxv;
    os_fault_guard_install();                       /* what the application does at start-up (src/core/syscall.c) */
    check_objects();
    check_inheritance();
    check_dialog();
    check_try();
    sc_put(g_fail ? "RESULT FAIL\n" : "RESULT OK\n");
    sc_flush();
    return g_fail ? 1 : 0;
}
