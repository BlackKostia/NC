# Duop Bookmarks (Hotlist) & Frecency (z) Dialog
# Pure x86-64 GAS, zero .data, strict OOP vtable subclass of Dialog.

.intel_syntax noprefix
.include "classes.inc"

.section .rodata
str_BookmarkDialog: .asciz "BookmarkDialog"
str_bmd_filter_pfx: .asciz "> "
str_bmd_empty:      .asciz "(empty)"

.align 8
.global BookmarkDialog_vtbl
BookmarkDialog_vtbl:
    DIALOG_VTBL_SLOTS str_BookmarkDialog, Dialog_vtbl, BookmarkDialog._size, BookmarkDialog_dtor, BookmarkDialog_layout, BookmarkDialog_render, BookmarkDialog_handle_key, BookmarkDialog_handle_mouse, Widget_on_focus, Widget_hit_test, Dialog_on_confirm, Dialog_on_cancel

.section .text
.global BookmarkDialog_new
.global BookmarkDialog_get_selected

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

    # In Frecency mode, row +2 is filter input, list starts at +3 (12 rows)
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
    mov eax, [rbx + BookmarkDialog.match_cnt]
    test eax, eax
    jnz .Lbmr_adj_scroll
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
    jmp .Lbmr_hint

.Lbmr_adj_scroll:
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
    mov dword ptr [rsp], 0    # row_i = 0
.Lbmr_row:
    mov ecx, [rsp]
    cmp ecx, r15d
    jge .Lbmr_hint
    add ecx, [rbx + BookmarkDialog.scroll]
    cmp ecx, [rbx + BookmarkDialog.match_cnt]
    jge .Lbmr_hint

    mov [rsp + 4], ecx        # item_idx
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

    mov ecx, [rsp + 4]
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
    add edx, [rsp]
    mov r8d, 64
    call ScreenBuffer_draw_text

.Lbmr_next_row:
    inc dword ptr [rsp]
    jmp .Lbmr_row

.Lbmr_hint:
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

    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

BookmarkDialog_handle_key:
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    mov eax, [r12 + Event.key]

    cmp eax, KEY_ESC
    je .Lbmk_cancel
    cmp eax, KEY_ENTER
    je .Lbmk_ok
    cmp eax, KEY_UP
    je .Lbmk_up
    cmp eax, KEY_DOWN
    je .Lbmk_down

    cmp dword ptr [rbx + BookmarkDialog.mode], 1
    je .Lbmk_fre_key

    # Bookmarks mode keys
    cmp eax, 'k'
    je .Lbmk_up
    cmp eax, 'j'
    je .Lbmk_down
    cmp eax, 'a'
    je .Lbmk_add
    cmp eax, 'd'
    je .Lbmk_del
    xor eax, eax
    pop r12
    pop rbx
    ret

.Lbmk_fre_key:
    cmp eax, KEY_BACKSPACE
    je .Lbmk_bs
    cmp eax, 32
    jl .Lbmk_ign
    cmp eax, 126
    jg .Lbmk_ign
    mov ecx, [rbx + BookmarkDialog.filter_len]
    cmp ecx, 62
    jge .Lbmk_ign
    mov [rbx + BookmarkDialog.filter + rcx], al
    inc ecx
    mov byte ptr [rbx + BookmarkDialog.filter + rcx], 0
    mov [rbx + BookmarkDialog.filter_len], ecx
    mov dword ptr [rbx + BookmarkDialog.cursor], 0
    mov rdi, rbx
    call bmd_refresh_matches
    jmp .Lbmk_done

.Lbmk_bs:
    mov ecx, [rbx + BookmarkDialog.filter_len]
    test ecx, ecx
    jz .Lbmk_ign
    dec ecx
    mov byte ptr [rbx + BookmarkDialog.filter + rcx], 0
    mov [rbx + BookmarkDialog.filter_len], ecx
    mov dword ptr [rbx + BookmarkDialog.cursor], 0
    mov rdi, rbx
    call bmd_refresh_matches
    jmp .Lbmk_done

.Lbmk_up:
    cmp dword ptr [rbx + BookmarkDialog.cursor], 0
    jle .Lbmk_done
    dec dword ptr [rbx + BookmarkDialog.cursor]
    jmp .Lbmk_done

.Lbmk_down:
    mov eax, [rbx + BookmarkDialog.cursor]
    inc eax
    cmp eax, [rbx + BookmarkDialog.match_cnt]
    jge .Lbmk_done
    mov [rbx + BookmarkDialog.cursor], eax
    jmp .Lbmk_done

.Lbmk_add:
    mov rax, [rbx + Dialog.app]
    mov rax, [rax + App.active_pane]
    mov rax, [rax + FilePane.model]
    lea rdi, [rax + DirModel.path]
    call nav_bookmarks_add
    mov rdi, rbx
    call bmd_refresh_matches
    jmp .Lbmk_done

.Lbmk_del:
    cmp dword ptr [rbx + BookmarkDialog.match_cnt], 0
    jle .Lbmk_done
    mov edi, [rbx + BookmarkDialog.cursor]
    call nav_bookmarks_remove
    mov rdi, rbx
    call bmd_refresh_matches
    jmp .Lbmk_done

.Lbmk_ok:
    mov rdi, rbx
    call Dialog_on_confirm
    jmp .Lbmk_done

.Lbmk_cancel:
    mov rdi, rbx
    call Dialog_on_cancel
.Lbmk_done:
    mov rax, [rbx + Dialog.app]
    mov dword ptr [rax + App.need_redraw], 1
    mov eax, 1
    pop r12
    pop rbx
    ret
.Lbmk_ign:
    xor eax, eax
    pop r12
    pop rbx
    ret

BookmarkDialog_handle_mouse:
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    cmp dword ptr [r12 + Event.mouse_kind], MACT_PRESS
    jne .Lbmm_none
    mov eax, [r12 + Event.mouse_y]
    mov ecx, [rbx + Widget.y]
    add ecx, 2
    cmp dword ptr [rbx + BookmarkDialog.mode], 1
    jne .Lbmm_chk_row
    inc ecx
.Lbmm_chk_row:
    sub eax, ecx
    jl .Lbmm_none
    add eax, [rbx + BookmarkDialog.scroll]
    cmp eax, [rbx + BookmarkDialog.match_cnt]
    jge .Lbmm_none
    mov [rbx + BookmarkDialog.cursor], eax
    mov rdi, rbx
    call Dialog_on_confirm
    mov eax, 1
    pop r12
    pop rbx
    ret
.Lbmm_none:
    xor eax, eax
    pop r12
    pop rbx
    ret
