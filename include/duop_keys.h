/* include/duop_keys.h - input vocabulary shared with assembly (include/config.inc): event types, modifiers, special
 * keys (everything >= 0x100000 is not a Unicode codepoint), mouse buttons/actions. tests/test_abi_layouts.py checks it. */
#pragma once

#define EVT_NONE 0
#define EVT_KEY 1
#define EVT_MOUSE 2
#define EVT_RESIZE 3
#define EVT_TICK 4

#define MOD_SHIFT 1
#define MOD_ALT 2
#define MOD_CTRL 4

#define KEY_NONE 0
#define KEY_UP 0x100001
#define KEY_DOWN 0x100002
#define KEY_LEFT 0x100003
#define KEY_RIGHT 0x100004
#define KEY_HOME 0x100005
#define KEY_END 0x100006
#define KEY_PGUP 0x100007
#define KEY_PGDN 0x100008
#define KEY_INSERT 0x100009
#define KEY_DELETE 0x10000A
#define KEY_BACKSPACE 0x10000B
#define KEY_TAB 0x10000C
#define KEY_BTAB 0x10000D
#define KEY_ENTER 0x10000E
#define KEY_ESC 0x10000F
#define KEY_F1 0x100011
#define KEY_F2 0x100012
#define KEY_F3 0x100013
#define KEY_F4 0x100014
#define KEY_F5 0x100015
#define KEY_F6 0x100016
#define KEY_F7 0x100017
#define KEY_F8 0x100018
#define KEY_F9 0x100019
#define KEY_F10 0x10001A
#define KEY_F11 0x10001B
#define KEY_F12 0x10001C

#define MOUSE_LEFT 0
#define MOUSE_MID 1
#define MOUSE_RIGHT 2
#define MOUSE_NONE 3
#define MOUSE_WHEEL_UP 64
#define MOUSE_WHEEL_DOWN 65

#define MACT_PRESS 1
#define MACT_RELEASE 2
#define MACT_DRAG 3
#define MACT_MOVE 4
#define MACT_WHEEL 5
