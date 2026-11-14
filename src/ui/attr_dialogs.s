# src/ui/attr_dialogs.s - ChmodDialog (clickable rwx bits, octal mode, uid:gid)
.intel_syntax noprefix

.include "pal.inc"
.include "classes.inc"

.section .rodata
str_ChmodDialog: .asciz "ChmodDialog"
str_rwx_hdr:     .asciz "Owner   Group   Other     Octal:"
str_rwx_chars:   .ascii "rwxrwxrwx"
str_owner_lbl:   .asciz "uid:gid: "

.section .text
.global ChmodDialog_vtbl
ChmodDialog_vtbl:
    DIALOG_VTBL_SLOTS str_ChmodDialog, Dialog_vtbl, ChmodDialog._size, Dialog_dtor, ChmodDialog_layout, ChmodDialog_render, ChmodDialog_on_key, ChmodDialog_on_mouse, Widget_on_focus, Widget_hit_test, Dialog_on_confirm, Dialog_on_cancel

.global ChmodDialog_new
.global ChmodDialog_layout
.global ChmodDialog_render
.global ChmodDialog_on_key
.global ChmodDialog_on_mouse

.extern Dialog_vtbl
.extern Dialog_init
.extern Dialog_dtor
.extern Dialog_draw_frame
.extern Dialog_on_confirm
.extern Dialog_on_cancel
.extern Dialog_on_mouse
.extern dlg_layout_right_buttons
.extern Widget_on_focus
.extern Widget_hit_test
.extern ScreenBuffer_set_pen
.extern ScreenBuffer_draw_text
.extern ScreenBuffer_set_cell
.extern i18n_get
.extern os_statat
.extern str_copy
.extern str_len
.extern u64_to_dec
.extern path_basename
.extern mem_alloc

# ChmodDialog *ChmodDialog_new(App *app, const char *path)
ChmodDialog_new:
    push rbx
    push r12
    push r13
    sub rsp, FileStat._size + 16
    mov r12, rdi
    mov r13, rsi

    NEW_OBJ ChmodDialog_vtbl, ChmodDialog._size
    test rax, rax
    jz .Lcdn_ret
    mov rbx, rax

    call i18n_get
    mov rdx, [rax + LangStrings.dlg_title_chmod]
    mov rdi, rbx
    mov rsi, r12
    mov ecx, OP_CHMOD
    call Dialog_init

    lea rdi, [rbx + ChmodDialog.target_path]
    mov rsi, r13
    mov edx, PATH_MAX
    call str_copy

    mov edi, AT_FDCWD
    mov rsi, r13
    mov rdx, rsp
    mov ecx, AT_SYMLINK_NOFOLLOW
    call os_statat
    test eax, eax
    js .Lcdn_def
    mov eax, [rsp + FileStat.mode]
    and eax, 07777
    mov [rbx + ChmodDialog.mode], eax
    mov eax, [rsp + FileStat.uid]
    mov [rbx + ChmodDialog.uid], eax
    mov eax, [rsp + FileStat.gid]
    mov [rbx + ChmodDialog.gid], eax
    jmp .Lcdn_fmt_own
.Lcdn_def:
    mov dword ptr [rbx + ChmodDialog.mode], 0644

.Lcdn_fmt_own:
    mov edi, [rbx + ChmodDialog.uid]
    lea rsi, [rbx + ChmodDialog.owner_buf]
    call u64_to_dec
    lea rcx, [rbx + ChmodDialog.owner_buf]
    add rcx, rax
    mov byte ptr [rcx], ':'
    inc rcx
    mov edi, [rbx + ChmodDialog.gid]
    mov rsi, rcx
    call u64_to_dec
    lea rdi, [rbx + ChmodDialog.owner_buf]
    call str_len
    mov [rbx + ChmodDialog.owner_len], eax

    mov ecx, 80
    mov r8d, 24
    test r12, r12
    jz .Lcdn_lay
    mov ecx, [r12 + App.term_w]
    mov r8d, [r12 + App.term_h]
.Lcdn_lay:
    mov rdi, rbx
    xor esi, esi
    xor edx, edx
    call ChmodDialog_layout
    mov rax, rbx
.Lcdn_ret:
    add rsp, FileStat._size + 16
    pop r13
    pop r12
    pop rbx
    ret

# void ChmodDialog_layout(ChmodDialog *this, int x, int y, int cols, int rows)
ChmodDialog_layout:
    mov eax, ecx
    sub eax, 4
    cmp eax, 56
    jle .Lcdl_wok
    mov eax, 56
.Lcdl_wok:
    cmp eax, 40
    jge .Lcdl_wmin
    mov eax, 40
.Lcdl_wmin:
    mov [rdi + Widget.w], eax
    mov r9d, 10
    mov [rdi + Widget.h], r9d
    sub ecx, eax
    sar ecx, 1
    mov [rdi + Widget.x], ecx
    sub r8d, r9d
    sar r8d, 1
    mov [rdi + Widget.y], r8d
    jmp dlg_layout_right_buttons

