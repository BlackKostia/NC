# FilePane Widget (Inherits from Widget) — file pane render (split from file_pane.s)

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

.section .rodata
str_ellip_pfx:   .asciz "…"
str_sort_asc:    .asciz " ▲"
str_sort_desc:   .asciz " ▼"

.section .text
.global FilePane_render

# void FilePane_render(FilePane *this, ScreenBuffer *scr, Theme *theme)
FilePane_render:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 512              # local buffers & state
    # [rsp+0..127]  = scratch line buf (128B)
    # [rsp+128..159]= aux buf (32B)
    # [rsp+160]     = border_fg (4)
    # [rsp+164]     = focused (4)
    # [rsp+168]     = name_w (4)
    # [rsp+172]     = size_w (4)
    # [rsp+176]     = extra_w (4)
    # [rsp+180]     = extra_is_date (4)
    # [rsp+184]     = list_h (4)
    # [rsp+188]     = row idx r (4)

    mov rbx, rdi; mov r12, rsi; mov r13, rdx

    cmp dword ptr [rbx + Widget.w], 6
    jl .Lfpr_done
    cmp dword ptr [rbx + Widget.h], 6
    jl .Lfpr_done

    # Determine focus & border color
    call FilePane_render__determine_focus_border_color
    # Compute column widths
    call FilePane_render__compute_column_widths
    # 1. Draw rounded box + surface fill
    call FilePane_render__draw_rounded_box_surface
    # 2. Draw top path title pill (or tab strip when tab_count > 1)
    mov dword ptr [rbx + FilePane.tab_zone_count], 0
    cmp dword ptr [rbx + FilePane.tab_count], 1
    jg .Lfpr_draw_tabs

    call FilePane_render__build
    # Append trailing space
    call FilePane_render__append_trailing_space
    jmp .Lfpr_divider

.Lfpr_draw_tabs:
    # Sync active tab path first
    mov rdi, rbx
    call fp_get_active_tab
    test rax, rax
    jz .Lfpr_divider
    call FilePane_render__part6
    xor r14d, r14d            # t = 0
    mov r15d, [rbx + Widget.x]
    add r15d, 2               # cur_x
.Lfpr_tab_loop:
    cmp r14d, [rbx + FilePane.tab_count]
    jge .Lfpr_divider
    mov eax, [rbx + Widget.x]
    add eax, [rbx + Widget.w]
    sub eax, 4
    cmp r15d, eax
    jge .Lfpr_divider

    # Format "[<t+1>:<basename>]" into [rsp+0..127]
    call FilePane_render__path_basename
    push rax                  # tab display width (approx byte len)
    call FilePane_render__draw_text
    # Measure actual utf8 display width for HitZone
    lea rdi, [rsp + 8]
    call utf8_display_width
    pop rcx
    call FilePane_render__part9
    add r15d, eax
    inc r15d                  # 1 space gap
    inc r14d
    jmp .Lfpr_tab_loop

.Lfpr_divider:
    call FilePane_render__draw_divider_line
    # 4. Draw column headers on row y + 1
    # Name header
    call FilePane_render__name_header
    # Size header if size_w > 0
    cmp dword ptr [rsp + 172], 0
    je .Lfpr_rows_start

    call FilePane_render__draw_text_pad
    # Extra header (Modified or Perms)
    cmp dword ptr [rsp + 176], 0
    je .Lfpr_rows_start

    call FilePane_render__part13
    push rax
    mov rdi, rsp
    add rdi, 8
    mov edx, 128
    call str_copy
    pop rax
    call FilePane_render__leading_separator_space
    # 5. Render File Rows
.Lfpr_rows_start:
    mov rdi, r14
    mov esi, [rbx + FilePane.scroll]
    mov edx, [rsp + 184]
    call DirModel_stat_range
    mov dword ptr [rsp + 188], 0  # r = 0
.Lfpr_row_loop:
    mov eax, [rsp + 188]
    cmp eax, [rsp + 184]
    jge .Lfpr_scrollbar

    call FilePane_render__idx
    jz .Lfpr_row_next
    call FilePane_render__compute_row_bg_fg
    # Fill row interior with bg first
    call FilePane_render__fill_row_interior_bg
    call FilePane_render__part18
    mov eax, [rsp + 196]; push rax; push r13
    call fp_draw_glyph_and_git
    add rsp, 16
    # Filename at x + 5 (max width = name_w - 4)
    call FilePane_render__filename
    # Ellipsis if name disp_width > available name_w - 5
    call FilePane_render__ellipsis_name_disp_width
    cmp dword ptr [rsp + 172], 0
    je .Lfpr_row_next

    # Use muted fg for size/date unless on cursor/selected
    call FilePane_render__use_muted_fg_size
    # Extra column (Modified or Perms)
    call FilePane_render__extra_column
.Lfpr_row_next:
    inc dword ptr [rsp + 188]
    jmp .Lfpr_row_loop

    # 6. Interactive Scrollbar on right border (if count > list_h)
.Lfpr_scrollbar:
    mov rdi, rbx; mov rsi, r12; mov rdx, r13; call fp_draw_du_pane
    mov rax, [r14 + DirModel.count]
    mov ecx, [rsp + 184]      # list_h
    cmp rax, rcx
    jle .Lfpr_footer

    # thumb_h = max(1, (list_h * list_h) / count)
    call FilePane_render__thumb_h
    # 7. Footer summary row (y + h - 2)
