# Frozen reference oracle: original src/ui/bookmark_dlg.s before C23 migration (v2.6.53).
# Duop Bookmarks (Hotlist) & Frecency (z) Dialog
# Pure x86-64 GAS, zero .data, strict OOP vtable subclass of Dialog.

.intel_syntax noprefix
.include "classes.inc"

.section .rodata
str_BookmarkDialog: .asciz "BookmarkDialog"
str_bmd_filter_pfx: .asciz "> "
str_bmd_empty:      .asciz "(empty)"

.align 8
BookmarkDialog_vtbl:
    DIALOG_VTBL_SLOTS str_BookmarkDialog, Dialog_vtbl, BookmarkDialog._size, BookmarkDialog_dtor, BookmarkDialog_layout, BookmarkDialog_render, BookmarkDialog_handle_key, BookmarkDialog_handle_mouse, Widget_on_focus, Widget_hit_test, Dialog_on_confirm, Dialog_on_cancel

.section .text
.global bmd_refresh_matches
.global BookmarkDialog_new
.global BookmarkDialog_get_selected
.global BookmarkDialog_vtbl

# Internal: refresh match list when mode == 1 (Frecency)
bmd_refresh_matches:
    push rbx
    mov rbx, rdi
    cmp dword ptr [rbx + BookmarkDialog.mode], 1
    jne .Lbrm_bm
    lea rdi, [rbx + BookmarkDialog.filter]
    lea rsi, [rbx + BookmarkDialog.matches]
    mov edx, 128
    call nav_frecency_match
    mov [rbx + BookmarkDialog.match_cnt], eax
    jmp .Lbrm_clamp
.Lbrm_bm:
    call nav_bookmarks_count
    mov [rbx + BookmarkDialog.match_cnt], eax
.Lbrm_clamp:
    mov eax, [rbx + BookmarkDialog.match_cnt]
    test eax, eax
    jnz .Lbrm_nonzero
    mov dword ptr [rbx + BookmarkDialog.cursor], 0
    mov dword ptr [rbx + BookmarkDialog.scroll], 0
    pop rbx
    ret
.Lbrm_nonzero:
    cmp [rbx + BookmarkDialog.cursor], eax
    jl .Lbrm_ret
    dec eax
    mov [rbx + BookmarkDialog.cursor], eax
.Lbrm_ret:
    pop rbx
    ret

# BookmarkDialog *BookmarkDialog_new(App *app, int mode)
BookmarkDialog_new:
    push rbx
    push r12
    push r13
    mov r12, rdi              # app
    mov r13d, esi             # mode (0=Bookmarks, 1=Frecency)

    NEW_OBJ BookmarkDialog_vtbl, BookmarkDialog._size
    mov rbx, rax
    call i18n_get
    mov rcx, [rax + LangStrings.dlg_title_bookmarks]
    mov r8d, OP_BOOKMARKS
    test r13d, r13d
    jz .Lbmn_init
    mov rcx, [rax + LangStrings.dlg_title_frecency]
    mov r8d, OP_FRECENCY
.Lbmn_init:
    mov rdi, rbx
    mov rsi, r12
    mov rdx, rcx
    mov ecx, r8d
    call Dialog_init

    mov [rbx + BookmarkDialog.mode], r13d
    mov dword ptr [rbx + BookmarkDialog.cursor], 0
    mov dword ptr [rbx + BookmarkDialog.scroll], 0
    mov dword ptr [rbx + BookmarkDialog.filter_len], 0
    mov byte ptr [rbx + BookmarkDialog.filter], 0
    mov dword ptr [rbx + Widget.w], 68
    mov dword ptr [rbx + Widget.h], 18

    mov rdi, rbx
    call bmd_refresh_matches

    mov rdi, rbx
    xor esi, esi
    xor edx, edx
    mov ecx, [r12 + App.term_w]
    mov r8d, [r12 + App.term_h]
    call BookmarkDialog_layout

    mov rax, rbx
    pop r13
    pop r12
    pop rbx
    ret

