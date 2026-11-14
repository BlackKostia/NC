# Duop Runtime Configuration (~/.config/duop/duoprc) & User Menu Expansion
# Pure x86-64 GAS, zero .data, PAL-clean (no raw syscalls, no upward layer deps).

.intel_syntax noprefix
.include "pal.inc"
.include "config.inc"
.include "types.inc"

.equ CFG_MAX_BINDS,   32
.equ CFG_MAX_OPENS,   32
.equ CFG_MAX_MENUS,   24
.equ CFG_BIND_SZ,     16      # key(4), mods(4), action(4), pad(4)
.equ CFG_OPEN_SZ,     256     # ext(16), cmd(240)
.equ CFG_MENU_SZ,     256     # label(64), cmd(192)

.equ CFG_THEME,       0
.equ CFG_LANG,        4
.equ CFG_HIDDEN,      8
.equ CFG_SORT,        12
.equ CFG_COLOR_MASK,  16
.equ CFG_BIND_CNT,    20
.equ CFG_OPEN_CNT,    24
.equ CFG_MENU_CNT,    28
.equ CFG_COLORS,      32
.equ CFG_BINDS,       160
.equ CFG_OPENS,       672
.equ CFG_MENUS,       8864
.equ CFG_TOTAL_SZ,    15008

.equ CFG_FILE_MAX,    16384

.section .rodata
env_duop_cfg:      .asciz "DUOP_CONFIG="
env_xdg_cfg:       .asciz "XDG_CONFIG_HOME="
env_home:          .asciz "HOME="
rel_xdg_duoprc:    .asciz "duop/duoprc"
rel_home_duoprc:   .asciz ".config/duop/duoprc"

kw_theme:          .asciz "theme"
kw_lang:           .asciz "lang"
kw_show_hidden:    .asciz "show_hidden"
kw_sort:           .asciz "sort"
kw_color:          .asciz "color"
kw_bind:           .asciz "bind"
kw_open:           .asciz "open"
kw_menu:           .asciz "menu"

val_tokyo:         .asciz "tokyo"
val_catp:          .asciz "catppuccin"
val_emerald:       .asciz "emerald"
val_en:            .asciz "en"
val_ua:            .asciz "ua"
val_uk:            .asciz "uk"
val_on:            .asciz "on"
val_true:          .asciz "true"
val_off:           .asciz "off"
val_false:         .asciz "false"
val_name:          .asciz "name"
val_size:          .asciz "size"
val_mtime:         .asciz "mtime"
val_ext:           .asciz "ext"

# 29 Theme color field names matching Theme.bg .. Theme.scroll_thumb
cf_bg:             .asciz "bg"
cf_surface:        .asciz "surface"
cf_surface_alt:    .asciz "surface_alt"
cf_header_bg:      .asciz "header_bg"
cf_header_fg:      .asciz "header_fg"
cf_accent:         .asciz "accent"
cf_accent_fg:      .asciz "accent_fg"
cf_border_active:  .asciz "border_active"
cf_border_inact:   .asciz "border_inactive"
cf_text:           .asciz "text"
cf_muted:          .asciz "muted"
cf_dir_fg:         .asciz "dir_fg"
cf_exec_fg:        .asciz "exec_fg"
cf_link_fg:        .asciz "link_fg"
cf_hidden_fg:      .asciz "hidden_fg"
cf_selected_fg:    .asciz "selected_fg"
cf_selected_bg:    .asciz "selected_bg"
cf_cur_act_bg:     .asciz "cursor_active_bg"
cf_cur_inact_bg:   .asciz "cursor_inactive_bg"
cf_badge_bg:       .asciz "badge_bg"
cf_badge_hov_bg:   .asciz "badge_hover_bg"
cf_badge_fg:       .asciz "badge_fg"
cf_dialog_bg:      .asciz "dialog_bg"
cf_dialog_border:  .asciz "dialog_border"
cf_ok_fg:          .asciz "ok_fg"
cf_warn_fg:        .asciz "warn_fg"
cf_err_fg:         .asciz "err_fg"
cf_scroll_track:   .asciz "scroll_track"
cf_scroll_thumb:   .asciz "scroll_thumb"

