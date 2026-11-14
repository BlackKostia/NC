# FilePane Widget (Inherits from Widget) — file pane layout (split from file_pane.s)

.intel_syntax noprefix
.include "classes.inc"
.equ FP_TAB_MAX,       8
.equ FP_TAB_PATH,      0
.equ FP_TAB_CURSOR,    4096
.equ FP_TAB_SCROLL,    4100
.equ FP_TAB_SORT_MODE, 4104
.equ FP_TAB_SORT_DESC, 4108
.equ FP_TAB_SHOW_HID,  4112
.equ FP_TAB_SIZE,      4384

.section .text
.global FilePane_layout

# void FilePane_layout(FilePane *this, int x, int y, int w, int h)
FilePane_layout:
    push rbx
    mov rbx, rdi
    call Widget_layout

    mov rdi, rbx
    call compute_cols         # r8d=name_w, r9d=size_w, r10d=extra_w, r11d=is_date

    mov eax, [rbx + Widget.x]
    inc eax                   # col start
    mov ecx, [rbx + Widget.y]
    inc ecx                   # header row y + 1

    # Zone 0: SORT_NAME
    lea rdx, [rbx + FilePane.hdr_zones]
    mov [rdx + HitZone.x1], ax
    add eax, r8d
    mov [rdx + HitZone.x2], ax
    mov [rdx + HitZone.y], cx
    mov word ptr [rdx + HitZone.id], SORT_NAME
    mov dword ptr [rbx + FilePane.hdr_zone_count], 1

    test r9d, r9d
    jz .Lfpl_vis
    # Zone 1: SORT_SIZE
    add rdx, HitZone._size
    mov [rdx + HitZone.x1], ax
    add eax, r9d
    mov [rdx + HitZone.x2], ax
    mov [rdx + HitZone.y], cx
    mov word ptr [rdx + HitZone.id], SORT_SIZE
    mov dword ptr [rbx + FilePane.hdr_zone_count], 2

    test r10d, r10d
    jz .Lfpl_vis
    # Zone 2: SORT_MTIME (if date) or SORT_EXT (if perm)
    add rdx, HitZone._size
    mov [rdx + HitZone.x1], ax
    add eax, r10d
    mov [rdx + HitZone.x2], ax
    mov [rdx + HitZone.y], cx
    mov esi, SORT_EXT
    test r11d, r11d
    jz .Lfpl_z2_id
    mov esi, SORT_MTIME
.Lfpl_z2_id:
    mov [rdx + HitZone.id], si
    mov dword ptr [rbx + FilePane.hdr_zone_count], 3

.Lfpl_vis:
    mov rdi, rbx
    call FilePane_ensure_visible
    pop rbx
    ret
