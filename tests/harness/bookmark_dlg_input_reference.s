# Frozen reference oracle: original src/ui/bookmark_dlg_input.s before C23 migration (v2.6.53).
# Duop Bookmarks (Hotlist) & Frecency (z) Dialog — bookmark dlg input (split from bookmark_dlg.s)

.intel_syntax noprefix
.include "classes.inc"

.section .text
.global BookmarkDialog_handle_key
.global BookmarkDialog_handle_mouse

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

    # Bookmarks mode keys (layout-independent; the frecency mode above filters by typed text)
    mov eax, [r12 + Event.lat]
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
    call BookmarkDialog_handle_key__bmd_refresh_matches
    jmp .Lbmk_done

.Lbmk_bs:
    mov ecx, [rbx + BookmarkDialog.filter_len]
    test ecx, ecx
    jz .Lbmk_ign
    call BookmarkDialog_handle_key__bmd_refresh_matches_2
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
    call BookmarkDialog_handle_key__nav_bookmarks_add
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

# BookmarkDialog_handle_key step: bmd_refresh_matches (runs on the caller's frame)
BookmarkDialog_handle_key__bmd_refresh_matches:
    lea rsp, [rsp - 8]
    mov [rbx + BookmarkDialog.filter + rcx], al
    inc ecx
    mov byte ptr [rbx + BookmarkDialog.filter + rcx], 0
    mov [rbx + BookmarkDialog.filter_len], ecx
    mov dword ptr [rbx + BookmarkDialog.cursor], 0
    mov rdi, rbx
    call bmd_refresh_matches
.LBookmarkDialog_handle_key__bmd_refresh_matches_ret:
    lea rsp, [rsp + 8]
    ret

# BookmarkDialog_handle_key step: bmd_refresh_matches (runs on the caller's frame)
BookmarkDialog_handle_key__bmd_refresh_matches_2:
    lea rsp, [rsp - 8]
    dec ecx
    mov byte ptr [rbx + BookmarkDialog.filter + rcx], 0
    mov [rbx + BookmarkDialog.filter_len], ecx
    mov dword ptr [rbx + BookmarkDialog.cursor], 0
    mov rdi, rbx
    call bmd_refresh_matches
.LBookmarkDialog_handle_key__bmd_refresh_matches_2_ret:
    lea rsp, [rsp + 8]
    ret

# BookmarkDialog_handle_key step: nav_bookmarks_add (runs on the caller's frame)
BookmarkDialog_handle_key__nav_bookmarks_add:
    lea rsp, [rsp - 8]
    mov rax, [rbx + Dialog.app]
    mov rax, [rax + App.active_pane]
    mov rax, [rax + FilePane.model]
    lea rdi, [rax + DirModel.path]
    call nav_bookmarks_add
    mov rdi, rbx
    call bmd_refresh_matches
.LBookmarkDialog_handle_key__nav_bookmarks_add_ret:
    lea rsp, [rsp + 8]
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
