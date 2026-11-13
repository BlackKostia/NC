# Internationalization (i18n) Module — English & Ukrainian Localization Tables
# Follows the same table-driven vtable/descriptor design as Theme (Zero libc).

.intel_syntax noprefix
.include "classes.inc"
.include "version.inc"

.section .rodata
env_lc_all:      .asciz "LC_ALL"
env_lc_messages: .asciz "LC_MESSAGES"
env_lang:        .asciz "LANG"

# ==============================================================================
# English String Table (LANG_EN = 0)
# ==============================================================================
en_code:            .asciz "EN"
en_name:            .asciz "English"

en_hdr_brand:       .asciz " ◆ Duop "
en_hdr_mode_dual:   .asciz " Dual "
en_hdr_mode_prev:   .asciz " Preview "
en_hdr_btn_quit:    .asciz " Quit "
en_hdr_btn_help:    .asciz " Help "
en_hdr_btn_lang:    .asciz " Lang:EN "
en_hdr_btn_hid_on:  .asciz " Dot:ON "
en_hdr_btn_hid_off: .asciz " Dot:OFF "
en_hdr_btn_prev:    .asciz " Preview "
en_hdr_theme_pfx:   .asciz " Theme:"

en_flbl_1:          .asciz "Help"
en_flbl_2:          .asciz "Ren"
en_flbl_3:          .asciz "View"
en_flbl_4:          .asciz "Edit"
en_flbl_5:          .asciz "Copy"
en_flbl_6:          .asciz "Move"
en_flbl_7:          .asciz "Mkdir"
en_flbl_8:          .asciz "Del"
en_flbl_9:          .asciz "Prev"
en_flbl_0:          .asciz "Quit"

en_sb_dir_tag:      .asciz "<DIR>"
en_sb_filter_pfx:   .asciz " Filter: \""
en_sb_filter_sfx:   .asciz "\"  [Esc clear]"
en_sb_hint_right:   .asciz "Tab:Switch  Space:Mark  /:Filter  Alt+T/L"
en_msg_lang_sw:     .asciz "Interface language: English"

en_fp_col_name:     .asciz "Name"
en_fp_col_size:     .asciz "Size"
en_fp_col_mod:      .asciz "Modified"
en_fp_col_perm:     .asciz "Perms"
en_fp_dir_badge:    .asciz "<DIR>"
en_fp_sel_pfx:      .asciz " ✓ "
en_fp_sel_mid:      .asciz " selected ("
en_fp_sel_end:      .asciz ")"
en_fp_sum_dirs:     .asciz " dirs, "
en_fp_sum_files:    .asciz " files • "
en_fp_flt_tag:      .asciz " filter:"

en_pv_title:        .asciz " ◈ Live Preview "
en_pv_dir_msg:      .asciz "Directory — Press Enter or double-click to browse"
en_pv_bin_hdr:      .asciz "Binary file detected — Hex preview:"
en_pv_empty:        .asciz "(Empty file)"
en_pv_sz_lbl:       .asciz "Size: "
en_pv_perm_lbl:     .asciz "  Perms: "

en_err_perm:        .asciz "Permission denied"
en_err_exists:      .asciz "Destination already exists"
en_err_noent:       .asciz "File or directory not found"
en_err_notempty:    .asciz "Directory not empty"
en_err_isdir:       .asciz "Target is a directory"
en_err_notdir:      .asciz "Not a directory"
en_err_same:        .asciz "Source and destination are the same"
en_err_generic:     .asciz "Filesystem operation failed"

en_dlg_btn_ok:      .asciz "  OK  "
en_dlg_btn_cancel:  .asciz " Cancel "
en_dlg_btn_yes:     .asciz "  Yes  "
en_dlg_btn_no:      .asciz "  No   "
en_dlg_btn_close:   .asciz " Close "
en_dlg_btn_hex:     .asciz " Hex/Text "
en_dlg_title_help:
    .ascii "Duop Help & Architecture (v"
    DUOP_VER_ASCII
    .asciz ")"
