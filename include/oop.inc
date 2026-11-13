# OOP Framework for GNU Assembler (x86-64 Intel Syntax)
#
# Provides:
#   - Class struct layout with single inheritance (CLASS_BEGIN / EXTENDS / FIELD / CLASS_END)
#   - VTable layout with single inheritance (VTBL_BEGIN / VTBL_EXTENDS / VTBL_SLOT / VTBL_END)
#   - Virtual method dispatch (VCALL / VCALL_REG / SUPER_CALL)
#   - Runtime object construction & type checks (NEW_OBJ / DELETE_OBJ / IS_INSTANCE)
#
# Calling convention:
#   System V AMD64 ABI: `rdi` always holds `this` (object pointer).
#   `Object.vptr` is always at offset 0 of every object instance.

.intel_syntax noprefix

# --- Class Definition Macros ---
.macro CLASS_BEGIN name
    .struct 0
\name\()._start:
.endm

.macro EXTENDS parent
    .struct \parent\()._size
.endm

.macro FIELD name, size
\name:
    .space \size
.endm

.macro CLASS_END name
\name\()._size:
    .section .text
.endm

# --- Virtual Table Layout Macros ---
.macro VTBL_BEGIN name
    .struct 0
\name\()._start:
.endm

.macro VTBL_EXTENDS parent
    .struct \parent\()._size
.endm

.macro VTBL_SLOT name
\name:
    .space 8
.endm

.macro VTBL_END name
\name\()._size:
    .section .text
.endm

# --- Polymorphic Dispatch Macros ---
# Assumes `rdi` already holds `this`
.macro VCALL slot
    mov rax, [rdi + Object.vptr]
    call qword ptr [rax + \slot]
.endm

# Sets `rdi = reg` and invokes virtual method `\slot`
.macro VCALL_REG reg, slot
    .ifc \reg, rdi
    .else
        mov rdi, \reg
    .endif
    mov rax, [rdi + Object.vptr]
    call qword ptr [rax + \slot]
.endm

# Invokes base class implementation directly (`rdi` holds `this`)
.macro SUPER_CALL parent_vtbl, slot
    lea rax, [rip + \parent_vtbl]
    call qword ptr [rax + \slot]
.endm

# --- Heap / Lifecycle Helpers ---
# Allocates zeroed object of `size` with `vptr = vtbl`, result in `rax`
.macro NEW_OBJ vtbl, size
    lea rdi, [rip + \vtbl]
    mov rsi, \size
    call Object_alloc
.endm

# Calls virtual destructor (if ptr != 0) and releases memory
.macro DELETE_OBJ reg
    .ifc \reg, rdi
    .else
        mov rdi, \reg
    .endif
    call Object_free
.endm

# Checks if `obj_reg` is an instance of `vtbl` (or subclass), result in `eax` (1/0)
.macro IS_INSTANCE obj_reg, vtbl
    .ifc \obj_reg, rdi
    .else
        mov rdi, \obj_reg
    .endif
    lea rsi, [rip + \vtbl]
    call Object_is_instance
.endm
