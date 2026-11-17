# Звіт: Сильні та слабкі сторони системи розширень Duop і план покращення

Документ містить технічний аудит поточної системи пакетів та розширень Duop (`v2.5.4`) і дорожню карту її подальшого розвитку зі збереженням філософії проєкту (**zero-libc**, **`.data == 0`**, **lean-модулі**, **миттєвий старт**).

---

## 1. Сильні сторони поточної реалізації

1. **Повна мовна незалежність (Out-of-process архітектура)**
   - Пакет може бути написаний на будь-якій мові (Python, Bash, Rust, Go, C, Assembly) або бути суто ресурсним (`*.lang`, `*.layout`).
   - Відсутність `dlopen` і вбудованої VM означає, що помилка чи падіння плагіна **ніколи не призведуть до крашу `duop`**.

2. **Нульовий вплив на базову продуктивність та розмір ядра**
   - Статичний ELF-бінарник залишається мінімальним (`~178 KiB` `.text`, `0` байтів `.data`), а сканування маніфестів відбувається ліниво (лише при відкритті `Alt+K`, `Alt+U`, `PopupMenu` або прев'ю).

3. **Захист від shell-ін'єкцій**
   - `pkg_action_build_argv` ([pkg_actions.s](file:///home/chessplayer/DEV/NC/src/fs/pkg_actions.s)) і `sys_exec_argv` ([syscall.s](file:///home/chessplayer/DEV/NC/src/core/syscall.s)) підставляють `{dir}`, `{other_dir}`, `{file}`, `{path}`, `{marked_file}` напряму в `argv[]` системного виклику `execve`, оминаючи `/bin/sh -c`.

4. **Ізольований асинхронний прев'ювер із таймаутом**
   - Зовнішні прев'ювери (`preview_ext` + `preview_exec`) виконуються у фоновому процесі [preview_helper.c](../src/fs/preview_helper.c) через `pipe` із жорстким таймаутом `350 ms` і `SIGKILL` ([pkg_preview.s](file:///home/chessplayer/DEV/NC/src/fs/pkg_preview.s)), що гарантує чутливість інтерфейсу.

5. **Контроль цілісності та чисте видалення**
   - Перевірка SHA-256 перед розпакуванням, збереження хешу в `sha256` для `duop pkg verify`, облік активованих `.lang`/`.layout` у `files.list` для чистого `duop pkg remove`.

6. **Перевикористовуваний інструментарій**
   - У `packages/duop-sysmon/` закладено беззалежні модулі [duop_tui_kit.py](file:///home/chessplayer/DEV/NC/packages/duop-sysmon/duop_tui_kit.py) та [sys_telemetry.py](file:///home/chessplayer/DEV/NC/packages/duop-sysmon/sys_telemetry.py) для швидкої розробки сучасних TrueColor-утиліт.

---

## 2. Слабкі сторони та поточні обмеження

1. **Плоска модель файлів при розпакуванні**
   - `pkg_manager.s` витягує файли за `path_basename` у `<pkg_root>/<name>/<basename>`. Складні багатомодульні пакети з підкаталогами (наприклад `lib/`, `assets/`, `bin/`) не зберігають ієрархію директорій.

2. **Відсутність інтерактивної навігації для `kind = vfs` у панелях**
   - Зараз `pkg_vfs_list_stdout` ([pkg_vfs.s](file:///home/chessplayer/DEV/NC/src/fs/pkg_vfs.s)) працює через CLI (`duop pkg vfs-list <uri>`), але `FilePane_nav_to` / `DirModel` ще не підключають зовнішній VFS-провайдер безпосередньо в панелі як віртуальну ФС (`virtual_mode = 3`).

3. **Спрощене порівняння версій у `pkg_registry_upgrade`**
   - Зараз `upgrade` порівнює версії через `str_cmp` (`!=`), а не справжній SemVer (`major.minor.patch`), тому відкат у реєстрі може трактуватися як оновлення.

4. **Відсутність криптографічного підпису реєстру `registry.tsv`**
   - Перевіряється SHA-256 архіву, але сам індекс реєстру (`registry.tsv`) приймається за довірою до HTTPS/локального файлу (немає Ed25519/minisign підпису індексу).

5. **Обмежена підтримка ANSI-кольорів у `PreviewPane` для зовнішніх прев'юверів**
   - Зовнішній прев'ювер може виводити ANSI escape-послідовності або таблиці, але `PreviewPane` очікує чистий текст (не інтерпретує SGR TrueColor-коди з stdout прев'ювера).

6. **Відсутність ізоляції (sandboxing) для сторонніх `tool`-пакетів**
   - Встановлений пакет виконується з тими самими правами користувача, що й `duop` (немає опційного обмеження через `PR_SET_NO_NEW_PRIVS` / `landlock` / read-only режиму).

---

## 3. План покращення (Roadmap розвитку розширень)

| Пріоритет | Покращення | Статус | Деталі реалізації |
|---|---|---|---|
| **P1** | **Інтерактивний VFS у `FilePane` (`virtual_mode = 3`)** | ✅ Реалізовано | `pkg_vfs_pane.s` інтегровано в `Ctrl+G` (`Goto`), `Enter` (`app_open.s`) та `F3` (`app_cmds.s`): `<scheme>://...` завантажує `LIST`, `F3` читає через `READ`, `..` повертає на рівень вище / назад на диск. |
| **P2** | **SemVer-компаратор у `pkg_registry.s`** | ✅ Реалізовано | `pkg_semver_cmp(a, b)` виконує числове порівняння `major.minor.patch`; `pkg_registry_upgrade` оновлює лише коли `registry_ver > installed_ver`. |
| **P3** | **Підтримка відносних підкаталогів у пакетах** | ✅ Реалізовано | `pkm_safe_relpath` та `pkm_ensure_parent` у `pkg_manager.s` зберігають `bin/`, `lib/`, `assets/`, відхиляючи `..` і `/`. |
| **P4** | **Підтримка `mode = bg` та статусного фідбеку** | ✅ Реалізовано | `sys_exec_argv_bg` у `syscall.s` + `App_run_pkg_action` виконують фонові `tool`-пакети без захоплення TTY і показують статус у `StatusBar`. |
| **P5** | **ANSI SGR-рендер у `PreviewPane` + мінімальна ізоляція** | ✅ Реалізовано | `pv_copy_line_strip_ansi` у `preview_pane.s` очищає SGR escape-послідовності у прев'ю, а `OS_NO_NEW_PRIVS` (`prctl`) ізолює дочірні процеси в `pkg_preview.s`. |
| **UX** | **Запуск розширень із `Ctrl+K` та вкладки в `Alt+K`** | ✅ Реалізовано | `FuzzyDialog` (`Ctrl+K`) включає встановлені `menu = ...` розширення; `Alt+K` показує вкладки `Installed` / `Available`, `Enter` запускає/встановлює, `u` оновлює/апгрейдить. |