en_dlg_title_view:  .asciz "File Viewer"
en_dlg_vw_hint:     .asciz "↑↓/Wheel: Scroll   H: Text/Hex   Esc/Q: Close"
en_dlg_hlp_hint:    .asciz "↑↓/Wheel: Scroll   Esc/Enter: Close"

en_hl_0:  .asciz "◆ KEYBOARD NAVIGATION"
en_hl_1:  .asciz "  ↑/↓, j/k, PgUp/PgDn, Home/End  Move cursor in active panel"
en_hl_2:  .asciz "  Tab                            Switch between Left and Right panels"
en_hl_3:  .asciz "  Enter / Backspace / ~          Open item / Parent dir / Home dir"
en_hl_4:  .asciz "  Space / Insert / * / Ctrl+A    Mark file / Toggle mark all"
en_hl_5:  .asciz "  /                              Live filename filter (Esc clears)"
en_hl_6:  .asciz "  . or Ctrl+H                    Toggle hidden (dot) files"
en_hl_7:  .asciz "  Alt+T / Alt+L / Ctrl+P / G     Theme / Language / Preview / Go to path"
en_hl_8:  .asciz "◆ FILE OPERATIONS (F-KEYS & SHORTCUTS)"
en_hl_9:  .asciz "  F2 Rename   F3 View (Text/Hex)   F4 Edit ($EDITOR)   Ctrl+N New File"
en_hl_10: .asciz "  F5 Copy     F6 Move              F7 Mkdir            F8/Del Delete"
en_hl_11: .asciz "  F9 Preview  Ctrl+O Subshell      Ctrl+R Refresh      F10/q Quit"
en_hl_12: .asciz "◆ MOUSE SUPPORT (SGR 1006)"
en_hl_13: .asciz "  Left Click / Double Click        Select row / Open dir or View file"
en_hl_14: .asciz "  Right Click / Scroll Wheel       Mark file / Scroll panel under mouse"
en_hl_15: .asciz "  Click Column Header / Scrollbar  Sort Name/Size/Date / Drag scrollbar"
en_hl_16: .asciz "◆ ARCHITECTURE (Pure x86-64 GAS + Linux Syscalls)"
en_hl_17: .asciz "  OOP VTables: Object -> Widget -> Pane/Bars/Dialog -> Confirm/Input/Viewer"
en_hl_18: .asciz "◆ AUTHOR & OPEN-SOURCE LICENSE"
en_hl_19: .asciz "  Developer: Kostiantyn Nedbailo (Недбайло Костянтин Геннадійович)"
en_hl_20: .asciz "  Email:     ChessPlayerSedoy@gmail.com"
en_hl_21: .asciz "  License:   MIT License (OSI Open Source — see LICENSE)"

en_app_title_mkdir:   .asciz "Create Directory"
en_app_prm_mkdir:     .asciz "Directory name:"
en_app_title_newfile: .asciz "Create New File"
en_app_prm_newfile:   .asciz "File name:"
en_app_title_rename:  .asciz "Rename"
en_app_prm_rename:    .asciz "New name:"
en_app_title_copy:    .asciz "Copy"
en_app_prm_copy:      .asciz "Copy destination path:"
en_app_title_move:    .asciz "Move"
en_app_prm_move:      .asciz "Move destination path:"
en_app_title_filter:  .asciz "Live Filter"
en_app_prm_filter:    .asciz "Filter substring (empty clears):"
en_app_title_goto:    .asciz "Go To Directory"
en_app_prm_goto:      .asciz "Target directory path:"
en_app_title_delete:  .asciz "Confirm Delete"
en_app_msg_del_one:   .asciz "Delete this item permanently?"
en_app_msg_del_many:  .asciz "Delete selected items permanently?"
en_app_sel_items_sfx: .asciz " item(s) selected"
en_app_ok_mkdir:      .asciz "Directory created"
en_app_ok_newfile:    .asciz "File created"
en_app_ok_rename:     .asciz "Renamed successfully"
en_app_ok_copy:       .asciz "Copied successfully"
en_app_ok_move:       .asciz "Moved successfully"
en_app_ok_delete:     .asciz "Deleted successfully"
en_app_ok_refresh:    .asciz "Refreshed"
en_app_err_parent:    .asciz "Cannot operate on '..'"
en_app_err_isdir:     .asciz "Cannot view/edit a directory"