BookmarkDialog_layout:
    mov eax, ecx
    sub eax, 4
    cmp eax, 68
    jle .Lbml_w_ok
    mov eax, 68
.Lbml_w_ok:
    cmp eax, 36
    jge .Lbml_w_min
    mov eax, 36
.Lbml_w_min:
    mov [rdi + Widget.w], eax
    mov edx, 18
    mov esi, r8d
    sub esi, 2
    cmp edx, esi
    jle .Lbml_h_ok
    mov edx, esi
.Lbml_h_ok:
    mov [rdi + Widget.h], edx
    sub ecx, eax
    sar ecx, 1
    mov [rdi + Widget.x], ecx
    sub r8d, edx
    sar r8d, 1
    mov [rdi + Widget.y], r8d
    ret

BookmarkDialog_dtor:
    jmp Dialog_dtor

# const char *BookmarkDialog_get_selected(BookmarkDialog *this)
BookmarkDialog_get_selected:
    mov eax, [rdi + BookmarkDialog.cursor]
    cmp eax, 0
    jl .Lbgs_none
    cmp eax, [rdi + BookmarkDialog.match_cnt]
    jge .Lbgs_none
    cmp dword ptr [rdi + BookmarkDialog.mode], 1
    je .Lbgs_fre
    mov edi, eax
    jmp nav_bookmarks_get
.Lbgs_fre:
    mov edi, [rdi + BookmarkDialog.matches + rax*4]
    jmp nav_frecency_get
.Lbgs_none:
    xor eax, eax
    ret

BookmarkDialog_render:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16
    call BookmarkDialog_render__dlg
    # In Frecency mode, row +2 is filter input, list starts at +3 (12 rows)
    call BookmarkDialog_render__frecency_mode_row_filter
    mov eax, [rbx + BookmarkDialog.match_cnt]
    test eax, eax
    jnz .Lbmr_adj_scroll
    call BookmarkDialog_render__draw_text
    jmp .Lbmr_hint

.Lbmr_adj_scroll:
    call BookmarkDialog_render__part4
    call BookmarkDialog_render__row_i
.Lbmr_hint:
    call BookmarkDialog_render__draw_text_2
    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# BookmarkDialog_render step: dlg (runs on the caller's frame)
BookmarkDialog_render__dlg:
    lea rsp, [rsp - 8]
    mov rbx, rdi              # dlg
    mov r12, rsi              # scr

    mov rax, [rbx + Dialog.app]
    mov r13, [rax + App.theme]
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    xor ecx, ecx
    xor r8d, r8d
    call Dialog_draw_frame

    mov r14d, [rbx + Widget.y]
    add r14d, 2               # first content row
    mov r15d, 13              # visible list rows

.LBookmarkDialog_render__dlg_ret:
    lea rsp, [rsp + 8]
    ret

# BookmarkDialog_render step: In Frecency mode row is filter input list starts at (runs on the caller's frame)
BookmarkDialog_render__frecency_mode_row_filter:
    lea rsp, [rsp - 8]
    cmp dword ptr [rbx + BookmarkDialog.mode], 1
    jne .Lbmr_list
    mov rdi, r12
    mov esi, [r13 + Theme.accent]
    mov edx, [r13 + Theme.surface_alt]
    mov ecx, ATTR_BOLD
    call ScreenBuffer_set_pen

    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 2
    mov edx, r14d
    lea rcx, [rip + str_bmd_filter_pfx]
    mov r8d, 64
    call ScreenBuffer_draw_text

    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 4
    mov edx, r14d
    lea rcx, [rbx + BookmarkDialog.filter]
    mov r8d, 60
    call ScreenBuffer_draw_text

    inc r14d
    dec r15d

.Lbmr_list:
.LBookmarkDialog_render__frecency_mode_row_filter_ret:
    lea rsp, [rsp + 8]
    ret

# BookmarkDialog_render step: draw_text (runs on the caller's frame)
BookmarkDialog_render__draw_text:
    lea rsp, [rsp - 8]
    mov rdi, r12
    mov esi, [r13 + Theme.muted]
    mov edx, [r13 + Theme.surface]
    xor ecx, ecx
    call ScreenBuffer_set_pen
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 3
    mov edx, r14d
    lea rcx, [rip + str_bmd_empty]
    mov r8d, 40
    call ScreenBuffer_draw_text
