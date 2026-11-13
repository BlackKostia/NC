# План розвитку Duop (`ROADMAP`)

Цей документ описує покрокову архітектурну дорожню карту розвитку **Duop (`duop`)** — двопанельного TUI-менеджера на чистому x86-64 GNU Assembler (`.intel_syntax noprefix`, нуль `libc`, прямі системні виклики Linux).

**Головна стратегічна перевага проєкту**, яку необхідно зберігати й підсилювати на кожному етапі: **миттєвий старт (~1 мс), мізерне споживання RAM, один переносимий статичний ELF без жодних залежностей** (працює будь-де: rescue-диски, мінімальні контейнери, embedded, SSH-сервери без встановлених пакетів).

---

## Поточна база (`v1.0` — реалізовано)

- **Кодова база**: `13 356` рядків (`.inc` + `.s`), stripped release-бінарник `make release`: ~50 КБ (`text=45445, data=0, bss=680`).
- **ООП-рантайм** ([oop.inc](include/oop.inc), [oop_rt.s](src/core/oop_rt.s), [classes.inc](include/classes.inc)): `Object`, `ScreenBuffer`, `DirModel`, `App`, `Widget` → `HeaderBar`, `FunctionBar`, `StatusBar`, `FilePane`, `PreviewPane`, `Dialog` → `ConfirmDialog`, `InputDialog`, `ViewerDialog`, `HelpDialog`.
- **Графіка та ввід**: 24-біт TrueColor diff-рендер ([screen.s](src/tui/screen.s)), 3 теми ([theme.s](src/tui/theme.s)), повний декодер клавіатури (включно з `Alt + UTF-8`) і миші `SGR 1006` ([input.s](src/tui/input.s)).
- **Двомовність (UA / EN)** ([i18n.s](src/tui/i18n.s)): `--lang ua|en`, автовизначення `LC_ALL`/`LC_MESSAGES`/`LANG`, миттєве перемикання `Alt+L` (`Alt+д`) або кнопкою у шапці, динамічні UTF-8 хіт-зони (`utf8_display_width`).
- **Файлова підсистема** ([dir_model.s](src/fs/dir_model.s), [file_ops.s](src/fs/file_ops.s)): `getdents64`, `newfstatat`, QuickSort, живий фільтр, рекурсивні `copy`/`move`/`delete`, Text/Hex viewer і live preview.
- **Автотести** ([test_pty.py](tests/test_pty.py)): 14 наскрізних PTY-тестів.

---

## Рівень 1 (`v1.1`) — Закрити базові прогалини (щоденний інструмент замість `mc` / `ranger` / `lf`)

### 1.0 `cd-on-exit` (`--choosedir=FILE`)
- **Файли**: [main.s](src/main.s), [app.s](src/app/app.s), shell-обгортка у `README.md` / `scripts/`.
- **Реалізація**: при виході з прапорцем `--choosedir=FILE` записувати шлях активної панелі у `FILE`, щоб shell (`bash`/`zsh`/`fish`) після закриття `duop` переходив у вибраний каталог.

### 1.1 Конфігурація `~/.config/duop/duoprc` та User Menu
- **Новий файл**: `src/core/config.s`; інтеграція в [app.s](src/app/app.s) і [theme.s](src/tui/theme.s).
- **Можливості**:
  - перевизначення гарячих клавіш (`bind`);
  - власні RGB-теми (TrueColor);
  - правила відкриття файлів за розширенням (`*.png`, `*.pdf`, `*.mp4` → `$EDITOR` / `xdg-open` / довільна команда);
  - **User Menu / плагіни без інтерпретатора**: кастомні команди в конфігу з плейсхолдерами `%f` (поточний файл), `%F` (усі позначені), `%d`/`%D` (каталог активної/пасивної панелі), `%s` (виділення) — із виводом результату в діалог або панель.
- **Принцип**: зашиті в `.rodata` дефолти гарантують 100% працездатність і без файлу `duoprc`.

### 1.2 Єдиний цикл подій (`poll`/`ppoll`) та автооновлення через `inotify`
- **Файли**: [app.s](src/app/app.s), [input.s](src/tui/input.s), [linux_sys.inc](include/linux_sys.inc).
- **Архітектурна зміна**: винести мультиплексування `SYS_poll`/`SYS_ppoll` із `wait_and_read` ([input.s](src/tui/input.s)) у головний цикл `App_run`, щоб водночас слухати `STDIN_FD`, `inotify_fd` (`SYS_inotify_init1`, `SYS_inotify_add_watch` для лівої й правої панелей), канали фонових задач (`pipe2`) і вбудований PTY без затримок у 200 мс.

