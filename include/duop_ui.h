/* include/duop_ui.h - the C forms of the assembler OOP / TRY macros, for the C23 ports of src/ui and src/app
 * (include/oop.inc, classes.inc, try_using.inc; docs/HYBRID_PORTABILITY_PLAN.md phase P2).
 *
 *   asm                                  C
 *   NEW_OBJ vtbl, size                   DUOP_NEW(Type, vtbl)                   zeroed, vptr set, NULL on OOM (test it)
 *   DELETE_OBJ reg                       DUOP_DELETE(obj)                       dtor through the vtable, then mem_free; NULL-safe
 *   IS_INSTANCE reg, vtbl                DUOP_IS_INSTANCE(obj, vtbl)            1 for the class or a subclass
 *   VCALL slot                           WIDGET_CALL(obj, slot, args...)        also OBJECT_CALL, DIALOG_CALL, DUOP_VCALL
 *   SUPER_CALL parent_vtbl, slot         DUOP_SUPER_CALL(Vtbl, Self, parent_vtbl, obj, slot, args...)
 *   WIDGET_VTBL_SLOTS name, ...          WIDGET_VTBL(NAME, "Class", SUPER_VTBL, sizeof(Class), .slot = fn, ...)
 *   DIALOG_VTBL_SLOTS name, ...          DIALOG_VTBL(NAME, "Class", SUPER_VTBL, sizeof(Class), .slot = fn, ...)
 *   TRY_BEGIN / TRY_END                  DUOP_TRY_BEGIN(frame, sig) { ... DUOP_TRY_END(frame); }
 *
 * Vtables are `const` (read-only data), the first member of every vtable is its ObjectVtbl, and `Object.vptr` is at offset 0, so a
 * subclass vtable converts to `const ObjectVtbl *` with a plain cast. Widget structs come from build/duop_classes.h (tools/gen_abi.py). */
#pragma once
#include "duop_abi.h"
#include "duop_oop.h"

/* StatusBar message kinds (classes.inc MSG_*) and the message size (config.inc STATUS_MAX) */
#define MSG_INFO 0
#define MSG_OK 1
#define MSG_WARN 2
#define MSG_ERR 3
#define STATUS_MAX 512
#define INPUT_MAX 512

/* Dialog.result / App_close_dialog codes (include/config.inc) */
#define DLG_OPEN 0
#define DLG_OK 1
#define DLG_CANCEL 2

/* Right-pane mode (include/config.inc) */
#define RIGHT_MODE_PANE 0
#define RIGHT_MODE_PREVIEW 1

/* Leaf UI helpers (src/ui/) */
void osc52_copy_text(const char *str);
int term_key_encode(const void *evt, char *out);
int term_on_key(void *app, void *evt);
void term_shutdown(void);
int PreviewPane_on_mouse(Widget *self, void *evt);
void hdr_draw_mode_and_git(void *hdr, void *scr, const void *theme, const void *ls);

typedef struct FilePane FilePane;
typedef struct FilePaneCols {
    int32_t name_w;
    int32_t size_w;
    int32_t extra_w;
    int32_t extra_is_date;
} FilePaneCols;
FilePaneCols file_pane_compute_cols(int32_t w);
void FilePane_layout(Widget *self, int x, int y, int w, int h);
void FilePane_ensure_visible(FilePane *self);

typedef struct ScreenBuffer ScreenBuffer;
typedef struct Theme Theme;
typedef struct PreviewPane PreviewPane;
int syntax_detect(const char *path);
void syntax_draw_line(ScreenBuffer *scr, int x, int y, const char *line, int max_w,
                      const char *path, const Theme *theme, uint32_t bg);
int elf_preview_try_render(PreviewPane *pv, ScreenBuffer *scr, const Theme *theme);
int InputDialog_on_key(Widget *self, void *event);

typedef struct Dialog Dialog;

/* DialogVtbl (classes.inc): WidgetVtbl + the two button actions. Dialog_* defaults live in src/ui/dialogs*.s until Dialog is ported. */
typedef struct DialogVtbl {
    WidgetVtbl base;
    void (*on_confirm)(Dialog *self);
    void (*on_cancel)(Dialog *self);
} DialogVtbl;

void Dialog_dtor(Widget *self);
void Dialog_layout(Widget *self, int x, int y, int w, int h);
void Dialog_render(Widget *self, void *screen, void *theme);
int Dialog_on_key(Widget *self, void *event);
int Dialog_on_mouse(Widget *self, void *event);
void Dialog_on_confirm(Dialog *self);
void Dialog_on_cancel(Dialog *self);