.align 8
color_field_table:
    .quad cf_bg, cf_surface, cf_surface_alt, cf_header_bg, cf_header_fg
    .quad cf_accent, cf_accent_fg, cf_border_active, cf_border_inact
    .quad cf_text, cf_muted, cf_dir_fg, cf_exec_fg, cf_link_fg, cf_hidden_fg
    .quad cf_selected_fg, cf_selected_bg, cf_cur_act_bg, cf_cur_inact_bg
    .quad cf_badge_bg, cf_badge_hov_bg, cf_badge_fg
    .quad cf_dialog_bg, cf_dialog_border, cf_ok_fg, cf_warn_fg, cf_err_fg
    .quad cf_scroll_track, cf_scroll_thumb
.equ COLOR_FIELD_COUNT, 29

act_quit:          .asciz "quit"
act_help:          .asciz "help"
act_rename:        .asciz "rename"
act_view:          .asciz "view"
act_edit:          .asciz "edit"
act_copy:          .asciz "copy"
act_move:          .asciz "move"
act_mkdir:         .asciz "mkdir"
act_delete:        .asciz "delete"
act_preview:       .asciz "preview"
act_hidden:        .asciz "hidden"
act_theme:         .asciz "theme"
act_lang:          .asciz "lang"
act_filter:        .asciz "filter"
act_goto:          .asciz "goto"
act_newfile:       .asciz "newfile"
act_shell:         .asciz "shell"
act_refresh:       .asciz "refresh"
act_usermenu:      .asciz "usermenu"

.align 8
action_names_table:
    .quad act_quit, act_help, act_rename, act_view, act_edit
    .quad act_copy, act_move, act_mkdir, act_delete, act_preview
    .quad act_hidden, act_theme, act_lang, act_filter, act_goto
    .quad act_newfile, act_shell, act_refresh, act_usermenu
.equ ACTION_NAME_COUNT, 19

pfx_ctrl:          .asciz "ctrl+"
pfx_alt:           .asciz "alt+"

def_m0_lbl:        .asciz "Disk usage of current dir (du -sh)"
def_m0_cmd:        .asciz "du -sh \"%d\"; printf 'Press Enter...'; read -r _"
def_m1_lbl:        .asciz "File info (file / stat)"
def_m1_cmd:        .asciz "file \"%p\"; stat \"%p\"; printf 'Press Enter...'; read -r _"
def_m2_lbl:        .asciz "Line count (wc -l)"
def_m2_cmd:        .asciz "wc -l \"%p\"; printf 'Press Enter...'; read -r _"

.align 8
default_menu_table:
    .quad def_m0_lbl, def_m0_cmd
    .quad def_m1_lbl, def_m1_cmd
    .quad def_m2_lbl, def_m2_cmd
.equ DEFAULT_MENU_COUNT, 3

.section .bss
.align 16
g_config:          .space CFG_TOTAL_SZ

.section .text
.global config_load
.global config_get
.global config_lookup_bind
.global config_lookup_open
.global config_menu_count
.global config_menu_item
.global config_expand_cmd

.extern mem_alloc
.extern mem_free
.extern mem_zero
.extern sys_read_retry
.extern str_len
.extern str_copy
.extern str_cmp
.extern str_casecmp
.extern str_starts_with
.extern path_join

# Helper: const char *cfg_getenv(char **envp, const char *key_eq)
cfg_getenv:
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    test rbx, rbx
    jz .Lcge_none
    mov rdi, r12
    call str_len
    mov rcx, rax
.Lcge_loop:
    mov rdx, [rbx]
    test rdx, rdx
    jz .Lcge_none
    push rcx
    mov rdi, rdx
    mov rsi, r12
    call str_starts_with
    pop rcx
    test eax, eax
    jnz .Lcge_found
    add rbx, 8
    jmp .Lcge_loop
.Lcge_found:
    mov rax, [rbx]
    add rax, rcx
    pop r12
    pop rbx
    ret
.Lcge_none:
    xor eax, eax
    pop r12
    pop rbx
    ret

# Helper: skip spaces/tabs; returns advanced ptr in rax
skip_ws:
    mov rax, rdi
.Lsw_loop:
    movzx ecx, byte ptr [rax]
    cmp cl, ' '
    je .Lsw_next
    cmp cl, '\t'
    je .Lsw_next
    ret
.Lsw_next:
    inc rax
    jmp .Lsw_loop

# Helper: parse hex digit in al -> 0..15 or -1
hex_val:
    cmp al, '0'; jb .Lhv_bad
    cmp al, '9'; jbe .Lhv_dig
    or al, 0x20
    cmp al, 'a'; jb .Lhv_bad
    cmp al, 'f'; ja .Lhv_bad
    sub al, 'a' - 10
    movzx eax, al
    ret