# ==============================================================================
# Ukrainian String Table (LANG_UA = 1)
# ==============================================================================
ua_code:            .asciz "UA"
ua_name:            .asciz "Українська"

ua_hdr_brand:       .asciz " ◆ Duop "
ua_hdr_mode_dual:   .asciz " 2 панелі "
ua_hdr_mode_prev:   .asciz " Перегляд "
ua_hdr_btn_quit:    .asciz " Вихід "
ua_hdr_btn_help:    .asciz " Довідка "
ua_hdr_btn_lang:    .asciz " Мова:UA "
ua_hdr_btn_hid_on:  .asciz " Прих:ВКЛ "
ua_hdr_btn_hid_off: .asciz " Прих:ВИМ "
ua_hdr_btn_prev:    .asciz " Прев'ю "
ua_hdr_theme_pfx:   .asciz " Тема:"

ua_flbl_1:          .asciz "Довід"
ua_flbl_2:          .asciz "Перейм"
ua_flbl_3:          .asciz "Перегл"
ua_flbl_4:          .asciz "Редаг"
ua_flbl_5:          .asciz "Копія"
ua_flbl_6:          .asciz "Перем"
ua_flbl_7:          .asciz "Тека"
ua_flbl_8:          .asciz "Видал"
ua_flbl_9:          .asciz "Прев'ю"
ua_flbl_0:          .asciz "Вихід"

ua_sb_dir_tag:      .asciz "<ТЕКА>"
ua_sb_filter_pfx:   .asciz " Фільтр: \""
ua_sb_filter_sfx:   .asciz "\"  [Esc скинути]"
ua_sb_hint_right:   .asciz "Tab:Панель  Space:Вибір  /:Фільтр  Alt+T/L"
ua_msg_lang_sw:     .asciz "Мова інтерфейсу: Українська"

ua_fp_col_name:     .asciz "Ім'я"
ua_fp_col_size:     .asciz "Розмір"
ua_fp_col_mod:      .asciz "Змінено"
ua_fp_col_perm:     .asciz "Права"
ua_fp_dir_badge:    .asciz "<ТЕКА>"
ua_fp_sel_pfx:      .asciz " ✓ "
ua_fp_sel_mid:      .asciz " вибрано ("
ua_fp_sel_end:      .asciz ")"
ua_fp_sum_dirs:     .asciz " тек, "
ua_fp_sum_files:    .asciz " файлів • "
ua_fp_flt_tag:      .asciz " фільтр:"

ua_pv_title:        .asciz " ◈ Швидкий перегляд "
ua_pv_dir_msg:      .asciz "Тека — Натисніть Enter або двічі клікніть, щоб відкрити"
ua_pv_bin_hdr:      .asciz "Виявлено бінарний файл — Hex-перегляд:"
ua_pv_empty:        .asciz "(Порожній файл)"
ua_pv_sz_lbl:       .asciz "Розмір: "
ua_pv_perm_lbl:     .asciz "  Права: "

ua_err_perm:        .asciz "Доступ заборонено"
ua_err_exists:      .asciz "Цільовий об'єкт уже існує"
ua_err_noent:       .asciz "Файл або теку не знайдено"
ua_err_notempty:    .asciz "Тека не порожня"
ua_err_isdir:       .asciz "Ціль є текою"
ua_err_notdir:      .asciz "Не є текою"
ua_err_same:        .asciz "Джерело і призначення збігаються"
ua_err_generic:     .asciz "Помилка файлової операції"

