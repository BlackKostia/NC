# src/ui/fuzzy_dialog.s - Command Palette (Ctrl+K) & Fuzzy Finder (Ctrl+P)
.intel_syntax noprefix

.include "pal.inc"
.include "classes.inc"

.equ FUZ_MAX_ITEMS, 1024
.equ FUZ_POOL_CAP,  65536
.equ FUZ_VIS_ROWS,  14
.equ FUZ_DLG_W,     74
.equ FUZ_DLG_H,     21

.section .text
.global FuzzyDialog_new
.global FuzzyDialog_get_selected

.extern Dialog_init
.extern Dialog_dtor
.extern Dialog_layout
.extern Dialog_draw_frame
.extern Dialog_on_key
.extern Dialog_on_mouse
.extern Dialog_on_confirm
.extern Dialog_on_cancel
.extern Widget_on_focus
.extern Widget_hit_test
.extern ScreenBuffer_set_pen
.extern ScreenBuffer_set_cell
.extern ScreenBuffer_draw_text
.extern ScreenBuffer_fill_rect
.extern theme_get
.extern i18n_get
.extern i18n_get_idx
.extern fuzzy_score
.extern dir_fuzzy_collect
.extern mem_alloc
.extern mem_free
.extern str_copy
.extern utf8_decode

.section .rodata
.align 8
FuzzyDialog_vtbl:
    DIALOG_VTBL_SLOTS FuzzyDialog_name, Dialog_vtbl, FuzzyDialog._size, FuzzyDialog_dtor, Dialog_layout, FuzzyDialog_render, FuzzyDialog_handle_key, Dialog_on_mouse, Widget_on_focus, Widget_hit_test, Dialog_on_confirm, Dialog_on_cancel
FuzzyDialog_name: .asciz "FuzzyDialog"

fuz_palette_cmds:
    .quad ACT_THEME,    fpc_theme_en,    fpc_theme_ua
    .quad ACT_LANG,     fpc_lang_en,     fpc_lang_ua
    .quad ACT_PREVIEW,  fpc_prev_en,     fpc_prev_ua
    .quad ACT_HIDDEN,   fpc_hid_en,      fpc_hid_ua
    .quad ACT_HELP,     fpc_help_en,     fpc_help_ua
    .quad ACT_RENAME,   fpc_ren_en,      fpc_ren_ua
    .quad ACT_VIEW,     fpc_view_en,     fpc_view_ua
    .quad ACT_EDIT,     fpc_edit_en,     fpc_edit_ua
    .quad ACT_COPY,     fpc_copy_en,     fpc_copy_ua
    .quad ACT_MOVE,     fpc_move_en,     fpc_move_ua
    .quad ACT_MKDIR,    fpc_mkdir_en,    fpc_mkdir_ua
    .quad ACT_DELETE,   fpc_del_en,      fpc_del_ua
    .quad ACT_NEWFILE,  fpc_new_en,      fpc_new_ua
    .quad ACT_FILTER,   fpc_flt_en,      fpc_flt_ua
    .quad ACT_GOTO,     fpc_goto_en,     fpc_goto_ua
    .quad ACT_REFRESH,  fpc_ref_en,      fpc_ref_ua
    .quad ACT_USERMENU, fpc_um_en,       fpc_um_ua
    .quad ACT_SHELL,    fpc_sh_en,       fpc_sh_ua
    .quad ACT_QUIT,     fpc_quit_en,     fpc_quit_ua
.equ FUZ_CMD_CNT, 19

