# Configuration, UI constants, key codes, mouse constants, and Unicode glyphs

.intel_syntax noprefix

# --- Path & Buffer Limits ---
.equ PATH_MAX,            4096
.equ NAME_MAX,            256
.equ FILTER_MAX,          64
.equ STATUS_MAX,          512
.equ INPUT_MAX,           512
.equ PREVIEW_BUF_SIZE,    32768
.equ VIEWER_MAX_SIZE,     1048576   # 1 MiB max file load into built-in viewer
.equ OPS_DIRENTS_BUF_SIZE, 32768    # 32 KiB per recursion frame in file_ops
.equ DIRENTS_BUF_SIZE,    1048576   # 1 MiB getdents64 read buffer for DirModel streaming
.equ OUT_BUF_INIT_CAP,    131072    # 128 KiB ANSI flush buffer
.equ INITIAL_FILE_CAP,    512
.equ INITIAL_NAME_CAP,    65536     # 64 KiB contiguous UTF-8 filename pool
.equ STREAM_BATCH_BUDGET, 4096      # entries per incremental load batch in App_run
.equ HUGE_DIR_THRESHOLD,  50000     # switch to ls -f unsorted mode above this threshold

# --- Image decoding & preview thumbnails (src/fs/img_*.s) ---
.equ IMG_FMT_NONE, 0
.equ IMG_FMT_PNG,  1
.equ IMG_FMT_JPEG, 2
.equ IMG_FMT_GIF,  3
.equ IMG_FMT_BMP,  4
.equ IMG_FMT_PNM,  5
.equ IMG_FMT_TGA,  6
.equ IMG_FMT_QOI,  7
.equ IMG_FMT_WEBP, 8                 # detected, not decoded
.equ IMG_MAX_DIM,    16384
.equ IMG_MAX_PIXELS, 40000000
.equ IMG_E_FORMAT,  -1               # not an image / bad header
.equ IMG_E_UNSUP,   -2               # valid but unsupported variant (progressive JPEG, WebP, ...)
.equ IMG_E_CORRUPT, -3
.equ IMG_E_NOMEM,   -4
.equ IMG_THUMB_MAXW, 160             # thumbnail pixels (half-block: 1 col x 2 rows per cell)
.equ IMG_THUMB_MAXH, 100
.equ IMG_THUMB_HDR,  16              # u32 fmt, u32 src_w, u32 src_h, u16 tw, u16 th
.equ IMG_THUMB_CAP,  IMG_THUMB_HDR + IMG_THUMB_MAXW * IMG_THUMB_MAXH * 4
.equ PV_THUMB_OFF,  PREVIEW_BUF_SIZE + 16              # thumbnail inside PreviewPane.buf
.equ PV_BUF_TOTAL,  PV_THUMB_OFF + IMG_THUMB_CAP
.equ PV_MODE_AUTO,  0                # preview / viewer presentation of a file
.equ PV_MODE_IMAGE, 1
.equ PV_MODE_HEX,   2
.equ PV_MODE_TEXT,  3

# --- Background Task (fork worker) ---
.equ TASK_OP_COPY,        1
.equ TASK_OP_MOVE,        2
.equ TASK_OP_DELETE,      3
.equ TASK_PHASE_SCAN,     1
.equ TASK_PHASE_RUN,      2
.equ TASK_PHASE_DONE,     3
.equ TASK_SHM_SIZE,       4096      # one shared page for TaskShared
.equ TASK_DLG_DELAY_MS,   300       # show ProgressDialog only for operations slower than this
.equ TASK_TICK_MS,        100       # UI refresh cadence while a task runs
.equ TASK_KILL_GRACE_MS,  3000      # shutdown: SIGKILL a worker that ignores cancel this long

.equ CONFLICT_ACT_OVERWRITE, 1
.equ CONFLICT_ACT_SKIP,      2
.equ CONFLICT_ACT_RENAME,    3

# --- Event loop timings ---
.equ PREVIEW_DEBOUNCE_MS, 25        # coalesce rapid cursor moves into one preview read
.equ WATCH_DEBOUNCE_MS,   150       # coalesce bursts of directory change events
.equ WATCH_MIN_GAP_MS,    500       # at most two auto-refreshes per second per pane

# --- LRU Directory Cache ---
.equ DC_SLOTS,            16
.equ DC_BUDGET,           33554432  # 32 MiB of cached entries/order/name pools at most

# --- Double-click threshold (milliseconds) ---
.equ DBLCLICK_MS,         420

# --- Cell & Attribute Bits ---
.equ CELL_WIDE_TAIL,      0xFFFFFFFF
.equ ATTR_NONE,           0
.equ ATTR_BOLD,           1
.equ ATTR_DIM,            2
.equ ATTR_ITALIC,         4
.equ ATTR_UNDERLINE,      8
.equ ATTR_REVERSE,        16

# --- Event Types ---
.equ EVT_NONE,            0
.equ EVT_KEY,             1
.equ EVT_MOUSE,           2
.equ EVT_RESIZE,          3
.equ EVT_TICK,            4

# --- Key Modifiers ---
.equ MOD_SHIFT,           1
.equ MOD_ALT,             2
.equ MOD_CTRL,            4