ua_dlg_btn_ok:      .asciz "  OK  "
ua_dlg_btn_cancel:  .asciz " Скасувати "
ua_dlg_btn_yes:     .asciz "  Так  "
ua_dlg_btn_no:      .asciz "  Ні   "
ua_dlg_btn_close:   .asciz " Закрити "
ua_dlg_btn_hex:     .asciz " Hex/Текст "
ua_dlg_title_help:
    .ascii "Довідка та архітектура Duop (v"
    DUOP_VER_ASCII
    .asciz ")"
ua_dlg_title_view:  .asciz "Переглядач файлів"
ua_dlg_vw_hint:     .asciz "↑↓/Колесо: Прокрутка   H: Текст/Hex   Esc/Q: Закрити"
ua_dlg_hlp_hint:    .asciz "↑↓/Колесо: Прокрутка   Esc/Enter: Закрити"

ua_hl_0:  .asciz "◆ НАВІГАЦІЯ З КЛАВІАТУРИ"
ua_hl_1:  .asciz "  ↑/↓, j/k, PgUp/PgDn, Home/End  Переміщення курсора в активній панелі"
ua_hl_2:  .asciz "  Tab                            Перемкнути ліву / праву панель"
ua_hl_3:  .asciz "  Enter / Backspace / ~          Відкрити / Батьківська / Домашня тека"
ua_hl_4:  .asciz "  Space / Insert / * / Ctrl+A    Позначити файл / Усі файли"
ua_hl_5:  .asciz "  /                              Фільтр назв наживо (Esc — скинути)"
ua_hl_6:  .asciz "  . або Ctrl+H                   Показати / приховати файли з крапкою"
ua_hl_7:  .asciz "  Alt+T / Alt+L / Ctrl+P / G     Тема / Мова / Швидк.перегл. / Шлях"
ua_hl_8:  .asciz "◆ ФАЙЛОВІ ОПЕРАЦІЇ (F-КЛАВІШІ ТА ГАРЯЧІ КЛАВІШІ)"
ua_hl_9:  .asciz "  F2 Перейм.   F3 Перегляд    F4 Редаг. ($EDITOR)    Ctrl+N Новий файл"
ua_hl_10: .asciz "  F5 Копія     F6 Переміст.   F7 Створити теку       F8/Del Видалити"
ua_hl_11: .asciz "  F9 Прев'ю    Ctrl+O Шелл    Ctrl+R Оновити         F10/q Вихід"
ua_hl_12: .asciz "◆ ПІДТРИМКА МИШІ (SGR 1006)"
ua_hl_13: .asciz "  Лівий клік / Подвійний клік    Вибрати рядок / Відкрити або Перегляд"
ua_hl_14: .asciz "  Правий клік / Колесо           Позначити файл / Прокрутка під курсором"
ua_hl_15: .asciz "  Заголовок колонки / Повзунок   Сортувати / Перетягувати скролбар"
ua_hl_16: .asciz "◆ АРХІТЕКТУРА (Чистий x86-64 GAS + Системні виклики Linux)"
ua_hl_17: .asciz "  ООП VTable: Object -> Widget -> Pane/Bars/Dialog -> Confirm/Input/View"
ua_hl_18: .asciz "◆ РОЗРОБНИК І ВІДКРИТА ЛІЦЕНЗІЯ"
ua_hl_19: .asciz "  Розробник: Недбайло Костянтин Геннадійович"
ua_hl_20: .asciz "  Контакт:   ChessPlayerSedoy@gmail.com"
ua_hl_21: .asciz "  Ліцензія:  MIT License (відкритий код — файл LICENSE)"

