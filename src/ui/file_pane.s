# FilePane Widget (Inherits from Widget)
# Full-featured file list panel: TrueColor styling, adaptive columns, interactive
# column-header sorting, double-click open, right-click mark, wheel & drag scrollbar.

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
str_FilePane:    .asciz "FilePane"
str_home_env:    .asciz "HOME"
str_dotdot_fp:   .asciz ".."
str_ellip_pfx:   .asciz "…"
str_sort_asc:    .asciz " ▲"
str_sort_desc:   .asciz " ▼"

.global FilePane_vtbl
FilePane_vtbl:
    WIDGET_VTBL_SLOTS str_FilePane, Widget_vtbl, FilePane._size, FilePane_dtor, FilePane_layout, FilePane_render, FilePane_on_key, FilePane_on_mouse, Widget_on_focus, Widget_hit_test

.section .text
.global FilePane_new
.global FilePane_dtor
.global FilePane_layout
.global FilePane_render
.global FilePane_on_key
.global FilePane_on_mouse
.global FilePane_ensure_visible
.global FilePane_get_selected_entry
.global FilePane_reload_keep_cursor
.global FilePane_enter_parent
.global FilePane_nav_to
.global FilePane_hist_back
.global FilePane_hist_fwd
.global FilePane_tab_new
.global FilePane_tab_close
.global FilePane_tab_switch

# FilePane *FilePane_new(App *app, const char *initial_path, int id)
FilePane_new:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rdi              # app
    mov r13, rsi              # initial_path
    mov r14d, edx             # id

    NEW_OBJ FilePane_vtbl, FilePane._size
    test rax, rax
    jz .Lfpn_fail
    mov rbx, rax

    mov rdi, rbx
    mov rsi, r12
    mov edx, r14d
    call Widget_init

    mov [rbx + FilePane.app], r12
    mov dword ptr [rbx + FilePane.last_click_idx], -1
    mov dword ptr [rbx + FilePane.hovered_row], -1
    mov dword ptr [rbx + FilePane.hovered_col_hdr], -1

    mov rdi, r13
    call DirModel_new
    test rax, rax
    jz .Lfpn_fail_free
    mov [rbx + FilePane.model], rax

    lea rdi, [rax + DirModel.path]
    call nav_tabs_alloc
    mov [rbx + FilePane.tabs], rax
    mov dword ptr [rbx + FilePane.tab_count], 1
    mov dword ptr [rbx + FilePane.active_tab], 0

    mov rax, rbx
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.Lfpn_fail_free:
    mov rdi, rbx
    call mem_free
.Lfpn_fail:
    xor eax, eax
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# void FilePane_dtor(FilePane *this)
FilePane_dtor:
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + FilePane.tabs]
    mov esi, [rbx + FilePane.tab_count]
    call nav_tabs_free
    mov qword ptr [rbx + FilePane.tabs], 0
    mov rdi, [rbx + FilePane.model]
    DELETE_OBJ rdi
    mov qword ptr [rbx + FilePane.model], 0
    pop rbx
    ret

# Helper: int get_list_h(FilePane *this)
get_list_h:
    mov eax, [rdi + Widget.h]
    sub eax, 5
    cmp eax, 1
    jge .Lglh_ok
    mov eax, 1
.Lglh_ok:
    ret

# void FilePane_ensure_visible(FilePane *this)
FilePane_ensure_visible:
    mov rcx, [rdi + FilePane.model]
    mov rdx, [rcx + DirModel.count]
    test rdx, rdx
    jnz .Lfev_nonempty
    mov dword ptr [rdi + FilePane.cursor], 0
    mov dword ptr [rdi + FilePane.scroll], 0
    ret
.Lfev_nonempty:
    mov eax, [rdi + FilePane.cursor]
    test eax, eax
    jns .Lfev_c_nonneg
    xor eax, eax
.Lfev_c_nonneg:
    cmp rax, rdx
    jb .Lfev_c_ok
    lea eax, [edx - 1]
.Lfev_c_ok:
    mov [rdi + FilePane.cursor], eax

    call get_list_h           # eax = list_h
    mov r8d, eax
    mov eax, [rdi + FilePane.cursor]
    mov r9d, [rdi + FilePane.scroll]

    cmp eax, r9d
    jge .Lfev_chk_bot
    mov r9d, eax
    jmp .Lfev_clamp_scroll
.Lfev_chk_bot:
    lea r10d, [r9d + r8d]
    cmp eax, r10d
    jl .Lfev_clamp_scroll
    mov r9d, eax
    sub r9d, r8d
    inc r9d
.Lfev_clamp_scroll:
    # Clamp scroll <= max(0, count - list_h)
    mov eax, edx
    sub eax, r8d
    test eax, eax
    jns .Lfev_max_ok
    xor eax, eax
.Lfev_max_ok:
    cmp r9d, eax
    jle .Lfev_s_nonneg
    mov r9d, eax
.Lfev_s_nonneg:
    test r9d, r9d
    jns .Lfev_done
    xor r9d, r9d
.Lfev_done:
    mov [rdi + FilePane.scroll], r9d
    ret

# FileEntry *FilePane_get_selected_entry(FilePane *this)
FilePane_get_selected_entry:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, [rdi + FilePane.model]
    mov esi, [rdi + FilePane.cursor]
    mov rdi, rbx
    call DirModel_get_entry
    test rax, rax
    jz .Lfpge_done
    mov r12, rax
    mov rdi, rbx
    mov rsi, r12
    call DirModel_ensure_entry_stat
    mov rax, r12
.Lfpge_done:
    add rsp, 8
    pop r12
    pop rbx
    ret

