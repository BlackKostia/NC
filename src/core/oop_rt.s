# OOP Runtime Support: Base Object & Widget Classes, RTTI, Virtual Dispatch

.intel_syntax noprefix
.include "classes.inc"

.section .rodata
str_Object:
    .asciz "Object"
str_Widget:
    .asciz "Widget"

.global Object_vtbl
Object_vtbl:
    OBJECT_VTBL_SLOTS str_Object, 0, Object._size, Object_dtor

.global Widget_vtbl
Widget_vtbl:
    WIDGET_VTBL_SLOTS str_Widget, Object_vtbl, Widget._size

.section .text
.global Object_alloc
.global Object_free
.global Object_is_instance
.global Object_get_class_name
.global Object_dtor

.global Widget_init
.global Widget_dtor
.global Widget_layout
.global Widget_render
.global Widget_on_key
.global Widget_on_mouse
.global Widget_on_focus
.global Widget_hit_test

# void *Object_alloc(const void *vtbl, size_t size)
Object_alloc:
    push rbx
    mov rbx, rdi              # save vtbl
    mov rdi, rsi
    call mem_alloc
    test rax, rax
    jz .Loa_fail
    mov [rax + Object.vptr], rbx
.Loa_fail:
    pop rbx
    ret

# void Object_free(Object *obj)
Object_free:
    test rdi, rdi
    jz .Lof_done
    push rbx
    mov rbx, rdi
    mov rax, [rbx + Object.vptr]
    test rax, rax
    jz .Lof_raw_free
    mov rdi, rbx
    call qword ptr [rax + ObjectVtbl.dtor]
.Lof_raw_free:
    mov rdi, rbx
    call mem_free
    pop rbx
.Lof_done:
    ret

# int Object_is_instance(const Object *obj, const void *target_vtbl)
Object_is_instance:
    test rdi, rdi
    jz .Loii_no
    mov rax, [rdi + Object.vptr]
.Loii_walk:
    test rax, rax
    jz .Loii_no
    cmp rax, rsi
    je .Loii_yes
    mov rax, [rax + ObjectVtbl.super]
    jmp .Loii_walk
.Loii_yes:
    mov eax, 1
    ret
.Loii_no:
    xor eax, eax
    ret

# const char *Object_get_class_name(const Object *obj)
Object_get_class_name:
    test rdi, rdi
    jz .Logn_null
    mov rax, [rdi + Object.vptr]
    mov rax, [rax + ObjectVtbl.class_name]
    ret
.Logn_null:
    xor eax, eax
    ret

# void Object_dtor(Object *this)
Object_dtor:
    ret

# void Widget_init(Widget *this, void *parent, int id)
Widget_init:
    mov [rdi + Widget.parent], rsi
    mov dword ptr [rdi + Widget.id], edx
    mov dword ptr [rdi + Widget.flags], WF_VISIBLE | WF_ENABLED | WF_DIRTY
    ret

# void Widget_dtor(Widget *this)
Widget_dtor:
    ret

# void Widget_layout(Widget *this, int x, int y, int w, int h)
# rdi=this, esi=x, edx=y, ecx=w, r8d=h
Widget_layout:
    mov dword ptr [rdi + Widget.x], esi
    mov dword ptr [rdi + Widget.y], edx
    mov dword ptr [rdi + Widget.w], ecx
    mov dword ptr [rdi + Widget.h], r8d
    or dword ptr [rdi + Widget.flags], WF_DIRTY
    ret

# void Widget_render(Widget *this, ScreenBuffer *scr, Theme *theme)
Widget_render:
    ret

# int Widget_on_key(Widget *this, Event *evt)
Widget_on_key:
    xor eax, eax
    ret

# int Widget_on_mouse(Widget *this, Event *evt)
Widget_on_mouse:
    xor eax, eax
    ret

# void Widget_on_focus(Widget *this, int gained)
Widget_on_focus:
    test esi, esi
    jz .Lwof_blur
    or dword ptr [rdi + Widget.flags], WF_FOCUSED | WF_DIRTY
    ret
.Lwof_blur:
    and dword ptr [rdi + Widget.flags], ~WF_FOCUSED
    or dword ptr [rdi + Widget.flags], WF_DIRTY
    ret

# int Widget_hit_test(Widget *this, int mx, int my)
Widget_hit_test:
    test dword ptr [rdi + Widget.flags], WF_VISIBLE
    jz .Lwht_no
    mov eax, [rdi + Widget.x]
    cmp esi, eax
    jl .Lwht_no
    add eax, [rdi + Widget.w]
    cmp esi, eax
    jge .Lwht_no

    mov eax, [rdi + Widget.y]
    cmp edx, eax
    jl .Lwht_no
    add eax, [rdi + Widget.h]
    cmp edx, eax
    jge .Lwht_no

    mov eax, 1
    ret
.Lwht_no:
    xor eax, eax
    ret