fpc_theme_en: .asciz "Theme: Cycle Color Theme (Alt+T)"
fpc_theme_ua: .asciz "Тема: Змінити тему (Alt+T)"
fpc_lang_en:  .asciz "Language: Switch EN/UA (Alt+L)"
fpc_lang_ua:  .asciz "Мова: Перемкнути EN/UA (Alt+L)"
fpc_prev_en:  .asciz "Preview: Toggle Pane (F9)"
fpc_prev_ua:  .asciz "Перегляд: Панель прев'ю (F9)"
fpc_hid_en:   .asciz "Dotfiles: Toggle Hidden (.)"
fpc_hid_ua:   .asciz "Приховані: Показати/сховати (.)"
fpc_help_en:  .asciz "Help: Show Keybindings (F1)"
fpc_help_ua:  .asciz "Довідка: Клавіші (F1)"
fpc_ren_en:   .asciz "Rename: Rename Entry (F2)"
fpc_ren_ua:   .asciz "Перейменувати (F2)"
fpc_view_en:  .asciz "View: Open File Viewer (F3)"
fpc_view_ua:  .asciz "Перегляд файлу (F3)"
fpc_edit_en:  .asciz "Edit: Open in $EDITOR (F4)"
fpc_edit_ua:  .asciz "Редагувати у $EDITOR (F4)"
fpc_copy_en:  .asciz "Copy: Copy to Opposite Pane (F5)"
fpc_copy_ua:  .asciz "Копіювати в іншу панель (F5)"
fpc_move_en:  .asciz "Move: Move to Opposite Pane (F6)"
fpc_move_ua:  .asciz "Перемістити в іншу панель (F6)"
fpc_mkdir_en: .asciz "Mkdir: Create Directory (F7)"
fpc_mkdir_ua: .asciz "Створити каталог (F7)"
fpc_del_en:   .asciz "Delete: Permanent Delete (F8)"
fpc_del_ua:   .asciz "Видалити назавжди (F8)"
fpc_new_en:   .asciz "New File: Create Empty File (Ctrl+N)"
fpc_new_ua:   .asciz "Новий файл (Ctrl+N)"
fpc_flt_en:   .asciz "Filter: Live Filter (/)"
fpc_flt_ua:   .asciz "Фільтр: Швидкий фільтр (/)"
fpc_goto_en:  .asciz "Go To: Jump to Path (Ctrl+G)"
fpc_goto_ua:  .asciz "Перейти: Ввести шлях (Ctrl+G)"
fpc_ref_en:   .asciz "Refresh: Reload Panes (Ctrl+R)"
fpc_ref_ua:   .asciz "Оновити панелі (Ctrl+R)"
fpc_um_en:    .asciz "User Menu: Custom Commands (Alt+U)"
fpc_um_ua:    .asciz "Меню користувача (Alt+U)"
fpc_sh_en:    .asciz "Shell: Suspend to Shell (Ctrl+O)"
fpc_sh_ua:    .asciz "Оболонка: Вийти в Shell (Ctrl+O)"
fpc_quit_en:  .asciz "Quit: Exit Duop (F10)"
fpc_quit_ua:  .asciz "Вихід: Завершити Duop (F10)"
fuz_prm:      .asciz "> "

.section .text

# FuzzyDialog *FuzzyDialog_new(App *app, int mode, const char *base_path)
FuzzyDialog_new:
    push rbx; push r12; push r13; push r14; sub rsp, 8
    mov r12, rdi; mov r13d, esi; mov r14, rdx
    NEW_OBJ FuzzyDialog_vtbl, FuzzyDialog._size
    test rax, rax; jz .Lfdn_ret
    mov rbx, rax
    mov [rbx + FuzzyDialog.mode], r13d
    call i18n_get
    mov rdx, [rax + LangStrings.dlg_title_palette]; mov ecx, OP_PALETTE
    test r13d, r13d; jz .Lfdn_init
    mov rdx, [rax + LangStrings.dlg_title_fuzzy]; mov ecx, OP_FUZZY
.Lfdn_init:
    mov rdi, rbx; mov rsi, r12; call Dialog_init
    mov dword ptr [rbx + Widget.w], FUZ_DLG_W
    mov dword ptr [rbx + Widget.h], FUZ_DLG_H
    mov rdi, rbx; xor esi, esi; xor edx, edx
    mov ecx, [r12 + App.term_w]; mov r8d, [r12 + App.term_h]
    call Dialog_layout
    mov edi, FUZ_MAX_ITEMS * 16; call mem_alloc
    mov [rbx + FuzzyDialog.items_ptr], rax
    mov edi, FUZ_MAX_ITEMS * 16; call mem_alloc
    mov [rbx + FuzzyDialog.matches_ptr], rax
    test r13d, r13d; jnz .Lfdn_files
    call i18n_get_idx
    mov r8d, eax; xor ecx, ecx
    lea r9, [rip + fuz_palette_cmds]; mov r10, [rbx + FuzzyDialog.items_ptr]
.Lfdn_cmd_loop:
    cmp ecx, FUZ_CMD_CNT; jge .Lfdn_cmds_done
    mov rax, rcx; imul rax, 24
    mov r11, [r9 + rax]; mov rdx, [r9 + rax + 8]
    test r8d, r8d; jz .Lfdn_cmd_set
    mov rdx, [r9 + rax + 16]
.Lfdn_cmd_set:
    mov rax, rcx; shl rax, 4
    mov [r10 + rax], rdx; mov dword ptr [r10 + rax + 8], 0; mov [r10 + rax + 12], r11d
    inc ecx; jmp .Lfdn_cmd_loop