.Lfpr_footer:
    mov rdi, r14
    lea rsi, [rsp + 128]      # out_bytes (8B)
    call DirModel_count_selected
    test rax, rax
    jz .Lfpr_foot_totals

    # " ✓ <N> selected (<size>)"
    push rax
    call FilePane_render__part24
    pop rdi                   # sel count
    call FilePane_render__sel_bytes
    mov rdi, r12
    mov esi, [r13 + Theme.selected_fg]
    mov edx, [r13 + Theme.surface]
    mov ecx, ATTR_BOLD
    call ScreenBuffer_set_pen
    jmp .Lfpr_foot_draw

.Lfpr_foot_totals:
    call FilePane_render__format_size
    # Append streaming counter, Esc-aborted badge, or ls -f [FS-order] badge
    call FilePane_render__append_streaming_counter_esc
.Lfpr_foot_draw:
    call FilePane_render__filter_badge_bottom_border
.Lfpr_done:
    add rsp, 512
    pop r15; pop r14; pop r13; pop r12; pop rbx; ret

# FilePane_render step: Determine focus border color (runs on the caller's frame)
FilePane_render__determine_focus_border_color:
    lea rsp, [rsp - 8]
    xor eax, eax
    test dword ptr [rbx + Widget.flags], WF_FOCUSED
    setnz al
    mov [rsp + 164 + 16], eax
    mov ecx, [r13 + Theme.border_inactive]
    test eax, eax
    jz .Lfpr_bcol
    mov ecx, [r13 + Theme.border_active]
.Lfpr_bcol:
    mov [rsp + 160 + 16], ecx

.LFilePane_render__determine_focus_border_color_ret:
    lea rsp, [rsp + 8]
    ret

# FilePane_render step: Compute column widths (runs on the caller's frame)
FilePane_render__compute_column_widths:
    lea rsp, [rsp - 8]
    mov rdi, rbx
    call compute_cols
    mov [rsp + 168 + 16], r8d
    mov [rsp + 172 + 16], r9d
    mov [rsp + 176 + 16], r10d
    mov [rsp + 180 + 16], r11d

    mov rdi, rbx
    call get_list_h
    mov [rsp + 184 + 16], eax

.LFilePane_render__compute_column_widths_ret:
    lea rsp, [rsp + 8]
    ret

# FilePane_render step: Draw rounded box surface fill (runs on the caller's frame)
FilePane_render__draw_rounded_box_surface:
    lea rsp, [rsp - 8]
    mov rdi, r12
    mov esi, [rsp + 160 + 16]
    mov edx, [r13 + Theme.surface]
    xor ecx, ecx
    call ScreenBuffer_set_pen

    mov rdi, r12
    mov esi, [rbx + Widget.x]
    mov edx, [rbx + Widget.y]
    mov ecx, [rbx + Widget.w]
    mov r8d, [rbx + Widget.h]
    mov r9d, 1                # fill_interior = 1
    call ScreenBuffer_draw_box

.LFilePane_render__draw_rounded_box_surface_ret:
    lea rsp, [rsp + 8]
    ret

# FilePane_render step: Build (runs on the caller's frame)
FilePane_render__build:
    lea rsp, [rsp - 8]
    mov r14, [rbx + FilePane.model]
    lea r15, [r14 + DirModel.path]
    mov rdi, r15
    call str_len
    mov ecx, [rbx + Widget.w]
    sub ecx, 12               # max path display chars
    cmp ecx, 4
    jge .Lfpr_pmax_ok
    mov ecx, 4
.Lfpr_pmax_ok:
    # Build " ◆ <path> " (truncate from left with "…" if len > ecx)
    mov byte ptr [rsp + 16], ' '
    mov byte ptr [rsp + 1 + 16], 0
    cmp eax, ecx
    jbe .Lfpr_path_full
    # Take tail of length (ecx - 1)
    mov [rsp + 204 + 16], ecx # str_cat clobbers rcx: keep the width limit in the frame
    lea rdi, [rsp + 16]
    lea rsi, [rip + str_ellip_pfx]
    mov edx, 128
    call str_cat
    mov rdi, r15
    call str_len
    sub eax, [rsp + 204 + 16]
    inc eax
    lea rsi, [r15 + rax]
    lea rdi, [rsp + 16]
    mov edx, 128
    call str_cat
    jmp .Lfpr_path_tail
.Lfpr_path_full:
    lea rdi, [rsp + 16]
    mov rsi, r15
    mov edx, 128
    call str_cat
.Lfpr_path_tail:
.LFilePane_render__build_ret:
    lea rsp, [rsp + 8]
    ret

# FilePane_render step: Append trailing space (runs on the caller's frame)
FilePane_render__append_trailing_space:
    lea rsp, [rsp - 8]
    lea rdi, [rsp + 16]
    call str_len
    cmp eax, 126
    jae .Lfpr_path_pen
    mov byte ptr [rsp + rax + 16], ' '
    mov byte ptr [rsp + rax + 1 + 16], 0

.Lfpr_path_pen:
    mov rdi, r12
    mov esi, [r13 + Theme.border_inactive]
    mov edx, [r13 + Theme.surface_alt]
    xor ecx, ecx
    cmp dword ptr [rsp + 164 + 16], 0
    je .Lfpr_path_draw
    mov esi, [r13 + Theme.accent_fg]
    mov edx, [r13 + Theme.accent]
    mov ecx, ATTR_BOLD