### 1.3 Історія навігації, закладки, `frecency` та вкладки панелей
- **Файли**: [classes.inc](include/classes.inc), [file_pane.s](src/ui/file_pane.s), [app.s](src/app/app.s).
- **Функціонал**:
  - історія переходів **Назад / Вперед** (`Alt+←` / `Alt+→`);
  - **Hotlist закладок** (`Ctrl+D`) з діалогом швидкого переходу;
  - вбудований **`frecency`-стрибок** (аналог `zoxide`, команда `z <підрядок>`) із персистентним журналом;
  - **вкладки у кожній панелі** (`Ctrl+T` — нова, `Ctrl+W` — закрити, клік мишею по смужці вкладок, середній клік для закриття).

### 1.4 Асинхронні файлові операції, `copy_file_range` і діалоги прогресу/конфліктів
- **Файли**: [file_ops.s](src/fs/file_ops.s), [dialogs.s](src/ui/dialogs.s), [classes.inc](include/classes.inc) (`TaskQueue`), [linux_sys.inc](include/linux_sys.inc).
- **Архітектура**:
  - фонова черга задач у окремому процесі (`fork`/`clone(SIGCHLD)` + двосторонні `pipe2`) замість спільного `CLONE_VM`, що гарантує відсутність data race у алокаторі [memory.s](src/core/memory.s) та глобальних буферах;
  - zero-copy копіювання через `SYS_copy_file_range` (миттєвий reflink на `btrfs`/`xfs`, без копіювання байтів через user-space) з fallback на `read`/`write`;
  - `ProgressDialog`: прогрес-бар, поточний файл, швидкість (`МБ/с`), ETA, пауза/відновлення (`SIGSTOP`/`SIGCONT`) і скасування (`SIGTERM`);
  - інтерактивний діалог конфліктів **`[ Перезаписати ]` / `[ Пропустити ]` / `[ Перейменувати ]` / `[ Для всіх ]`**.

### 1.5 Рекурсивний пошук у віртуальну панель
- **Файли**: [dir_model.s](src/fs/dir_model.s), [dialogs.s](src/ui/dialogs.s).
- **Можливості**: пошук за маскою імені та за вмістом файлу (`grep`), завантаження результатів безпосередньо у **віртуальну панель** (`DirModel` у режимі `VIRTUAL_SEARCH`) із переходом до оригіналу по `Enter`.

### 1.6 Кошик (`freedesktop Trash`), `Undo` (`Ctrl+Z`) та розширені атрибути
- **Файли**: [file_ops.s](src/fs/file_ops.s), [dialogs.s](src/ui/dialogs.s), [app.s](src/app/app.s).
- **Кошик + Undo**: переміщення видалених файлів у `$XDG_DATA_HOME/Trash` (`files/` + `info/*.trashinfo`) із можливістю відкату останньої операції (`Ctrl+Z`: перейменування, переміщення, видалення в кошик).
- **Атрибути та посилання**:
  - `ChmodDialog` / `chown` (клікабельні біти `rwx`, вісімкове представлення);
  - створення `symlink` та `hardlink`;
  - панель детальної інформації (`inode`, hardlink count, права, час, `CRC32`/`SHA-256` checksum).

---

## Рівень 2 (`v1.2` – `v2.0`) — «Вау»-можливості, що перевершують `mc` / `ranger` / `lf` / `yazi`

### 2.1 Вбудований Fuzzy Finder + Command Palette (`Ctrl+K`)
- **Файли**: [dialogs.s](src/ui/dialogs.s), [app.s](src/app/app.s), [types.inc](include/types.inc) (`FuzzyDialog`).
- **Можливості**:
  - **Command Palette (`Ctrl+K`)**: миттєвий пошук будь-якої дії та комбінації клавіш;
  - **Fuzzy Finder** (`fzf`-стиль) по всьому дереву каталогів із підсвічуванням збігів символів і сортуванням за релевантністю.

### 2.2 Перегляд зображень у терміналі
- **Файли**: [preview_pane.s](src/ui/preview_pane.s), [screen.s](src/tui/screen.s).
- **Підхід**:
  - **Kitty Graphics Protocol (`f=100`)** передає PNG-файли «як є» без написання PNG-декодера;
  - облік графічного прямокутника в `ScreenBuffer`, щоб при перекритті діалогами чи зміні файлу коректно надсилати команду очищення (`\x1b_Ga=d...\x1b\\`) і уникати артефактів поверх тексту;
  - наступний крок: fallback на **Sixel** та TrueColor half-blocks (`▀`/`▄`) для SSH/rescue-консолей без Kitty.

