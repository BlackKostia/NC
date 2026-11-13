# HeaderBar Widget (Inherits from Widget)
# Displays application brand badge, mode pill, and clickable right-aligned action pills.

.intel_syntax noprefix
.include "classes.inc"

.section .rodata
str_HeaderBar:   .asciz "HeaderBar"

.global HeaderBar_vtbl
HeaderBar_vtbl:
    WIDGET_VTBL_SLOTS str_HeaderBar, Widget_vtbl, HeaderBar._size, Widget_dtor, HeaderBar_layout, HeaderBar_render, Widget_on_key, HeaderBar_on_mouse, Widget_on_focus, Widget_hit_test

.section .text
.global HeaderBar_new
.global HeaderBar_layout
.global HeaderBar_render
.global HeaderBar_on_mouse

# HeaderBar *HeaderBar_new(App *app)
HeaderBar_new:
    push rbx
    push r12
    mov r12, rdi              # app

    NEW_OBJ HeaderBar_vtbl, HeaderBar._size
    test rax, rax
    jz .Lhbn_done
    mov rbx, rax

    mov rdi, rbx
    mov rsi, r12
    mov edx, 100
    call Widget_init
    mov [rbx + HeaderBar.app], r12
    mov dword ptr [rbx + HeaderBar.hovered_id], -1
    mov rax, rbx
.Lhbn_done:
    pop r12
    pop rbx
    ret

# Helper: append HitZone(x1, x2, y, id) at end of HeaderBar.zones
add_hdr_zone:
    # rdi=this, esi=x1, edx=x2, ecx=y, r8d=id
    mov eax, [rdi + HeaderBar.zone_count]
    cmp eax, 8
    jae .Lahz_done
    imul r9, rax, HitZone._size
    lea r9, [rdi + HeaderBar.zones + r9]
    mov [r9 + HitZone.x1], si
    mov [r9 + HitZone.x2], dx
    mov [r9 + HitZone.y], cx
    mov [r9 + HitZone.id], r8w
    inc dword ptr [rdi + HeaderBar.zone_count]
.Lahz_done:
    ret

# Helper: try to allocate right-aligned header pill of width ecx
# rdi=this, rsi=&right_x, edx=min_x, ecx=pill_w, r8d=y, r9d=id -> eax=1 if added
try_add_hdr_pill:
    mov eax, [rsi]
    sub eax, ecx
    dec eax                   # leave 1-col gap
    cmp eax, edx
    jl .Ltahp_fail
    mov [rsi], eax
    push rcx
    # add_hdr_zone(rdi=this, esi=x1, edx=x2, ecx=y, r8d=id)
    lea edx, [eax + ecx]
    mov esi, eax
    mov ecx, r8d
    mov r8d, r9d
    call add_hdr_zone
    pop rcx
    mov eax, 1
    ret
.Ltahp_fail:
    xor eax, eax
    ret

# void HeaderBar_layout(HeaderBar *this, int x, int y, int w, int h)
HeaderBar_layout:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16               # [rsp+0]=right_x (4B), [rsp+4]=min_x (4B)
    mov rbx, rdi
    mov r12d, ecx             # w
    mov r13d, edx             # y
    call Widget_layout

    mov dword ptr [rbx + HeaderBar.zone_count], 0
    call i18n_get
    mov r15, rax              # LangStrings *

    mov eax, [rbx + Widget.x]
    add eax, r12d
    mov [rsp], eax            # right_x

    # Reserve left area for brand + mode badge
    mov rdi, [r15 + LangStrings.hdr_brand]
    call utf8_display_width
    mov r14d, eax
    mov rdi, [r15 + LangStrings.hdr_mode_dual]
    call utf8_display_width
    mov r12d, eax
    mov rdi, [r15 + LangStrings.hdr_mode_prev]
    call utf8_display_width
    cmp eax, r12d
    cmovg r12d, eax
    mov eax, [rbx + Widget.x]
    add eax, r14d
    add eax, r12d
    add eax, 2
    mov [rsp + 4], eax        # min_x

    # 1. Quit
    mov rdi, [r15 + LangStrings.hdr_btn_quit]
    call utf8_display_width
    mov ecx, eax
    mov rdi, rbx
    mov rsi, rsp
    mov edx, [rsp + 4]
    mov r8d, r13d
    mov r9d, HDR_BTN_QUIT
    call try_add_hdr_pill
    test eax, eax
    jz .Lhbl_done

    # 2. Help
    mov rdi, [r15 + LangStrings.hdr_btn_help]
    call utf8_display_width
    mov ecx, eax
    mov rdi, rbx
    mov rsi, rsp
    mov edx, [rsp + 4]
    mov r8d, r13d
    mov r9d, HDR_BTN_HELP
    call try_add_hdr_pill
    test eax, eax
    jz .Lhbl_done

    # 3. Language switch
    mov rdi, [r15 + LangStrings.hdr_btn_lang]
    call utf8_display_width
    mov ecx, eax
    mov rdi, rbx
    mov rsi, rsp
    mov edx, [rsp + 4]
    mov r8d, r13d
    mov r9d, HDR_BTN_LANG
    call try_add_hdr_pill
    test eax, eax
    jz .Lhbl_done

    # 4. Hidden toggle (stable width = max(on, off))
    mov rdi, [r15 + LangStrings.hdr_btn_hid_on]
    call utf8_display_width
    mov r14d, eax
    mov rdi, [r15 + LangStrings.hdr_btn_hid_off]
    call utf8_display_width
    cmp r14d, eax
    cmovg eax, r14d
    mov ecx, eax
    mov rdi, rbx
    mov rsi, rsp
    mov edx, [rsp + 4]
    mov r8d, r13d
    mov r9d, HDR_BTN_HIDDEN
    call try_add_hdr_pill
    test eax, eax
    jz .Lhbl_done

    # 5. Preview toggle
    mov rdi, [r15 + LangStrings.hdr_btn_prev]
    call utf8_display_width
    mov ecx, eax
    mov rdi, rbx
    mov rsi, rsp
    mov edx, [rsp + 4]
    mov r8d, r13d
    mov r9d, HDR_BTN_PREVIEW
    call try_add_hdr_pill
    test eax, eax
    jz .Lhbl_done

    # 6. Theme pill (prefix + "Tokyo Night " = +12 cols)
    mov rdi, [r15 + LangStrings.hdr_theme_pfx]
    call utf8_display_width
    lea ecx, [eax + 12]
    mov rdi, rbx
    mov rsi, rsp
    mov edx, [rsp + 4]
    mov r8d, r13d
    mov r9d, HDR_BTN_THEME
    call try_add_hdr_pill