.Lfpr_path_draw:
    call ScreenBuffer_set_pen

    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 2
    mov edx, [rbx + Widget.y]
    lea rcx, [rsp + 16]
    mov r8d, [rbx + Widget.w]
    sub r8d, 8
    call ScreenBuffer_draw_text
    mov rdi, rbx
    mov rsi, r12
    call fp_draw_search_badge
.LFilePane_render__append_trailing_space_ret:
    lea rsp, [rsp + 8]
    ret

# FilePane_render step (runs on the caller's frame)
FilePane_render__part6:
    lea rsp, [rsp - 8]
    mov rdi, rax
    mov rcx, [rbx + FilePane.model]
    lea rsi, [rcx + DirModel.path]
    mov edx, PATH_MAX
    call str_copy

.LFilePane_render__part6_ret:
    lea rsp, [rsp + 8]
    ret

# FilePane_render step: path_basename (runs on the caller's frame)
FilePane_render__path_basename:
    lea rsp, [rsp - 8]
    mov byte ptr [rsp + 16], '['
    lea eax, [r14d + '1']
    mov [rsp + 1 + 16], al
    mov byte ptr [rsp + 2 + 16], ':'
    mov byte ptr [rsp + 3 + 16], 0

    mov rcx, [rbx + FilePane.tabs]
    imul rax, r14, FP_TAB_SIZE
    lea rdi, [rcx + rax + FP_TAB_PATH]
    call path_basename
    test rax, rax
    jz .Lfpr_tab_noname
    cmp byte ptr [rax], 0
    jne .Lfpr_tab_cat
.Lfpr_tab_noname:
    mov byte ptr [rsp + 3 + 16], '/'
    mov byte ptr [rsp + 4 + 16], 0
    jmp .Lfpr_tab_close_br
.Lfpr_tab_cat:
    lea rdi, [rsp + 16]
    mov rsi, rax
    mov edx, 22
    call str_cat
.Lfpr_tab_close_br:
    lea rdi, [rsp + 16]
    call str_len
    cmp eax, 125
    jae .Lfpr_tab_pen
    mov byte ptr [rsp + rax + 16], ']'
    mov byte ptr [rsp + rax + 1 + 16], 0
    inc eax
.Lfpr_tab_pen:
.LFilePane_render__path_basename_ret:
    lea rsp, [rsp + 8]
    ret

# FilePane_render step: draw_text (runs on the caller's frame)
FilePane_render__draw_text:
    lea rsp, [rsp - 8]
    cmp r14d, [rbx + FilePane.active_tab]
    jne .Lfpr_tab_inact
    cmp dword ptr [rsp + 164 + 8 + 16], 0
    je .Lfpr_tab_inact_act
    mov esi, [r13 + Theme.accent_fg]
    mov edx, [r13 + Theme.accent]
    mov ecx, ATTR_BOLD
    jmp .Lfpr_tab_setpen
.Lfpr_tab_inact_act:
    mov esi, [r13 + Theme.text]
    mov edx, [r13 + Theme.surface_alt]
    mov ecx, ATTR_BOLD
    jmp .Lfpr_tab_setpen
.Lfpr_tab_inact:
    mov esi, [r13 + Theme.muted]
    mov edx, [r13 + Theme.surface]
    xor ecx, ecx
.Lfpr_tab_setpen:
    mov rdi, r12
    call ScreenBuffer_set_pen

    mov rdi, r12
    mov esi, r15d
    mov edx, [rbx + Widget.y]
    lea rcx, [rsp + 16]
    add rcx, 8
    mov r8d, 24
    call ScreenBuffer_draw_text

.LFilePane_render__draw_text_ret:
    lea rsp, [rsp + 8]
    ret

# FilePane_render step (runs on the caller's frame)
FilePane_render__part9:
    lea rsp, [rsp - 8]
    test eax, eax
    jnz .Lfpr_tz
    mov eax, ecx
.Lfpr_tz:
    mov ecx, [rbx + FilePane.tab_zone_count]
    cmp ecx, FP_TAB_MAX
    jge .Lfpr_tab_adv
    imul rdx, rcx, HitZone._size
    lea r8, [rbx + FilePane.tab_zones + rdx]
    mov word ptr [r8 + HitZone.x1], r15w
    mov edx, [rbx + Widget.y]
    mov word ptr [r8 + HitZone.y], dx
    lea edx, [r15d + eax]
    mov word ptr [r8 + HitZone.x2], dx
    mov word ptr [r8 + HitZone.id], r14w
    inc dword ptr [rbx + FilePane.tab_zone_count]
.Lfpr_tab_adv:
.LFilePane_render__part9_ret:
    lea rsp, [rsp + 8]
    ret

# FilePane_render step: Draw divider line at (runs on the caller's frame)
FilePane_render__draw_divider_line:
    lea rsp, [rsp - 8]
    mov r14, [rbx + FilePane.model]
    # 3. Draw divider line at y + 2: ├───────┤
    mov rdi, r12
    mov esi, [rsp + 160 + 16]
    mov edx, [r13 + Theme.surface]
    xor ecx, ecx
    call ScreenBuffer_set_pen

    mov rdi, r12
    mov esi, [rbx + Widget.x]
    mov edx, [rbx + Widget.y]
    add edx, 2
    mov ecx, CH_BOX_LT
    call ScreenBuffer_set_cell_pen

    mov rdi, r12
    mov esi, [rbx + Widget.x]
    inc esi
    mov edx, [rbx + Widget.y]
    add edx, 2
    mov ecx, [rbx + Widget.w]
    sub ecx, 2
    mov r8d, CH_BOX_H
    call ScreenBuffer_draw_hline

    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, [rbx + Widget.w]
    dec esi
    mov edx, [rbx + Widget.y]
    add edx, 2
    mov ecx, CH_BOX_RT
    call ScreenBuffer_set_cell_pen