.Lhv_dig:
    sub al, '0'
    movzx eax, al
    ret
.Lhv_bad:
    mov eax, -1
    ret

# Helper: parse "#RRGGBB" or "RRGGBB" -> rax = 0x01RRGGBB or -1
parse_hex_rgb:
    push rbx
    mov rbx, rdi
    cmp byte ptr [rbx], '#'
    jne .Lphr_digits
    inc rbx
.Lphr_digits:
    xor ecx, ecx              # acc
    xor edx, edx              # i = 0..5
.Lphr_loop:
    cmp edx, 6
    jae .Lphr_ok
    mov al, [rbx + rdx]
    call hex_val
    test eax, eax
    js .Lphr_bad
    shl ecx, 4
    or ecx, eax
    inc edx
    jmp .Lphr_loop
.Lphr_ok:
    or ecx, 0x01000000
    mov eax, ecx
    pop rbx
    ret
.Lphr_bad:
    mov eax, -1
    pop rbx
    ret

# Helper: parse key spec ("F1".."F12", "Ctrl+X", "Alt+X", or single char)
# rdi = tok -> eax = key, edx = mods (or eax = 0 on invalid)
parse_key_spec:
    push rbx
    push r12
    mov rbx, rdi
    xor r12d, r12d            # mods = 0

.Lpks_pfx:
    mov rdi, rbx
    lea rsi, [rip + pfx_ctrl]
    call str_len
    # case-insensitive prefix check for "ctrl+" (5) / "alt+" (4)
    mov al, [rbx]
    or al, 0x20
    cmp al, 'c'
    jne .Lpks_chk_alt
    mov al, [rbx + 1]; or al, 0x20; cmp al, 't'; jne .Lpks_chk_alt
    mov al, [rbx + 2]; or al, 0x20; cmp al, 'r'; jne .Lpks_chk_alt
    mov al, [rbx + 3]; or al, 0x20; cmp al, 'l'; jne .Lpks_chk_alt
    cmp byte ptr [rbx + 4], '+'
    jne .Lpks_chk_alt
    or r12d, MOD_CTRL
    add rbx, 5
    jmp .Lpks_pfx

.Lpks_chk_alt:
    mov al, [rbx]
    or al, 0x20
    cmp al, 'a'
    jne .Lpks_main
    mov al, [rbx + 1]; or al, 0x20; cmp al, 'l'; jne .Lpks_main
    mov al, [rbx + 2]; or al, 0x20; cmp al, 't'; jne .Lpks_main
    cmp byte ptr [rbx + 3], '+'
    jne .Lpks_main
    or r12d, MOD_ALT
    add rbx, 4
    jmp .Lpks_pfx

.Lpks_main:
    cmp byte ptr [rbx], 0
    je .Lpks_bad
    # Single char?
    cmp byte ptr [rbx + 1], 0
    jne .Lpks_fn
    movzx eax, byte ptr [rbx]
    test r12d, MOD_CTRL
    jz .Lpks_ok
    # Normalize Ctrl+<letter> to lowercase ASCII
    cmp eax, 'A'; jb .Lpks_ok
    cmp eax, 'Z'; ja .Lpks_ok
    add eax, 32
.Lpks_ok:
    mov edx, r12d
    pop r12
    pop rbx
    ret

.Lpks_fn:
    mov al, [rbx]
    or al, 0x20
    cmp al, 'f'
    jne .Lpks_bad
    movzx eax, byte ptr [rbx + 1]
    cmp al, '1'; jb .Lpks_bad
    cmp al, '9'; ja .Lpks_bad
    cmp byte ptr [rbx + 2], 0
    jne .Lpks_f10
    sub eax, '1'
    add eax, KEY_F1
    jmp .Lpks_ok
.Lpks_f10:
    cmp byte ptr [rbx + 1], '1'
    jne .Lpks_bad
    cmp byte ptr [rbx + 3], 0
    jne .Lpks_bad
    movzx eax, byte ptr [rbx + 2]
    cmp al, '0'; je .Lpks_is_f10
    cmp al, '1'; je .Lpks_is_f11
    cmp al, '2'; je .Lpks_is_f12
    jmp .Lpks_bad
.Lpks_is_f10:
    mov eax, KEY_F10
    jmp .Lpks_ok
.Lpks_is_f11:
    mov eax, KEY_F11
    jmp .Lpks_ok