.Lfdn_cmds_done:
    mov dword ptr [rbx + FuzzyDialog.total_cnt], FUZ_CMD_CNT
    jmp .Lfdn_filter
.Lfdn_files:
    lea rdi, [rbx + FuzzyDialog.base_path]; mov rsi, r14; mov edx, PATH_MAX
    call str_copy
    mov edi, FUZ_POOL_CAP; call mem_alloc
    mov [rbx + FuzzyDialog.pool_ptr], rax
    test rax, rax; jz .Lfdn_filter
    mov rdi, r14; mov rsi, rax; mov edx, FUZ_POOL_CAP
    mov rcx, [rbx + FuzzyDialog.items_ptr]; mov r8d, FUZ_MAX_ITEMS
    call dir_fuzzy_collect
    mov [rbx + FuzzyDialog.total_cnt], eax
.Lfdn_filter:
    mov rdi, rbx; call fuz_refilter
    mov rax, rbx
.Lfdn_ret:
    add rsp, 8; pop r14; pop r13; pop r12; pop rbx; ret

FuzzyDialog_dtor:
    push rbx; mov rbx, rdi
    mov rdi, [rbx + FuzzyDialog.items_ptr]; test rdi, rdi; jz .Lfdd_p; call mem_free
.Lfdd_p:
    mov rdi, [rbx + FuzzyDialog.pool_ptr]; test rdi, rdi; jz .Lfdd_m; call mem_free
.Lfdd_m:
    mov rdi, [rbx + FuzzyDialog.matches_ptr]; test rdi, rdi; jz .Lfdd_base; call mem_free
.Lfdd_base:
    mov rdi, rbx; pop rbx; jmp Dialog_dtor

fuz_refilter:
    push rbx; push r12; push r13; push r14; sub rsp, 24
    mov rbx, rdi
    mov dword ptr [rbx + FuzzyDialog.match_cnt], 0
    mov dword ptr [rbx + FuzzyDialog.cursor], 0
    mov dword ptr [rbx + FuzzyDialog.scroll], 0
    mov r12, [rbx + FuzzyDialog.items_ptr]; mov r13, [rbx + FuzzyDialog.matches_ptr]
    test r12, r12; jz .Lfr_ret; test r13, r13; jz .Lfr_ret
    xor r14d, r14d
.Lfr_loop:
    cmp r14d, [rbx + FuzzyDialog.total_cnt]; jge .Lfr_sort
    mov rax, r14; shl rax, 4
    mov rsi, [r12 + rax]; lea rdi, [rbx + FuzzyDialog.query_buf]; mov rdx, rsp
    call fuzzy_score
    cmp eax, 0; jl .Lfr_next
    mov ecx, [rbx + FuzzyDialog.match_cnt]; cmp ecx, FUZ_MAX_ITEMS; jge .Lfr_sort
    inc dword ptr [rbx + FuzzyDialog.match_cnt]
    shl rcx, 4
    mov [r13 + rcx], r14d; mov [r13 + rcx + 4], eax
    mov rdx, [rsp]; mov [r13 + rcx + 8], rdx
.Lfr_next:
    inc r14d; jmp .Lfr_loop
.Lfr_sort:
    cmp byte ptr [rbx + FuzzyDialog.query_buf], 0; je .Lfr_ret
    mov ecx, [rbx + FuzzyDialog.match_cnt]; mov r8d, 1
.Lfr_ins_i:
    cmp r8d, ecx; jge .Lfr_ret
    mov rax, r8; shl rax, 4
    mov r9, [r13 + rax]; mov r10, [r13 + rax + 8]; mov edx, [r13 + rax + 4]
    mov r11d, r8d; dec r11d
.Lfr_ins_j:
    cmp r11d, 0; jl .Lfr_ins_put
    mov rax, r11; shl rax, 4
    cmp [r13 + rax + 4], edx; jge .Lfr_ins_put
    mov rdi, [r13 + rax]; mov rsi, [r13 + rax + 8]
    mov [r13 + rax + 16], rdi; mov [r13 + rax + 24], rsi
    dec r11d; jmp .Lfr_ins_j
.Lfr_ins_put:
    inc r11d; mov rax, r11; shl rax, 4
    mov [r13 + rax], r9; mov [r13 + rax + 8], r10
    inc r8d; jmp .Lfr_ins_i
.Lfr_ret:
    add rsp, 24; pop r14; pop r13; pop r12; pop rbx; ret

