# Duop (`duop`)

Сучасний двопанельний термінальний файловий менеджер, написаний **повністю на чистому x86-64 асемблері** (**GNU Assembler / GAS**, `.intel_syntax noprefix`) без жодних сторонніх залежностей (навіть без `libc` та `ncurses` — лише прямі системні виклики ядра Linux).

## Чому обрано GNU Assembler (GAS)

- **Синтаксис Intel без синтаксичного шуму**: директива `.intel_syntax noprefix` забезпечує чистий запис інструкцій і адресних виразів.
- **Потужна підтримка ООП на рівні асемблера**: директива `.struct` автоматично обчислює зміщення полів і дає механізм наслідування (`.struct Parent._size`), а `.macro` з іменованими аргументами та значеннями за замовчуванням дозволяє декларативно описувати таблиці віртуальних методів (`vtable`) із наслідуванням неуперевизначених слотів.
- **Пряма інтеграція з `ld` та `gdb`**: генерація DWARF-символів (`-g`), модульна роздільна компіляція та мінімальний статичний ELF64-бінарник.

## ООП-архітектура на асемблері

Система ООП реалізована у [`include/oop.inc`](include/oop.inc), [`include/classes.inc`](include/classes.inc) та [`src/core/oop_rt.s`](src/core/oop_rt.s):