# Helper: void cd_format_octal(int mode, char *out5)
cd_format_octal:
    mov byte ptr [rsi + 0], '0'
    mov eax, edi
    shr eax, 6
    and eax, 7
    add al, '0'
    mov [rsi + 1], al
    mov eax, edi
    shr eax, 3
    and eax, 7
    add al, '0'
    mov [rsi + 2], al
    mov eax, edi
    and eax, 7
    add al, '0'
    mov [rsi + 3], al
    mov byte ptr [rsi + 4], 0
    ret

# Helper: void cd_draw_bits(ChmodDialog *this, ScreenBuffer *scr, Theme *th)
cd_draw_bits:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx

    mov edi, [rbx + ChmodDialog.mode]
    mov rsi, rsp
    call cd_format_octal

    mov rdi, r12
    mov esi, [r13 + Theme.accent]
    mov edx, [r13 + Theme.dialog_bg]
    mov ecx, ATTR_BOLD
    call ScreenBuffer_set_pen
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 35
    mov edx, [rbx + Widget.y]
    add edx, 4
    mov rcx, rsp
    mov r8d, 5
    call ScreenBuffer_draw_text

    xor r14d, r14d            # i = 0..8
.Lcdb_loop:
    # x_pos = x + 3 + i*2 + (i/3)*2
    mov eax, r14d
    xor edx, edx
    mov ecx, 3
    div ecx
    lea r15d, [r14d*2 + 3]
    lea r15d, [r15d + eax*2]
    add r15d, [rbx + Widget.x]

    mov ecx, 8
    sub ecx, r14d
    mov eax, 1
    shl eax, cl
    test [rbx + ChmodDialog.mode], eax
    jz .Lcdb_dash
    lea r8, [rip + str_rwx_chars]
    movzx eax, byte ptr [r8 + r14]
    jmp .Lcdb_char_ok
.Lcdb_dash:
    mov eax, '-'
.Lcdb_char_ok:
    mov [rsp + 8], eax
    mov esi, [r13 + Theme.text]
    mov edx, [r13 + Theme.surface_alt]
    xor ecx, ecx
    cmp r14d, [rbx + ChmodDialog.cursor]
    jne .Lcdb_pen
    mov edx, [r13 + Theme.cursor_active_bg]
    mov ecx, ATTR_BOLD
.Lcdb_pen:
    mov rdi, r12
    call ScreenBuffer_set_pen
    mov rdi, r12
    mov esi, r15d
    mov edx, [rbx + Widget.y]
    add edx, 4
    mov ecx, [rsp + 8]
    call ScreenBuffer_set_cell

    inc r14d
    cmp r14d, 9
    jb .Lcdb_loop

    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# void ChmodDialog_render(ChmodDialog *this, ScreenBuffer *scr, Theme *theme)
ChmodDialog_render:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx

    call i18n_get
    mov r14, rax
    mov rcx, [r14 + LangStrings.dlg_btn_ok]
    mov r8, [r14 + LangStrings.dlg_btn_cancel]
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call Dialog_draw_frame

    mov rdi, r12
    mov esi, [r13 + Theme.text]
    mov edx, [r13 + Theme.dialog_bg]
    xor ecx, ecx
    call ScreenBuffer_set_pen

    lea rdi, [rbx + ChmodDialog.target_path]
    call path_basename
    mov rcx, rax
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 3
    mov edx, [rbx + Widget.y]
    add edx, 2
    mov r8d, [rbx + Widget.w]
    sub r8d, 6
    call ScreenBuffer_draw_text

    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 3
    mov edx, [rbx + Widget.y]
    add edx, 3
    lea rcx, [rip + str_rwx_hdr]
    mov r8d, 36
    call ScreenBuffer_draw_text

    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call cd_draw_bits

    mov rdi, r12
    mov esi, [r13 + Theme.text]
    mov edx, [r13 + Theme.dialog_bg]
    xor ecx, ecx
    call ScreenBuffer_set_pen
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 3
    mov edx, [rbx + Widget.y]
    add edx, 6
    lea rcx, [rip + str_owner_lbl]
    mov r8d, 9
    call ScreenBuffer_draw_text

    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 12
    mov edx, [rbx + Widget.y]
    add edx, 6
    lea rcx, [rbx + ChmodDialog.owner_buf]
    mov r8d, 24
    call ScreenBuffer_draw_text

    mov rdi, r12
    mov esi, [r13 + Theme.muted]
    mov edx, [r13 + Theme.dialog_bg]
    xor ecx, ecx
    call ScreenBuffer_set_pen
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 2
    mov edx, [rbx + Widget.y]
    add edx, [rbx + Widget.h]
    sub edx, 2
    mov rcx, [r14 + LangStrings.chm_hint]
    mov r8d, [rbx + Widget.w]
    sub r8d, 24
    call ScreenBuffer_draw_text

    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# void ChmodDialog_on_key(ChmodDialog *this, Event *ev)
