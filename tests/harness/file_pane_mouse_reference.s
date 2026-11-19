# Frozen reference oracle: src/ui/file_pane_mouse.s (before C23 migration to src/ui/file_pane_mouse.c).
# FilePane Widget (Inherits from Widget) — file pane mouse (split from file_pane.s)

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
.global FilePane_on_mouse

# int FilePane_on_mouse(FilePane *this, Event *evt)
FilePane_on_mouse:
    push rbx
    push r12
    push r13
    push r14
    call FilePane_on_mouse__this
    cmp eax, MACT_RELEASE
    jne .Lfpm_chk_drag
    mov dword ptr [rbx + FilePane.dragging_scroll], 0
    xor eax, eax
    jmp .Lfpm_ret

.Lfpm_chk_drag:
    cmp eax, MACT_DRAG
    jne .Lfpm_chk_wheel
    cmp dword ptr [rbx + FilePane.dragging_scroll], 0
    je .Lfpm_ret0
    call FilePane_on_mouse__scrub_scrollbar
    jmp .Lfpm_ret

.Lfpm_chk_wheel:
    cmp eax, MACT_WHEEL
    jne .Lfpm_chk_move
    call FilePane_on_mouse__list_h
    mov [rbx + FilePane.scroll], eax
    mov rax, [rbx + FilePane.app]
    mov dword ptr [rax + App.need_redraw], 1
    mov eax, 1
    jmp .Lfpm_ret

.Lfpm_chk_move:
    cmp eax, MACT_MOVE
    jne .Lfpm_chk_press

    # Check column header hover
    call FilePane_on_mouse__check_column_header_hover
    cmp r14d, [rbx + FilePane.hovered_col_hdr]
    jne .Lfpm_hm_dirty
    cmp r10d, [rbx + FilePane.hovered_row]
    je .Lfpm_ret0
.Lfpm_hm_dirty:
    mov [rbx + FilePane.hovered_col_hdr], r14d
    mov [rbx + FilePane.hovered_row], r10d
    mov rax, [rbx + FilePane.app]
    mov dword ptr [rax + App.need_redraw], 1
    jmp .Lfpm_ret0

.Lfpm_chk_press:
    cmp eax, MACT_PRESS
    jne .Lfpm_ret0

    # Focus this pane on click
    call FilePane_on_mouse__focus_this_pane_click
    # Check tab strip hit zones on top border row
    cmp r9d, [rbx + Widget.y]
    jne .Lfpm_chk_colhdr
    cmp dword ptr [rbx + FilePane.tab_count], 1
    jle .Lfpm_chk_colhdr
    xor ecx, ecx
.Lfpm_tz_loop:
    cmp ecx, [rbx + FilePane.tab_zone_count]
    jge .Lfpm_chk_colhdr
    imul rdx, rcx, HitZone._size
    lea r10, [rbx + FilePane.tab_zones + rdx]
    movsx eax, word ptr [r10 + HitZone.x1]
    cmp r8d, eax
    jl .Lfpm_tz_next
    movsx eax, word ptr [r10 + HitZone.x2]
    cmp r8d, eax
    jge .Lfpm_tz_next
    movsx esi, word ptr [r10 + HitZone.id]
    mov eax, [r12 + Event.mouse_btn]
    cmp eax, MOUSE_MID
    je .Lfpm_tz_close
    cmp eax, MOUSE_LEFT
    jne .Lfpm_tz_next
    mov rdi, rbx
    call FilePane_tab_switch
    mov rdi, [rbx + FilePane.app]
    call App_sync_preview
    jmp .Lfpm_handled
.Lfpm_tz_close:
    mov rdi, rbx
    call FilePane_tab_close
    mov rdi, [rbx + FilePane.app]
    call App_sync_preview
    jmp .Lfpm_handled
.Lfpm_tz_next:
    inc ecx
    jmp .Lfpm_tz_loop

.Lfpm_chk_colhdr:

    # Check click on column header row (y + 1)
    mov eax, [rbx + Widget.y]
    inc eax
    cmp r9d, eax
    jne .Lfpm_chk_sb
    xor ecx, ecx
.Lfpm_hdr_click:
    cmp ecx, [rbx + FilePane.hdr_zone_count]
    jge .Lfpm_handled
    imul rax, rcx, HitZone._size
    lea r10, [rbx + FilePane.hdr_zones + rax]
    movsx edx, word ptr [r10 + HitZone.x1]
    cmp r8d, edx
    jl .Lfpm_hc_next
    movsx edx, word ptr [r10 + HitZone.x2]
    cmp r8d, edx
    jge .Lfpm_hc_next
    call FilePane_on_mouse__part6
    call FilePane_on_mouse__sort
    jmp .Lfpm_handled
.Lfpm_hc_next:
    inc ecx
    jmp .Lfpm_hdr_click