.LFilePane_render__draw_divider_line_ret:
    lea rsp, [rsp + 8]
    ret

# FilePane_render step: Name header (runs on the caller's frame)
FilePane_render__name_header:
    lea rsp, [rsp - 8]
    mov esi, [r13 + Theme.muted]
    mov edx, [r13 + Theme.surface]
    mov ecx, ATTR_BOLD
    cmp dword ptr [r14 + DirModel.sort_mode], SORT_NAME
    jne .Lfpr_nh_hov
    mov esi, [r13 + Theme.accent]
.Lfpr_nh_hov:
    cmp dword ptr [rbx + FilePane.hovered_col_hdr], SORT_NAME
    jne .Lfpr_nh_pen
    mov edx, [r13 + Theme.surface_alt]
    or ecx, ATTR_UNDERLINE
.Lfpr_nh_pen:
    mov rdi, r12
    call ScreenBuffer_set_pen

    call i18n_get
    mov rsi, [rax + LangStrings.fp_col_name]
    lea rdi, [rsp + 16]
    mov edx, 128
    call str_copy
    cmp dword ptr [r14 + DirModel.is_unsorted], 0
    jne .Lfpr_nh_draw
    cmp dword ptr [r14 + DirModel.sort_mode], SORT_NAME
    jne .Lfpr_nh_draw
    lea rsi, [rip + str_sort_asc]
    cmp dword ptr [r14 + DirModel.sort_desc], 0
    je .Lfpr_nh_cat
    lea rsi, [rip + str_sort_desc]
.Lfpr_nh_cat:
    lea rdi, [rsp + 16]
    mov edx, 128
    call str_cat
.Lfpr_nh_draw:
    # Draw 4 leading spaces + Name header
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    inc esi
    mov edx, [rbx + Widget.y]
    inc edx
    mov ecx, 4
    mov r8d, ' '
    call ScreenBuffer_draw_hline

    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 5
    mov edx, [rbx + Widget.y]
    inc edx
    lea rcx, [rsp + 16]
    mov r8d, [rsp + 168 + 16]
    sub r8d, 4
    call ScreenBuffer_draw_text_pad

.LFilePane_render__name_header_ret:
    lea rsp, [rsp + 8]
    ret

# FilePane_render step: draw_text_pad (runs on the caller's frame)
FilePane_render__draw_text_pad:
    lea rsp, [rsp - 8]
    mov esi, [r13 + Theme.muted]
    mov edx, [r13 + Theme.surface]
    mov ecx, ATTR_BOLD
    cmp dword ptr [r14 + DirModel.sort_mode], SORT_SIZE
    jne .Lfpr_sh_hov
    mov esi, [r13 + Theme.accent]
.Lfpr_sh_hov:
    cmp dword ptr [rbx + FilePane.hovered_col_hdr], SORT_SIZE
    jne .Lfpr_sh_pen
    mov edx, [r13 + Theme.surface_alt]
    or ecx, ATTR_UNDERLINE
.Lfpr_sh_pen:
    mov rdi, r12
    call ScreenBuffer_set_pen

    call i18n_get
    mov rsi, [rax + LangStrings.fp_col_size]
    lea rdi, [rsp + 16]
    mov edx, 128
    call str_copy
    cmp dword ptr [r14 + DirModel.is_unsorted], 0
    jne .Lfpr_sh_draw
    cmp dword ptr [r14 + DirModel.sort_mode], SORT_SIZE
    jne .Lfpr_sh_draw
    lea rsi, [rip + str_sort_asc]
    cmp dword ptr [r14 + DirModel.sort_desc], 0
    je .Lfpr_sh_cat
    lea rsi, [rip + str_sort_desc]
.Lfpr_sh_cat:
    lea rdi, [rsp + 16]
    mov edx, 128
    call str_cat
.Lfpr_sh_draw:
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    inc esi
    add esi, [rsp + 168 + 16]
    mov edx, [rbx + Widget.y]
    inc edx
    lea rcx, [rsp + 16]
    mov r8d, [rsp + 172 + 16]
    call ScreenBuffer_draw_text_pad

.LFilePane_render__draw_text_pad_ret:
    lea rsp, [rsp + 8]
    ret

# FilePane_render step (runs on the caller's frame)
FilePane_render__part13:
    lea rsp, [rsp - 8]
    mov eax, SORT_EXT
    cmp dword ptr [rsp + 180 + 16], 0
    je .Lfpr_eh_id
    mov eax, SORT_MTIME
.Lfpr_eh_id:
    mov esi, [r13 + Theme.muted]
    mov edx, [r13 + Theme.surface]
    mov ecx, ATTR_BOLD
    cmp eax, [r14 + DirModel.sort_mode]
    jne .Lfpr_eh_hov
    mov esi, [r13 + Theme.accent]
.Lfpr_eh_hov:
    cmp eax, [rbx + FilePane.hovered_col_hdr]
    jne .Lfpr_eh_pen
    mov edx, [r13 + Theme.surface_alt]
    or ecx, ATTR_UNDERLINE