# void FilePane_reload_keep_cursor(FilePane *this, const char *focus_name_or_null)
FilePane_reload_keep_cursor:
    push rbx
    push r12
    sub rsp, NAME_MAX + 16
    mov rbx, rdi
    mov r12, rsi

    test r12, r12
    jnz .Lfrkc_have_name
    mov rdi, rbx
    call FilePane_get_selected_entry
    test rax, rax
    jz .Lfrkc_reload
    mov rdi, [rbx + FilePane.model]
    mov rsi, rax
    call DirModel_entry_name
    mov rdi, rsp
    mov rsi, rax
    mov edx, NAME_MAX
    call str_copy
    mov r12, rsp
    jmp .Lfrkc_reload

.Lfrkc_have_name:
    mov rdi, rsp
    mov rsi, r12
    mov edx, NAME_MAX
    call str_copy
    mov r12, rsp

.Lfrkc_reload:
    mov rdi, [rbx + FilePane.model]
    call DirModel_reload

    test r12, r12
    jz .Lfrkc_vis
    mov rdi, [rbx + FilePane.model]
    mov rsi, r12
    call DirModel_find_by_name
    cmp rax, 0
    jl .Lfrkc_vis
    mov [rbx + FilePane.cursor], eax

.Lfrkc_vis:
    mov rdi, rbx
    call FilePane_ensure_visible
    add rsp, NAME_MAX + 16
    pop r12
    pop rbx
    ret

# void FilePane_enter_parent(FilePane *this)
# Navigates to parent directory and selects the child directory we just came from.
FilePane_enter_parent:
    push rbx
    sub rsp, NAME_MAX + 16
    mov rbx, rdi
    call fp_exit_virtual
    test eax, eax
    jnz .Lfep_done
    mov rcx, [rbx + FilePane.model]
    lea rdi, [rcx + DirModel.path]
    cmp byte ptr [rdi], '/'
    jne .Lfep_go
    cmp byte ptr [rdi + 1], 0
    je .Lfep_done             # already at root "/"

.Lfep_go:
    call path_basename
    mov rdi, rsp
    mov rsi, rax
    mov edx, NAME_MAX
    call str_copy

    mov rdi, [rbx + FilePane.model]
    lea rsi, [rip + str_dotdot_fp]
    call DirModel_chdir
    test rax, rax
    js .Lfep_done

    mov rdi, [rbx + FilePane.model]
    mov rsi, rsp
    call DirModel_find_by_name
    cmp rax, 0
    jge .Lfep_set_cur
    xor eax, eax
.Lfep_set_cur:
    mov [rbx + FilePane.cursor], eax
    mov dword ptr [rbx + FilePane.scroll], 0
    mov rdi, rbx
    call FilePane_ensure_visible

    mov rdi, rbx
    call fp_get_active_tab
    test rax, rax
    jz .Lfep_done
    mov rdi, rax
    mov rcx, [rbx + FilePane.model]
    lea rsi, [rcx + DirModel.path]
    push rsi
    call nav_hist_push
    pop rdi
    call nav_frecency_record
.Lfep_done:
    add rsp, NAME_MAX + 16
    pop rbx
    ret

# Helper: compute adaptive column layout into r8d=name_w, r9d=size_w, r10d=extra_w, r11d=extra_is_date(1)/perm(0)
compute_cols:
    mov eax, [rdi + Widget.w]
    sub eax, 2                # inner width
    cmp eax, 1
    jge .Lcc_ok
    mov eax, 1
.Lcc_ok:
    xor r9d, r9d              # size_w
    xor r10d, r10d            # extra_w
    xor r11d, r11d            # extra_is_date

    cmp dword ptr [rdi + Widget.w], 54
    jl .Lcc_chk_med
    mov r9d, 9
    mov r10d, 17              # 1 space + 16 date
    mov r11d, 1
    jmp .Lcc_name
.Lcc_chk_med:
    cmp dword ptr [rdi + Widget.w], 40
    jl .Lcc_chk_sm
    mov r9d, 9
    mov r10d, 11              # 1 space + 10 perms
    jmp .Lcc_name
.Lcc_chk_sm:
    cmp dword ptr [rdi + Widget.w], 28
    jl .Lcc_name
    mov r9d, 9
.Lcc_name:
    mov r8d, eax
    sub r8d, r9d
    sub r8d, r10d
    cmp r8d, 6
    jge .Lcc_ret
    mov r8d, eax
    xor r9d, r9d
    xor r10d, r10d
.Lcc_ret:
    ret

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
    xor eax, eax
    test dword ptr [rbx + Widget.flags], WF_FOCUSED
    setnz al
    mov [rsp + 164], eax
    mov ecx, [r13 + Theme.border_inactive]
    test eax, eax
    jz .Lfpr_bcol
    mov ecx, [r13 + Theme.border_active]
.Lfpr_bcol:
    mov [rsp + 160], ecx

    # Compute column widths
    mov rdi, rbx
    call compute_cols
    mov [rsp + 168], r8d
    mov [rsp + 172], r9d
    mov [rsp + 176], r10d
    mov [rsp + 180], r11d

    mov rdi, rbx
    call get_list_h
    mov [rsp + 184], eax

    # 1. Draw rounded box + surface fill
    mov rdi, r12
    mov esi, [rsp + 160]
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

    # 2. Draw top path title pill (or tab strip when tab_count > 1)
    mov dword ptr [rbx + FilePane.tab_zone_count], 0
    cmp dword ptr [rbx + FilePane.tab_count], 1
    jg .Lfpr_draw_tabs

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
    mov byte ptr [rsp], ' '
    mov byte ptr [rsp + 1], 0
    cmp eax, ecx
    jbe .Lfpr_path_full
    # Take tail of length (ecx - 1)
    mov rdi, rsp
    lea rsi, [rip + str_ellip_pfx]
    mov edx, 128
    call str_cat
    mov rdx, rax              # wait, call str_len(r15) again cleanly
    mov rdi, r15
    call str_len
    sub eax, ecx
    inc eax
    lea rsi, [r15 + rax]
    mov rdi, rsp
    mov edx, 128
    call str_cat
    jmp .Lfpr_path_tail
