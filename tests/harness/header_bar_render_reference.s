# Frozen reference oracle: src/ui/header_bar_render.s (before C23 migration to src/ui/header_bar.c).
# HeaderBar Widget (Inherits from Widget) — header bar render (split from header_bar.s)

.intel_syntax noprefix
.include "classes.inc"

.section .text
.global HeaderBar_render
.global HeaderBar_on_mouse

# void HeaderBar_render(HeaderBar *this, ScreenBuffer *scr, Theme *theme)
HeaderBar_render:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 64
    call HeaderBar_render__fill_entire_bar_background
    # Draw mode pill + git badge if room
    call HeaderBar_render__draw_mode_pill_git
    xor r14d, r14d            # zone idx
.Lhbr_zloop:
    cmp r14d, [rbx + HeaderBar.zone_count]
    jge .Lhbr_done
    call HeaderBar_render__pick_pill_bg
    # Select label string based on zone id (esi)
    mov r15, [rsp + 48]       # LangStrings *
    cmp esi, HDR_BTN_QUIT
    je .Lhbr_l_quit
    cmp esi, HDR_BTN_HELP
    je .Lhbr_l_help
    cmp esi, HDR_BTN_LANG
    je .Lhbr_l_lang
    cmp esi, HDR_BTN_HIDDEN
    je .Lhbr_l_hidden
    cmp esi, HDR_BTN_PREVIEW
    je .Lhbr_l_prev
    cmp esi, HDR_BTN_THEME
    je .Lhbr_l_theme
    jmp .Lhbr_znext

.Lhbr_l_quit:
    mov rax, [r15 + LangStrings.hdr_btn_quit]
    jmp .Lhbr_draw_pill
.Lhbr_l_help:
    mov rax, [r15 + LangStrings.hdr_btn_help]
    jmp .Lhbr_draw_pill
.Lhbr_l_lang:
    mov rax, [r15 + LangStrings.hdr_btn_lang]
    jmp .Lhbr_draw_pill
.Lhbr_l_prev:
    mov rax, [r15 + LangStrings.hdr_btn_prev]
    jmp .Lhbr_draw_pill
.Lhbr_l_hidden:
    mov rax, [rbx + HeaderBar.app]
    mov rax, [rax + App.active_pane]
    mov rax, [rax + FilePane.model]
    cmp dword ptr [rax + DirModel.show_hidden], 0
    je .Lhbr_hid_off
    mov rax, [r15 + LangStrings.hdr_btn_hid_on]
    jmp .Lhbr_draw_pill
.Lhbr_hid_off:
    mov rax, [r15 + LangStrings.hdr_btn_hid_off]
    jmp .Lhbr_draw_pill
.Lhbr_l_theme:
    push rcx
    push r8
    call HeaderBar_render__part4
    pop r8
    pop rcx
    mov rax, rsp              # buf at [rsp]
    jmp .Lhbr_draw_pill

.Lhbr_draw_pill:
    call HeaderBar_render__width
.Lhbr_znext:
    inc r14d
    jmp .Lhbr_zloop

.Lhbr_done:
    add rsp, 64
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# HeaderBar_render step: Fill entire bar background (runs on the caller's frame)
HeaderBar_render__fill_entire_bar_background:
    lea rsp, [rsp - 8]
    mov rbx, rdi              # this
    mov r12, rsi              # scr
    mov r13, rdx              # theme

    # Fill entire bar background
    mov rdi, r12
    mov esi, [r13 + Theme.header_fg]
    mov edx, [r13 + Theme.header_bg]
    xor ecx, ecx
    call ScreenBuffer_set_pen

    mov rdi, r12
    mov esi, [rbx + Widget.x]
    mov edx, [rbx + Widget.y]
    mov ecx, [rbx + Widget.w]
    mov r8d, 1
    mov r9d, ' '
    call ScreenBuffer_fill_rect

    # Draw brand badge on left
    call i18n_get
    mov [rsp + 48 + 16], rax  # save LangStrings *

    mov rdi, r12
    mov esi, [r13 + Theme.accent_fg]
    mov edx, [r13 + Theme.accent]
    mov ecx, ATTR_BOLD
    call ScreenBuffer_set_pen

    mov rax, [rsp + 48 + 16]
    mov rcx, [rax + LangStrings.hdr_brand]
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    mov edx, [rbx + Widget.y]
    mov r8d, [rbx + Widget.w]
    call ScreenBuffer_draw_text