.Lfpr_eh_pen:
    push rax
    mov rdi, r12
    call ScreenBuffer_set_pen
    pop rax

    push rax
    call i18n_get
    mov rcx, rax
    pop rax
    mov rsi, [rcx + LangStrings.fp_col_perm]
    cmp dword ptr [rsp + 180 + 16], 0
    je .Lfpr_eh_copy
    mov rsi, [rcx + LangStrings.fp_col_mod]
.Lfpr_eh_copy:
.LFilePane_render__part13_ret:
    lea rsp, [rsp + 8]
    ret

# FilePane_render step: leading separator space (runs on the caller's frame)
FilePane_render__leading_separator_space:
    lea rsp, [rsp - 8]
    cmp dword ptr [r14 + DirModel.is_unsorted], 0
    jne .Lfpr_eh_draw
    cmp eax, [r14 + DirModel.sort_mode]
    jne .Lfpr_eh_draw
    lea rsi, [rip + str_sort_asc]
    cmp dword ptr [r14 + DirModel.sort_desc], 0
    je .Lfpr_eh_cat
    lea rsi, [rip + str_sort_desc]
.Lfpr_eh_cat:
    lea rdi, [rsp + 16]
    mov edx, 128
    call str_cat
.Lfpr_eh_draw:
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    inc esi
    add esi, [rsp + 168 + 16]
    add esi, [rsp + 172 + 16]
    inc esi                   # leading separator space
    mov edx, [rbx + Widget.y]
    inc edx
    lea rcx, [rsp + 16]
    mov r8d, [rsp + 176 + 16]
    dec r8d
    call ScreenBuffer_draw_text_pad

.LFilePane_render__leading_separator_space_ret:
    lea rsp, [rsp + 8]
    ret

# FilePane_render step: idx (runs on the caller's frame)
FilePane_render__idx:
    lea rsp, [rsp - 8]
    mov ecx, [rbx + FilePane.scroll]
    add ecx, eax              # idx = scroll + r
    mov rdi, r14
    mov esi, ecx
    push rcx
    call DirModel_get_entry
    pop rcx                   # idx
    test rax, rax
.LFilePane_render__idx_ret:
    lea rsp, [rsp + 8]
    ret

# FilePane_render step: Compute row bg fg attrs (runs on the caller's frame)
FilePane_render__compute_row_bg_fg:
    lea rsp, [rsp - 8]
    mov r15, rax              # FileEntry *

    # Compute row bg & fg & attrs
    mov r8d, [r13 + Theme.surface]     # bg
    xor r9d, r9d                       # attrs
    mov eax, [r15 + FileEntry.flags]

    cmp ecx, [rbx + FilePane.cursor]
    jne .Lfpr_chk_hov_row
    mov r8d, [r13 + Theme.cursor_inactive_bg]
    cmp dword ptr [rsp + 164 + 16], 0
    je .Lfpr_fg_pick
    mov r8d, [r13 + Theme.cursor_active_bg]
    mov r9d, ATTR_BOLD
    jmp .Lfpr_fg_pick

.Lfpr_chk_hov_row:
    mov edx, [rsp + 188 + 16]
    cmp edx, [rbx + FilePane.hovered_row]
    jne .Lfpr_chk_sel_bg
    mov r8d, [r13 + Theme.surface_alt]
    jmp .Lfpr_fg_pick
.Lfpr_chk_sel_bg:
    test eax, FE_SELECTED
    jz .Lfpr_fg_pick
    mov r8d, [r13 + Theme.selected_bg]

.Lfpr_fg_pick:
    mov edx, [r13 + Theme.text]        # fg
    test eax, FE_SELECTED
    jz .Lfpr_fg_dir
    mov edx, [r13 + Theme.selected_fg]
    or r9d, ATTR_BOLD
    jmp .Lfpr_row_bg_fill
.Lfpr_fg_dir:
    test eax, (FE_IS_DIR | FE_LINK_DIR)
    jz .Lfpr_fg_lnk
    mov edx, [r13 + Theme.dir_fg]
    or r9d, ATTR_BOLD
    jmp .Lfpr_row_bg_fill
.Lfpr_fg_lnk:
    test eax, FE_IS_LINK
    jz .Lfpr_fg_exec
    mov edx, [r13 + Theme.link_fg]
    jmp .Lfpr_row_bg_fill
.Lfpr_fg_exec:
    test eax, FE_IS_EXEC
    jz .Lfpr_fg_hid
    mov edx, [r13 + Theme.exec_fg]
    jmp .Lfpr_row_bg_fill
.Lfpr_fg_hid:
    test eax, FE_IS_HIDDEN
    jz .Lfpr_row_bg_fill
    mov edx, [r13 + Theme.hidden_fg]

.Lfpr_row_bg_fill:
.LFilePane_render__compute_row_bg_fg_ret:
    lea rsp, [rsp + 8]
    ret