.Lfpr_path_full:
    mov rdi, rsp
    mov rsi, r15
    mov edx, 128
    call str_cat
.Lfpr_path_tail:
    # Append trailing space
    mov rdi, rsp
    call str_len
    cmp eax, 126
    jae .Lfpr_path_pen
    mov byte ptr [rsp + rax], ' '
    mov byte ptr [rsp + rax + 1], 0

.Lfpr_path_pen:
    mov rdi, r12
    mov esi, [r13 + Theme.border_inactive]
    mov edx, [r13 + Theme.surface_alt]
    xor ecx, ecx
    cmp dword ptr [rsp + 164], 0
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
    mov rcx, rsp
    mov r8d, [rbx + Widget.w]
    sub r8d, 8
    call ScreenBuffer_draw_text
    mov rdi, rbx
    mov rsi, r12
    call fp_draw_search_badge
    jmp .Lfpr_divider

.Lfpr_draw_tabs:
    # Sync active tab path first
    mov rdi, rbx
    call fp_get_active_tab
    test rax, rax
    jz .Lfpr_divider
    mov rdi, rax
    mov rcx, [rbx + FilePane.model]
    lea rsi, [rcx + DirModel.path]
    mov edx, PATH_MAX
    call str_copy

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
    mov byte ptr [rsp], '['
    lea eax, [r14d + '1']
    mov [rsp + 1], al
    mov byte ptr [rsp + 2], ':'
    mov byte ptr [rsp + 3], 0

    mov rcx, [rbx + FilePane.tabs]
    imul rax, r14, FP_TAB_SIZE
    lea rdi, [rcx + rax + FP_TAB_PATH]
    call path_basename
    test rax, rax
    jz .Lfpr_tab_noname
    cmp byte ptr [rax], 0
    jne .Lfpr_tab_cat
.Lfpr_tab_noname:
    mov byte ptr [rsp + 3], '/'
    mov byte ptr [rsp + 4], 0
    jmp .Lfpr_tab_close_br
.Lfpr_tab_cat:
    lea rdi, [rsp]
    mov rsi, rax
    mov edx, 22
    call str_cat
.Lfpr_tab_close_br:
    mov rdi, rsp
    call str_len
    cmp eax, 125
    jae .Lfpr_tab_pen
    mov byte ptr [rsp + rax], ']'
    mov byte ptr [rsp + rax + 1], 0
    inc eax
.Lfpr_tab_pen:
    push rax                  # tab display width (approx byte len)
    cmp r14d, [rbx + FilePane.active_tab]
    jne .Lfpr_tab_inact
    cmp dword ptr [rsp + 164 + 8], 0
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
    mov rcx, rsp
    add rcx, 8
    mov r8d, 24
    call ScreenBuffer_draw_text

    # Measure actual utf8 display width for HitZone
    lea rdi, [rsp + 8]
    call utf8_display_width
    pop rcx
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
    add r15d, eax
    inc r15d                  # 1 space gap
    inc r14d
    jmp .Lfpr_tab_loop

.Lfpr_divider:
    mov r14, [rbx + FilePane.model]
    # 3. Draw divider line at y + 2: ├───────┤
    mov rdi, r12
    mov esi, [rsp + 160]
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

    # 4. Draw column headers on row y + 1
    # Name header
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
    mov rdi, rsp
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
    mov rdi, rsp
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
    mov rcx, rsp
    mov r8d, [rsp + 168]
    sub r8d, 4
    call ScreenBuffer_draw_text_pad

    # Size header if size_w > 0
    cmp dword ptr [rsp + 172], 0
    je .Lfpr_rows_start

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
    mov rdi, rsp
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
    mov rdi, rsp
    mov edx, 128
    call str_cat
.Lfpr_sh_draw:
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    inc esi
    add esi, [rsp + 168]
    mov edx, [rbx + Widget.y]
    inc edx
    mov rcx, rsp
    mov r8d, [rsp + 172]
    call ScreenBuffer_draw_text_pad

    # Extra header (Modified or Perms)
    cmp dword ptr [rsp + 176], 0
    je .Lfpr_rows_start

    mov eax, SORT_EXT
    cmp dword ptr [rsp + 180], 0
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
    cmp dword ptr [rsp + 180], 0
    je .Lfpr_eh_copy
    mov rsi, [rcx + LangStrings.fp_col_mod]
.Lfpr_eh_copy:
    push rax
    mov rdi, rsp
    add rdi, 8
    mov edx, 128
    call str_copy
    pop rax
    cmp dword ptr [r14 + DirModel.is_unsorted], 0
    jne .Lfpr_eh_draw
    cmp eax, [r14 + DirModel.sort_mode]
    jne .Lfpr_eh_draw
    lea rsi, [rip + str_sort_asc]
    cmp dword ptr [r14 + DirModel.sort_desc], 0
    je .Lfpr_eh_cat
    lea rsi, [rip + str_sort_desc]
.Lfpr_eh_cat:
    mov rdi, rsp
    mov edx, 128
    call str_cat
.Lfpr_eh_draw:
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    inc esi
    add esi, [rsp + 168]
    add esi, [rsp + 172]
    inc esi                   # leading separator space
    mov edx, [rbx + Widget.y]
    inc edx
    mov rcx, rsp
    mov r8d, [rsp + 176]
    dec r8d
    call ScreenBuffer_draw_text_pad

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

    mov ecx, [rbx + FilePane.scroll]
    add ecx, eax              # idx = scroll + r
    mov rdi, r14
    mov esi, ecx
    push rcx
    call DirModel_get_entry
    pop rcx                   # idx
    test rax, rax
    jz .Lfpr_row_next
    mov r15, rax              # FileEntry *

    # Compute row bg & fg & attrs
    mov r8d, [r13 + Theme.surface]     # bg
    xor r9d, r9d                       # attrs
    mov eax, [r15 + FileEntry.flags]

    cmp ecx, [rbx + FilePane.cursor]
    jne .Lfpr_chk_hov_row
    mov r8d, [r13 + Theme.cursor_inactive_bg]
    cmp dword ptr [rsp + 164], 0
    je .Lfpr_fg_pick
    mov r8d, [r13 + Theme.cursor_active_bg]
    mov r9d, ATTR_BOLD
    jmp .Lfpr_fg_pick