ua_app_title_mkdir:   .asciz "Створити теку"
ua_app_prm_mkdir:     .asciz "Назва теки:"
ua_app_title_newfile: .asciz "Створити новий файл"
ua_app_prm_newfile:   .asciz "Назва файлу:"
ua_app_title_rename:  .asciz "Перейменувати"
ua_app_prm_rename:    .asciz "Нова назва:"
ua_app_title_copy:    .asciz "Копіювати"
ua_app_prm_copy:      .asciz "Шлях призначення (копія):"
ua_app_title_move:    .asciz "Перемістити"
ua_app_prm_move:      .asciz "Шлях призначення (переміщення):"
ua_app_title_filter:  .asciz "Швидкий фільтр"
ua_app_prm_filter:    .asciz "Підрядок фільтра (порожній — скидає):"
ua_app_title_goto:    .asciz "Перейти до теки"
ua_app_prm_goto:      .asciz "Цільовий шлях теки:"
ua_app_title_delete:  .asciz "Підтвердження видалення"
ua_app_msg_del_one:   .asciz "Видалити цей об'єкт назавжди?"
ua_app_msg_del_many:  .asciz "Видалити вибрані об'єкти назавжди?"
ua_app_sel_items_sfx: .asciz " об'єкт(ів) вибрано"
ua_app_ok_mkdir:      .asciz "Теку створено"
ua_app_ok_newfile:    .asciz "Файл створено"
ua_app_ok_rename:     .asciz "Успішно перейменовано"
ua_app_ok_copy:       .asciz "Успішно скопійовано"
ua_app_ok_move:       .asciz "Успішно переміщено"
ua_app_ok_delete:     .asciz "Успішно видалено"
ua_app_ok_refresh:    .asciz "Оновлено"
ua_app_err_parent:    .asciz "Неможливо виконати над '..'"
ua_app_err_isdir:     .asciz "Неможливо переглянути/редагувати теку"

.align 8
.global lang_en_table
lang_en_table:
    .quad en_code, en_name
    .quad en_hdr_brand, en_hdr_mode_dual, en_hdr_mode_prev, en_hdr_btn_quit, en_hdr_btn_help, en_hdr_btn_lang
    .quad en_hdr_btn_hid_on, en_hdr_btn_hid_off, en_hdr_btn_prev, en_hdr_theme_pfx
    .quad en_flbl_1, en_flbl_2, en_flbl_3, en_flbl_4, en_flbl_5
    .quad en_flbl_6, en_flbl_7, en_flbl_8, en_flbl_9, en_flbl_0
    .quad en_sb_dir_tag, en_sb_filter_pfx, en_sb_filter_sfx, en_sb_hint_right, en_msg_lang_sw
    .quad en_fp_col_name, en_fp_col_size, en_fp_col_mod, en_fp_col_perm, en_fp_dir_badge
    .quad en_fp_sel_pfx, en_fp_sel_mid, en_fp_sel_end, en_fp_sum_dirs, en_fp_sum_files, en_fp_flt_tag
    .quad en_pv_title, en_pv_dir_msg, en_pv_bin_hdr, en_pv_empty, en_pv_sz_lbl, en_pv_perm_lbl
    .quad en_err_perm, en_err_exists, en_err_noent, en_err_notempty, en_err_isdir, en_err_notdir, en_err_same, en_err_generic
    .quad en_dlg_btn_ok, en_dlg_btn_cancel, en_dlg_btn_yes, en_dlg_btn_no, en_dlg_btn_close, en_dlg_btn_hex
    .quad en_dlg_title_help, en_dlg_title_view, en_dlg_vw_hint, en_dlg_hlp_hint
    .quad en_hl_0, en_hl_1, en_hl_2, en_hl_3, en_hl_4, en_hl_5, en_hl_6, en_hl_7, en_hl_8
    .quad en_hl_9, en_hl_10, en_hl_11, en_hl_12, en_hl_13, en_hl_14, en_hl_15, en_hl_16, en_hl_17
    .quad en_hl_18, en_hl_19, en_hl_20, en_hl_21
    .quad en_app_title_mkdir, en_app_prm_mkdir, en_app_title_newfile, en_app_prm_newfile
    .quad en_app_title_rename, en_app_prm_rename, en_app_title_copy, en_app_prm_copy
    .quad en_app_title_move, en_app_prm_move, en_app_title_filter, en_app_prm_filter
    .quad en_app_title_goto, en_app_prm_goto, en_app_title_delete, en_app_msg_del_one, en_app_msg_del_many
    .quad en_app_sel_items_sfx, en_app_ok_mkdir, en_app_ok_newfile, en_app_ok_rename
    .quad en_app_ok_copy, en_app_ok_move, en_app_ok_delete, en_app_ok_refresh, en_app_err_parent, en_app_err_isdir