fuz_draw_row:
    push rbx; push r12; push r13; push r14; push r15; sub rsp, 32
    mov [rsp], rdi; mov [rsp + 8], rdx; mov [rsp + 16], ecx; mov [rsp + 24], r9
    mov r12d, esi; lea r13d, [esi + ecx]; mov r14, r8
    mov ebx, [rsp + 80]; mov r15, [rsp + 88]; xor r10d, r10d
.Lfdr_loop:
    cmp r12d, r13d; jge .Lfdr_ret
    cmp byte ptr [r14], 0; je .Lfdr_ret
    push r10; mov rdi, r14; call utf8_decode; pop r10
    mov r8d, eax; add r14, rdx
    mov esi, [r15 + Theme.text]; mov edx, [r15 + Theme.dialog_bg]; xor ecx, ecx
    test ebx, ebx; jz .Lfdr_chk_m
    mov esi, [r15 + Theme.accent_fg]; mov edx, [r15 + Theme.cursor_active_bg]
.Lfdr_chk_m:
    cmp r10d, 64; jae .Lfdr_put
    mov r11d, 1; push rcx; mov ecx, r10d; shl r11, cl; pop rcx
    test [rsp + 24], r11; jz .Lfdr_put
    mov esi, [r15 + Theme.accent]; mov ecx, ATTR_BOLD
.Lfdr_put:
    push r10; push r8
    mov rdi, [rsp + 16]; call ScreenBuffer_set_pen
    mov rdi, [rsp + 16]; mov esi, r12d; mov edx, [rsp + 24]; mov ecx, [rsp]
    call ScreenBuffer_set_cell
    add rsp, 8; pop r10
    inc r12d; inc r10d; jmp .Lfdr_loop
.Lfdr_ret:
    add rsp, 32; pop r15; pop r14; pop r13; pop r12; pop rbx; ret

FuzzyDialog_render:
    push rbx; push r12; push r13; push r14; push r15; sub rsp, 16
    mov rbx, rdi; mov r12, rsi
    call Dialog_draw_frame; call theme_get; mov r13, rax
    mov r14d, [rbx + Widget.x]; mov r15d, [rbx + Widget.y]
    mov rdi, r12; mov esi, [r13 + Theme.text]; mov edx, [r13 + Theme.surface_alt]; xor ecx, ecx
    call ScreenBuffer_set_pen
    mov rdi, r12; lea esi, [r14d + 2]; lea edx, [r15d + 2]
    mov ecx, FUZ_DLG_W - 4; mov r8d, 1; mov r9d, ' '; call ScreenBuffer_fill_rect
    mov rdi, r12; mov esi, [r13 + Theme.accent]; mov edx, [r13 + Theme.surface_alt]; mov ecx, ATTR_BOLD
    call ScreenBuffer_set_pen
    mov rdi, r12; lea esi, [r14d + 3]; lea edx, [r15d + 2]; lea rcx, [rip + fuz_prm]; mov r8d, 2
    call ScreenBuffer_draw_text
    mov rdi, r12; mov esi, [r13 + Theme.text]; mov edx, [r13 + Theme.surface_alt]; xor ecx, ecx
    call ScreenBuffer_set_pen
    mov rdi, r12; lea esi, [r14d + 5]; lea edx, [r15d + 2]
    lea rcx, [rbx + FuzzyDialog.query_buf]; mov r8d, FUZ_DLG_W - 8
    call ScreenBuffer_draw_text
    mov dword ptr [rsp], 0
.Lfzr_row:
    mov eax, [rsp]; cmp eax, FUZ_VIS_ROWS; jge .Lfzr_hint
    add eax, [rbx + FuzzyDialog.scroll]; cmp eax, [rbx + FuzzyDialog.match_cnt]; jge .Lfzr_hint
    mov [rsp + 4], eax; xor r8d, r8d
    cmp eax, [rbx + FuzzyDialog.cursor]; sete r8b; mov [rsp + 8], r8d
    mov edx, [r13 + Theme.dialog_bg]; test r8d, r8d; jz .Lfzr_fill
    mov edx, [r13 + Theme.cursor_active_bg]
.Lfzr_fill:
    mov rdi, r12; mov esi, [r13 + Theme.text]; xor ecx, ecx; call ScreenBuffer_set_pen
    mov rdi, r12; lea esi, [r14d + 2]; mov edx, [rsp]; add edx, r15d; add edx, 4
    mov ecx, FUZ_DLG_W - 4; mov r8d, 1; mov r9d, ' '; call ScreenBuffer_fill_rect
    mov eax, [rsp + 4]; shl rax, 4; add rax, [rbx + FuzzyDialog.matches_ptr]
    mov ecx, [rax]; mov r9, [rax + 8]; shl rcx, 4
    add rcx, [rbx + FuzzyDialog.items_ptr]; mov r8, [rcx]
    mov rdi, r12; lea esi, [r14d + 3]; mov edx, [rsp]; add edx, r15d; add edx, 4
    mov ecx, FUZ_DLG_W - 6; mov eax, [rsp + 8]
    push r13; push rax; call fuz_draw_row; add rsp, 16
    inc dword ptr [rsp]; jmp .Lfzr_row