.Lfpr_chk_hov_row:
    mov edx, [rsp + 188]
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
    # Fill row interior with bg first
    mov [rsp + 192], edx      # save fg
    mov [rsp + 196], r8d      # save bg
    mov [rsp + 200], r9d      # save attrs

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
    add edx, [rsp + 188]
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
    add edx, [rsp + 188]
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
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 3
    mov edx, [rbx + Widget.y]
    add edx, 3
    add edx, [rsp + 188]
    mov r8, rbx; mov r9, r15
    mov eax, [rsp + 196]; push rax; push r13
    call fp_draw_glyph_and_git
    add rsp, 16
    # Filename at x + 5 (max width = name_w - 4)
    mov r8d, [rsp + 168]
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
    add edx, [rsp + 188]
    call ScreenBuffer_draw_text

    # Ellipsis if name disp_width > available name_w - 5
    movzx eax, byte ptr [r15 + FileEntry.disp_width]
    mov ecx, [rsp + 168]
    sub ecx, 5
    cmp eax, ecx
    jle .Lfpr_draw_size
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, [rsp + 168]
    mov edx, [rbx + Widget.y]
    add edx, 3
    add edx, [rsp + 188]
    mov ecx, CH_ELLIPSIS
    call ScreenBuffer_set_cell_pen

.Lfpr_draw_size:
    cmp dword ptr [rsp + 172], 0
    je .Lfpr_row_next

    # Use muted fg for size/date unless on cursor/selected
    mov esi, [r13 + Theme.muted]
    test dword ptr [r15 + FileEntry.flags], FE_SELECTED
    jz .Lfpr_sz_chk_cur
    mov esi, [rsp + 192]
    jmp .Lfpr_sz_pen
.Lfpr_sz_chk_cur:
    mov eax, [rbx + FilePane.scroll]
    add eax, [rsp + 188]
    cmp eax, [rbx + FilePane.cursor]
    jne .Lfpr_sz_pen
    mov esi, [rsp + 192]
.Lfpr_sz_pen:
    mov rdi, r12
    mov edx, [rsp + 196]
    mov ecx, [rsp + 200]
    call ScreenBuffer_set_pen

    test dword ptr [r15 + FileEntry.flags], FE_IS_DIR
    jz .Lfpr_sz_fmt
    call i18n_get
    mov rsi, [rax + LangStrings.fp_dir_badge]
    lea rdi, [rsp + 128]
    mov edx, 32
    call str_copy
    jmp .Lfpr_sz_align
.Lfpr_sz_fmt:
    mov rdi, [r15 + FileEntry.size]
    lea rsi, [rsp + 128]
    call format_size

.Lfpr_sz_align:
    # Right-align size inside [x+1+name_w .. x+1+name_w+size_w-1)
    lea rdi, [rsp + 128]
    call utf8_display_width
    mov ecx, [rsp + 172]
    sub ecx, 1                # 1 space margin
    sub ecx, eax              # right shift
    jns .Lfpr_sz_draw
    xor ecx, ecx
.Lfpr_sz_draw:
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    inc esi
    add esi, [rsp + 168]
    add esi, ecx
    mov edx, [rbx + Widget.y]
    add edx, 3
    add edx, [rsp + 188]
    lea rcx, [rsp + 128]
    mov r8d, [rsp + 172]
    call ScreenBuffer_draw_text

    # Extra column (Modified or Perms)
    cmp dword ptr [rsp + 176], 0
    je .Lfpr_row_next

    test dword ptr [r15 + FileEntry.flags], FE_IS_PARENT
    jnz .Lfpr_row_next

    cmp dword ptr [rsp + 180], 0
    je .Lfpr_ex_perms
    mov rdi, [r15 + FileEntry.mtime]
    lea rsi, [rsp + 128]
    call format_datetime
    jmp .Lfpr_ex_draw
.Lfpr_ex_perms:
    mov edi, [r15 + FileEntry.mode]
    lea rsi, [rsp + 128]
    call format_perms

.Lfpr_ex_draw:
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    inc esi
    add esi, [rsp + 168]
    add esi, [rsp + 172]
    inc esi
    mov edx, [rbx + Widget.y]
    add edx, 3
    add edx, [rsp + 188]
    lea rcx, [rsp + 128]
    mov r8d, [rsp + 176]
    dec r8d
    call ScreenBuffer_draw_text

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
    mov r10d, eax
    lea r11d, [r10d + r9d]    # thumb_end

    # Draw scrollbar rows
    xor r15d, r15d            # r = 0..list_h-1
.Lfpr_sb_loop:
    cmp r15d, [rsp + 184]
    jge .Lfpr_footer
    mov esi, [r13 + Theme.scroll_track]
    mov ecx, CH_SHADE_LIGHT
    cmp r15d, r10d
    jl .Lfpr_sb_draw
    cmp r15d, r11d
    jge .Lfpr_sb_draw
    mov esi, [r13 + Theme.scroll_thumb]
    mov ecx, CH_BLOCK_FULL
.Lfpr_sb_draw:
    push rcx
    mov rdi, r12
    mov edx, [r13 + Theme.surface]
    xor ecx, ecx
    call ScreenBuffer_set_pen
    pop rcx

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

    # 7. Footer summary row (y + h - 2)