.LHeaderBar_render__fill_entire_bar_background_ret:
    lea rsp, [rsp + 8]
    ret

# HeaderBar_render step: Draw mode pill git badge if room (runs on the caller's frame)
HeaderBar_render__draw_mode_pill_git:
    lea rsp, [rsp - 8]
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov rcx, [rsp + 48 + 16]
    call hdr_draw_mode_and_git

.Lhbr_zones:
.LHeaderBar_render__draw_mode_pill_git_ret:
    lea rsp, [rsp + 8]
    ret

# HeaderBar_render step: Pick pill bg (runs on the caller's frame)
HeaderBar_render__pick_pill_bg:
    lea rsp, [rsp - 8]
    imul rax, r14, HitZone._size
    lea r15, [rbx + HeaderBar.zones + rax]
    movsx esi, word ptr [r15 + HitZone.id]
    movsx ecx, word ptr [r15 + HitZone.x1]
    movsx r8d, word ptr [r15 + HitZone.x2]
    sub r8d, ecx              # width

    # Pick pill bg (highlight if hovered)
    mov edx, [r13 + Theme.badge_bg]
    mov edi, [r13 + Theme.badge_fg]
    xor r9d, r9d
    cmp esi, [rbx + HeaderBar.hovered_id]
    jne .Lhbr_not_hov
    mov edx, [r13 + Theme.accent]
    mov edi, [r13 + Theme.accent_fg]
    mov r9d, ATTR_BOLD
.Lhbr_not_hov:
    push rcx
    push r8
    push rsi
    mov [rsp + 24 + 16], edi  # fg
    mov rdi, r12
    mov esi, [rsp + 24 + 16]
    # edx = bg
    mov ecx, r9d
    call ScreenBuffer_set_pen
    pop rsi
    pop r8
    pop rcx

.LHeaderBar_render__pick_pill_bg_ret:
    lea rsp, [rsp + 8]
    ret

# HeaderBar_render step (runs on the caller's frame)
HeaderBar_render__part4:
    lea rsp, [rsp - 8]
    lea rdi, [rsp + 16]
    add rdi, 16               # scratch buf at [rsp + 16] after 2 pushes -> safe 48B
    mov rsi, [r15 + LangStrings.hdr_theme_pfx]
    mov edx, 48
    call str_copy
    lea rdi, [rsp + 16]
    add rdi, 16
    mov rsi, [r13 + Theme.name]
    mov edx, 48
    call str_cat
.LHeaderBar_render__part4_ret:
    lea rsp, [rsp + 8]
    ret

# HeaderBar_render step: width (runs on the caller's frame)
HeaderBar_render__width:
    lea rsp, [rsp - 8]
    mov rdi, r12
    mov esi, ecx              # x
    mov edx, [rbx + Widget.y]
    mov rcx, rax
    # r8d = width
    call ScreenBuffer_draw_text_pad

.LHeaderBar_render__width_ret:
    lea rsp, [rsp + 8]
    ret

# int HeaderBar_on_mouse(HeaderBar *this, Event *evt)
HeaderBar_on_mouse:
    push rbx
    push r12
    push r13
    call HeaderBar_on_mouse__evt
    # Find zone containing (r8d, r9d)
    call HeaderBar_on_mouse__find_zone_containing
    call HeaderBar_on_mouse__allow_hover_update_without
    pop r13
    pop r12
    pop rbx
    ret