# --- Special Key Codes (non-Unicode range >= 0x100000) ---
.equ KEY_NONE,            0
.equ KEY_UP,              0x100001
.equ KEY_DOWN,            0x100002
.equ KEY_LEFT,            0x100003
.equ KEY_RIGHT,           0x100004
.equ KEY_HOME,            0x100005
.equ KEY_END,             0x100006
.equ KEY_PGUP,            0x100007
.equ KEY_PGDN,            0x100008
.equ KEY_INSERT,          0x100009
.equ KEY_DELETE,          0x10000A
.equ KEY_BACKSPACE,       0x10000B
.equ KEY_TAB,             0x10000C
.equ KEY_BTAB,            0x10000D
.equ KEY_ENTER,           0x10000E
.equ KEY_ESC,             0x10000F
.equ KEY_F1,              0x100011
.equ KEY_F2,              0x100012
.equ KEY_F3,              0x100013
.equ KEY_F4,              0x100014
.equ KEY_F5,              0x100015
.equ KEY_F6,              0x100016
.equ KEY_F7,              0x100017
.equ KEY_F8,              0x100018
.equ KEY_F9,              0x100019
.equ KEY_F10,             0x10001A
.equ KEY_F11,             0x10001B
.equ KEY_F12,             0x10001C

# --- Mouse Buttons & Actions ---
.equ MOUSE_LEFT,          0
.equ MOUSE_MID,           1
.equ MOUSE_RIGHT,         2
.equ MOUSE_NONE,          3
.equ MOUSE_WHEEL_UP,      64
.equ MOUSE_WHEEL_DOWN,    65

.equ MACT_PRESS,          1
.equ MACT_RELEASE,        2
.equ MACT_DRAG,           3
.equ MACT_MOVE,           4
.equ MACT_WHEEL,          5

# --- FileEntry Flags ---
.equ FE_IS_DIR,           1
.equ FE_IS_LINK,          2
.equ FE_IS_EXEC,          4
.equ FE_IS_HIDDEN,        8
.equ FE_SELECTED,         16
.equ FE_IS_PARENT,        32
.equ FE_LINK_DIR,         64
.equ FE_STAT_READY,       128
.equ FE_DT_UNKNOWN,       256

# --- Sort Modes ---
.equ SORT_NAME,           0
.equ SORT_SIZE,           1
.equ SORT_MTIME,          2
.equ SORT_EXT,            3

# --- Widget Flags ---
.equ WF_VISIBLE,          1
.equ WF_FOCUSED,          2
.equ WF_HOVERED,          4
.equ WF_DIRTY,            8
.equ WF_ENABLED,          16

# --- Dialog Result Codes ---
.equ DLG_OPEN,            0
.equ DLG_OK,              1
.equ DLG_CANCEL,          2

# --- App Modes / Right Pane Mode ---
.equ RIGHT_MODE_PANE,     0
.equ RIGHT_MODE_PREVIEW,  1

# --- Configurable Action IDs (duoprc bind) ---
.equ ACT_QUIT,            1
.equ ACT_HELP,            2
.equ ACT_RENAME,          3
.equ ACT_VIEW,            4
.equ ACT_EDIT,            5
.equ ACT_COPY,            6
.equ ACT_MOVE,            7
.equ ACT_MKDIR,           8
.equ ACT_DELETE,          9
.equ ACT_PREVIEW,         10
.equ ACT_HIDDEN,          11
.equ ACT_THEME,           12
.equ ACT_LANG,            13
.equ ACT_FILTER,          14
.equ ACT_GOTO,            15
.equ ACT_NEWFILE,         16
.equ ACT_SHELL,           17
.equ ACT_REFRESH,         18
.equ ACT_USERMENU,        19

# --- Unicode Codepoints for Modern UI ---
.equ CH_BOX_TL,           0x256D   # ╭
.equ CH_BOX_TR,           0x256E   # ╮
.equ CH_BOX_BL,           0x2570   # ╰
.equ CH_BOX_BR,           0x256F   # ╯
.equ CH_BOX_H,            0x2500   # ─
.equ CH_BOX_V,            0x2502   # │
.equ CH_BOX_LT,           0x251C   # ├
.equ CH_BOX_RT,           0x2524   # ┤
.equ CH_BOX_TT,           0x252C   # ┬
.equ CH_BOX_BT,           0x2534   # ┴
.equ CH_BOX_VH,           0x253C   # ┼
.equ CH_BOX_HV,           0x2503   # ┃
.equ CH_BLOCK_FULL,       0x2588   # █
.equ CH_SHADE_LIGHT,      0x2591   # ░
.equ CH_TRI_RIGHT,        0x25B8   # ▸
.equ CH_TRI_DOWN,         0x25BE   # ▾
.equ CH_TRI_UP,           0x25B2   # ▲
.equ CH_TRI_DN_SOLID,     0x25BC   # ▼
.equ CH_SQ_SMALL,         0x25AA   # ▪
.equ CH_SQ_EMPTY,         0x25AB   # ▫
.equ CH_DIAMOND,          0x25C6   # ◆
.equ CH_DIAMOND_DOT,      0x25C8   # ◈
.equ CH_DIAMOND_OPEN,     0x25C7   # ◇
.equ CH_ARROW_NE,         0x2197   # ↗
.equ CH_CHECK,            0x2713   # ✓
.equ CH_LAQUO,            0x00AB   # «
.equ CH_RAQUO,            0x00BB   # »
.equ CH_LSAQUO,           0x2039   # ‹
.equ CH_RSAQUO,           0x203A   # ›
.equ CH_BULLET,           0x2022   # •
.equ CH_ELLIPSIS,         0x2026   # …
.equ CH_TIMES,            0x00D7   # ×