### 2.3 Режим аналізу диска (`Alt+D`, `ncdu`-режим)
- **Файли**: [dir_model.s](src/fs/dir_model.s), [file_pane.s](src/ui/file_pane.s).
- **Реалізація**: високошвидкісний паралельний обхід каталогів на `getdents64` (окремі `mmap`-арени на воркер), візуальні TrueColor-бари частки розміру в таблиці, сортування за розміром та видалення прямо з режиму аналізу.

### 2.4 Віртуальна файлова система архівів (VFS)
- **Файли**: [dir_model.s](src/fs/dir_model.s) + модуль розпакування (`src/fs/inflate.s`).
- **Поетапно**:
  1. підтримка `.tar` (просте читання 512-байтних заголовків POSIX/ustar);
  2. компактний `inflate`-модуль (~600 рядків) для прозорої навігації по `.tar.gz` та `.zip` як по звичайних директоріях.

### 2.5 Git-інтеграція в панелях та шапці
- **Файли**: [file_pane.s](src/ui/file_pane.s), [header_bar.s](src/ui/header_bar.s), [types.inc](include/types.inc) (`FileEntry`).
- **Реалізація**: асинхронний виклик `git status --porcelain=v1 -z -b` через `fork/execve` + `pipe` у головному циклі `poll`; індикатор гілки в [HeaderBar](src/ui/header_bar.s) та колонка статусів (`M` / `A` / `?` / `!`) у `FilePane`.

### 2.6 Масове перейменування
- **Файли**: [dialogs.s](src/ui/dialogs.s), [app.s](src/app/app.s).
- **Два режими**:
  - редагування списку імен через `$EDITOR` (підхід `vidir`);
  - вбудований діалог із живим прев'ю **`Було → Стане`**, заміною підрядків і шаблонами `{n}`, `{ext}`, лічильником.

### 2.7 Підсвітка синтаксису, ELF64-інспектор та In-place Hex-редактор
- **Файли**: [preview_pane.s](src/ui/preview_pane.s), [dialogs.s](src/ui/dialogs.s).
- **Підсвітка синтаксису**: табличний лексер для C, x86-64 asm, Python, shell, JSON, Markdown (`Makefile`).
- **ELF64-інспектор**: показ заголовків, секцій і точки входу для виконуваних файлів та `.o`-модулів.
- **Hex-редактор**: редагування байтів прямо в Hex-режимі `ViewerDialog` (введення hex-пар або ASCII, запис у файл, `Ctrl+Z` відкат у межах буфера).

### 2.8 Порівняння/синхронізація панелей, Mouse Drag-and-Drop і контекстне меню
- **Файли**: [file_pane.s](src/ui/file_pane.s), [app.s](src/app/app.s), `src/ui/popup_menu.s`.
- **Функції**: підсвітка відмінностей лівої та правої панелей + sync за датою/розміром; Mouse Drag-and-Drop (`MACT_DRAG`) між панелями; плаваюче контекстне меню правої кнопки + копіювання шляхів через `OSC 52`.

### 2.9 Вбудований термінал знизу (`Ctrl+\``)
- **Файли**: `src/ui/term_pane.s`, [app.s](src/app/app.s).
- **Реалізація**: дочірня PTY-сесія (`/dev/ptmx`) із компактним VT-парсером прямо під панелями файлів як неруйнівна альтернатива повному виходу у shell на `Ctrl+O`.

---

## Рівень 3 — Популяризація, дистрибуція та переносимість

1. **Англомовний `README.md` + демо**: головний `README.md` англійською мовою (і окремий `README.uk.md`) + записане GIF/`asciinema` демо на першому екрані.
2. **Публічні бенчмарки у `README`**:
   - розмір stripped ELF-бінарника;
   - час холодного старту (`hyperfine`);
   - споживання RSS RAM (`/usr/bin/time -v`);
   - швидкість відкриття та обходу каталогу на `100 000` файлів у порівнянні з `mc`, `ranger`, `lf`, `nnn`, `yazi`.
3. **CI та дистрибуція**:
   - GitHub Actions CI (`make release` + `tests/test_pty.py` + контроль розміру секцій), бейджі статусу;
   - готові статичні релізи у GitHub Releases + пакети для `AUR`, `.deb`, `Nix`, `Homebrew` (`linuxbrew`) та однорядковий `curl | sh` інсталятор.
4. **Порт на AArch64 (Raspberry Pi, ARM-сервери, Android/Termux)**:
   - винести архітектурно-залежні сисколи за універсальним інтерфейсом (`openat`, `newfstatat`, `ppoll`, `pipe2`, `clone`) у `src/arch/x86_64/` та `src/arch/aarch64/` після стабілізації ядра x86-64.
