# StatusBar Widget (Inherits from Widget)
# Shows temporary status notifications, active filter indicator, or detailed entry info.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .rodata
str_StatusBar:    .asciz "StatusBar"
str_pfx_ok:       .asciz " ✓ "
str_pfx_warn:     .asciz " ! "
str_pfx_err:      .asciz " ✗ "
str_pfx_info:     .asciz " • "
str_sep:          .asciz "  │  "
str_arrow:        .asciz " → "

.global StatusBar_vtbl
StatusBar_vtbl:
    WIDGET_VTBL_SLOTS str_StatusBar, Widget_vtbl, StatusBar._size, Widget_dtor, Widget_layout, StatusBar_render, Widget_on_key, Widget_on_mouse, Widget_on_focus, Widget_hit_test

.section .text
.global StatusBar_new
.global StatusBar_set_message
.global StatusBar_render

# StatusBar *StatusBar_new(App *app)
StatusBar_new:
    push rbx
    push r12
    mov r12, rdi
    NEW_OBJ StatusBar_vtbl, StatusBar._size
    test rax, rax
    jz .Lsbn_done
    mov rbx, rax
    mov rdi, rbx
    mov rsi, r12
    mov edx, 102
    call Widget_init
    mov [rbx + StatusBar.app], r12
    mov rax, rbx
.Lsbn_done:
    pop r12
    pop rbx
    ret

# void StatusBar_set_message(StatusBar *this, const char *msg, int kind, int ttl_ms)
StatusBar_set_message:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12d, edx             # kind
    mov r13d, ecx             # ttl_ms

    lea rdi, [rbx + StatusBar.msg]
    # rsi = msg
    mov edx, STATUS_MAX
    call str_copy
    mov [rbx + StatusBar.msg_kind], r12d

    call sys_clock_ms
    movsxd rcx, r13d
    add rax, rcx
    mov [rbx + StatusBar.msg_expire_ms], rax

    pop r13
    pop r12
    pop rbx
    ret

# void StatusBar_render(StatusBar *this, ScreenBuffer *scr, Theme *theme)
StatusBar_render:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 640              # scratch: [0..511]=line, [512..543]=tmp1, [544..575]=tmp2, [576..639]=extra
    mov rbx, rdi              # this
    mov r12, rsi              # scr
    mov r13, rdx              # theme

    # Fill bar background
    mov rdi, r12
    mov esi, [r13 + Theme.text]
    mov edx, [r13 + Theme.bg]
    xor ecx, ecx
    call ScreenBuffer_set_pen

    mov rdi, r12
    mov esi, [rbx + Widget.x]
    mov edx, [rbx + Widget.y]
    mov ecx, [rbx + Widget.w]
    mov r8d, 1
    mov r9d, ' '
    call ScreenBuffer_fill_rect

    # Check active timed message
    cmp qword ptr [rbx + StatusBar.msg_expire_ms], 0
    je .Lsbr_check_filter
    call sys_clock_ms
    cmp rax, [rbx + StatusBar.msg_expire_ms]
    jb .Lsbr_draw_msg
    mov qword ptr [rbx + StatusBar.msg_expire_ms], 0
    jmp .Lsbr_check_filter

.Lsbr_draw_msg:
    mov eax, [rbx + StatusBar.msg_kind]
    mov esi, [r13 + Theme.accent]
    lea r14, [rip + str_pfx_info]
    cmp eax, MSG_OK
    jne .Lsbr_m_warn
    mov esi, [r13 + Theme.ok_fg]
    lea r14, [rip + str_pfx_ok]
    jmp .Lsbr_m_build
.Lsbr_m_warn:
    cmp eax, MSG_WARN
    jne .Lsbr_m_err
    mov esi, [r13 + Theme.warn_fg]
    lea r14, [rip + str_pfx_warn]
    jmp .Lsbr_m_build
.Lsbr_m_err:
    cmp eax, MSG_ERR
    jne .Lsbr_m_build
    mov esi, [r13 + Theme.err_fg]
    lea r14, [rip + str_pfx_err]

.Lsbr_m_build:
    mov rdi, r12
    mov edx, [r13 + Theme.bg]
    mov ecx, ATTR_BOLD
    call ScreenBuffer_set_pen

    mov rdi, rsp
    mov rsi, r14
    mov edx, 512
    call str_copy

    mov rdi, rsp
    lea rsi, [rbx + StatusBar.msg]
    mov edx, 512
    call str_cat

    mov rdi, r12
    mov esi, [rbx + Widget.x]
    mov edx, [rbx + Widget.y]
    mov rcx, rsp
    mov r8d, [rbx + Widget.w]
    call ScreenBuffer_draw_text
    jmp .Lsbr_done

.Lsbr_check_filter:
    mov r14, [rbx + StatusBar.app]
    mov r14, [r14 + App.active_pane]
    test r14, r14
    jz .Lsbr_done
    mov r15, [r14 + FilePane.model]
    jmp .Lsbr_entry_info

.Lsbr_show_filter_empty:
    cmp byte ptr [r15 + DirModel.filter], 0
    je .Lsbr_hint

    mov rdi, r12
    mov esi, [r13 + Theme.warn_fg]
    mov edx, [r13 + Theme.bg]
    mov ecx, ATTR_BOLD
    call ScreenBuffer_set_pen

    call i18n_get
    mov rsi, [rax + LangStrings.sb_filter_pfx]
    mov rdi, rsp
    mov edx, 512
    call str_copy
    mov rdi, rsp
    lea rsi, [r15 + DirModel.filter]
    mov edx, 512
    call str_cat
    call i18n_get
    mov rsi, [rax + LangStrings.sb_filter_sfx]
    mov rdi, rsp
    mov edx, 512
    call str_cat

    mov rdi, r12
    mov esi, [rbx + Widget.x]
    mov edx, [rbx + Widget.y]
    mov rcx, rsp
    mov r8d, [rbx + Widget.w]
    call ScreenBuffer_draw_text
    jmp .Lsbr_done

