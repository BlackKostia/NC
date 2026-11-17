/* include/duop_oop.h - C view of the Object/Widget runtime (include/classes.inc, src/core/oop_rt.c).
 * Single inheritance with the vtable pointer at offset 0 of every object; `this` is the first argument (rdi / x0).
 * Layouts mirror classes.inc exactly; tests/test_abi_layouts.py compares every offset with the assembler's. */
#pragma once
#include "duop_abi.h"

typedef struct Object Object;
typedef struct Widget Widget;

typedef struct ObjectVtbl {
    const struct ObjectVtbl *super;
    const char *class_name;
    uint64_t inst_size;
    void (*dtor)(Object *self);
} ObjectVtbl;

typedef struct WidgetVtbl {
    ObjectVtbl base;
    void (*layout)(Widget *self, int x, int y, int w, int h);
    void (*render)(Widget *self, void *screen, void *theme);
    int (*on_key)(Widget *self, void *event);
    int (*on_mouse)(Widget *self, void *event);
    void (*on_focus)(Widget *self, int gained);
    int (*hit_test)(Widget *self, int mx, int my);
} WidgetVtbl;

struct Object { const ObjectVtbl *vptr; };

struct Widget {
    Object base;
    void *parent;
    int32_t x, y, w, h;
    uint32_t flags;
    int32_t id;
};

#define WF_VISIBLE 1u
#define WF_FOCUSED 2u
#define WF_DIRTY 8u
#define WF_ENABLED 16u

extern const ObjectVtbl Object_vtbl;
extern const WidgetVtbl Widget_vtbl;

void *Object_alloc(const ObjectVtbl *vtbl, size_t size);       /* zeroed, vptr set; NULL on OOM */
void Object_free(Object *obj);                                 /* dtor through the vtable, then mem_free; NULL-safe */
int Object_is_instance(const Object *obj, const ObjectVtbl *target);
const char *Object_get_class_name(const Object *obj);
void Object_dtor(Object *self);
void Widget_init(Widget *self, void *parent, int id);
void Widget_dtor(Widget *self);
void Widget_layout(Widget *self, int x, int y, int w, int h);
void Widget_render(Widget *self, void *screen, void *theme);
int Widget_on_key(Widget *self, void *event);
int Widget_on_mouse(Widget *self, void *event);
void Widget_on_focus(Widget *self, int gained);
int Widget_hit_test(Widget *self, int mx, int my);

void *mem_alloc(size_t size);
void mem_free(void *ptr);