5. **Публічні анонси**: Hacker News (*«Dual-pane TUI file manager in pure x86-64 assembly, ~50 KB, zero libc»*), `r/linux`, `r/commandline`, `r/asm`, `lobste.rs`.

---

## Рекомендований порядок реалізації

1. **`--choosedir=FILE` (`cd-on-exit`)** + shell-обгортка → миттєва щоденна придатність.
2. **Уніфікований `poll`/`ppoll`-цикл + `inotify`**.
3. **Конфіг `duoprc`** (`src/core/config.s` + User Menu `%f %F %d %D %s` + розширення відкриття).
4. **Історія (`Alt+←/→`), закладки (`Ctrl+D`), `frecency` (`z`), вкладки (`Ctrl+T`/`Ctrl+W`)**.
5. **Асинхронні операції (`fork`+`pipe2`+`copy_file_range`) + `ProgressDialog` + конфлікти + Trash/Undo**.
6. **Fuzzy finder + Command Palette (`Ctrl+K`) + рекурсивний пошук у віртуальну панель**.
7. **`ncdu`-режим (паралельний `getdents64`)** + бенчмарки на 100k файлів.
8. **Kitty-прев'ю зображень (`f=100`) + Git-колонка + `tar`/`zip` VFS**.
9. **Підсвітка синтаксису + Hex-редактор + масове перейменування (`vidir`/шаблони) + порівняння панелей + вбудований PTY-термінал**.
10. *Паралельно*: англійський `README`, GIF-демо, GitHub Actions CI, GitHub Releases/пакети та порт на AArch64.

---

## Матриця ключових файлів

| Файл | Основне призначення у плані розвитку |
|---|---|
| [src/main.s](src/main.s) | Обробка `--choosedir=FILE`, старт конфігу та CLI-прапорців |
| `src/core/config.s` *(новий)* | Парсер `~/.config/duop/duoprc`, біндинги клавіш, кастомні теми, асоціації та User Menu |
| [src/app/app.s](src/app/app.s) | Єдиний цикл `poll`/`ppoll` (`STDIN_FD`, `inotify`, фонові воркери, `git`), `CommandPalette`, `Undo` |
| [src/fs/file_ops.s](src/fs/file_ops.s) | `copy_file_range`, асинхронна черга задач `TaskQueue`, `XDG Trash`, `Undo`-журнал, `chmod`/`chown`/`link` |
| [src/fs/dir_model.s](src/fs/dir_model.s) | Віртуальні панелі (пошук, `.tar`/`.zip` VFS, `ncdu`-дерево), кешування Git-статусу |
| [src/ui/dialogs.s](src/ui/dialogs.s) | `ProgressDialog`, діалоги конфліктів, `ChmodDialog`, `CommandPalette`, `FuzzyDialog`, Hex-edit, `BulkRename` |
| [src/ui/file_pane.s](src/ui/file_pane.s) | Смужка вкладок (`Tabs`), колонка Git-статусів, смужки розміру `ncdu`, підсвітка `DirDiff` |
| [src/ui/preview_pane.s](src/ui/preview_pane.s) | `Kitty f=100` / `Sixel` / half-block прев'ю, таблична підсвітка синтаксису, `ELF64`-інспектор |
| [include/classes.inc](include/classes.inc), [include/types.inc](include/types.inc), [include/config.inc](include/config.inc), [include/linux_sys.inc](include/linux_sys.inc) | Структури `TaskQueue`, `Config`, `History`, `FuzzyDialog`, константи нових клавіш і системних викликів (`inotify`, `copy_file_range`, `fchmodat`, `ppoll`, `pipe2`) |

---

## Критерії готовності та перевірки (Definition of Done)

1. **Чистий static ELF без `libc`**: збірка `make release` і контроль розміру секцій (`size duop`).
2. **ООП та двомовність**: кожен новий віджет/діалог наслідує `Widget`/`Dialog`, усі тексти додаються в `lang_en_table` та `lang_ua_table` ([i18n.s](src/tui/i18n.s)), хіт-зони миші розраховуються через `utf8_display_width`.
3. **PTY-тести**: кожна нова фіча покривається автоматичним сценарієм у [test_pty.py](tests/test_pty.py) (`make clean && make && make test`).
4. **Бенчмарки**: автоматизований замір часу старту (`hyperfine`), пам'яті (`/usr/bin/time -v`) і пропускної здатності каталогу на `100k` файлів.
