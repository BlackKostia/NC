# NeoCommander (`nc`)

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
 ├── DirModel        (читання директорій через getdents64 + newfstatat, QuickSort, фільтрація)
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
             └── HelpDialog     (довідка по клавішах, миші та архітектурі)
```

## Структура проєкту

```text
NC/
├── AGENTS.md                 # Правила модульної архітектури, SemVer і комітів
├── VERSION                   # Поточна SemVer-версія (1.0.0)
├── Makefile                  # Збірка (all / release / run / test / verify / hooks / clean)
├── .agents/                  # Antigravity скіли (nc-*) та lifecycle-хуки (hooks.json)
├── .githooks/                # Git-хуки (pre-commit, commit-msg, post-commit)
├── include/
│   ├── linux_sys.inc         # Системні виклики x86-64, kernel termios/stat/sigaction
│   ├── config.inc            # Ліміти, коди клавіш/миші, UTF-8 гліфи інтерфейсу
│   ├── oop.inc               # Макроси ООП-системи (CLASS_*, VTBL_*, VCALL, NEW_OBJ)
│   ├── types.inc             # Структури даних (Rect, Cell, Event, HitZone, FileEntry, Theme, LangStrings)
│   └── classes.inc           # Повна специфікація класів і vtable
├── src/
│   ├── main.s                # Точка входу _start (прапорці --lang / -l / -h / --help)
│   ├── core/                 # memory.s, string.s, utf8.s, oop_rt.s, syscall.s
│   ├── tui/                  # theme.s (3 TrueColor теми), i18n.s (UA/EN таблиці), screen.s, input.s (клавіатура + SGR 1006)
│   ├── fs/                   # dir_model.s, file_ops.s (рекурсивні copy/move/delete, mkdir/touch/rename)
│   ├── ui/                   # header_bar.s, function_bar.s, status_bar.s, file_pane.s, preview_pane.s, dialogs.s
│   └── app/                  # app.s
└── tests/
    └── test_pty.py           # Наскрізні тести в реальному PTY (клавіатура, миша, resize, ФС)
```

## Збірка, запуск та тестування

```bash
make          # Зібрати ./nc (з DWARF debug-інформацією)
make release  # Зібрати оптимізований stripped-бінарник
make run      # Запустити ./nc
make test     # Запустити наскрізні PTY-тести
make verify   # Повна перевірка (модульність + release + debug + ELF .data==0 + PTY)
make hooks    # Активувати Git-хуки з .githooks/ та права на скрипти
```

Можна передавати початкові каталоги та мову інтерфейсу (`ua` або `en`; також автовизначення з `LC_ALL`/`LC_MESSAGES`/`LANG`), або перевірити версію через `-V`/`--version`:
```bash
./nc --lang ua /path/to/left /path/to/right
./nc --version
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
- `Alt+L` (або кнопка `Мова:UA`/`Lang:EN` у верхній панелі) — миттєве перемикання мови (Українська / English), працює навіть при увімкненій українській розкладці (`Alt+д`)
- `F1` — довідка, `F2` — перейменування, `F3` — перегляд (`H` перемикає `Text/Hex`), `F4` — зовнішній `$EDITOR`, `F5` — копіювання, `F6` — переміщення, `F7` — створити каталог, `F8` / `Del` — видалення, `F9` / `Ctrl+P` — режим Live Preview, `Ctrl+N` — новий файл, `Ctrl+G` — перейти за шляхом, `Ctrl+O` — shell, `F10` / `q` — вихід

### Миша (SGR 1006)
- **Лівий клік / Подвійний клік** — вибір панелі й рядка / вхід у директорію або відкриття переглядача
- **Правий клік** — позначення/зняття виділення файлу
- **Колесо миші** — прокрутка панелі під курсором, вікна перегляду чи довідки
- **Клік по заголовках колонок (`Name`, `Size`, `Modified`)** — зміна поля й напрямку сортування (`▲`/`▼`)
- **Перетягування скролбару** — швидка прокрутка великих директорій
- **Hover та клік по кнопках** у верхньому барі, нижньому F-барі та діалогових вікнах

## План розвитку

Детальну архітектурну дорожню карту (`v1.1` → `v2.0`) задокументовано у [`ROADMAP.md`](ROADMAP.md).
