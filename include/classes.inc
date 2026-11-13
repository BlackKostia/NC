# Class Hierarchy & Virtual Table Specifications for Duop
#
# Inheritance tree:
#   Object
#     ├── ScreenBuffer
#     ├── DirModel
#     ├── App
#     └── Widget
#           ├── HeaderBar
#           ├── FunctionBar
#           ├── StatusBar
#           ├── FilePane
#           ├── PreviewPane
#           └── Dialog
#                 ├── ConfirmDialog
#                 ├── InputDialog
#                 ├── ViewerDialog
#                 └── HelpDialog

.intel_syntax noprefix

.include "config.inc"
.include "oop.inc"
.include "types.inc"

# ==============================================================================
# VTable Layouts
# ==============================================================================

VTBL_BEGIN ObjectVtbl
    VTBL_SLOT ObjectVtbl.super
    VTBL_SLOT ObjectVtbl.class_name
    VTBL_SLOT ObjectVtbl.inst_size
    VTBL_SLOT ObjectVtbl.dtor
VTBL_END ObjectVtbl

VTBL_BEGIN WidgetVtbl
    VTBL_EXTENDS ObjectVtbl
    VTBL_SLOT WidgetVtbl.layout
    VTBL_SLOT WidgetVtbl.render
    VTBL_SLOT WidgetVtbl.on_key
    VTBL_SLOT WidgetVtbl.on_mouse
    VTBL_SLOT WidgetVtbl.on_focus
    VTBL_SLOT WidgetVtbl.hit_test
VTBL_END WidgetVtbl

VTBL_BEGIN DialogVtbl
    VTBL_EXTENDS WidgetVtbl
    VTBL_SLOT DialogVtbl.on_confirm
    VTBL_SLOT DialogVtbl.on_cancel
VTBL_END DialogVtbl

# ==============================================================================
# Declarative VTable Builder Macros (Named Overrides + Inherited Defaults)
# ==============================================================================

.macro OBJECT_VTBL_SLOTS class_name_str, super_vtbl=0, inst_size=0, dtor=Object_dtor
    .quad \super_vtbl
    .quad \class_name_str
    .quad \inst_size
    .quad \dtor
.endm

.macro WIDGET_VTBL_SLOTS class_name_str, super_vtbl=Widget_vtbl, inst_size=Widget._size, dtor=Widget_dtor, layout=Widget_layout, render=Widget_render, on_key=Widget_on_key, on_mouse=Widget_on_mouse, on_focus=Widget_on_focus, hit_test=Widget_hit_test
    OBJECT_VTBL_SLOTS \class_name_str, \super_vtbl, \inst_size, \dtor
    .quad \layout
    .quad \render
    .quad \on_key
    .quad \on_mouse
    .quad \on_focus
    .quad \hit_test
.endm

.macro DIALOG_VTBL_SLOTS class_name_str, super_vtbl=Dialog_vtbl, inst_size=Dialog._size, dtor=Dialog_dtor, layout=Dialog_layout, render=Dialog_render, on_key=Dialog_on_key, on_mouse=Dialog_on_mouse, on_focus=Widget_on_focus, hit_test=Widget_hit_test, on_confirm=Dialog_on_confirm, on_cancel=Dialog_on_cancel
    WIDGET_VTBL_SLOTS \class_name_str, \super_vtbl, \inst_size, \dtor, \layout, \render, \on_key, \on_mouse, \on_focus, \hit_test
    .quad \on_confirm
    .quad \on_cancel
.endm

# ==============================================================================
# Class Struct Definitions
# ==============================================================================

CLASS_BEGIN Object
    FIELD Object.vptr, 8
CLASS_END Object

CLASS_BEGIN ScreenBuffer
    EXTENDS Object
    FIELD ScreenBuffer.front,      8
    FIELD ScreenBuffer.back,       8
    FIELD ScreenBuffer.out_buf,    8
    FIELD ScreenBuffer.out_len,    8
    FIELD ScreenBuffer.out_cap,    8
    FIELD ScreenBuffer.cell_cap,   8
    FIELD ScreenBuffer.width,      4
    FIELD ScreenBuffer.height,     4
    FIELD ScreenBuffer.force_full, 4
    FIELD ScreenBuffer.pen_fg,     4
    FIELD ScreenBuffer.pen_bg,     4
    FIELD ScreenBuffer.pen_attrs,  4
CLASS_END ScreenBuffer

CLASS_BEGIN DirModel
    EXTENDS Object
    FIELD DirModel.entries,     8
    FIELD DirModel.count,       8
    FIELD DirModel.cap,         8
    FIELD DirModel.total_bytes, 8
    FIELD DirModel.dir_count,   4
    FIELD DirModel.file_count,  4
    FIELD DirModel.sort_mode,   4
    FIELD DirModel.sort_desc,   4
    FIELD DirModel.show_hidden, 4
    FIELD DirModel.pad,         4
    FIELD DirModel.path,        PATH_MAX
    FIELD DirModel.filter,      FILTER_MAX
CLASS_END DirModel

CLASS_BEGIN Widget
    EXTENDS Object
    FIELD Widget.parent, 8
    FIELD Widget.x,      4
    FIELD Widget.y,      4
    FIELD Widget.w,      4
    FIELD Widget.h,      4
    FIELD Widget.flags,  4
    FIELD Widget.id,     4
CLASS_END Widget

CLASS_BEGIN HeaderBar
    EXTENDS Widget
    FIELD HeaderBar.app,        8
    FIELD HeaderBar.hovered_id, 4
    FIELD HeaderBar.zone_count, 4
    FIELD HeaderBar.zones,      8*HitZone._size
