/* src/core/oop_rt.c - OOP runtime: base Object and Widget classes, RTTI, default virtual methods
 * (freestanding C23; replaces oop_rt.s). Vtables live in .rodata; concrete classes (still assembly) inherit by
 * naming Widget_vtbl as their super and these functions as default slots. */
#include "duop_oop.h"

static const char str_Object[] = "Object";
static const char str_Widget[] = "Widget";

const ObjectVtbl Object_vtbl = {nullptr, str_Object, sizeof(Object), Object_dtor};

const WidgetVtbl Widget_vtbl = {
    {&Object_vtbl, str_Widget, sizeof(Widget), (void (*)(Object *))Widget_dtor},
    Widget_layout, Widget_render, Widget_on_key, Widget_on_mouse, Widget_on_focus, Widget_hit_test,
};

void *Object_alloc(const ObjectVtbl *vtbl, size_t size)
{
    Object *o = mem_alloc(size);
    if (o) o->vptr = vtbl;
    return o;
}

void Object_free(Object *obj)
{
    if (!obj) return;
    if (obj->vptr) obj->vptr->dtor(obj);
    mem_free(obj);
}

int Object_is_instance(const Object *obj, const ObjectVtbl *target)
{
    if (!obj) return 0;
    for (const ObjectVtbl *v = obj->vptr; v; v = v->super)
        if (v == target) return 1;
    return 0;
}

const char *Object_get_class_name(const Object *obj)
{
    return obj ? obj->vptr->class_name : nullptr;
}

void Object_dtor(Object *self) { (void)self; }

void Widget_init(Widget *self, void *parent, int id)
{
    self->parent = parent;
    self->id = id;
    self->flags = WF_VISIBLE | WF_ENABLED | WF_DIRTY;
}

void Widget_dtor(Widget *self) { (void)self; }

void Widget_layout(Widget *self, int x, int y, int w, int h)
{
    self->x = x;
    self->y = y;
    self->w = w;
    self->h = h;
    self->flags |= WF_DIRTY;
}

void Widget_render(Widget *self, void *screen, void *theme) { (void)self; (void)screen; (void)theme; }
int Widget_on_key(Widget *self, void *event) { (void)self; (void)event; return 0; }
int Widget_on_mouse(Widget *self, void *event) { (void)self; (void)event; return 0; }

void Widget_on_focus(Widget *self, int gained)
{
    if (gained) self->flags |= WF_FOCUSED | WF_DIRTY;
    else self->flags = (self->flags & ~WF_FOCUSED) | WF_DIRTY;
}

int Widget_hit_test(Widget *self, int mx, int my)
{
    if (!(self->flags & WF_VISIBLE)) return 0;
    return mx >= self->x && mx < self->x + self->w && my >= self->y && my < self->y + self->h;
}