# FilePane_render step: Fill row interior with bg first (runs on the caller's frame)
FilePane_render__fill_row_interior_bg:
    lea rsp, [rsp - 8]
    mov [rsp + 192 + 16], edx  # save fg
    mov [rsp + 196 + 16], r8d  # save bg
    mov [rsp + 200 + 16], r9d  # save attrs

    mov rdi, r12
    mov esi, edx
    mov edx, r8d
    mov ecx, r9d
    call ScreenBuffer_set_pen

    mov rdi, r12
    mov esi, [rbx + Widget.x]
    inc esi
    mov edx, [rbx + Widget.y]
    add edx, 3
    add edx, [rsp + 188 + 16]
    mov ecx, [rbx + Widget.w]
    sub ecx, 2
    mov r8d, ' '
    call ScreenBuffer_draw_hline
    # Selection marker at x + 1
    mov eax, [r15 + FileEntry.flags]
    test eax, FE_SELECTED
    jz .Lfpr_draw_glyph
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    inc esi
    mov edx, [rbx + Widget.y]
    add edx, 3
    add edx, [rsp + 188 + 16]
    mov ecx, CH_CHECK
    call ScreenBuffer_set_cell_pen
.Lfpr_draw_glyph:
    mov eax, [r15 + FileEntry.flags]
    mov ecx, CH_SQ_SMALL
    test eax, FE_IS_PARENT
    jz .Lfpr_g_dir
    mov ecx, CH_LAQUO
    jmp .Lfpr_g_put
.Lfpr_g_dir:
    test eax, FE_IS_LINK
    jz .Lfpr_g_dir2
    mov ecx, CH_ARROW_NE
    jmp .Lfpr_g_put
.Lfpr_g_dir2:
    test eax, FE_IS_DIR
    jz .Lfpr_g_exec
    mov ecx, CH_TRI_RIGHT
    jmp .Lfpr_g_put
.Lfpr_g_exec:
    test eax, FE_IS_EXEC
    jz .Lfpr_g_put
    mov ecx, CH_DIAMOND
.Lfpr_g_put:
.LFilePane_render__fill_row_interior_bg_ret:
    lea rsp, [rsp + 8]
    ret

# FilePane_render step (runs on the caller's frame)
FilePane_render__part18:
    lea rsp, [rsp - 8]
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 3
    mov edx, [rbx + Widget.y]
    add edx, 3
    add edx, [rsp + 188 + 16]
    mov r8, rbx; mov r9, r15
.LFilePane_render__part18_ret:
    lea rsp, [rsp + 8]
    ret

# FilePane_render step: Filename at (runs on the caller's frame)
FilePane_render__filename:
    lea rsp, [rsp - 8]
    mov r8d, [rsp + 168 + 16]
    sub r8d, 5
    cmp r8d, 1
    jge .Lfpr_name_w_ok
    mov r8d, 1
.Lfpr_name_w_ok:
    push r8
    sub rsp, 8
    mov rdi, r14
    mov rsi, r15
    call DirModel_entry_name
    add rsp, 8
    pop r8
    mov rcx, rax
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 5
    mov edx, [rbx + Widget.y]
    add edx, 3
    add edx, [rsp + 188 + 16]
    call ScreenBuffer_draw_text

.LFilePane_render__filename_ret:
    lea rsp, [rsp + 8]
    ret

# FilePane_render step: Ellipsis if name disp_width available name_w (runs on the caller's frame)
FilePane_render__ellipsis_name_disp_width:
    lea rsp, [rsp - 8]
    movzx eax, byte ptr [r15 + FileEntry.disp_width]
    mov ecx, [rsp + 168 + 16]
    sub ecx, 5
    cmp eax, ecx
    jle .Lfpr_draw_size
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, [rsp + 168 + 16]
    mov edx, [rbx + Widget.y]
    add edx, 3
    add edx, [rsp + 188 + 16]
    mov ecx, CH_ELLIPSIS
    call ScreenBuffer_set_cell_pen

.Lfpr_draw_size:
.LFilePane_render__ellipsis_name_disp_width_ret:
    lea rsp, [rsp + 8]
    ret

# FilePane_render step: Use muted fg for size date unless on cursor selected (runs on the caller's frame)
FilePane_render__use_muted_fg_size:
    lea rsp, [rsp - 8]
    mov esi, [r13 + Theme.muted]
    test dword ptr [r15 + FileEntry.flags], FE_SELECTED
    jz .Lfpr_sz_chk_cur
    mov esi, [rsp + 192 + 16]
    jmp .Lfpr_sz_pen
.Lfpr_sz_chk_cur:
    mov eax, [rbx + FilePane.scroll]
    add eax, [rsp + 188 + 16]
    cmp eax, [rbx + FilePane.cursor]
    jne .Lfpr_sz_pen
    mov esi, [rsp + 192 + 16]
.Lfpr_sz_pen:
    mov rdi, r12
    mov edx, [rsp + 196 + 16]
    mov ecx, [rsp + 200 + 16]
    call ScreenBuffer_set_pen

    test dword ptr [r15 + FileEntry.flags], FE_IS_DIR
    jz .Lfpr_sz_fmt
    call i18n_get
    mov rsi, [rax + LangStrings.fp_dir_badge]
    lea rdi, [rsp + 128 + 16]
    mov edx, 32
    call str_copy
    jmp .Lfpr_sz_align
.Lfpr_sz_fmt:
    mov rdi, [r15 + FileEntry.size]
    lea rsi, [rsp + 128 + 16]
    call format_size

.Lfpr_sz_align:
    # Right-align size inside [x+1+name_w .. x+1+name_w+size_w-1)
    lea rdi, [rsp + 128 + 16]
    call utf8_display_width
    mov ecx, [rsp + 172 + 16]
    sub ecx, 1                # 1 space margin
    sub ecx, eax              # right shift
    jns .Lfpr_sz_draw
    xor ecx, ecx