- **Інкапсуляція та пам'ять об'єктів**: кожен екземпляр починається з `Object.vptr` (offset `0`), вказівник `this` передається у `rdi` згідно з System V AMD64 ABI. Життєвий цикл керується макросами `NEW_OBJ` та `DELETE_OBJ` (віртуальний деструктор + звільнення пам'яті).
- **Наслідування полів**: `CLASS_BEGIN` / `EXTENDS` / `FIELD` / `CLASS_END` будують сумісні макети структур у пам'яті.
- **Поліморфізм та `vtable`**: `VTBL_BEGIN` / `VTBL_EXTENDS` / `VTBL_SLOT` визначають розкладку таблиці методів, а макроси `WIDGET_VTBL_SLOTS` і `DIALOG_VTBL_SLOTS` дозволяють класам-нащадкам перевизначати лише потрібні методи (`render=FilePane_render, on_mouse=FilePane_on_mouse`), автоматично успадковуючи решту від базового класу.
- **Віртуальний виклик та RTTI**: `VCALL` / `VCALL_REG`, `SUPER_CALL`, а також `IS_INSTANCE` (обхід ланцюжка `super` у `vtable`).

### Ієрархія класів

```text
Object
 ├── ScreenBuffer    (подвійний буфер термінала, TrueColor RGB diff-рендер)
 ├── DirModel        (компактні 32Б записи + name_pool, лінивий/io_uring stat, потокове читання, Introsort + LSD Radix Sort, ls -f режим)
 ├── App             (головний цикл подій, диспетчеризація клавіатури/миші, файлові команди)
 └── Widget
       ├── HeaderBar     (верхня панель, індикатори режиму, клікабельні кнопки Theme/Preview/Dot/Help/Quit)
       ├── FunctionBar   (нижня панель кнопок 1..0 з hover-підсвічуванням і кліком)
       ├── StatusBar     (таймерні статус-сповіщення, деталі файлу, ціль symlink)
       ├── FilePane      (файлова панель, скролбар, сортування кліком по шапці, double-click)
       ├── PreviewPane   (живий попередній перегляд тексту / hex-дампу)
       └── Dialog
             ├── ConfirmDialog  (модальне підтвердження видалення)
             ├── InputDialog    (UTF-8 редактор рядка для Mkdir/Rename/Copy/Move/Filter/GoTo)
             ├── ViewerDialog   (вбудований переглядач файлів у режимах Text та Hex)
             ├── HelpDialog     (довідка по клавішах, миші та архітектурі)
             └── ProgressDialog (прогрес фонової операції: файл, смуга, байти/файли, швидкість, ETA, Пауза/У фоні/Скасувати)
```

## Структура проєкту

```text
duop/
├── AGENTS.md                 # Правила модульної архітектури, SemVer і комітів
├── LICENSE                   # Відкрита ліцензія MIT
├── VERSION                   # Поточна SemVer-версія (1.5.0)
├── Makefile                  # Збірка (OS/ARCH compile-time PAL, all / release / run / test / verify / hooks / clean)
├── .agents/                  # Antigravity скіли (duop-*) та lifecycle-хуки (hooks.json)
├── .githooks/                # Git-хуки (pre-commit, commit-msg, post-commit)
├── include/
│   ├── pal.inc               # Платформо-незалежний PAL-контракт (FileStat)
│   ├── os/linux/x86_64/      # pal_target.inc: номери системних викликів і inline-макроси OS_*
│   ├── config.inc            # Ліміти, коди клавіш/миші, UTF-8 гліфи інтерфейсу
│   ├── oop.inc               # Макроси ООП-системи (CLASS_*, VTBL_*, VCALL, NEW_OBJ)
│   ├── types.inc             # Структури даних (Rect, Cell, Event, HitZone, FileEntry, Theme, LangStrings)
│   └── classes.inc           # Повна специфікація класів і vtable
├── src/
│   ├── main.s                # Точка входу _start (прапорці --lang / -l / -h / --help / -V / --version / -L / --license)
│   ├── os/linux/x86_64/      # pal_os.s, pal_uring.s (io_uring IORING_OP_STATX пакетний stat з fallback), pal_simd.s (SSE2 memcpy/memset/memcmp/strlen/ci-пошук)
│   ├── core/                 # memory.s (slab-алокатор 64 Б–64 КіБ + mmap для великих), string.s, utf8.s, oop_rt.s, syscall.s
│   ├── tui/                  # theme.s (3 TrueColor теми), i18n.s (UA/EN таблиці), screen.s, input.s (клавіатура + SGR 1006)
│   ├── fs/                   # dir_model.s (32Б FileEntry + потокове читання), dir_sort.s (Introsort/Radix + prefix-key), dir_cache.s (LRU-кеш тек), file_ops.s, task.s (fork-воркер фонових операцій), dir_watch.s (inotify), preview_io.s (асинхронне читання прев'ю)
│   ├── ui/                   # header_bar.s, function_bar.s, status_bar.s, file_pane.s, preview_pane.s, dialogs.s, viewer_dialog.s (mmap-переглядач будь-якого розміру), progress_dialog.s
│   └── app/                  # app.s, app_task.s (контролер фонових операцій), app_events.s (таймаути, дебаунси, автооновлення)
└── tests/
    ├── test_pal_architecture.py # Перевірка compile-time PAL, ізоляції сисколів, макросів OS_* та ELF .data==0
    ├── test_pty.py           # Наскрізні тести в реальному PTY (клавіатура, миша, resize, ФС)
    ├── test_fs_reliability.py # Стрес- та відмовостійкі тести copy/move/delete/rename/EXDEV
    ├── test_performance_dir.py # Тести 32B/pool, lazy stat, Radix/Introsort, huge-mode [FS-order] та Esc-скасування
    ├── test_bg_tasks.py      # Фонові операції: неблокуючий UI, прогрес, пауза/скасування, EBUSY, вихід, EN/UA
    ├── test_event_loop.py    # 0 пробуджень у простої, inotify-автооновлення, дебаунс/асинхронне прев'ю, DEC 2026
    ├── test_nav_viewer.py    # LRU-кеш тек без chdir/getcwd, mmap-переглядач + SIGBUS-захист, rolling io_uring, чергування стрімінгу
    ├── test_fastpath.py      # Бюджет сисколів (strace): slab, copy_file_range, d_type-видалення; prefix-сортування, звуження фільтра
    └── bench_million.py       # Бенчмарк відкриття великих директорій (TTFF, Full, RSS, syscalls)
```

## Збірка, запуск та тестування

```bash
make          # Зібрати ./duop (з DWARF debug-інформацією)
make release  # Зібрати оптимізований stripped-бінарник
make run      # Запустити ./duop
make test     # Запустити наскрізні PTY-тести
make verify   # Повна перевірка (модульність + release + debug + ELF .data==0 + PTY)
make hooks    # Активувати Git-хуки з .githooks/ та права на скрипти
```

Можна передавати початкові каталоги та мову інтерфейсу (`ua` або `en`; також автовизначення з `LC_ALL`/`LC_MESSAGES`/`LANG`), або перевірити версію/ліцензію через `-V`/`--version` та `-L`/`--license`:
```bash
./duop --lang ua /path/to/left /path/to/right
./duop --version
./duop --license
```

## Керування

### Клавіатура
- `↑` / `↓`, `j` / `k`, `PgUp` / `PgDn`, `Home` / `End` — навігація по списку
- `Tab` — перемикання активної панелі
- `Enter` — увійти в директорію або відкрити файл у вбудованому переглядачі (`Text`/`Hex`)
- `Backspace` / `~` — на рівень вище / у `$HOME`
- `Space` / `Insert` / `*` / `Ctrl+A` — позначити файл або перемкнути виділення всіх
- `/` — швидкий фільтр у реальному часі (`Esc` — очистити фільтр)
- `.` або `Ctrl+H` — показ прихованих файлів
- `Alt+T` — перемикання теми (`Tokyo Night`, `Catppuccin`, `Emerald`)
- `Alt+L` (або кнопка `Мова:UA`/`Lang:EN` у верхній панелі) — наступна встановлена мова інтерфейсу по колу, працює навіть при увімкненій українській розкладці (`Alt+д`)
- **Мовні пакети інтерфейсу** — переклади не вшиті в код: англійська вбудована (основа й запасний варіант для кожного відсутнього ключа), решта мов — файли `*.lang`, що читаються під час запуску. Нова мова — новий файл без перекомпіляції: скопіюйте [`lang/uk.lang`](lang/uk.lang) у `~/.config/duop/lang/<id>.lang`, змініть `code`/`name` і перекладіть рядки `ключ = значення` (ключі — поля `LangStrings` з `include/types.inc`; `"..."` зберігає пробіли з країв, екранування `\n \t \" \\`, `{version}` — версія Duop). Мова обирається через `--lang <id|code>`, `lang = <id>` у `duoprc` або `LC_ALL`/`LC_MESSAGES`/`LANG` (`uk_UA.UTF-8` → `uk`). Пошук: `$DUOP_LANGS` (каталоги через `:`, замінює типові) або `~/.config/duop/lang`, далі `lang/` і `../share/duop/lang` поруч із бінарником, `/usr/local/share/duop/lang`, `/usr/share/duop/lang`
- **Розкладки клавіатури** — це дані, а не код: гарячі клавіші (`Alt+…`, `Ctrl+…`, `j`/`k`, літери в діалогах і переглядачі) прив'язані до фізичної клавіші через файли `*.layout`, що читаються під час запуску. Нова розкладка — це новий файл, без перекомпіляції: кожен рядок `chars = …` перелічує, що друкує розкладка на клавішах попереднього рядка `keys = …` (ASCII-символи ігноруються, текст у полях введення не змінюється). Пошук: `$DUOP_LAYOUTS` (каталоги через `:`, замінює типові) або `~/.config/duop/layouts` (`$XDG_CONFIG_HOME`), далі `layouts/` і `../share/duop/layouts` поруч із бінарником, `/usr/local/share/duop/layouts`, `/usr/share/duop/layouts`. Українська постачається як [`layouts/uk.layout`](layouts/uk.layout)
- `F1` — довідка, `F2` — перейменування, `F3` — перегляд (для зображень спершу питає: Зображення / HEX / Текст; `i`/`h`/`t` перемикають режим), `Alt+V` — режим прев'ю Зображення / HEX / Текст (PNG, JPEG, GIF, BMP, TGA, PNM, QOI; справжні пікселі через Kitty або Sixel — визначається автоматично, інакше блоки 2×2; примусово: `DUOP_IMG_MODE=kitty|sixel|blocks|halfblock`), `F4` — зовнішній `$EDITOR`, `F5` — копіювання, `F6` — переміщення, `F7` — створити каталог, `F8` / `Del` — видалення, `F9` / `Ctrl+P` — режим Live Preview, `Ctrl+N` — новий файл, `Ctrl+G` — перейти за шляхом, `Ctrl+O` — shell, `F10` / `q` — вихід
- **Автооновлення панелей**: зміни на диску (створення, видалення, перейменування, зміна розміру) з'являються самі через `inotify`, без `Ctrl+R`; позначені файли ніколи не скидаються. У простої процес не прокидається взагалі (0 % CPU)
- **Фонові операції** (`F5`/`F6`/`F8` виконуються в окремому `fork`-процесі, інтерфейс не блокується): `ProgressDialog` з'являється для операцій довших за 300 мс — поточний файл, прогрес-бар, байти/файли, швидкість, ETA; `P`/`Space` — пауза/продовження (`SIGSTOP`/`SIGCONT`), `Esc`/`B` — у фон (прогрес лишається у статус-рядку), `C` — скасувати (недописаний файл видаляється), `Alt+J` або клік по статус-рядку — повернути діалог. В українській розкладці працюють `з`/`и`/`с`/`Alt+о` (з `layouts/uk.layout`). Вихід під час операції просить підтвердження й коректно зупиняє воркер

### Миша (SGR 1006)
- **Лівий клік / Подвійний клік** — вибір панелі й рядка / вхід у директорію або відкриття переглядача
- **Правий клік** — позначення/зняття виділення файлу
- **Колесо миші** — прокрутка панелі під курсором, вікна перегляду чи довідки
- **Клік по заголовках колонок (`Name`, `Size`, `Modified`)** — зміна поля й напрямку сортування (`▲`/`▼`)
- **Перетягування скролбару** — швидка прокрутка великих директорій
- **Hover та клік по кнопках** у верхньому барі, нижньому F-барі та діалогових вікнах

## План розвитку

Детальну архітектурну дорожню карту (`v1.1` → `v2.0`) задокументовано у [`ROADMAP.md`](ROADMAP.md).

## Розробник

- **Автор**: Недбайло Костянтин Геннадійович (`Kostiantyn Nedbailo`)
- **E-mail**: [ChessPlayerSedoy@gmail.com](mailto:ChessPlayerSedoy@gmail.com)

## Ліцензія

**Duop** — це програмне забезпечення з відкритим вихідним кодом (Open Source), яке поширюється за ліцензією [**MIT License**](LICENSE).
