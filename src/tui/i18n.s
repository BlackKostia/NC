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
en_hl_17: .asciz "  F5/F6/F8 run in a fork worker: Alt+J progress, P pause, Esc hide, C cancel"
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
en_fp_loading_pfx:    .asciz " Loading: "
en_fp_huge_badge:     .asciz " [FS-order]"
en_fp_abort_badge:    .asciz " [Esc:stopped]"
en_app_load_aborted:  .asciz "Directory streaming stopped by Esc"
en_task_title_copy:   .asciz "Copying"
en_task_title_move:   .asciz "Moving"
en_task_title_delete: .asciz "Deleting"
en_task_btn_pause:    .asciz " Pause "
en_task_btn_resume:   .asciz " Resume "
en_task_btn_bg:       .asciz " Background "
en_task_lbl_files:    .asciz "Files: "
en_task_lbl_eta:      .asciz "ETA "
en_task_lbl_scan:     .asciz "Scanning… "
en_task_lbl_paused:   .asciz "Paused"
en_task_lbl_cancel:   .asciz "Canceling…"
en_task_sb_hint:      .asciz "Alt+J: details"
en_err_canceled:      .asciz "Operation canceled"
en_err_busy:          .asciz "Another background operation is running"
en_app_title_quit_tk: .asciz "Background Operation"
en_app_msg_quit_tk:   .asciz "An operation is still running. Cancel it and quit?"
en_dlg_title_usermenu: .asciz "User Menu"
en_um_hint:           .asciz "Enter: Run  •  Esc: Close"
en_dlg_title_bm:      .asciz "Bookmarks (Hotlist)"
en_bm_hint:           .asciz "Enter: Jump  •  a: Add  •  d: Remove  •  Esc: Close"
en_dlg_title_fre:     .asciz "Frecency Jump (z)"
en_fre_hint:          .asciz "Type substring • Up/Down • Enter: Jump • Esc: Close"
en_msg_bm_added:      .asciz "Bookmark added"
en_msg_hist_empty:    .asciz "No history"
en_msg_tab_last:      .asciz "Cannot close last tab"
en_dlg_title_conflict: .asciz "File Conflict"
en_cfl_btn_overwrite: .asciz "Overwrite"
en_cfl_btn_skip:      .asciz "Skip"
en_cfl_btn_rename:    .asciz "Rename"
en_cfl_lbl_forall:    .asciz "For all"
en_cfl_hint:          .asciz "o: Overwrite • s: Skip • r: Rename • a: For all • Esc: Cancel"
en_dlg_title_search:  .asciz "Recursive Search"
en_srch_lbl_name:     .asciz "Name mask:"
en_srch_lbl_grep:     .asciz "Content (grep):"
en_srch_hint:         .asciz "Tab: Switch field • Enter: Search • Esc: Cancel"
en_fp_search_badge:   .asciz " [Search]"
en_msg_search_none:   .asciz "No matches found"
en_dlg_title_info:    .asciz "File Info"
en_dlg_title_chmod:   .asciz "Permissions (chmod/chown)"
en_dlg_title_symlink: .asciz "Create Symlink"
en_dlg_title_hardlink:.asciz "Create Hardlink"
en_prm_link_target:   .asciz "Link path:"
en_chm_hint:          .asciz "1-9/Space: Bit • u/g: uid:gid • Enter: Apply"
en_msg_trashed:       .asciz "Moved to Trash"
en_msg_undone:        .asciz "Undone"
en_msg_undo_empty:    .asciz "Nothing to undo"
en_dlg_title_palette: .asciz "Command Palette"
en_dlg_title_fuzzy:   .asciz "Fuzzy Finder"
en_fuz_hint:          .asciz "Type: Filter   Up/Dn: Select   Enter: Run/Jump   Esc: Close"
en_fp_du_badge:       .asciz "Disk Usage"
en_br_title:          .asciz "Bulk Rename"
en_br_tmpl:           .asciz "Template:"
en_br_find:           .asciz "Find:"
en_br_repl:           .asciz "Replace:"
en_ctx_view:          .asciz "View"
en_ctx_copy:          .asciz "Copy"
en_ctx_move:          .asciz "Move"
en_ctx_copy_path:     .asciz "Copy Path"
en_ctx_delete:        .asciz "Delete"
en_msg_copied_path:   .asciz "Copied path to clipboard"
en_diff_pfx:          .asciz "Diff: "
en_term_title:        .asciz "Terminal"

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
ua_hl_17: .asciz "  F5/F6/F8 у фоновому процесі: Alt+J прогрес, P пауза, Esc сховати, C стоп"
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
ua_fp_loading_pfx:    .asciz " Читання: "
ua_fp_huge_badge:     .asciz " [Порядок ФС]"
ua_fp_abort_badge:    .asciz " [Зупинено Esc]"
ua_app_load_aborted:  .asciz "Дочитування теки зупинено клавішею Esc"
ua_task_title_copy:   .asciz "Копіювання"
ua_task_title_move:   .asciz "Переміщення"
ua_task_title_delete: .asciz "Видалення"
ua_task_btn_pause:    .asciz " Пауза "
ua_task_btn_resume:   .asciz " Продовжити "
ua_task_btn_bg:       .asciz " У фоні "
ua_task_lbl_files:    .asciz "Файли: "
ua_task_lbl_eta:      .asciz "Залишилось "
ua_task_lbl_scan:     .asciz "Підрахунок… "
ua_task_lbl_paused:   .asciz "Призупинено"
ua_task_lbl_cancel:   .asciz "Скасування…"
ua_task_sb_hint:      .asciz "Alt+J: деталі"
ua_err_canceled:      .asciz "Операцію скасовано"
ua_err_busy:          .asciz "Уже виконується інша фонова операція"
ua_app_title_quit_tk: .asciz "Фонова операція"
ua_app_msg_quit_tk:   .asciz "Операція ще триває. Скасувати її та вийти?"
ua_dlg_title_usermenu: .asciz "Меню користувача"
ua_um_hint:           .asciz "Enter: Виконати  •  Esc: Закрити"
ua_dlg_title_bm:      .asciz "Закладки (Hotlist)"
ua_bm_hint:           .asciz "Enter: Перейти  •  a: Додати  •  d: Видалити  •  Esc: Закрити"
ua_dlg_title_fre:     .asciz "Швидкий перехід (z)"
ua_fre_hint:          .asciz "Підрядок • ↑/↓ • Enter: Перейти • Esc: Закрити"
ua_msg_bm_added:      .asciz "Закладку додано"
ua_msg_hist_empty:    .asciz "Історія порожня"
ua_msg_tab_last:      .asciz "Не можна закрити останню вкладку"
ua_dlg_title_conflict: .asciz "Конфлікт файлу"
ua_cfl_btn_overwrite: .asciz "Перезаписати"
ua_cfl_btn_skip:      .asciz "Пропустити"
ua_cfl_btn_rename:    .asciz "Перейменувати"
ua_cfl_lbl_forall:    .asciz "Для всіх"
ua_cfl_hint:          .asciz "o: Перезапис • s: Пропуск • r: Перейм. • a: Для всіх • Esc"
ua_dlg_title_search:  .asciz "Рекурсивний пошук"
ua_srch_lbl_name:     .asciz "Маска імені:"
ua_srch_lbl_grep:     .asciz "Вміст (grep):"
ua_srch_hint:         .asciz "Tab: Поле • Enter: Пошук • Esc: Скасувати"
ua_fp_search_badge:   .asciz " [Пошук]"
ua_msg_search_none:   .asciz "Збігів не знайдено"
ua_dlg_title_info:    .asciz "Інформація про файл"
ua_dlg_title_chmod:   .asciz "Права (chmod/chown)"
ua_dlg_title_symlink: .asciz "Створити symlink"
ua_dlg_title_hardlink:.asciz "Створити hardlink"
ua_prm_link_target:   .asciz "Шлях посилання:"
ua_chm_hint:          .asciz "1-9/Пробіл: Біт • u/g: uid:gid • Enter: ОК"
ua_msg_trashed:       .asciz "Переміщено до кошика"
ua_msg_undone:        .asciz "Скасовано"
ua_msg_undo_empty:    .asciz "Нічого скасовувати"
ua_dlg_title_palette: .asciz "Палітра команд"
ua_dlg_title_fuzzy:   .asciz "Швидкий пошук"
ua_fuz_hint:          .asciz "Ввід: Фільтр   Вгору/Вниз: Вибір   Enter: Виконати   Esc: Закрити"
ua_fp_du_badge:       .asciz "Аналіз диска"
ua_br_title:          .asciz "Групове перейменування"
ua_br_tmpl:           .asciz "Шаблон:"
ua_br_find:           .asciz "Знайти:"
ua_br_repl:           .asciz "Заміна:"
ua_ctx_view:          .asciz "Перегляд"
ua_ctx_copy:          .asciz "Копіювати"
ua_ctx_move:          .asciz "Перемістити"
ua_ctx_copy_path:     .asciz "Копіювати шлях"
ua_ctx_delete:        .asciz "Видалити"
ua_msg_copied_path:   .asciz "Шлях скопійовано"
ua_diff_pfx:          .asciz "Різн: "
ua_term_title:        .asciz "Термінал"

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
    .quad en_fp_loading_pfx, en_fp_huge_badge, en_fp_abort_badge, en_app_load_aborted
    .quad en_task_title_copy, en_task_title_move, en_task_title_delete
    .quad en_task_btn_pause, en_task_btn_resume, en_task_btn_bg
    .quad en_task_lbl_files, en_task_lbl_eta, en_task_lbl_scan, en_task_lbl_paused, en_task_lbl_cancel
    .quad en_task_sb_hint, en_err_canceled, en_err_busy, en_app_title_quit_tk, en_app_msg_quit_tk
    .quad en_dlg_title_usermenu, en_um_hint
    .quad en_dlg_title_bm, en_bm_hint, en_dlg_title_fre, en_fre_hint
    .quad en_msg_bm_added, en_msg_hist_empty, en_msg_tab_last
    .quad en_dlg_title_conflict, en_cfl_btn_overwrite, en_cfl_btn_skip, en_cfl_btn_rename, en_cfl_lbl_forall, en_cfl_hint
    .quad en_dlg_title_search, en_srch_lbl_name, en_srch_lbl_grep, en_srch_hint, en_fp_search_badge, en_msg_search_none
    .quad en_dlg_title_info, en_dlg_title_chmod, en_dlg_title_symlink, en_dlg_title_hardlink, en_prm_link_target, en_chm_hint, en_msg_trashed, en_msg_undone, en_msg_undo_empty, en_dlg_title_palette, en_dlg_title_fuzzy, en_fuz_hint, en_fp_du_badge, en_br_title, en_br_tmpl, en_br_find, en_br_repl
    .quad en_ctx_view, en_ctx_copy, en_ctx_move, en_ctx_copy_path, en_ctx_delete, en_msg_copied_path, en_diff_pfx, en_term_title
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
    .quad ua_fp_loading_pfx, ua_fp_huge_badge, ua_fp_abort_badge, ua_app_load_aborted
    .quad ua_task_title_copy, ua_task_title_move, ua_task_title_delete
    .quad ua_task_btn_pause, ua_task_btn_resume, ua_task_btn_bg
    .quad ua_task_lbl_files, ua_task_lbl_eta, ua_task_lbl_scan, ua_task_lbl_paused, ua_task_lbl_cancel
    .quad ua_task_sb_hint, ua_err_canceled, ua_err_busy, ua_app_title_quit_tk, ua_app_msg_quit_tk
    .quad ua_dlg_title_usermenu, ua_um_hint
    .quad ua_dlg_title_bm, ua_bm_hint, ua_dlg_title_fre, ua_fre_hint
    .quad ua_msg_bm_added, ua_msg_hist_empty, ua_msg_tab_last
    .quad ua_dlg_title_conflict, ua_cfl_btn_overwrite, ua_cfl_btn_skip, ua_cfl_btn_rename, ua_cfl_lbl_forall, ua_cfl_hint
    .quad ua_dlg_title_search, ua_srch_lbl_name, ua_srch_lbl_grep, ua_srch_hint, ua_fp_search_badge, ua_msg_search_none
    .quad ua_dlg_title_info, ua_dlg_title_chmod, ua_dlg_title_symlink, ua_dlg_title_hardlink, ua_prm_link_target, ua_chm_hint, ua_msg_trashed, ua_msg_undone, ua_msg_undo_empty, ua_dlg_title_palette, ua_dlg_title_fuzzy, ua_fuz_hint, ua_fp_du_badge, ua_br_title, ua_br_tmpl, ua_br_find, ua_br_repl
    .quad ua_ctx_view, ua_ctx_copy, ua_ctx_move, ua_ctx_copy_path, ua_ctx_delete, ua_msg_copied_path, ua_diff_pfx, ua_term_title
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