.Lfpr_sz_draw:
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    inc esi
    add esi, [rsp + 168 + 16]
    add esi, ecx
    mov edx, [rbx + Widget.y]
    add edx, 3
    add edx, [rsp + 188 + 16]
    lea rcx, [rsp + 128 + 16]
    mov r8d, [rsp + 172 + 16]
    call ScreenBuffer_draw_text

.LFilePane_render__use_muted_fg_size_ret:
    lea rsp, [rsp + 8]
    ret

# FilePane_render step: Extra column (runs on the caller's frame)
FilePane_render__extra_column:
    lea rsp, [rsp - 8]
    cmp dword ptr [rsp + 176 + 16], 0
    je .LFilePane_render__extra_column_ret

    test dword ptr [r15 + FileEntry.flags], FE_IS_PARENT
    jnz .LFilePane_render__extra_column_ret

    cmp dword ptr [rsp + 180 + 16], 0
    je .Lfpr_ex_perms
    mov rdi, [r15 + FileEntry.mtime]
    lea rsi, [rsp + 128 + 16]
    call format_datetime
    jmp .Lfpr_ex_draw
.Lfpr_ex_perms:
    mov edi, [r15 + FileEntry.mode]
    lea rsi, [rsp + 128 + 16]
    call format_perms

.Lfpr_ex_draw:
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    inc esi
    add esi, [rsp + 168 + 16]
    add esi, [rsp + 172 + 16]
    inc esi
    mov edx, [rbx + Widget.y]
    add edx, 3
    add edx, [rsp + 188 + 16]
    lea rcx, [rsp + 128 + 16]
    mov r8d, [rsp + 176 + 16]
    dec r8d
    call ScreenBuffer_draw_text

.LFilePane_render__extra_column_ret:
    lea rsp, [rsp + 8]
    ret

# FilePane_render step: thumb_h (runs on the caller's frame)
FilePane_render__thumb_h:
    lea rsp, [rsp - 8]
    mov rax, [r14 + DirModel.count]
    mov r8d, eax              # count
    mov eax, ecx
    imul eax, ecx
    xor edx, edx
    div r8d                   # thumb_h
    cmp eax, 1
    jge .Lfpr_th_ok
    mov eax, 1
.Lfpr_th_ok:
    mov r9d, eax              # thumb_h
    # thumb_pos = (scroll * (list_h - thumb_h)) / max(1, count - list_h)
    mov r10d, ecx
    sub r10d, r9d             # travel
    mov eax, [rbx + FilePane.scroll]
    imul eax, r10d
    mov r11d, r8d
    sub r11d, ecx             # max_scroll
    cmp r11d, 1
    jge .Lfpr_ms_ok
    mov r11d, 1
.Lfpr_ms_ok:
    xor edx, edx
    div r11d                  # eax = thumb_start
    mov [rsp + 208 + 16], eax # thumb_start/end live in the frame: the draw calls clobber r8-r10
    add eax, r9d
    mov [rsp + 212 + 16], eax # thumb_end
    # Draw scrollbar rows
    xor r15d, r15d            # r = 0..list_h-1
.Lfpr_sb_loop:
    cmp r15d, [rsp + 184 + 16]
    jge .LFilePane_render__thumb_h_ret
    mov esi, [r13 + Theme.scroll_track]
    mov ecx, CH_SHADE_LIGHT
    cmp r15d, [rsp + 208 + 16]
    jl .Lfpr_sb_draw
    cmp r15d, [rsp + 212 + 16]
    jge .Lfpr_sb_draw
    mov esi, [r13 + Theme.scroll_thumb]
    mov ecx, CH_BLOCK_FULL
.Lfpr_sb_draw:
    mov [rsp + 216 + 16], ecx # glyph survives the call (and the call site stays 16-byte aligned)
    mov rdi, r12
    mov edx, [r13 + Theme.surface]
    xor ecx, ecx
    call ScreenBuffer_set_pen
    mov ecx, [rsp + 216 + 16]

    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, [rbx + Widget.w]
    dec esi
    mov edx, [rbx + Widget.y]
    add edx, 3
    add edx, r15d
    call ScreenBuffer_set_cell_pen
    inc r15d
    jmp .Lfpr_sb_loop

.LFilePane_render__thumb_h_ret:
    lea rsp, [rsp + 8]
    ret

# FilePane_render step (runs on the caller's frame)
FilePane_render__part24:
    lea rsp, [rsp - 8]
    call i18n_get
    mov rsi, [rax + LangStrings.fp_sel_pfx]
    lea rdi, [rsp + 16]
    add rdi, 8                # line buf at [rsp] before push -> [rsp+8]
    mov edx, 128
    call str_copy
.LFilePane_render__part24_ret:
    lea rsp, [rsp + 8]
    ret

# FilePane_render step: sel_bytes (runs on the caller's frame)
FilePane_render__sel_bytes:
    lea rsp, [rsp - 8]
    lea rsi, [rsp + 160 + 16]
    call u64_to_dec
    lea rdi, [rsp + 16]
    lea rsi, [rsp + 160 + 16]
    mov edx, 128
    call str_cat
    call i18n_get
    mov rsi, [rax + LangStrings.fp_sel_mid]
    lea rdi, [rsp + 16]
    mov edx, 128
    call str_cat
    mov rdi, [rsp + 128 + 16]  # sel_bytes
    lea rsi, [rsp + 160 + 16]
    call format_size
    lea rdi, [rsp + 16]
    lea rsi, [rsp + 160 + 16]
    mov edx, 128
    call str_cat
    call i18n_get
    mov rsi, [rax + LangStrings.fp_sel_end]
    lea rdi, [rsp + 16]
    mov edx, 128
    call str_cat