.if (. - lang_en_table) != LangStrings._size
    .error "lang_en_table size does not match LangStrings._size"
.endif

.align 8
.global lang_ua_table
lang_ua_table:
    .quad ua_code, ua_name
    .quad ua_hdr_brand, ua_hdr_mode_dual, ua_hdr_mode_prev, ua_hdr_btn_quit, ua_hdr_btn_help, ua_hdr_btn_lang
    .quad ua_hdr_btn_hid_on, ua_hdr_btn_hid_off, ua_hdr_btn_prev, ua_hdr_theme_pfx
    .quad ua_flbl_1, ua_flbl_2, ua_flbl_3, ua_flbl_4, ua_flbl_5
    .quad ua_flbl_6, ua_flbl_7, ua_flbl_8, ua_flbl_9, ua_flbl_0
    .quad ua_sb_dir_tag, ua_sb_filter_pfx, ua_sb_filter_sfx, ua_sb_hint_right, ua_msg_lang_sw
    .quad ua_fp_col_name, ua_fp_col_size, ua_fp_col_mod, ua_fp_col_perm, ua_fp_dir_badge
    .quad ua_fp_sel_pfx, ua_fp_sel_mid, ua_fp_sel_end, ua_fp_sum_dirs, ua_fp_sum_files, ua_fp_flt_tag
    .quad ua_pv_title, ua_pv_dir_msg, ua_pv_bin_hdr, ua_pv_empty, ua_pv_sz_lbl, ua_pv_perm_lbl
    .quad ua_err_perm, ua_err_exists, ua_err_noent, ua_err_notempty, ua_err_isdir, ua_err_notdir, ua_err_same, ua_err_generic
    .quad ua_dlg_btn_ok, ua_dlg_btn_cancel, ua_dlg_btn_yes, ua_dlg_btn_no, ua_dlg_btn_close, ua_dlg_btn_hex
    .quad ua_dlg_title_help, ua_dlg_title_view, ua_dlg_vw_hint, ua_dlg_hlp_hint
    .quad ua_hl_0, ua_hl_1, ua_hl_2, ua_hl_3, ua_hl_4, ua_hl_5, ua_hl_6, ua_hl_7, ua_hl_8
    .quad ua_hl_9, ua_hl_10, ua_hl_11, ua_hl_12, ua_hl_13, ua_hl_14, ua_hl_15, ua_hl_16, ua_hl_17
    .quad ua_hl_18, ua_hl_19, ua_hl_20, ua_hl_21
    .quad ua_app_title_mkdir, ua_app_prm_mkdir, ua_app_title_newfile, ua_app_prm_newfile
    .quad ua_app_title_rename, ua_app_prm_rename, ua_app_title_copy, ua_app_prm_copy
    .quad ua_app_title_move, ua_app_prm_move, ua_app_title_filter, ua_app_prm_filter
    .quad ua_app_title_goto, ua_app_prm_goto, ua_app_title_delete, ua_app_msg_del_one, ua_app_msg_del_many
    .quad ua_app_sel_items_sfx, ua_app_ok_mkdir, ua_app_ok_newfile, ua_app_ok_rename
    .quad ua_app_ok_copy, ua_app_ok_move, ua_app_ok_delete, ua_app_ok_refresh, ua_app_err_parent, ua_app_err_isdir