.Lsbr_entry_info:
    mov rdi, r15
    mov esi, [r14 + FilePane.cursor]
    call DirModel_get_entry
    test rax, rax
    jz .Lsbr_show_filter_empty
    mov r14, rax              # FileEntry *
    mov rdi, r15
    mov rsi, r14
    call DirModel_ensure_entry_stat

    # Build info string: " <name>  │  <size>  │  <perms>  │  <date>"
    mov byte ptr [rsp], ' '
    mov byte ptr [rsp + 1], 0
    mov rdi, r15
    mov rsi, r14
    call DirModel_entry_name
    mov rsi, rax
    mov rdi, rsp
    mov edx, 512
    call str_cat

    mov rdi, rsp
    lea rsi, [rip + str_sep]
    mov edx, 512
    call str_cat

    test dword ptr [r14 + FileEntry.flags], FE_IS_DIR
    jz .Lsbr_size_num
    call i18n_get
    mov rsi, [rax + LangStrings.sb_dir_tag]
    jmp .Lsbr_cat_size
.Lsbr_size_num:
    mov rdi, [r14 + FileEntry.size]
    lea rsi, [rsp + 512]
    call format_size
    lea rsi, [rsp + 512]
.Lsbr_cat_size:
    mov rdi, rsp
    mov edx, 512
    call str_cat

    mov rdi, rsp
    lea rsi, [rip + str_sep]
    mov edx, 512
    call str_cat

    mov edi, [r14 + FileEntry.mode]
    lea rsi, [rsp + 512]
    call format_perms
    mov rdi, rsp
    lea rsi, [rsp + 512]
    mov edx, 512
    call str_cat

    test dword ptr [r14 + FileEntry.flags], FE_IS_PARENT
    jnz .Lsbr_draw_info

    mov rdi, rsp
    lea rsi, [rip + str_sep]
    mov edx, 512
    call str_cat

    mov rdi, [r14 + FileEntry.mtime]
    lea rsi, [rsp + 512]
    call format_datetime
    mov rdi, rsp
    lea rsi, [rsp + 512]
    mov edx, 512
    call str_cat

    # If symlink, show target via readlinkat
    test dword ptr [r14 + FileEntry.flags], FE_IS_LINK
    jz .Lsbr_draw_info
    mov edi, PATH_MAX + 512
    call mem_alloc
    test rax, rax
    jz .Lsbr_draw_info
    push rax
    sub rsp, 8
    mov rdi, r15
    mov rsi, r14
    call DirModel_entry_name
    add rsp, 8
    mov rdx, rax
    mov rdi, [rsp]
    lea rsi, [r15 + DirModel.path]
    mov ecx, PATH_MAX
    call path_join

    mov rsi, [rsp]
    lea rdx, [rsi + PATH_MAX]
    mov edi, AT_FDCWD
    mov r10d, 511
    OS_READLINKAT
    test rax, rax
    jle .Lsbr_sym_free
    mov rcx, [rsp]
    mov byte ptr [rcx + PATH_MAX + rax], 0
    lea rdi, [rsp + 8]
    lea rsi, [rip + str_arrow]
    mov edx, 512
    call str_cat
    mov rcx, [rsp]
    lea rsi, [rcx + PATH_MAX]
    lea rdi, [rsp + 8]
    mov edx, 512
    call str_cat
.Lsbr_sym_free:
    pop rdi
    call mem_free

.Lsbr_draw_info:
    mov rdi, r12
    mov esi, [r13 + Theme.text]
    mov edx, [r13 + Theme.bg]
    xor ecx, ecx
    call ScreenBuffer_set_pen

    mov r14d, [rbx + Widget.w]
    cmp r14d, 95
    jl .Lsbr_info_max_ok
    call i18n_get
    mov rdi, [rax + LangStrings.sb_hint_right]
    call utf8_display_width
    mov ecx, [rbx + Widget.w]
    sub ecx, eax
    sub ecx, 3
    cmp ecx, 20
    jl .Lsbr_info_max_ok
    mov r14d, ecx
.Lsbr_info_max_ok:
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    mov edx, [rbx + Widget.y]
    mov rcx, rsp
    mov r8d, r14d
    call ScreenBuffer_draw_text

.Lsbr_hint:
    cmp dword ptr [rbx + Widget.w], 95
    jl .Lsbr_done
    call i18n_get
    mov r15, rax
    mov rdi, [r15 + LangStrings.sb_hint_right]
    call utf8_display_width
    mov r14d, eax
    mov ecx, [rbx + Widget.w]
    sub ecx, r14d
    sub ecx, 3
    cmp ecx, 20
    jl .Lsbr_done

    mov rdi, r12
    mov esi, [r13 + Theme.muted]
    mov edx, [r13 + Theme.bg]
    xor ecx, ecx
    call ScreenBuffer_set_pen

    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, [rbx + Widget.w]
    sub esi, r14d
    dec esi
    mov edx, [rbx + Widget.y]
    mov rcx, [r15 + LangStrings.sb_hint_right]
    lea r8d, [r14d + 1]
    call ScreenBuffer_draw_text

.Lsbr_done:
    add rsp, 640
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