.LBookmarkDialog_render__draw_text_ret:
    lea rsp, [rsp + 8]
    ret

# BookmarkDialog_render step (runs on the caller's frame)
BookmarkDialog_render__part4:
    lea rsp, [rsp - 8]
    mov eax, [rbx + BookmarkDialog.cursor]
    cmp eax, [rbx + BookmarkDialog.scroll]
    jge .Lbmr_sc_hi
    mov [rbx + BookmarkDialog.scroll], eax
.Lbmr_sc_hi:
    mov ecx, [rbx + BookmarkDialog.scroll]
    add ecx, r15d
    cmp eax, ecx
    jl .Lbmr_draw_rows
    sub eax, r15d
    inc eax
    mov [rbx + BookmarkDialog.scroll], eax

.Lbmr_draw_rows:
.LBookmarkDialog_render__part4_ret:
    lea rsp, [rsp + 8]
    ret

# BookmarkDialog_render step: row_i (runs on the caller's frame)
BookmarkDialog_render__row_i:
    lea rsp, [rsp - 8]
    mov dword ptr [rsp + 16], 0  # row_i = 0
.Lbmr_row:
    mov ecx, [rsp + 16]
    cmp ecx, r15d
    jge .LBookmarkDialog_render__row_i_ret
    add ecx, [rbx + BookmarkDialog.scroll]
    cmp ecx, [rbx + BookmarkDialog.match_cnt]
    jge .LBookmarkDialog_render__row_i_ret

    mov [rsp + 4 + 16], ecx  # item_idx
    cmp ecx, [rbx + BookmarkDialog.cursor]
    jne .Lbmr_norm_pen
    mov esi, [r13 + Theme.accent_fg]
    mov edx, [r13 + Theme.accent]
    mov ecx, ATTR_BOLD
    jmp .Lbmr_set_pen
.Lbmr_norm_pen:
    mov esi, [r13 + Theme.text]
    mov edx, [r13 + Theme.surface]
    xor ecx, ecx
.Lbmr_set_pen:
    mov rdi, r12
    call ScreenBuffer_set_pen

    mov ecx, [rsp + 4 + 16]
    cmp dword ptr [rbx + BookmarkDialog.mode], 1
    je .Lbmr_get_fre
    mov edi, ecx
    call nav_bookmarks_get
    jmp .Lbmr_draw_str
.Lbmr_get_fre:
    mov edi, [rbx + BookmarkDialog.matches + rcx*4]
    call nav_frecency_get
.Lbmr_draw_str:
    test rax, rax
    jz .Lbmr_next_row
    mov rcx, rax
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 2
    mov edx, r14d
    add edx, [rsp + 16]
    mov r8d, 64
    call ScreenBuffer_draw_text

.Lbmr_next_row:
    inc dword ptr [rsp + 16]
    jmp .Lbmr_row

.LBookmarkDialog_render__row_i_ret:
    lea rsp, [rsp + 8]
    ret

# BookmarkDialog_render step: draw_text (runs on the caller's frame)
BookmarkDialog_render__draw_text_2:
    lea rsp, [rsp - 8]
    mov rdi, r12
    mov esi, [r13 + Theme.muted]
    mov edx, [r13 + Theme.surface]
    xor ecx, ecx
    call ScreenBuffer_set_pen
    call i18n_get
    mov rcx, [rax + LangStrings.bm_hint]
    cmp dword ptr [rbx + BookmarkDialog.mode], 1
    jne .Lbmr_hint_draw
    mov rcx, [rax + LangStrings.fre_hint]
.Lbmr_hint_draw:
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 2
    mov edx, [rbx + Widget.y]
    add edx, [rbx + Widget.h]
    sub edx, 2
    mov r8d, 64
    call ScreenBuffer_draw_text

.LBookmarkDialog_render__draw_text_2_ret:
    lea rsp, [rsp + 8]
    ret
