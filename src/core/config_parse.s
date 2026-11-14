# Duop Runtime Configuration (~/.config/duop/duoprc) & User Menu Expansion — config parse (split from config.s)

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
.equ CFG_TOTAL_SZ,    15024         # + CFG_LANG_ID (config.inc)
.equ CFG_FILE_MAX,    16384
.equ COLOR_FIELD_COUNT, 29
.equ ACTION_NAME_COUNT, 19
.equ DEFAULT_MENU_COUNT, 3
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

.section .rodata

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

.section .text
.global parse_config_line

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
    call parse_config_line__rest_line
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
    lea rdi, [rbp + CFG_LANG_ID]      # language pack id, resolved by i18n_find
    mov rsi, rax
    mov edx, I18N_ID_LEN
    call str_copy
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
    call parse_config_line__part2
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
    call parse_config_line__act_are
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
    call parse_config_line__part4
    je .Lpcl_done
    mov rdi, rdx
    call skip_ws
    cmp byte ptr [rax], 0
    je .Lpcl_done
    mov r13, rax              # cmd
    mov ecx, [rbp + CFG_OPEN_CNT]
    cmp ecx, CFG_MAX_OPENS
    jae .Lpcl_done
    call parse_config_line__part5
    jmp .Lpcl_done

.Lpcl_chk_menu:
    call parse_config_line__label
.Lpcl_done:
    add rsp, 16
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

# parse_config_line step: rest of line (runs on the caller's frame)
parse_config_line__rest_line:
    lea rsp, [rsp - 8]
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

.Lparse_config_line__rest_line_ret:
    lea rsp, [rsp + 8]
    ret

# parse_config_line step (runs on the caller's frame)
parse_config_line__part2:
    lea rsp, [rsp - 8]
    mov eax, [rsp + 16]
    mov [rbp + CFG_COLORS + rbx * 4], eax
    mov ecx, ebx
    mov edx, 1
    shl edx, cl
    or [rbp + CFG_COLOR_MASK], edx
.Lparse_config_line__part2_ret:
    lea rsp, [rsp + 8]
    ret

# parse_config_line step: ACT_ are (runs on the caller's frame)
parse_config_line__act_are:
    lea rsp, [rsp - 8]
    imul rax, rcx, CFG_BIND_SZ
    lea rdi, [rbp + CFG_BINDS + rax]
    mov edx, [rsp + 16]
    mov [rdi + 0], edx
    mov edx, [rsp + 4 + 16]
    mov [rdi + 4], edx
    inc ebx                   # ACT_* are 1..19
    mov [rdi + 8], ebx
    inc dword ptr [rbp + CFG_BIND_CNT]
.Lparse_config_line__act_are_ret:
    lea rsp, [rsp + 8]
    ret

# parse_config_line step (runs on the caller's frame)
parse_config_line__part4:
    lea rsp, [rsp - 8]
    mov r14, rax
    cmp byte ptr [r14], '.'
    jne .Lpcl_op_ext
    inc r14
.Lpcl_op_ext:
    cmp byte ptr [r14], 0
.Lparse_config_line__part4_ret:
    lea rsp, [rsp + 8]
    ret

# parse_config_line step (runs on the caller's frame)
parse_config_line__part5:
    lea rsp, [rsp - 8]
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
.Lparse_config_line__part5_ret:
    lea rsp, [rsp + 8]
    ret

# parse_config_line step: label (runs on the caller's frame)
parse_config_line__label:
    lea rsp, [rsp - 8]
    mov rdi, r12
    lea rsi, [rip + kw_menu]
    call str_casecmp
    test eax, eax
    jnz .Lparse_config_line__label_ret
    mov rdi, r13
    call next_token
    test rax, rax
    jz .Lparse_config_line__label_ret
    mov r14, rax              # label
    mov rdi, rdx
    call skip_ws
    cmp byte ptr [rax], 0
    je .Lparse_config_line__label_ret
    mov r13, rax              # cmd
    mov ecx, [rbp + CFG_MENU_CNT]
    cmp ecx, CFG_MAX_MENUS
    jae .Lparse_config_line__label_ret
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

.Lparse_config_line__label_ret:
    lea rsp, [rsp + 8]
    ret