.Lpks_is_f12:
    mov eax, KEY_F12
    jmp .Lpks_ok

.Lpks_bad:
    xor eax, eax
    xor edx, edx
    pop r12
    pop rbx
    ret

# Helper: extract next whitespace-delimited token (or "..." quoted token) in place
# rdi = cursor -> rax = token_start (NUL-terminated in buffer), rdx = next_cursor
next_token:
    call skip_ws
    mov r8, rax
    cmp byte ptr [r8], 0
    je .Lnt_empty
    cmp byte ptr [r8], '"'
    je .Lnt_quoted
    mov r9, r8
.Lnt_scan:
    movzx ecx, byte ptr [r9]
    test cl, cl
    jz .Lnt_end
    cmp cl, ' '
    je .Lnt_term
    cmp cl, '\t'
    je .Lnt_term
    cmp cl, '='
    je .Lnt_term
    inc r9
    jmp .Lnt_scan
.Lnt_term:
    mov byte ptr [r9], 0
    lea rdx, [r9 + 1]
    mov rax, r8
    ret
.Lnt_end:
    mov rax, r8
    mov rdx, r9
    ret
.Lnt_quoted:
    inc r8
    mov r9, r8
.Lnt_qscan:
    movzx ecx, byte ptr [r9]
    test cl, cl
    jz .Lnt_end
    cmp cl, '"'
    je .Lnt_term
    inc r9
    jmp .Lnt_qscan
.Lnt_empty:
    xor eax, eax
    mov rdx, r8
    ret

# Helper: parse one NUL-terminated line (modified in place)
parse_config_line:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    sub rsp, 16

    call skip_ws
    mov rbx, rax
    movzx eax, byte ptr [rbx]
    test al, al
    jz .Lpcl_done
    cmp al, '#'
    je .Lpcl_done
    cmp al, ';'
    je .Lpcl_done

    mov rdi, rbx
    call next_token           # rax = kw, rdx = rest
    test rax, rax
    jz .Lpcl_done
    mov r12, rax              # kw
    mov rdi, rdx
    call skip_ws
    cmp byte ptr [rax], '='
    jne .Lpcl_rest_ok
    inc rax
    mov rdi, rax
    call skip_ws
.Lpcl_rest_ok:
    mov r13, rax              # rest of line
    lea rbp, [rip + g_config]

    # --- theme ---
    mov rdi, r12
    lea rsi, [rip + kw_theme]
    call str_casecmp
    test eax, eax
    jnz .Lpcl_chk_lang
    mov rdi, r13
    call next_token
    test rax, rax
    jz .Lpcl_done
    mov r14, rax
    movzx ecx, byte ptr [r14]
    cmp cl, '0'
    jb .Lpcl_thm_name
    cmp cl, '2'
    ja .Lpcl_thm_name
    cmp byte ptr [r14 + 1], 0
    jne .Lpcl_thm_name
    sub ecx, '0'
    mov [rbp + CFG_THEME], ecx
    jmp .Lpcl_done
.Lpcl_thm_name:
    mov rdi, r14; lea rsi, [rip + val_tokyo]; call str_casecmp
    test eax, eax; jnz .Lpcl_t1
    mov dword ptr [rbp + CFG_THEME], 0; jmp .Lpcl_done
.Lpcl_t1:
    mov rdi, r14; lea rsi, [rip + val_catp]; call str_casecmp
    test eax, eax; jnz .Lpcl_t2
    mov dword ptr [rbp + CFG_THEME], 1; jmp .Lpcl_done
.Lpcl_t2:
    mov rdi, r14; lea rsi, [rip + val_emerald]; call str_casecmp
    test eax, eax; jnz .Lpcl_done
    mov dword ptr [rbp + CFG_THEME], 2
    jmp .Lpcl_done

.Lpcl_chk_lang:
    mov rdi, r12
    lea rsi, [rip + kw_lang]
    call str_casecmp
    test eax, eax
    jnz .Lpcl_chk_hid
    mov rdi, r13
    call next_token
    test rax, rax
    jz .Lpcl_done
    mov r14, rax
    mov rdi, r14; lea rsi, [rip + val_en]; call str_casecmp
    test eax, eax; jnz .Lpcl_lua
    mov dword ptr [rbp + CFG_LANG], 0; jmp .Lpcl_done
.Lpcl_lua:
    mov rdi, r14; lea rsi, [rip + val_ua]; call str_casecmp
    test eax, eax; jz .Lpcl_set_ua
    mov rdi, r14; lea rsi, [rip + val_uk]; call str_casecmp
    test eax, eax; jnz .Lpcl_done