.Lfpm_chk_sb:
    # Check scrollbar column (x + w - 1) inside list rows
    mov eax, [rbx + Widget.x]
    add eax, [rbx + Widget.w]
    dec eax
    cmp r8d, eax
    jne .Lfpm_chk_row
    mov ecx, [rbx + Widget.y]
    add ecx, 3
    cmp r9d, ecx
    jl .Lfpm_chk_row
    call FilePane_on_mouse__get_list_h
    jge .Lfpm_chk_row
    mov dword ptr [rbx + FilePane.dragging_scroll], 1
    mov rdi, rbx
    mov esi, r9d
    call scrub_scrollbar
    jmp .Lfpm_handled

.Lfpm_chk_row:
    mov eax, [rbx + Widget.y]
    call FilePane_on_mouse__double_click_open_entry

.Lfpm_handled:
    mov rax, [rbx + FilePane.app]
    mov dword ptr [rax + App.need_redraw], 1
    mov eax, 1
.Lfpm_ret:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.Lfpm_ret0:
    xor eax, eax
    jmp .Lfpm_ret

# FilePane_on_mouse step: this (runs on the caller's frame)
FilePane_on_mouse__this:
    lea rsp, [rsp - 8]
    mov rbx, rdi              # this
    mov r12, rsi              # evt
    mov r13, [rbx + FilePane.model]

    mov r8d, [r12 + Event.mouse_x]
    mov r9d, [r12 + Event.mouse_y]
    mov eax, [r12 + Event.mouse_kind]

.LFilePane_on_mouse__this_ret:
    lea rsp, [rsp + 8]
    ret

# FilePane_on_mouse step: scrub_scrollbar (runs on the caller's frame)
FilePane_on_mouse__scrub_scrollbar:
    lea rsp, [rsp - 8]
    mov rdi, rbx
    mov esi, r9d
    call scrub_scrollbar
    mov rax, [rbx + FilePane.app]
    mov dword ptr [rax + App.need_redraw], 1
    mov eax, 1
.LFilePane_on_mouse__scrub_scrollbar_ret:
    lea rsp, [rsp + 8]
    ret

# FilePane_on_mouse step: list_h (runs on the caller's frame)
FilePane_on_mouse__list_h:
    lea rsp, [rsp - 8]
    mov rdi, rbx
    call get_list_h
    mov r8d, eax              # list_h
    mov r9, [r13 + DirModel.count]
    sub r9d, r8d
    cmp r9d, 0
    jge .Lfpm_wh_maxok
    xor r9d, r9d
.Lfpm_wh_maxok:
    mov eax, [rbx + FilePane.scroll]
    cmp dword ptr [r12 + Event.mouse_btn], MOUSE_WHEEL_UP
    jne .Lfpm_wh_dn
    sub eax, 3
    jns .Lfpm_wh_apply
    xor eax, eax
    jmp .Lfpm_wh_apply
.Lfpm_wh_dn:
    add eax, 3
    cmp eax, r9d
    jle .Lfpm_wh_apply
    mov eax, r9d
.Lfpm_wh_apply:
.LFilePane_on_mouse__list_h_ret:
    lea rsp, [rsp + 8]
    ret

# FilePane_on_mouse step: Check column header hover (runs on the caller's frame)
FilePane_on_mouse__check_column_header_hover:
    lea rsp, [rsp - 8]
    mov r14d, -1
    xor ecx, ecx
.Lfpm_hm_hdr:
    cmp ecx, [rbx + FilePane.hdr_zone_count]
    jge .Lfpm_hm_row
    imul rax, rcx, HitZone._size
    lea r10, [rbx + FilePane.hdr_zones + rax]
    movsx edx, word ptr [r10 + HitZone.y]
    cmp r9d, edx
    jne .Lfpm_hm_hnext
    movsx edx, word ptr [r10 + HitZone.x1]
    cmp r8d, edx
    jl .Lfpm_hm_hnext
    movsx edx, word ptr [r10 + HitZone.x2]
    cmp r8d, edx
    jge .Lfpm_hm_hnext
    movsx r14d, word ptr [r10 + HitZone.id]
    jmp .Lfpm_hm_row
.Lfpm_hm_hnext:
    inc ecx
    jmp .Lfpm_hm_hdr

.Lfpm_hm_row:
    mov r10d, -1              # hovered_row
    mov eax, [rbx + Widget.y]
    add eax, 3
    cmp r9d, eax
    jl .Lfpm_hm_apply
    mov rdi, rbx
    push r8
    push r9
    call get_list_h
    pop r9
    pop r8
    mov edx, [rbx + Widget.y]
    add edx, 3
    add edx, eax
    cmp r9d, edx
    jge .Lfpm_hm_apply
    mov r10d, r9d
    sub r10d, [rbx + Widget.y]
    sub r10d, 3
.Lfpm_hm_apply:
.LFilePane_on_mouse__check_column_header_hover_ret:
    lea rsp, [rsp + 8]
    ret

