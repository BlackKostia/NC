# src/ui/attr_dialogs.s - ChmodDialog (clickable rwx bits, octal mode, uid:gid)

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"
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

.section .rodata
str_ChmodDialog: .asciz "ChmodDialog"
str_rwx_chars:   .ascii "rwxrwxrwx"

.section .text
.global ChmodDialog_vtbl
.global ChmodDialog_new
.global ChmodDialog_layout
.global cd_draw_bits

.section .rodata
.balign 8
ChmodDialog_vtbl:
    DIALOG_VTBL_SLOTS str_ChmodDialog, Dialog_vtbl, ChmodDialog._size, Dialog_dtor, ChmodDialog_layout, ChmodDialog_render, ChmodDialog_on_key, ChmodDialog_on_mouse, Widget_on_focus, Widget_hit_test, Dialog_on_confirm, Dialog_on_cancel
.section .text

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
    xor ecx, ecx                      # OS_STAT_NOFOLLOW
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
    call cd_draw_bits__cd_format_octal
.Lcdb_loop:
    # x_pos = x + 3 + i*2 + (i/3)*2
    call cd_draw_bits__x_pos
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

# cd_draw_bits step: cd_format_octal (runs on the caller's frame)
cd_draw_bits__cd_format_octal:
    lea rsp, [rsp - 8]
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx

    mov edi, [rbx + ChmodDialog.mode]
    lea rsi, [rsp + 16]
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
    lea rcx, [rsp + 16]
    mov r8d, 5
    call ScreenBuffer_draw_text

    xor r14d, r14d            # i = 0..8
.Lcd_draw_bits__cd_format_octal_ret:
    lea rsp, [rsp + 8]
    ret

# cd_draw_bits step: x_pos (runs on the caller's frame)
cd_draw_bits__x_pos:
    lea rsp, [rsp - 8]
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
    mov [rsp + 8 + 16], eax
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
    mov ecx, [rsp + 8 + 16]
    call ScreenBuffer_set_cell

.Lcd_draw_bits__x_pos_ret:
    lea rsp, [rsp + 8]
    ret