.Lfpr_footer:
    mov rdi, r14
    lea rsi, [rsp + 128]      # out_bytes (8B)
    call DirModel_count_selected
    test rax, rax
    jz .Lfpr_foot_totals

    # " ✓ <N> selected (<size>)"
    push rax
    call i18n_get
    mov rsi, [rax + LangStrings.fp_sel_pfx]
    mov rdi, rsp
    add rdi, 8                # line buf at [rsp] before push -> [rsp+8]
    mov edx, 128
    call str_copy
    pop rdi                   # sel count
    lea rsi, [rsp + 160]
    call u64_to_dec
    mov rdi, rsp
    lea rsi, [rsp + 160]
    mov edx, 128
    call str_cat
    call i18n_get
    mov rsi, [rax + LangStrings.fp_sel_mid]
    mov rdi, rsp
    mov edx, 128
    call str_cat
    mov rdi, [rsp + 128]      # sel_bytes
    lea rsi, [rsp + 160]
    call format_size
    mov rdi, rsp
    lea rsi, [rsp + 160]
    mov edx, 128
    call str_cat
    call i18n_get
    mov rsi, [rax + LangStrings.fp_sel_end]
    mov rdi, rsp
    mov edx, 128
    call str_cat

    mov rdi, r12
    mov esi, [r13 + Theme.selected_fg]
    mov edx, [r13 + Theme.surface]
    mov ecx, ATTR_BOLD
    call ScreenBuffer_set_pen
    jmp .Lfpr_foot_draw

.Lfpr_foot_totals:
    mov byte ptr [rsp], ' '
    mov byte ptr [rsp + 1], 0
    mov edi, [r14 + DirModel.dir_count]
    lea rsi, [rsp + 128]
    call u64_to_dec
    mov rdi, rsp
    lea rsi, [rsp + 128]
    mov edx, 128
    call str_cat
    call i18n_get
    mov rsi, [rax + LangStrings.fp_sum_dirs]
    mov rdi, rsp
    mov edx, 128
    call str_cat
    mov edi, [r14 + DirModel.file_count]
    lea rsi, [rsp + 128]
    call u64_to_dec
    mov rdi, rsp
    lea rsi, [rsp + 128]
    mov edx, 128
    call str_cat
    call i18n_get
    mov rsi, [rax + LangStrings.fp_sum_files]
    mov rdi, rsp
    mov edx, 128
    call str_cat
    mov rdi, [r14 + DirModel.total_bytes]
    lea rsi, [rsp + 128]
    call format_size
    mov rdi, rsp
    lea rsi, [rsp + 128]
    mov edx, 128
    call str_cat

    # Append streaming counter, Esc-aborted badge, or ls -f [FS-order] badge
    cmp dword ptr [r14 + DirModel.is_loading], 0
    je .Lfpr_chk_aborted
    call i18n_get
    mov rsi, [rax + LangStrings.fp_loading_pfx]
    mov rdi, rsp
    mov edx, 128
    call str_cat
    mov rdi, [r14 + DirModel.raw_count]
    lea rsi, [rsp + 128]
    call u64_to_dec
    mov rdi, rsp
    lea rsi, [rsp + 128]
    mov edx, 128
    call str_cat
    jmp .Lfpr_foot_pen

.Lfpr_chk_aborted:
    cmp dword ptr [r14 + DirModel.load_aborted], 0
    je .Lfpr_chk_huge
    call i18n_get
    mov rsi, [rax + LangStrings.fp_abort_badge]
    mov rdi, rsp
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
    mov rdi, rsp
    mov edx, 128
    call str_cat

.Lfpr_foot_pen:
    mov rdi, r12
    mov esi, [r13 + Theme.muted]
    mov edx, [r13 + Theme.surface]
    xor ecx, ecx
    call ScreenBuffer_set_pen

.Lfpr_foot_draw:
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    inc esi
    mov edx, [rbx + Widget.y]
    add edx, [rbx + Widget.h]
    sub edx, 2
    mov rcx, rsp
    mov r8d, [rbx + Widget.w]
    sub r8d, 2
    call ScreenBuffer_draw_text_pad

    # Filter badge on bottom border if filter active
    cmp byte ptr [r14 + DirModel.filter], 0
    je .Lfpr_done
    call i18n_get
    mov rsi, [rax + LangStrings.fp_flt_tag]
    mov rdi, rsp
    mov edx, 128
    call str_copy
    mov rdi, rsp
    lea rsi, [r14 + DirModel.filter]
    mov edx, 128
    call str_cat
    mov rdi, rsp
    call str_len
    cmp eax, 126
    jae .Lfpr_flt_draw
    mov byte ptr [rsp + rax], ' '
    mov byte ptr [rsp + rax + 1], 0
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
    mov rcx, rsp
    mov r8d, [rbx + Widget.w]
    sub r8d, 4
    call ScreenBuffer_draw_text

.Lfpr_done:
    add rsp, 512
    pop r15; pop r14; pop r13; pop r12; pop rbx; ret

# int FilePane_on_key(FilePane *this, Event *evt)
FilePane_on_key:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, [rbx + FilePane.model]

    mov eax, [r12 + Event.key]
    mov ecx, [r12 + Event.mods]

    # Ctrl+A -> toggle select all
    test ecx, MOD_CTRL
    jz .Lfpk_plain
    cmp eax, 'a'
    je .Lfpk_sel_all
    jmp .Lfpk_not_handled

.Lfpk_plain:
    cmp eax, KEY_UP
    je .Lfpk_up
    cmp eax, 'k'
    je .Lfpk_up
    cmp eax, KEY_DOWN
    je .Lfpk_down
    cmp eax, 'j'
    je .Lfpk_down
    cmp eax, KEY_PGUP
    je .Lfpk_pgup
    cmp eax, KEY_PGDN
    je .Lfpk_pgdn
    cmp eax, KEY_HOME
    je .Lfpk_home
    cmp eax, 'g'
    je .Lfpk_home
    cmp eax, KEY_END
    je .Lfpk_end
    cmp eax, 'G'
    je .Lfpk_end
    cmp eax, ' '
    je .Lfpk_toggle_sel
    cmp eax, KEY_INSERT
    je .Lfpk_toggle_sel
    cmp eax, '*'
    je .Lfpk_sel_all
    cmp eax, KEY_ENTER
    je .Lfpk_enter
    cmp eax, KEY_BACKSPACE
    je .Lfpk_parent
    cmp eax, '~'
    je .Lfpk_home_dir
    jmp .Lfpk_not_handled