.Lpcl_set_ua:
    mov dword ptr [rbp + CFG_LANG], 1
    jmp .Lpcl_done

.Lpcl_chk_hid:
    mov rdi, r12
    lea rsi, [rip + kw_show_hidden]
    call str_casecmp
    test eax, eax
    jnz .Lpcl_chk_sort
    mov rdi, r13
    call next_token
    test rax, rax
    jz .Lpcl_done
    mov r14, rax
    cmp byte ptr [r14], '1'; je .Lpcl_h1
    cmp byte ptr [r14], '0'; je .Lpcl_h0
    mov rdi, r14; lea rsi, [rip + val_on]; call str_casecmp; test eax, eax; jz .Lpcl_h1
    mov rdi, r14; lea rsi, [rip + val_true]; call str_casecmp; test eax, eax; jz .Lpcl_h1
    mov rdi, r14; lea rsi, [rip + val_off]; call str_casecmp; test eax, eax; jz .Lpcl_h0
    mov rdi, r14; lea rsi, [rip + val_false]; call str_casecmp; test eax, eax; jz .Lpcl_h0
    jmp .Lpcl_done
.Lpcl_h1:
    mov dword ptr [rbp + CFG_HIDDEN], 1; jmp .Lpcl_done
.Lpcl_h0:
    mov dword ptr [rbp + CFG_HIDDEN], 0; jmp .Lpcl_done

.Lpcl_chk_sort:
    mov rdi, r12
    lea rsi, [rip + kw_sort]
    call str_casecmp
    test eax, eax
    jnz .Lpcl_chk_color
    mov rdi, r13
    call next_token
    test rax, rax
    jz .Lpcl_done
    mov r14, rax
    mov rdi, r14; lea rsi, [rip + val_name]; call str_casecmp
    test eax, eax; jnz .Lpcl_s1
    mov dword ptr [rbp + CFG_SORT], SORT_NAME; jmp .Lpcl_done
.Lpcl_s1:
    mov rdi, r14; lea rsi, [rip + val_size]; call str_casecmp
    test eax, eax; jnz .Lpcl_s2
    mov dword ptr [rbp + CFG_SORT], SORT_SIZE; jmp .Lpcl_done
.Lpcl_s2:
    mov rdi, r14; lea rsi, [rip + val_mtime]; call str_casecmp
    test eax, eax; jnz .Lpcl_s3
    mov dword ptr [rbp + CFG_SORT], SORT_MTIME; jmp .Lpcl_done
.Lpcl_s3:
    mov rdi, r14; lea rsi, [rip + val_ext]; call str_casecmp
    test eax, eax; jnz .Lpcl_done
    mov dword ptr [rbp + CFG_SORT], SORT_EXT; jmp .Lpcl_done

.Lpcl_chk_color:
    mov rdi, r12
    lea rsi, [rip + kw_color]
    call str_casecmp
    test eax, eax
    jnz .Lpcl_chk_bind
    mov rdi, r13
    call next_token
    test rax, rax
    jz .Lpcl_done
    mov r14, rax              # field name
    mov rdi, rdx
    call next_token
    test rax, rax
    jz .Lpcl_done
    mov rdi, rax
    call parse_hex_rgb
    test eax, eax
    js .Lpcl_done
    mov [rsp], eax            # rgb
    xor ebx, ebx
    lea r13, [rip + color_field_table]
.Lpcl_cf_loop:
    cmp ebx, COLOR_FIELD_COUNT
    jae .Lpcl_done
    mov rdi, r14
    mov rsi, [r13 + rbx * 8]
    call str_casecmp
    test eax, eax
    jz .Lpcl_cf_set
    inc ebx
    jmp .Lpcl_cf_loop
.Lpcl_cf_set:
    mov eax, [rsp]
    mov [rbp + CFG_COLORS + rbx * 4], eax
    mov ecx, ebx
    mov edx, 1
    shl edx, cl
    or [rbp + CFG_COLOR_MASK], edx
    jmp .Lpcl_done