.Lhbl_done:
    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# void HeaderBar_render(HeaderBar *this, ScreenBuffer *scr, Theme *theme)
HeaderBar_render:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 64
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
    mov [rsp + 48], rax       # save LangStrings *

    mov rdi, r12
    mov esi, [r13 + Theme.accent_fg]
    mov edx, [r13 + Theme.accent]
    mov ecx, ATTR_BOLD
    call ScreenBuffer_set_pen

    mov rax, [rsp + 48]
    mov rcx, [rax + LangStrings.hdr_brand]
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    mov edx, [rbx + Widget.y]
    mov r8d, [rbx + Widget.w]
    call ScreenBuffer_draw_text

    # Draw mode pill if room
    mov rax, [rsp + 48]
    mov rdi, [rax + LangStrings.hdr_brand]
    call utf8_display_width
    mov r14d, [rbx + Widget.x]
    add r14d, eax
    inc r14d
    mov eax, [rbx + Widget.w]
    cmp eax, 30
    jl .Lhbr_zones

    mov rdi, r12
    mov esi, [r13 + Theme.header_fg]
    mov edx, [r13 + Theme.surface_alt]
    xor ecx, ecx
    call ScreenBuffer_set_pen

    mov rax, [rsp + 48]
    mov r8, [rbx + HeaderBar.app]
    mov rcx, [rax + LangStrings.hdr_mode_dual]
    cmp dword ptr [r8 + App.right_mode], RIGHT_MODE_PREVIEW
    jne .Lhbr_draw_mode
    mov rcx, [rax + LangStrings.hdr_mode_prev]
.Lhbr_draw_mode:
    push rcx
    mov rdi, rcx
    call utf8_display_width
    mov r8d, eax
    pop rcx
    mov rdi, r12
    mov esi, r14d
    mov edx, [rbx + Widget.y]
    call ScreenBuffer_draw_text

.Lhbr_zones:
    xor r14d, r14d            # zone idx
.Lhbr_zloop:
    cmp r14d, [rbx + HeaderBar.zone_count]
    jge .Lhbr_done
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
    mov [rsp + 24], edi       # fg
    mov rdi, r12
    mov esi, [rsp + 24]
    # edx = bg
    mov ecx, r9d
    call ScreenBuffer_set_pen
    pop rsi
    pop r8
    pop rcx

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
    mov rdi, rsp
    add rdi, 16               # scratch buf at [rsp + 16] after 2 pushes -> safe 48B
    mov rsi, [r15 + LangStrings.hdr_theme_pfx]
    mov edx, 48
    call str_copy
    mov rdi, rsp
    add rdi, 16
    mov rsi, [r13 + Theme.name]
    mov edx, 48
    call str_cat
    pop r8
    pop rcx
    mov rax, rsp              # buf at [rsp]
    jmp .Lhbr_draw_pill

.Lhbr_draw_pill:
    mov rdi, r12
    mov esi, ecx              # x
    mov edx, [rbx + Widget.y]
    mov rcx, rax
    # r8d = width
    call ScreenBuffer_draw_text_pad

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

# int HeaderBar_on_mouse(HeaderBar *this, Event *evt)
HeaderBar_on_mouse:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi              # evt

    mov r8d, [r12 + Event.mouse_x]
    mov r9d, [r12 + Event.mouse_y]

    # Find zone containing (r8d, r9d)
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

.Lhbm_do_theme:   call App_cmd_cycle_theme;    jmp .Lhbm_handled
.Lhbm_do_prev:    call App_cmd_toggle_preview; jmp .Lhbm_handled
.Lhbm_do_hidden:  call App_cmd_toggle_hidden;  jmp .Lhbm_handled
.Lhbm_do_lang:    call App_cmd_toggle_lang;    jmp .Lhbm_handled
.Lhbm_do_help:    call App_cmd_help;           jmp .Lhbm_handled
.Lhbm_do_quit:    call App_cmd_quit;           jmp .Lhbm_handled

.Lhbm_handled:
    mov eax, 1
.Lhbm_ret:
    pop r13
    pop r12
    pop rbx
    ret