.Lfpk_up:
    dec dword ptr [rbx + FilePane.cursor]
    jmp .Lfpk_sync
.Lfpk_down:
    inc dword ptr [rbx + FilePane.cursor]
    jmp .Lfpk_sync
.Lfpk_pgup:
    mov rdi, rbx
    call get_list_h
    sub [rbx + FilePane.cursor], eax
    jmp .Lfpk_sync
.Lfpk_pgdn:
    mov rdi, rbx
    call get_list_h
    add [rbx + FilePane.cursor], eax
    jmp .Lfpk_sync
.Lfpk_home:
    mov dword ptr [rbx + FilePane.cursor], 0
    jmp .Lfpk_sync
.Lfpk_end:
    mov rax, [r13 + DirModel.count]
    dec eax
    mov [rbx + FilePane.cursor], eax
    jmp .Lfpk_sync
.Lfpk_toggle_sel:
    mov rdi, r13
    mov esi, [rbx + FilePane.cursor]
    call DirModel_toggle_select
    inc dword ptr [rbx + FilePane.cursor]
    jmp .Lfpk_sync
.Lfpk_sel_all:
    mov rdi, r13
    call DirModel_select_all_toggle
    jmp .Lfpk_sync
.Lfpk_enter:
    mov rdi, [rbx + FilePane.app]
    mov rsi, rbx
    call App_open_selected_entry
    jmp .Lfpk_handled
.Lfpk_parent:
    mov rdi, rbx
    call FilePane_enter_parent
    mov rdi, [rbx + FilePane.app]
    call App_sync_preview
    jmp .Lfpk_handled
.Lfpk_home_dir:
    mov rcx, [rbx + FilePane.app]
    mov rdi, [rcx + App.envp]
    lea rsi, [rip + str_home_env]
    call env_getenv
    test rax, rax
    jz .Lfpk_handled
    mov rdi, r13
    mov rsi, rax
    call DirModel_chdir
    mov dword ptr [rbx + FilePane.cursor], 0
    mov dword ptr [rbx + FilePane.scroll], 0
    jmp .Lfpk_sync

.Lfpk_sync:
    mov rdi, rbx
    call FilePane_ensure_visible
    mov rdi, [rbx + FilePane.app]
    call App_sync_preview
.Lfpk_handled:
    mov rax, [rbx + FilePane.app]
    mov dword ptr [rax + App.need_redraw], 1
    mov eax, 1
    pop r13
    pop r12
    pop rbx
    ret

.Lfpk_not_handled:
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    ret

# Helper: scrub scroll from mouse y along scrollbar
scrub_scrollbar:
    # rdi=this, esi=my
    push rbx
    mov rbx, rdi
    mov eax, esi
    sub eax, [rbx + Widget.y]
    sub eax, 3
    test eax, eax
    jns .Lssb_nonneg
    xor eax, eax
.Lssb_nonneg:
    push rax
    mov rdi, rbx
    call get_list_h           # eax = list_h
    mov r8d, eax
    pop rax
    cmp eax, r8d
    jl .Lssb_r_ok
    lea eax, [r8d - 1]
.Lssb_r_ok:
    mov r9, [rbx + FilePane.model]
    mov r9, [r9 + DirModel.count]
    sub r9d, r8d              # max_scroll
    cmp r9d, 0
    jle .Lssb_zero
    cmp r8d, 2
    jl .Lssb_zero
    imul eax, r9d
    lea ecx, [r8d - 1]
    xor edx, edx
    div ecx
    mov [rbx + FilePane.scroll], eax
    jmp .Lssb_done
.Lssb_zero:
    mov dword ptr [rbx + FilePane.scroll], 0
.Lssb_done:
    pop rbx
    ret

# int FilePane_on_mouse(FilePane *this, Event *evt)
FilePane_on_mouse:
    push rbx
    push r12
    push r13
    push r14
    mov rbx, rdi              # this
    mov r12, rsi              # evt
    mov r13, [rbx + FilePane.model]

    mov r8d, [r12 + Event.mouse_x]
    mov r9d, [r12 + Event.mouse_y]
    mov eax, [r12 + Event.mouse_kind]

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
    mov rdi, rbx
    mov esi, r9d
    call scrub_scrollbar
    mov rax, [rbx + FilePane.app]
    mov dword ptr [rax + App.need_redraw], 1
    mov eax, 1
    jmp .Lfpm_ret

.Lfpm_chk_wheel:
    cmp eax, MACT_WHEEL
    jne .Lfpm_chk_move
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
    mov [rbx + FilePane.scroll], eax
    mov rax, [rbx + FilePane.app]
    mov dword ptr [rax + App.need_redraw], 1
    mov eax, 1
    jmp .Lfpm_ret

.Lfpm_chk_move:
    cmp eax, MACT_MOVE
    jne .Lfpm_chk_press

    # Check column header hover
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
    push r8
    push r9
    mov rdi, [rbx + FilePane.app]
    mov rsi, rbx
    call App_set_active_pane
    pop r9
    pop r8

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
    mov rdi, r13
    call DirModel_sort
    mov dword ptr [rbx + FilePane.cursor], 0
    mov dword ptr [rbx + FilePane.scroll], 0
    mov rdi, [rbx + FilePane.app]
    call App_sync_preview
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
    mov rdi, rbx
    push r9
    call get_list_h
    pop r9
    mov ecx, [rbx + Widget.y]
    add ecx, 3
    add ecx, eax
    cmp r9d, ecx
    jge .Lfpm_chk_row
    mov dword ptr [rbx + FilePane.dragging_scroll], 1
    mov rdi, rbx
    mov esi, r9d
    call scrub_scrollbar
    jmp .Lfpm_handled