.Lpcl_chk_bind:
    mov rdi, r12
    lea rsi, [rip + kw_bind]
    call str_casecmp
    test eax, eax
    jnz .Lpcl_chk_open
    mov rdi, r13
    call next_token
    test rax, rax
    jz .Lpcl_done
    mov r14, rax              # key tok
    mov rdi, rdx
    call next_token
    test rax, rax
    jz .Lpcl_done
    mov [rsp + 8], rax        # action tok
    mov rdi, r14
    call parse_key_spec       # eax = key, edx = mods
    test eax, eax
    jz .Lpcl_done
    mov [rsp], eax
    mov [rsp + 4], edx
    xor ebx, ebx
    lea r13, [rip + action_names_table]
.Lpcl_ba_loop:
    cmp ebx, ACTION_NAME_COUNT
    jae .Lpcl_done
    mov rdi, [rsp + 8]
    mov rsi, [r13 + rbx * 8]
    call str_casecmp
    test eax, eax
    jz .Lpcl_ba_set
    inc ebx
    jmp .Lpcl_ba_loop
.Lpcl_ba_set:
    mov ecx, [rbp + CFG_BIND_CNT]
    cmp ecx, CFG_MAX_BINDS
    jae .Lpcl_done
    imul rax, rcx, CFG_BIND_SZ
    lea rdi, [rbp + CFG_BINDS + rax]
    mov edx, [rsp]
    mov [rdi + 0], edx
    mov edx, [rsp + 4]
    mov [rdi + 4], edx
    inc ebx                   # ACT_* are 1..19
    mov [rdi + 8], ebx
    inc dword ptr [rbp + CFG_BIND_CNT]
    jmp .Lpcl_done

.Lpcl_chk_open:
    mov rdi, r12
    lea rsi, [rip + kw_open]
    call str_casecmp
    test eax, eax
    jnz .Lpcl_chk_menu
    mov rdi, r13
    call next_token
    test rax, rax
    jz .Lpcl_done
    mov r14, rax
    cmp byte ptr [r14], '.'
    jne .Lpcl_op_ext
    inc r14
.Lpcl_op_ext:
    cmp byte ptr [r14], 0
    je .Lpcl_done
    mov rdi, rdx
    call skip_ws
    cmp byte ptr [rax], 0
    je .Lpcl_done
    mov r13, rax              # cmd
    mov ecx, [rbp + CFG_OPEN_CNT]
    cmp ecx, CFG_MAX_OPENS
    jae .Lpcl_done
    imul rax, rcx, CFG_OPEN_SZ
    lea rbx, [rbp + CFG_OPENS + rax]
    mov rdi, rbx
    mov rsi, r14
    mov edx, 16
    call str_copy
    lea rdi, [rbx + 16]
    mov rsi, r13
    mov edx, 240
    call str_copy
    inc dword ptr [rbp + CFG_OPEN_CNT]
    jmp .Lpcl_done

.Lpcl_chk_menu:
    mov rdi, r12
    lea rsi, [rip + kw_menu]
    call str_casecmp
    test eax, eax
    jnz .Lpcl_done
    mov rdi, r13
    call next_token
    test rax, rax
    jz .Lpcl_done
    mov r14, rax              # label
    mov rdi, rdx
    call skip_ws
    cmp byte ptr [rax], 0
    je .Lpcl_done
    mov r13, rax              # cmd
    mov ecx, [rbp + CFG_MENU_CNT]
    cmp ecx, CFG_MAX_MENUS
    jae .Lpcl_done
    imul rax, rcx, CFG_MENU_SZ
    lea rbx, [rbp + CFG_MENUS + rax]
    mov rdi, rbx
    mov rsi, r14
    mov edx, 64
    call str_copy
    lea rdi, [rbx + 64]
    mov rsi, r13
    mov edx, 192
    call str_copy
    inc dword ptr [rbp + CFG_MENU_CNT]

.Lpcl_done:
    add rsp, 16
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

# void config_load(char **envp)
config_load:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, PATH_MAX + 8
    mov rbx, rdi              # envp

    # Initialize defaults
    lea rdi, [rip + g_config]
    mov esi, CFG_TOTAL_SZ
    call mem_zero
    lea r12, [rip + g_config]
    mov dword ptr [r12 + CFG_THEME], -1
    mov dword ptr [r12 + CFG_LANG], -1
    mov dword ptr [r12 + CFG_HIDDEN], -1
    mov dword ptr [r12 + CFG_SORT], -1

    # 1. Try DUOP_CONFIG
    mov rdi, rbx
    lea rsi, [rip + env_duop_cfg]
    call cfg_getenv
    test rax, rax
    jz .Lcl_try_xdg
    cmp byte ptr [rax], 0
    je .Lcl_try_xdg
    mov rsi, rax
    jmp .Lcl_open