.Lfzr_hint:
    mov rdi, r12; mov esi, [r13 + Theme.muted]; mov edx, [r13 + Theme.dialog_bg]; xor ecx, ecx
    call ScreenBuffer_set_pen
    call i18n_get; mov rcx, [rax + LangStrings.fuz_hint]
    mov rdi, r12; lea esi, [r14d + 2]; lea edx, [r15d + FUZ_DLG_H - 2]; mov r8d, FUZ_DLG_W - 4
    call ScreenBuffer_draw_text
    add rsp, 16; pop r15; pop r14; pop r13; pop r12; pop rbx; ret

FuzzyDialog_handle_key:
    push rbx; mov rbx, rdi; mov eax, [rsi + Event.key]
    cmp eax, KEY_ESC; je .Lfhk_cancel
    cmp eax, KEY_ENTER; je .Lfhk_ok
    cmp eax, KEY_UP; je .Lfhk_up
    cmp eax, KEY_DOWN; je .Lfhk_dn
    cmp eax, KEY_BACKSPACE; je .Lfhk_bs
    cmp eax, 32; jl .Lfhk_base
    cmp eax, 126; jle .Lfhk_ch
.Lfhk_base:
    mov rdi, rbx; pop rbx; jmp Dialog_on_key
.Lfhk_cancel:
    mov rdi, rbx; pop rbx; jmp Dialog_on_cancel
.Lfhk_ok:
    mov rdi, rbx; pop rbx; jmp Dialog_on_confirm
.Lfhk_up:
    mov eax, [rbx + FuzzyDialog.cursor]; test eax, eax; jle .Lfhk_done
    dec eax; mov [rbx + FuzzyDialog.cursor], eax
    cmp eax, [rbx + FuzzyDialog.scroll]; jge .Lfhk_done
    mov [rbx + FuzzyDialog.scroll], eax; jmp .Lfhk_done
.Lfhk_dn:
    mov eax, [rbx + FuzzyDialog.cursor]; inc eax
    cmp eax, [rbx + FuzzyDialog.match_cnt]; jge .Lfhk_done
    mov [rbx + FuzzyDialog.cursor], eax
    mov ecx, [rbx + FuzzyDialog.scroll]; add ecx, FUZ_VIS_ROWS
    cmp eax, ecx; jl .Lfhk_done
    sub eax, FUZ_VIS_ROWS - 1; mov [rbx + FuzzyDialog.scroll], eax; jmp .Lfhk_done
.Lfhk_bs:
    mov eax, [rbx + FuzzyDialog.query_len]; test eax, eax; jle .Lfhk_done
    dec eax; mov [rbx + FuzzyDialog.query_len], eax
    mov byte ptr [rbx + FuzzyDialog.query_buf + rax], 0
    mov rdi, rbx; call fuz_refilter; jmp .Lfhk_done
.Lfhk_ch:
    mov ecx, [rbx + FuzzyDialog.query_len]; cmp ecx, 126; jge .Lfhk_done
    mov [rbx + FuzzyDialog.query_buf + rcx], al; inc ecx
    mov [rbx + FuzzyDialog.query_len], ecx
    mov byte ptr [rbx + FuzzyDialog.query_buf + rcx], 0
    mov rdi, rbx; call fuz_refilter
.Lfhk_done:
    mov eax, 1; pop rbx; ret

FuzzyDialog_get_selected:
    mov eax, [rdi + FuzzyDialog.match_cnt]; test eax, eax; jle .Lfgs_none
    mov eax, [rdi + FuzzyDialog.cursor]; cmp eax, [rdi + FuzzyDialog.match_cnt]; jge .Lfgs_none
    shl rax, 4; add rax, [rdi + FuzzyDialog.matches_ptr]
    mov eax, [rax]; shl rax, 4; add rax, [rdi + FuzzyDialog.items_ptr]
    cmp dword ptr [rdi + FuzzyDialog.mode], 0; jne .Lfgs_path
    mov eax, [rax + 12]; ret
.Lfgs_path:
    mov rax, [rax]; ret
.Lfgs_none:
    xor eax, eax; ret