/* ---- allocation, destruction, run-time type checks ---- */
#define DUOP_OBJ_VTBL(vtbl) ((const ObjectVtbl *)&(vtbl))
#define DUOP_NEW(Type, vtbl) ((Type *)Object_alloc(DUOP_OBJ_VTBL(vtbl), sizeof(Type)))
#define DUOP_DELETE(obj) Object_free((Object *)(obj))
#define DUOP_IS_INSTANCE(obj, vtbl) Object_is_instance((const Object *)(obj), DUOP_OBJ_VTBL(vtbl))

/* ---- virtual dispatch: the vtable of `obj` is read at run time, `this` is the first argument ---- */
#define DUOP_VCALL(Vtbl, Self, obj, slot, ...) \
    (((const Vtbl *)((const Object *)(obj))->vptr)->slot((Self *)(obj)__VA_OPT__(, ) __VA_ARGS__))
#define OBJECT_CALL(obj, slot, ...) DUOP_VCALL(ObjectVtbl, Object, obj, slot __VA_OPT__(, ) __VA_ARGS__)
#define WIDGET_CALL(obj, slot, ...) DUOP_VCALL(WidgetVtbl, Widget, obj, slot __VA_OPT__(, ) __VA_ARGS__)
#define DIALOG_CALL(obj, slot, ...) DUOP_VCALL(DialogVtbl, Dialog, obj, slot __VA_OPT__(, ) __VA_ARGS__)
#define DUOP_SUPER_CALL(Vtbl, Self, parent_vtbl, obj, slot, ...) \
    (((const Vtbl *)&(parent_vtbl))->slot((Self *)(obj)__VA_OPT__(, ) __VA_ARGS__))

/* ---- vtable builders: every slot starts at the base class default, `.slot = fn` overrides it (the later initialiser wins, which
 * is exactly what -Woverride-init warns about, so it is silenced around the definition). The macro ends in `;`, and a further
 * `;` after it is harmless. ---- */
#if defined(__clang__)
#define DUOP_VTBL_PUSH _Pragma("clang diagnostic push") _Pragma("clang diagnostic ignored \"-Winitializer-overrides\"")
#define DUOP_VTBL_POP _Pragma("clang diagnostic pop")
#else
#define DUOP_VTBL_PUSH _Pragma("GCC diagnostic push") _Pragma("GCC diagnostic ignored \"-Woverride-init\"")
#define DUOP_VTBL_POP _Pragma("GCC diagnostic pop")
#endif

#define WIDGET_VTBL(NAME, CLASS, SUPER_VTBL, INST_SIZE, ...)                                                                           \
    DUOP_VTBL_PUSH const WidgetVtbl NAME = {                                                                                           \
        .base = {DUOP_OBJ_VTBL(SUPER_VTBL), CLASS, (INST_SIZE), (void (*)(Object *))Widget_dtor},                                       \
        .layout = Widget_layout, .render = Widget_render, .on_key = Widget_on_key, .on_mouse = Widget_on_mouse,                        \
        .on_focus = Widget_on_focus, .hit_test = Widget_hit_test, __VA_ARGS__};                                                                                           \
    DUOP_VTBL_POP

#define DIALOG_VTBL(NAME, CLASS, SUPER_VTBL, INST_SIZE, ...)                                                                           \
    DUOP_VTBL_PUSH const DialogVtbl NAME = {                                                                                           \
        .base = {.base = {DUOP_OBJ_VTBL(SUPER_VTBL), CLASS, (INST_SIZE), (void (*)(Object *))Dialog_dtor},                              \
                 .layout = Dialog_layout, .render = Dialog_render, .on_key = Dialog_on_key, .on_mouse = Dialog_on_mouse,               \
                 .on_focus = Widget_on_focus, .hit_test = Widget_hit_test},                                                            \
        .on_confirm = Dialog_on_confirm, .on_cancel = Dialog_on_cancel, __VA_ARGS__};                                                         \
    DUOP_VTBL_POP

/* ---- hardware-fault guard (os_try_begin / os_try_end, pal_fault.s): `sig` is 0 when the block ran to the end, else the signal that
 * interrupted it. Locals written inside the block and read after a fault must be volatile; leave the block only through
 * DUOP_TRY_END (a `return` or `goto` out of it leaves the frame linked). ---- */
#define DUOP_TRY_BEGIN(frame, sig) \
    TryFrame frame;                \
    int sig = os_try_begin(&(frame)); \
    if ((sig) == 0)
#define DUOP_TRY_END(frame) os_try_end(&(frame))