ChmodDialog_on_key:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    mov eax, [r12 + Event.key]

    cmp eax, KEY_ENTER; je .Lcdk_ok
    cmp eax, KEY_ESC;   je .Lcdk_esc
    cmp eax, KEY_LEFT;  je .Lcdk_left
    cmp eax, KEY_RIGHT; je .Lcdk_right
    cmp eax, ' ';       je .Lcdk_space
    cmp eax, 'u';       je .Lcdk_owner
    cmp eax, 'g';       je .Lcdk_owner

    cmp eax, '1'
    jb .Lcdk_chk_edit
    cmp eax, '9'
    ja .Lcdk_chk_edit
    cmp dword ptr [rbx + ChmodDialog.edit_owner], 0
    jne .Lcdk_chk_edit
    sub eax, '1'
    mov ecx, 8
    sub ecx, eax
    mov edx, 1
    shl edx, cl
    xor [rbx + ChmodDialog.mode], edx
    mov [rbx + ChmodDialog.cursor], eax
    jmp .Lcdk_redr

.Lcdk_chk_edit:
    cmp dword ptr [rbx + ChmodDialog.edit_owner], 0
    je .Lcdk_done
    cmp eax, KEY_BACKSPACE
    je .Lcdk_bs
    cmp eax, ':'
    je .Lcdk_app
    cmp eax, '0'
    jb .Lcdk_done
    cmp eax, '9'
    ja .Lcdk_done
.Lcdk_app:
    mov ecx, [rbx + ChmodDialog.owner_len]
    cmp ecx, 30
    jae .Lcdk_done
    mov [rbx + ChmodDialog.owner_buf + rcx], al
    inc ecx
    mov byte ptr [rbx + ChmodDialog.owner_buf + rcx], 0
    mov [rbx + ChmodDialog.owner_len], ecx
    jmp .Lcdk_redr
.Lcdk_bs:
    mov ecx, [rbx + ChmodDialog.owner_len]
    test ecx, ecx
    jz .Lcdk_done
    dec ecx
    mov byte ptr [rbx + ChmodDialog.owner_buf + rcx], 0
    mov [rbx + ChmodDialog.owner_len], ecx
    jmp .Lcdk_redr

.Lcdk_owner:
    xor dword ptr [rbx + ChmodDialog.edit_owner], 1
    jmp .Lcdk_redr
.Lcdk_left:
    cmp dword ptr [rbx + ChmodDialog.cursor], 0
    jle .Lcdk_done
    dec dword ptr [rbx + ChmodDialog.cursor]
    jmp .Lcdk_redr
.Lcdk_right:
    cmp dword ptr [rbx + ChmodDialog.cursor], 8
    jge .Lcdk_done
    inc dword ptr [rbx + ChmodDialog.cursor]
    jmp .Lcdk_redr
.Lcdk_space:
    mov ecx, 8
    sub ecx, [rbx + ChmodDialog.cursor]
    mov edx, 1
    shl edx, cl
    xor [rbx + ChmodDialog.mode], edx
.Lcdk_redr:
    mov rax, [rbx + Dialog.app]
    mov dword ptr [rax + App.need_redraw], 1
.Lcdk_done:
    add rsp, 8
    pop r12
    pop rbx
    ret
.Lcdk_ok:
    mov rdi, rbx
    call Dialog_on_confirm
    jmp .Lcdk_done
.Lcdk_esc:
    mov rdi, rbx
    call Dialog_on_cancel
    jmp .Lcdk_done

# void ChmodDialog_on_mouse(ChmodDialog *this, Event *ev)
ChmodDialog_on_mouse:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    cmp dword ptr [r12 + Event.mouse_kind], MACT_PRESS
    jne .Lcdm_base
    cmp dword ptr [r12 + Event.mouse_btn], MOUSE_LEFT
    jne .Lcdm_base
    mov eax, [rbx + Widget.y]
    add eax, 4
    cmp [r12 + Event.mouse_y], eax
    jne .Lcdm_base

    xor ecx, ecx
.Lcdm_chk:
    mov eax, ecx
    xor edx, edx
    mov r8d, 3
    div r8d
    lea r9d, [ecx*2 + 3]
    lea r9d, [r9d + eax*2]
    add r9d, [rbx + Widget.x]
    cmp [r12 + Event.mouse_x], r9d
    je .Lcdm_hit
    inc ecx
    cmp ecx, 9
    jb .Lcdm_chk
    jmp .Lcdm_base
.Lcdm_hit:
    mov [rbx + ChmodDialog.cursor], ecx
    mov edx, ecx
    mov ecx, 8
    sub ecx, edx
    mov eax, 1
    shl eax, cl
    xor [rbx + ChmodDialog.mode], eax
    mov rax, [rbx + Dialog.app]
    mov dword ptr [rax + App.need_redraw], 1
    jmp .Lcdm_done
.Lcdm_base:
    mov rdi, rbx
    mov rsi, r12
    call Dialog_on_mouse
.Lcdm_done:
    add rsp, 8
    pop r12
    pop rbx
    ret