# FilePane_on_mouse step: Focus this pane on click (runs on the caller's frame)
FilePane_on_mouse__focus_this_pane_click:
    lea rsp, [rsp - 8]
    push r8
    push r9
    mov rdi, [rbx + FilePane.app]
    mov rsi, rbx
    call App_set_active_pane
    pop r9
    pop r8

.LFilePane_on_mouse__focus_this_pane_click_ret:
    lea rsp, [rsp + 8]
    ret

# FilePane_on_mouse step (runs on the caller's frame)
FilePane_on_mouse__part6:
    lea rsp, [rsp - 8]
    movsx edi, word ptr [r10 + HitZone.id]
    cmp dword ptr [r13 + DirModel.is_unsorted], 0
    jne .Lfpm_hc_new
    cmp edi, [r13 + DirModel.sort_mode]
    jne .Lfpm_hc_new
    xor dword ptr [r13 + DirModel.sort_desc], 1
    jmp .Lfpm_hc_sort
.Lfpm_hc_new:
    mov [r13 + DirModel.sort_mode], edi
    mov dword ptr [r13 + DirModel.sort_desc], 0
.Lfpm_hc_sort:
.LFilePane_on_mouse__part6_ret:
    lea rsp, [rsp + 8]
    ret

# FilePane_on_mouse step: sort (runs on the caller's frame)
FilePane_on_mouse__sort:
    lea rsp, [rsp - 8]
    mov rdi, r13
    call DirModel_sort
    mov dword ptr [rbx + FilePane.cursor], 0
    mov dword ptr [rbx + FilePane.scroll], 0
    mov rdi, [rbx + FilePane.app]
    call App_sync_preview
.LFilePane_on_mouse__sort_ret:
    lea rsp, [rsp + 8]
    ret

# FilePane_on_mouse step: get_list_h (runs on the caller's frame)
FilePane_on_mouse__get_list_h:
    lea rsp, [rsp - 8]
    mov rdi, rbx
    push r9
    call get_list_h
    pop r9
    mov ecx, [rbx + Widget.y]
    add ecx, 3
    add ecx, eax
    cmp r9d, ecx
.LFilePane_on_mouse__get_list_h_ret:
    lea rsp, [rsp + 8]
    ret

# FilePane_on_mouse step: Double click open entry (runs on the caller's frame)
FilePane_on_mouse__double_click_open_entry:
    lea rsp, [rsp - 8]
    add eax, 3
    cmp r9d, eax
    jl .LFilePane_on_mouse__double_click_open_entry_ret
    mov rdi, rbx
    push r9
    call get_list_h
    pop r9
    mov ecx, [rbx + Widget.y]
    add ecx, 3
    add ecx, eax
    cmp r9d, ecx
    jge .LFilePane_on_mouse__double_click_open_entry_ret

    mov r14d, r9d
    sub r14d, [rbx + Widget.y]
    sub r14d, 3
    add r14d, [rbx + FilePane.scroll]  # clicked index
    mov rax, [r13 + DirModel.count]
    cmp r14, rax
    jae .LFilePane_on_mouse__double_click_open_entry_ret

    cmp dword ptr [r12 + Event.mouse_btn], MOUSE_RIGHT
    jne .Lfpm_left_click
    mov [rbx + FilePane.cursor], r14d
    mov rdi, r13
    mov esi, r14d
    call DirModel_toggle_select
    mov rdi, [rbx + FilePane.app]
    call App_sync_preview
    jmp .LFilePane_on_mouse__double_click_open_entry_ret

.Lfpm_left_click:
    cmp dword ptr [r12 + Event.mouse_btn], MOUSE_LEFT
    jne .LFilePane_on_mouse__double_click_open_entry_ret

    call sys_clock_ms
    mov r8, rax               # now_ms
    cmp r14d, [rbx + FilePane.last_click_idx]
    jne .Lfpm_single_click
    mov r9, r8
    sub r9, [rbx + FilePane.last_click_ms]
    cmp r9, DBLCLICK_MS
    jg .Lfpm_single_click

    # Double click -> open entry!
    mov dword ptr [rbx + FilePane.last_click_idx], -1
    mov [rbx + FilePane.cursor], r14d
    mov rdi, [rbx + FilePane.app]
    mov rsi, rbx
    call App_open_selected_entry
    jmp .LFilePane_on_mouse__double_click_open_entry_ret

.Lfpm_single_click:
    mov [rbx + FilePane.cursor], r14d
    mov [rbx + FilePane.last_click_idx], r14d
    mov [rbx + FilePane.last_click_ms], r8
    mov rdi, rbx
    call FilePane_ensure_visible
    mov rdi, [rbx + FilePane.app]
    call App_sync_preview
.LFilePane_on_mouse__double_click_open_entry_ret:
    lea rsp, [rsp + 8]
    ret