# HeaderBar_on_mouse step: evt (runs on the caller's frame)
HeaderBar_on_mouse__evt:
    lea rsp, [rsp - 8]
    mov rbx, rdi
    mov r12, rsi              # evt

    mov r8d, [r12 + Event.mouse_x]
    mov r9d, [r12 + Event.mouse_y]

.LHeaderBar_on_mouse__evt_ret:
    lea rsp, [rsp + 8]
    ret

# HeaderBar_on_mouse step: Find zone containing (runs on the caller's frame)
HeaderBar_on_mouse__find_zone_containing:
    lea rsp, [rsp - 8]
    mov r13d, -1              # hit id
    xor ecx, ecx
.Lhbm_find:
    cmp ecx, [rbx + HeaderBar.zone_count]
    jge .Lhbm_found
    imul rax, rcx, HitZone._size
    lea r10, [rbx + HeaderBar.zones + rax]
    movsx edx, word ptr [r10 + HitZone.y]
    cmp r9d, edx
    jne .Lhbm_fnext
    movsx edx, word ptr [r10 + HitZone.x1]
    cmp r8d, edx
    jl .Lhbm_fnext
    movsx edx, word ptr [r10 + HitZone.x2]
    cmp r8d, edx
    jge .Lhbm_fnext
    movsx r13d, word ptr [r10 + HitZone.id]
    jmp .Lhbm_found
.Lhbm_fnext:
    inc ecx
    jmp .Lhbm_find

.Lhbm_found:
.LHeaderBar_on_mouse__find_zone_containing_ret:
    lea rsp, [rsp + 8]
    ret

# HeaderBar_on_mouse step: allow hover update without swallowing if outside (runs on the caller's frame)
HeaderBar_on_mouse__allow_hover_update_without:
    lea rsp, [rsp - 8]
    mov eax, [r12 + Event.mouse_kind]
    cmp eax, MACT_MOVE
    je .Lhbm_hover
    cmp eax, MACT_PRESS
    je .Lhbm_press
    xor eax, eax
    jmp .Lhbm_ret

.Lhbm_hover:
    cmp r13d, [rbx + HeaderBar.hovered_id]
    je .Lhbm_ret_zero
    mov [rbx + HeaderBar.hovered_id], r13d
    mov rax, [rbx + HeaderBar.app]
    mov dword ptr [rax + App.need_redraw], 1
.Lhbm_ret_zero:
    xor eax, eax              # allow hover update without swallowing if outside
    jmp .Lhbm_ret

.Lhbm_press:
    cmp dword ptr [r12 + Event.mouse_btn], MOUSE_LEFT
    jne .Lhbm_ret_zero
    cmp r13d, -1
    je .Lhbm_ret_zero

    mov rdi, [rbx + HeaderBar.app]
    cmp r13d, HDR_BTN_THEME
    je .Lhbm_do_theme
    cmp r13d, HDR_BTN_PREVIEW
    je .Lhbm_do_prev
    cmp r13d, HDR_BTN_HIDDEN
    je .Lhbm_do_hidden
    cmp r13d, HDR_BTN_LANG
    je .Lhbm_do_lang
    cmp r13d, HDR_BTN_HELP
    je .Lhbm_do_help
    cmp r13d, HDR_BTN_QUIT
    je .Lhbm_do_quit
    jmp .Lhbm_handled

.Lhbm_do_theme:
    call App_cmd_cycle_theme;    jmp .Lhbm_handled
.Lhbm_do_prev:
    call App_cmd_toggle_preview; jmp .Lhbm_handled
.Lhbm_do_hidden:
    call App_cmd_toggle_hidden;  jmp .Lhbm_handled
.Lhbm_do_lang:
    call App_cmd_toggle_lang;    jmp .Lhbm_handled
.Lhbm_do_help:
    call App_cmd_help;           jmp .Lhbm_handled
.Lhbm_do_quit:
    call App_cmd_quit;           jmp .Lhbm_handled

.Lhbm_handled:
    mov eax, 1
.Lhbm_ret:
.LHeaderBar_on_mouse__allow_hover_update_without_ret:
    lea rsp, [rsp + 8]
    ret