.if (. - lang_ua_table) != LangStrings._size
    .error "lang_ua_table size does not match LangStrings._size"
.endif

.align 8
lang_ptrs:
    .quad lang_en_table
    .quad lang_ua_table
.equ LANG_COUNT, 2

.section .bss
.align 8
g_cur_lang:     .space 8
g_cur_lang_idx: .space 4

.section .text
.global i18n_get
.global i18n_set_lang
.global i18n_get_idx
.global i18n_count
.global i18n_detect_env
.global i18n_is_uk_code

# const LangStrings *i18n_get(void)
# Preserves all registers except RAX.
i18n_get:
    mov rax, [rip + g_cur_lang]
    test rax, rax
    jnz .Lig_ret
    lea rax, [rip + lang_en_table]
.Lig_ret:
    ret

# const LangStrings *i18n_set_lang(int idx)
i18n_set_lang:
    xor eax, eax
    cmp edi, LANG_UA
    jne .Lisl_store
    mov eax, LANG_UA
.Lisl_store:
    mov [rip + g_cur_lang_idx], eax
    lea rcx, [rip + lang_ptrs]
    mov rax, [rcx + rax*8]
    mov [rip + g_cur_lang], rax
    ret

# int i18n_get_idx(void)
i18n_get_idx:
    mov eax, [rip + g_cur_lang_idx]
    ret

# int i18n_count(void)
i18n_count:
    mov eax, LANG_COUNT
    ret

# int i18n_is_uk_code(const char *s)
# Returns 1 if s starts with "uk" or "ua" (case-insensitive) as a whole code/locale prefix.
i18n_is_uk_code:
    test rdi, rdi
    jz .Liuk_no
    movzx eax, byte ptr [rdi]
    or eax, 0x20
    cmp al, 'u'
    jne .Liuk_no
    movzx eax, byte ptr [rdi + 1]
    or eax, 0x20
    cmp al, 'k'
    je .Liuk_sep
    cmp al, 'a'
    jne .Liuk_no
.Liuk_sep:
    movzx eax, byte ptr [rdi + 2]
    test eax, eax
    jz .Liuk_yes
    cmp al, '_'
    je .Liuk_yes
    cmp al, '-'
    je .Liuk_yes
    cmp al, '.'
    je .Liuk_yes
    cmp al, '@'
    je .Liuk_yes
    cmp al, ' '
    je .Liuk_yes
.Liuk_no:
    xor eax, eax
    ret
.Liuk_yes:
    mov eax, 1
    ret

# int i18n_detect_env(char **envp)
# POSIX locale precedence: LC_ALL > LC_MESSAGES > LANG. Returns LANG_UA or LANG_EN.
i18n_detect_env:
    push rbx
    mov rbx, rdi
    test rbx, rbx
    jz .Lide_en

    mov rdi, rbx
    lea rsi, [rip + env_lc_all]
    call env_getenv
    test rax, rax
    jz .Lide_lc_msg
    cmp byte ptr [rax], 0
    jne .Lide_check

.Lide_lc_msg:
    mov rdi, rbx
    lea rsi, [rip + env_lc_messages]
    call env_getenv
    test rax, rax
    jz .Lide_lang
    cmp byte ptr [rax], 0
    jne .Lide_check

.Lide_lang:
    mov rdi, rbx
    lea rsi, [rip + env_lang]
    call env_getenv
    test rax, rax
    jz .Lide_en
    cmp byte ptr [rax], 0
    je .Lide_en

.Lide_check:
    mov rdi, rax
    call i18n_is_uk_code
    test eax, eax
    jz .Lide_en
    mov eax, LANG_UA
    pop rbx
    ret

.Lide_en:
    xor eax, eax              # LANG_EN
    pop rbx
    ret