.Lfpm_chk_row:
    mov eax, [rbx + Widget.y]
    add eax, 3
    cmp r9d, eax
    jl .Lfpm_handled
    mov rdi, rbx
    push r9
    call get_list_h
    pop r9
    mov ecx, [rbx + Widget.y]
    add ecx, 3
    add ecx, eax
    cmp r9d, ecx
    jge .Lfpm_handled

    mov r14d, r9d
    sub r14d, [rbx + Widget.y]
    sub r14d, 3
    add r14d, [rbx + FilePane.scroll]  # clicked index
    mov rax, [r13 + DirModel.count]
    cmp r14, rax
    jae .Lfpm_handled

    cmp dword ptr [r12 + Event.mouse_btn], MOUSE_RIGHT
    jne .Lfpm_left_click
    mov [rbx + FilePane.cursor], r14d
    mov rdi, r13
    mov esi, r14d
    call DirModel_toggle_select
    mov rdi, [rbx + FilePane.app]
    call App_sync_preview
    jmp .Lfpm_handled

.Lfpm_left_click:
    cmp dword ptr [r12 + Event.mouse_btn], MOUSE_LEFT
    jne .Lfpm_handled

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
    jmp .Lfpm_handled

.Lfpm_single_click:
    mov [rbx + FilePane.cursor], r14d
    mov [rbx + FilePane.last_click_idx], r14d
    mov [rbx + FilePane.last_click_ms], r8
    mov rdi, rbx
    call FilePane_ensure_visible
    mov rdi, [rbx + FilePane.app]
    call App_sync_preview

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

# ==============================================================================
# Tab & Navigation History Helpers (ROADMAP 1.3)
# ==============================================================================

# Internal: void *fp_get_active_tab(FilePane *this)
fp_get_active_tab:
    mov rax, [rdi + FilePane.tabs]
    test rax, rax
    jz .Lfgat_none
    mov ecx, [rdi + FilePane.active_tab]
    cmp ecx, 0
    jl .Lfgat_none
    cmp ecx, [rdi + FilePane.tab_count]
    jge .Lfgat_none
    imul rcx, rcx, FP_TAB_SIZE
    add rax, rcx
    ret
.Lfgat_none:
    xor eax, eax
    ret

# Internal: void fp_save_tab(FilePane *this)
fp_save_tab:
    push rbx
    mov rbx, rdi
    call fp_get_active_tab
    test rax, rax
    jz .Lfst_ret
    mov rcx, [rbx + FilePane.model]
    mov edx, [rbx + FilePane.cursor]
    mov [rax + FP_TAB_CURSOR], edx
    mov edx, [rbx + FilePane.scroll]
    mov [rax + FP_TAB_SCROLL], edx
    mov edx, [rcx + DirModel.sort_mode]
    mov [rax + FP_TAB_SORT_MODE], edx
    mov edx, [rcx + DirModel.sort_desc]
    mov [rax + FP_TAB_SORT_DESC], edx
    mov edx, [rcx + DirModel.show_hidden]
    mov [rax + FP_TAB_SHOW_HID], edx
    mov rdi, rax
    lea rsi, [rcx + DirModel.path]
    mov edx, PATH_MAX
    call str_copy
.Lfst_ret:
    pop rbx
    ret

# int FilePane_nav_to(FilePane *this, const char *path) -- returns DirModel_chdir result
FilePane_nav_to:
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    mov rdi, [rbx + FilePane.model]
    mov rsi, r12
    call DirModel_chdir; test rax, rax; js .Lfnt_ret
    mov rdi, [rbx + FilePane.model]; cmp dword ptr [rdi + DirModel.du_mode], 0; je .Lfnt_cur; call dir_du_populate
.Lfnt_cur:
    mov dword ptr [rbx + FilePane.cursor], 0; mov dword ptr [rbx + FilePane.scroll], 0
    mov rdi, rbx; call FilePane_ensure_visible
    mov rdi, rbx
    call fp_get_active_tab
    test rax, rax
    jz .Lfnt_rec
    mov rdi, rax
    mov rcx, [rbx + FilePane.model]
    lea rsi, [rcx + DirModel.path]
    call nav_hist_push
.Lfnt_rec:
    mov rcx, [rbx + FilePane.model]
    lea rdi, [rcx + DirModel.path]
    call nav_frecency_record
    xor eax, eax
.Lfnt_ret:
    pop r12
    pop rbx
    ret

# int FilePane_hist_back(FilePane *this) -- returns 1 if navigated, 0 if empty
FilePane_hist_back:
    push rbx
    mov rbx, rdi
    call fp_get_active_tab
    test rax, rax
    jz .Lfhb_no
    mov rdi, rax
    call nav_hist_back
    test rax, rax
    jz .Lfhb_no
    mov rdi, [rbx + FilePane.model]
    mov rsi, rax
    call DirModel_chdir
    test rax, rax
    js .Lfhb_no
    mov dword ptr [rbx + FilePane.cursor], 0
    mov dword ptr [rbx + FilePane.scroll], 0
    mov rdi, rbx
    call FilePane_ensure_visible
    mov eax, 1
    pop rbx
    ret
.Lfhb_no:
    xor eax, eax
    pop rbx
    ret

# int FilePane_hist_fwd(FilePane *this) -- returns 1 if navigated, 0 if empty
FilePane_hist_fwd:
    push rbx
    mov rbx, rdi
    call fp_get_active_tab
    test rax, rax
    jz .Lfhf_no
    mov rdi, rax
    call nav_hist_fwd
    test rax, rax
    jz .Lfhf_no
    mov rdi, [rbx + FilePane.model]
    mov rsi, rax
    call DirModel_chdir
    test rax, rax
    js .Lfhf_no
    mov dword ptr [rbx + FilePane.cursor], 0
    mov dword ptr [rbx + FilePane.scroll], 0
    mov rdi, rbx
    call FilePane_ensure_visible
    mov eax, 1
    pop rbx
    ret
