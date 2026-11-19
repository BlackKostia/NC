# Frozen reference oracle: src/ui/header_bar.s (before C23 migration to src/ui/header_bar.c).
# HeaderBar Widget (Inherits from Widget)
# Displays application brand badge, mode pill, and clickable right-aligned action pills.

.intel_syntax noprefix
.include "classes.inc"

.section .rodata
str_HeaderBar:   .asciz "HeaderBar"

HeaderBar_vtbl:
    WIDGET_VTBL_SLOTS str_HeaderBar, Widget_vtbl, HeaderBar._size, Widget_dtor, HeaderBar_layout, HeaderBar_render, Widget_on_key, HeaderBar_on_mouse, Widget_on_focus, Widget_hit_test

.section .text
.global HeaderBar_new
.global HeaderBar_layout
.global HeaderBar_vtbl

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
    call HeaderBar_layout__langstrings
    # Reserve left area for brand + mode badge
    call HeaderBar_layout__reserve_left_area_brand
    # 1. Quit
    call HeaderBar_layout__quit
    jz .Lhbl_done

    # 2. Help
    call HeaderBar_layout__help
    call HeaderBar_layout__language_switch
.Lhbl_done:
    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# HeaderBar_layout step: LangStrings (runs on the caller's frame)
HeaderBar_layout__langstrings:
    lea rsp, [rsp - 8]
    mov rbx, rdi
    mov r12d, ecx             # w
    mov r13d, edx             # y
    call Widget_layout

    mov dword ptr [rbx + HeaderBar.zone_count], 0
    call i18n_get
    mov r15, rax              # LangStrings *

    mov eax, [rbx + Widget.x]
    add eax, r12d
    mov [rsp + 16], eax  # right_x

.LHeaderBar_layout__langstrings_ret:
    lea rsp, [rsp + 8]
    ret

# HeaderBar_layout step: Reserve left area for brand mode badge (runs on the caller's frame)
HeaderBar_layout__reserve_left_area_brand:
    lea rsp, [rsp - 8]
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
    mov [rsp + 4 + 16], eax  # min_x

.LHeaderBar_layout__reserve_left_area_brand_ret:
    lea rsp, [rsp + 8]
    ret

# HeaderBar_layout step: Quit (runs on the caller's frame)
HeaderBar_layout__quit:
    lea rsp, [rsp - 8]
    mov rdi, [r15 + LangStrings.hdr_btn_quit]
    call utf8_display_width
    mov ecx, eax
    mov rdi, rbx
    lea rsi, [rsp + 16]
    mov edx, [rsp + 4 + 16]
    mov r8d, r13d
    mov r9d, HDR_BTN_QUIT
    call try_add_hdr_pill
    test eax, eax
.LHeaderBar_layout__quit_ret:
    lea rsp, [rsp + 8]
    ret

# HeaderBar_layout step: Help (runs on the caller's frame)
HeaderBar_layout__help:
    lea rsp, [rsp - 8]
    mov rdi, [r15 + LangStrings.hdr_btn_help]
    call utf8_display_width
    mov ecx, eax
    mov rdi, rbx
    lea rsi, [rsp + 16]
    mov edx, [rsp + 4 + 16]
    mov r8d, r13d
    mov r9d, HDR_BTN_HELP
    call try_add_hdr_pill
    test eax, eax
.LHeaderBar_layout__help_ret:
    lea rsp, [rsp + 8]
    ret

# HeaderBar_layout step: Language switch (runs on the caller's frame)
HeaderBar_layout__language_switch:
    lea rsp, [rsp - 8]
    jz .LHeaderBar_layout__language_switch_ret

    # 3. Language switch
    mov rdi, [r15 + LangStrings.hdr_btn_lang]
    call utf8_display_width
    mov ecx, eax
    mov rdi, rbx
    lea rsi, [rsp + 16]
    mov edx, [rsp + 4 + 16]
    mov r8d, r13d
    mov r9d, HDR_BTN_LANG
    call try_add_hdr_pill
    test eax, eax
    jz .LHeaderBar_layout__language_switch_ret

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
    lea rsi, [rsp + 16]
    mov edx, [rsp + 4 + 16]
    mov r8d, r13d
    mov r9d, HDR_BTN_HIDDEN
    call try_add_hdr_pill
    test eax, eax
    jz .LHeaderBar_layout__language_switch_ret

    # 5. Preview toggle
    mov rdi, [r15 + LangStrings.hdr_btn_prev]
    call utf8_display_width
    mov ecx, eax
    mov rdi, rbx
    lea rsi, [rsp + 16]
    mov edx, [rsp + 4 + 16]
    mov r8d, r13d
    mov r9d, HDR_BTN_PREVIEW
    call try_add_hdr_pill
    test eax, eax
    jz .LHeaderBar_layout__language_switch_ret

    # 6. Theme pill (prefix + "Tokyo Night " = +12 cols)
    mov rdi, [r15 + LangStrings.hdr_theme_pfx]
    call utf8_display_width
    lea ecx, [eax + 12]
    mov rdi, rbx
    lea rsi, [rsp + 16]
    mov edx, [rsp + 4 + 16]
    mov r8d, r13d
    mov r9d, HDR_BTN_THEME
    call try_add_hdr_pill

.LHeaderBar_layout__language_switch_ret:
    lea rsp, [rsp + 8]
    ret