CLASS_END HeaderBar

CLASS_BEGIN FunctionBar
    EXTENDS Widget
    FIELD FunctionBar.app,        8
    FIELD FunctionBar.hovered_id, 4
    FIELD FunctionBar.zone_count, 4
    FIELD FunctionBar.zones,      10*HitZone._size
CLASS_END FunctionBar

CLASS_BEGIN StatusBar
    EXTENDS Widget
    FIELD StatusBar.app,           8
    FIELD StatusBar.msg_expire_ms, 8
    FIELD StatusBar.msg_kind,      4
    FIELD StatusBar.filter_active, 4
    FIELD StatusBar.msg,           STATUS_MAX
CLASS_END StatusBar

CLASS_BEGIN FilePane
    EXTENDS Widget
    FIELD FilePane.model,           8
    FIELD FilePane.app,             8
    FIELD FilePane.last_click_ms,   8
    FIELD FilePane.last_click_idx,  4
    FIELD FilePane.cursor,          4
    FIELD FilePane.scroll,          4
    FIELD FilePane.hovered_row,     4
    FIELD FilePane.hovered_col_hdr, 4
    FIELD FilePane.dragging_scroll, 4
    FIELD FilePane.hdr_zone_count,  4
    FIELD FilePane.pad,             4
    FIELD FilePane.hdr_zones,       4*HitZone._size
CLASS_END FilePane

CLASS_BEGIN PreviewPane
    EXTENDS Widget
    FIELD PreviewPane.app,         8
    FIELD PreviewPane.buf,         8
    FIELD PreviewPane.buf_len,     8
    FIELD PreviewPane.file_size,   8
    FIELD PreviewPane.scroll,      4
    FIELD PreviewPane.total_lines, 4
    FIELD PreviewPane.is_binary,   4
    FIELD PreviewPane.is_dir,      4
    FIELD PreviewPane.file_mode,   4
    FIELD PreviewPane.pad,         4
    FIELD PreviewPane.target_path, PATH_MAX
CLASS_END PreviewPane

CLASS_BEGIN Dialog
    EXTENDS Widget
    FIELD Dialog.app,         8
    FIELD Dialog.title,       8
    FIELD Dialog.result,      4
    FIELD Dialog.focus_btn,   4
    FIELD Dialog.hovered_btn, 4
    FIELD Dialog.btn_count,   4
    FIELD Dialog.op_tag,      4
    FIELD Dialog.pad,         4
    FIELD Dialog.btns,        4*HitZone._size
CLASS_END Dialog

CLASS_BEGIN ConfirmDialog
    EXTENDS Dialog
    FIELD ConfirmDialog.message, 512
    FIELD ConfirmDialog.detail,  512
CLASS_END ConfirmDialog

CLASS_BEGIN InputDialog
    EXTENDS Dialog
    FIELD InputDialog.prompt, 128
    FIELD InputDialog.buf,    INPUT_MAX
    FIELD InputDialog.len,    4
    FIELD InputDialog.cursor, 4
    FIELD InputDialog.scroll, 4
    FIELD InputDialog.pad,    4
CLASS_END InputDialog

CLASS_BEGIN ViewerDialog
    EXTENDS Dialog
    FIELD ViewerDialog.data,        8
    FIELD ViewerDialog.data_len,    8
    FIELD ViewerDialog.scroll_line, 4
    FIELD ViewerDialog.total_lines, 4
    FIELD ViewerDialog.hex_mode,    4
    FIELD ViewerDialog.pad,         4
    FIELD ViewerDialog.path,        PATH_MAX
CLASS_END ViewerDialog

CLASS_BEGIN HelpDialog
    EXTENDS Dialog
    FIELD HelpDialog.scroll, 4
    FIELD HelpDialog.pad,    4
CLASS_END HelpDialog

CLASS_BEGIN App
    EXTENDS Object
    FIELD App.screen,        8
    FIELD App.theme,         8
    FIELD App.lang,          8
    FIELD App.left_pane,     8
    FIELD App.right_pane,    8
    FIELD App.active_pane,   8
    FIELD App.preview_pane,  8
    FIELD App.header_bar,    8
    FIELD App.status_bar,    8
    FIELD App.func_bar,      8
    FIELD App.active_dialog, 8
    FIELD App.envp,          8
    FIELD App.running,       4
    FIELD App.need_redraw,   4
    FIELD App.theme_idx,     4
    FIELD App.lang_idx,      4
    FIELD App.right_mode,    4
    FIELD App.term_w,        4
    FIELD App.term_h,        4
    FIELD App.mouse_x,       4
    FIELD App.mouse_y,       4
    FIELD App.pad,           4
CLASS_END App

# --- Language IDs ---
.equ LANG_EN, 0
.equ LANG_UA, 1

# --- Operation Tags for Dialogs ---
.equ OP_NONE,    0
.equ OP_MKDIR,   1
.equ OP_RENAME,  2
.equ OP_COPY,    3
.equ OP_MOVE,    4
.equ OP_DELETE,  5
.equ OP_NEWFILE, 6
.equ OP_FILTER,  7
.equ OP_GOTO,    8
.equ OP_CHMOD,   9

# --- HeaderBar Action IDs ---
.equ HDR_BTN_THEME,   1
.equ HDR_BTN_PREVIEW, 2
.equ HDR_BTN_HIDDEN,  3
.equ HDR_BTN_HELP,    4
.equ HDR_BTN_QUIT,    5
.equ HDR_BTN_LANG,    6

# --- Status Message Kinds ---
.equ MSG_INFO, 0
.equ MSG_OK,   1
.equ MSG_WARN, 2
.equ MSG_ERR,  3