.LFilePane_render__sel_bytes_ret:
    lea rsp, [rsp + 8]
    ret

# FilePane_render step: format_size (runs on the caller's frame)
FilePane_render__format_size:
    lea rsp, [rsp - 8]
    mov byte ptr [rsp + 16], ' '
    mov byte ptr [rsp + 1 + 16], 0
    mov edi, [r14 + DirModel.dir_count]
    lea rsi, [rsp + 128 + 16]
    call u64_to_dec
    lea rdi, [rsp + 16]
    lea rsi, [rsp + 128 + 16]
    mov edx, 128
    call str_cat
    call i18n_get
    mov rsi, [rax + LangStrings.fp_sum_dirs]
    lea rdi, [rsp + 16]
    mov edx, 128
    call str_cat
    mov edi, [r14 + DirModel.file_count]
    lea rsi, [rsp + 128 + 16]
    call u64_to_dec
    lea rdi, [rsp + 16]
    lea rsi, [rsp + 128 + 16]
    mov edx, 128
    call str_cat
    call i18n_get
    mov rsi, [rax + LangStrings.fp_sum_files]
    lea rdi, [rsp + 16]
    mov edx, 128
    call str_cat
    mov rdi, [r14 + DirModel.total_bytes]
    lea rsi, [rsp + 128 + 16]
    call format_size
    lea rdi, [rsp + 16]
    lea rsi, [rsp + 128 + 16]
    mov edx, 128
    call str_cat

.LFilePane_render__format_size_ret:
    lea rsp, [rsp + 8]
    ret

# FilePane_render step: Append streaming counter Esc aborted badge or ls badge (runs on the caller's frame)
FilePane_render__append_streaming_counter_esc:
    lea rsp, [rsp - 8]
    cmp dword ptr [r14 + DirModel.is_loading], 0
    je .Lfpr_chk_aborted
    call i18n_get
    mov rsi, [rax + LangStrings.fp_loading_pfx]
    lea rdi, [rsp + 16]
    mov edx, 128
    call str_cat
    mov rdi, [r14 + DirModel.raw_count]
    lea rsi, [rsp + 128 + 16]
    call u64_to_dec
    lea rdi, [rsp + 16]
    lea rsi, [rsp + 128 + 16]
    mov edx, 128
    call str_cat
    jmp .Lfpr_foot_pen

.Lfpr_chk_aborted:
    cmp dword ptr [r14 + DirModel.load_aborted], 0
    je .Lfpr_chk_huge
    call i18n_get
    mov rsi, [rax + LangStrings.fp_abort_badge]
    lea rdi, [rsp + 16]
    mov edx, 128
    call str_cat
    jmp .Lfpr_foot_pen

.Lfpr_chk_huge:
    cmp dword ptr [r14 + DirModel.huge_mode], 0
    je .Lfpr_foot_pen
    cmp dword ptr [r14 + DirModel.is_unsorted], 0
    je .Lfpr_foot_pen
    call i18n_get
    mov rsi, [rax + LangStrings.fp_huge_badge]
    lea rdi, [rsp + 16]
    mov edx, 128
    call str_cat

.Lfpr_foot_pen:
    mov rdi, r12
    mov esi, [r13 + Theme.muted]
    mov edx, [r13 + Theme.surface]
    xor ecx, ecx
    call ScreenBuffer_set_pen

.LFilePane_render__append_streaming_counter_esc_ret:
    lea rsp, [rsp + 8]
    ret

# FilePane_render step: Filter badge on bottom border if filter active (runs on the caller's frame)
FilePane_render__filter_badge_bottom_border:
    lea rsp, [rsp - 8]
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    inc esi
    mov edx, [rbx + Widget.y]
    add edx, [rbx + Widget.h]
    sub edx, 2
    lea rcx, [rsp + 16]
    mov r8d, [rbx + Widget.w]
    sub r8d, 2
    call ScreenBuffer_draw_text_pad

    # Filter badge on bottom border if filter active
    cmp byte ptr [r14 + DirModel.filter], 0
    je .LFilePane_render__filter_badge_bottom_border_ret
    call i18n_get
    mov rsi, [rax + LangStrings.fp_flt_tag]
    lea rdi, [rsp + 16]
    mov edx, 128
    call str_copy
    lea rdi, [rsp + 16]
    lea rsi, [r14 + DirModel.filter]
    mov edx, 128
    call str_cat
    lea rdi, [rsp + 16]
    call str_len
    cmp eax, 126
    jae .Lfpr_flt_draw
    mov byte ptr [rsp + rax + 16], ' '
    mov byte ptr [rsp + rax + 1 + 16], 0
.Lfpr_flt_draw:
    mov rdi, r12
    mov esi, [r13 + Theme.accent_fg]
    mov edx, [r13 + Theme.warn_fg]
    mov ecx, ATTR_BOLD
    call ScreenBuffer_set_pen

    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 2
    mov edx, [rbx + Widget.y]
    add edx, [rbx + Widget.h]
    dec edx
    lea rcx, [rsp + 16]
    mov r8d, [rbx + Widget.w]
    sub r8d, 4
    call ScreenBuffer_draw_text

.LFilePane_render__filter_badge_bottom_border_ret:
    lea rsp, [rsp + 8]
    ret