.Lcl_try_xdg:
    mov rdi, rbx
    lea rsi, [rip + env_xdg_cfg]
    call cfg_getenv
    test rax, rax
    jz .Lcl_try_home
    cmp byte ptr [rax], 0
    je .Lcl_try_home
    mov rdi, rsp
    mov rsi, rax
    lea rdx, [rip + rel_xdg_duoprc]
    mov ecx, PATH_MAX
    call path_join
    mov rsi, rsp
    jmp .Lcl_open

.Lcl_try_home:
    mov rdi, rbx
    lea rsi, [rip + env_home]
    call cfg_getenv
    test rax, rax
    jz .Lcl_done
    cmp byte ptr [rax], 0
    je .Lcl_done
    mov rdi, rsp
    mov rsi, rax
    lea rdx, [rip + rel_home_duoprc]
    mov ecx, PATH_MAX
    call path_join
    mov rsi, rsp

.Lcl_open:
    mov edi, AT_FDCWD
    mov edx, O_RDONLY | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
    js .Lcl_done
    mov r13d, eax             # fd

    mov edi, CFG_FILE_MAX
    call mem_alloc
    test rax, rax
    jz .Lcl_close
    mov r14, rax              # buf

    xor ebx, ebx              # total
.Lcl_read:
    cmp rbx, CFG_FILE_MAX - 1
    jae .Lcl_parse
    mov edi, r13d
    lea rsi, [r14 + rbx]
    mov rdx, CFG_FILE_MAX - 1
    sub rdx, rbx
    call sys_read_retry
    test rax, rax
    jle .Lcl_parse
    add rbx, rax
    jmp .Lcl_read

.Lcl_parse:
    mov byte ptr [r14 + rbx], 0
    mov rdi, r14
.Lcl_line_loop:
    cmp byte ptr [rdi], 0
    je .Lcl_free
    mov rbx, rdi
.Lcl_find_nl:
    movzx eax, byte ptr [rbx]
    test al, al
    jz .Lcl_last_line
    cmp al, '\n'
    je .Lcl_got_nl
    cmp al, '\r'
    jne .Lcl_fn_next
    mov byte ptr [rbx], 0
.Lcl_fn_next:
    inc rbx
    jmp .Lcl_find_nl
.Lcl_got_nl:
    mov byte ptr [rbx], 0
    inc rbx
    push rbx
    call parse_config_line
    pop rdi
    jmp .Lcl_line_loop
.Lcl_last_line:
    call parse_config_line

.Lcl_free:
    mov rdi, r14
    call mem_free
.Lcl_close:
    mov edi, r13d
    OS_CLOSE
.Lcl_done:
    add rsp, PATH_MAX + 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Config *config_get(void)
config_get:
    lea rax, [rip + g_config]
    ret

# int config_lookup_bind(int key, int mods) -> action_id or -1
config_lookup_bind:
    lea r8, [rip + g_config]
    mov ecx, [r8 + CFG_BIND_CNT]
    xor edx, edx
.Lclb_loop:
    cmp edx, ecx
    jae .Lclb_none
    imul rax, rdx, CFG_BIND_SZ
    lea r9, [r8 + CFG_BINDS + rax]
    cmp [r9 + 0], edi
    jne .Lclb_next
    cmp [r9 + 4], esi
    jne .Lclb_next
    mov eax, [r9 + 8]
    ret
.Lclb_next:
    inc edx
    jmp .Lclb_loop
.Lclb_none:
    mov eax, -1
    ret

# const char *config_lookup_open(const char *filename)
config_lookup_open:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    test rbx, rbx
    jz .Lclo_none
    # Find last '.' after index 0
    xor r12d, r12d
    mov rcx, 1
    cmp byte ptr [rbx], 0
    je .Lclo_none
.Lclo_dot:
    mov al, [rbx + rcx]
    test al, al
    jz .Lclo_dot_done
    cmp al, '.'
    jne .Lclo_dot_next
    lea r12, [rbx + rcx + 1]
.Lclo_dot_next:
    inc rcx
    jmp .Lclo_dot
.Lclo_dot_done:
    test r12, r12
    jz .Lclo_none
    cmp byte ptr [r12], 0
    je .Lclo_none

    lea r13, [rip + g_config]
    xor ebx, ebx