.Lfhf_no:
    xor eax, eax
    pop rbx
    ret

# int FilePane_tab_new(FilePane *this) -- returns 1 if opened, 0 if at limit
FilePane_tab_new:
    push rbx
    push r12
    mov rbx, rdi
    mov eax, [rbx + FilePane.tab_count]
    cmp eax, FP_TAB_MAX
    jge .Lftn_full
    call fp_save_tab
    mov r12d, [rbx + FilePane.tab_count]
    imul rcx, r12, FP_TAB_SIZE
    add rcx, [rbx + FilePane.tabs]
    push rcx
    mov rdi, rcx
    mov rsi, FP_TAB_SIZE
    call mem_zero
    pop rcx
    mov rax, [rbx + FilePane.model]
    lea rsi, [rax + DirModel.path]
    mov rdi, rcx
    mov edx, PATH_MAX
    push rcx
    call str_copy
    pop rcx
    mov rax, [rbx + FilePane.model]
    lea rsi, [rax + DirModel.path]
    mov rdi, rcx
    call nav_hist_push
    mov [rbx + FilePane.active_tab], r12d
    inc dword ptr [rbx + FilePane.tab_count]
    mov eax, 1
    pop r12
    pop rbx
    ret
.Lftn_full:
    xor eax, eax
    pop r12
    pop rbx
    ret

# int FilePane_tab_switch(FilePane *this, int idx)
FilePane_tab_switch:
    cmp esi, 0
    jl .Lfts_no
    cmp esi, [rdi + FilePane.tab_count]
    jge .Lfts_no
    cmp esi, [rdi + FilePane.active_tab]
    je .Lfts_ok
    push rbx
    push r12
    mov rbx, rdi
    mov r12d, esi
    call fp_save_tab
    mov [rbx + FilePane.active_tab], r12d
    mov rdi, rbx
    call fp_get_active_tab
    test rax, rax
    jz .Lfts_done
    mov rcx, [rbx + FilePane.model]
    mov edx, [rax + FP_TAB_SORT_MODE]
    mov [rcx + DirModel.sort_mode], edx
    mov edx, [rax + FP_TAB_SORT_DESC]
    mov [rcx + DirModel.sort_desc], edx
    mov edx, [rax + FP_TAB_SHOW_HID]
    mov [rcx + DirModel.show_hidden], edx
    push rax
    mov rdi, rcx
    lea rsi, [rax + FP_TAB_PATH]
    call DirModel_chdir
    pop rax
    mov edx, [rax + FP_TAB_CURSOR]
    mov [rbx + FilePane.cursor], edx
    mov edx, [rax + FP_TAB_SCROLL]
    mov [rbx + FilePane.scroll], edx
    mov rdi, rbx
    call FilePane_ensure_visible
.Lfts_done:
    pop r12
    pop rbx
.Lfts_ok:
    mov eax, 1
    ret
.Lfts_no:
    xor eax, eax
    ret

# int FilePane_tab_close(FilePane *this, int idx_or_neg1)
FilePane_tab_close:
    cmp dword ptr [rdi + FilePane.tab_count], 1
    jle .Lftc_last
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12d, esi
    cmp r12d, 0
    jge .Lftc_chk
    mov r12d, [rbx + FilePane.active_tab]
.Lftc_chk:
    cmp r12d, [rbx + FilePane.tab_count]
    jge .Lftc_fail

    # Free history strings in tab r12d
    imul rax, r12, FP_TAB_SIZE
    add rax, [rbx + FilePane.tabs]
    xor ecx, ecx
.Lftc_fh:
    cmp ecx, [rax + 4120]     # TAB_HIST_LEN
    jge .Lftc_shift
    push rax
    push rcx
    mov rdi, [rax + 4128 + rcx*8]
    test rdi, rdi
    jz .Lftc_fh_n
    call mem_free
.Lftc_fh_n:
    pop rcx
    pop rax
    inc ecx
    jmp .Lftc_fh

.Lftc_shift:
    mov r13d, r12d
    mov edx, [rbx + FilePane.tab_count]
    dec edx
.Lftc_sh_loop:
    cmp r13d, edx
    jge .Lftc_dec
    imul rdi, r13, FP_TAB_SIZE
    add rdi, [rbx + FilePane.tabs]
    lea rsi, [rdi + FP_TAB_SIZE]
    push rdx
    mov rdx, FP_TAB_SIZE
    call mem_copy
    pop rdx
    inc r13d
    jmp .Lftc_sh_loop

.Lftc_dec:
    dec dword ptr [rbx + FilePane.tab_count]
    mov eax, [rbx + FilePane.active_tab]
    cmp eax, r12d
    jl .Lftc_ret1
    je .Lftc_reload
    dec dword ptr [rbx + FilePane.active_tab]
    jmp .Lftc_ret1

.Lftc_reload:
    mov eax, [rbx + FilePane.active_tab]
    cmp eax, [rbx + FilePane.tab_count]
    jl .Lftc_rel_go
    dec eax
    mov [rbx + FilePane.active_tab], eax
.Lftc_rel_go:
    mov rdi, rbx
    call fp_get_active_tab
    test rax, rax
    jz .Lftc_ret1
    mov rdi, [rbx + FilePane.model]
    lea rsi, [rax + FP_TAB_PATH]
    push rax
    call DirModel_chdir
    pop rax
    mov edx, [rax + FP_TAB_CURSOR]
    mov [rbx + FilePane.cursor], edx
    mov edx, [rax + FP_TAB_SCROLL]
    mov [rbx + FilePane.scroll], edx
    mov rdi, rbx
    call FilePane_ensure_visible

.Lftc_ret1:
    mov eax, 1
    pop r13
    pop r12
    pop rbx
    ret
.Lftc_fail:
    pop r13
    pop r12
    pop rbx
.Lftc_last:
    xor eax, eax
    ret