.Lclo_loop:
    cmp ebx, [r13 + CFG_OPEN_CNT]
    jae .Lclo_none
    imul rax, rbx, CFG_OPEN_SZ
    lea r8, [r13 + CFG_OPENS + rax]
    mov rdi, r12
    mov rsi, r8
    push r8
    call str_casecmp
    pop r8
    test eax, eax
    jz .Lclo_hit
    inc ebx
    jmp .Lclo_loop
.Lclo_hit:
    lea rax, [r8 + 16]
    pop r13
    pop r12
    pop rbx
    ret
.Lclo_none:
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    ret

# int config_menu_count(void)
config_menu_count:
    lea rax, [rip + g_config]
    mov eax, [rax + CFG_MENU_CNT]
    test eax, eax
    jnz .Lcmc_ret
    mov eax, DEFAULT_MENU_COUNT
.Lcmc_ret:
    ret

# int config_menu_item(int idx, const char **out_label, const char **out_cmd)
config_menu_item:
    lea r8, [rip + g_config]
    mov ecx, [r8 + CFG_MENU_CNT]
    test ecx, ecx
    jz .Lcmi_def
    cmp edi, ecx
    jae .Lcmi_bad
    imul rax, rdi, CFG_MENU_SZ
    lea r8, [r8 + CFG_MENUS + rax]
    mov [rsi], r8
    lea r8, [r8 + 64]
    mov [rdx], r8
    mov eax, 1
    ret
.Lcmi_def:
    cmp edi, DEFAULT_MENU_COUNT
    jae .Lcmi_bad
    shl rdi, 4                # * 16 (2 quads)
    lea r8, [rip + default_menu_table]
    mov rax, [r8 + rdi]
    mov [rsi], rax
    mov rax, [r8 + rdi + 8]
    mov [rdx], rax
    mov eax, 1
    ret
.Lcmi_bad:
    xor eax, eax
    ret

# void config_expand_cmd(const char *tmpl, char *out, size_t cap, const ConfigExpandCtx *ctx)
# ConfigExpandCtx: +0 cur_name, +8 cur_path, +16 sel_names, +24 active_dir, +32 inactive_dir
config_expand_cmd:
    push rbx
    push r12
    push r13
    push r14
    mov rbx, rdi              # tmpl
    mov r12, rsi              # out
    mov r13, rdx              # cap
    mov r14, rcx              # ctx
    test r13, r13
    jz .Lcec_ret
    dec r13                   # reserve NUL
    xor ecx, ecx              # out_i = 0

.Lcec_loop:
    movzx eax, byte ptr [rbx]
    test al, al
    jz .Lcec_done
    cmp al, '%'
    jne .Lcec_lit
    movzx edx, byte ptr [rbx + 1]
    test dl, dl
    jz .Lcec_lit

    cmp dl, '%'
    je .Lcec_pct
    xor r8d, r8d
    cmp dl, 'f'; jne .Lcec_p
    mov r8, [r14 + 0]; jmp .Lcec_sub
.Lcec_p:
    cmp dl, 'p'; jne .Lcec_F
    mov r8, [r14 + 8]; jmp .Lcec_sub
.Lcec_F:
    cmp dl, 'F'; jne .Lcec_s
    mov r8, [r14 + 16]; jmp .Lcec_sub
.Lcec_s:
    cmp dl, 's'; jne .Lcec_d
    mov r8, [r14 + 16]; jmp .Lcec_sub
.Lcec_d:
    cmp dl, 'd'; jne .Lcec_D
    mov r8, [r14 + 24]; jmp .Lcec_sub
.Lcec_D:
    cmp dl, 'D'; jne .Lcec_lit
    mov r8, [r14 + 32]
.Lcec_sub:
    add rbx, 2
    test r8, r8
    jz .Lcec_loop
.Lcec_cp:
    movzx eax, byte ptr [r8]
    test al, al
    jz .Lcec_loop
    cmp rcx, r13
    jae .Lcec_done
    mov [r12 + rcx], al
    inc rcx
    inc r8
    jmp .Lcec_cp

.Lcec_pct:
    add rbx, 2
    cmp rcx, r13
    jae .Lcec_done
    mov byte ptr [r12 + rcx], '%'
    inc rcx
    jmp .Lcec_loop

.Lcec_lit:
    cmp rcx, r13
    jae .Lcec_done
    mov [r12 + rcx], al
    inc rcx
    inc rbx
    jmp .Lcec_loop

.Lcec_done:
    mov byte ptr [r12 + rcx], 0
.Lcec_ret:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
