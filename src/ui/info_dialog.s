# src/ui/info_dialog.s - Detailed File Info dialog (inode, nlink, mode, CRC32, SHA-256)
.intel_syntax noprefix

.include "pal.inc"
.include "classes.inc"

.section .rodata
str_InfoDialog: .asciz "InfoDialog"
str_inf_path:   .asciz "Path:   "
str_inf_size:   .asciz "Size:   "
str_inf_ino:    .asciz "Inode:  "
str_inf_nlink:  .asciz "Links:  "
str_inf_uidgid: .asciz "Owner:  "
str_inf_crc:    .asciz "CRC32:  "
str_inf_sha:    .asciz "SHA256: "
str_inf_na:     .asciz "(dir/n/a)"
str_hex_tbl:    .ascii "0123456789abcdef"

.section .text
.global InfoDialog_vtbl
InfoDialog_vtbl:
    DIALOG_VTBL_SLOTS str_InfoDialog, Dialog_vtbl, InfoDialog._size, Dialog_dtor, InfoDialog_layout, InfoDialog_render, InfoDialog_on_key, Dialog_on_mouse, Widget_on_focus, Widget_hit_test, Dialog_on_cancel, Dialog_on_cancel

.global InfoDialog_new
.global InfoDialog_layout
.global InfoDialog_render
.global InfoDialog_on_key

.extern Dialog_vtbl
.extern Dialog_init
.extern Dialog_dtor
.extern Dialog_draw_frame
.extern Dialog_on_cancel
.extern Dialog_on_mouse
.extern dlg_layout_right_buttons
.extern Widget_on_focus
.extern Widget_hit_test
.extern ScreenBuffer_set_pen
.extern ScreenBuffer_draw_text
.extern i18n_get
.extern os_statat
.extern hash_file
.extern str_copy
.extern u64_to_dec
.extern path_basename
.extern mem_alloc

# InfoDialog *InfoDialog_new(App *app, const char *path)
InfoDialog_new:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov r13, rsi

    NEW_OBJ InfoDialog_vtbl, InfoDialog._size
    test rax, rax
    jz .Lidn_ret
    mov rbx, rax

    call i18n_get
    mov rdx, [rax + LangStrings.dlg_title_info]
    mov rdi, rbx
    mov rsi, r12
    mov ecx, OP_INFO
    call Dialog_init

    lea rdi, [rbx + InfoDialog.target_path]
    mov rsi, r13
    mov edx, PATH_MAX
    call str_copy

    mov edi, AT_FDCWD
    mov rsi, r13
    lea rdx, [rbx + InfoDialog.st]
    xor ecx, ecx                      # OS_STAT_NOFOLLOW
    call os_statat
    test rax, rax
    js .Lidn_lay

    mov eax, [rbx + InfoDialog.st + FileStat.mode]
    and eax, S_IFMT
    cmp eax, S_IFREG
    jne .Lidn_lay
    mov rdi, r13
    lea rsi, [rbx + InfoDialog.crc32]
    lea rdx, [rbx + InfoDialog.sha_hex]
    call hash_file
    test eax, eax
    jnz .Lidn_lay
    mov dword ptr [rbx + InfoDialog.hash_ok], 1

.Lidn_lay:
    mov ecx, 80
    mov r8d, 24
    test r12, r12
    jz .Lidn_l2
    mov ecx, [r12 + App.term_w]
    mov r8d, [r12 + App.term_h]
.Lidn_l2:
    mov rdi, rbx
    xor esi, esi
    xor edx, edx
    call InfoDialog_layout
    mov rax, rbx
.Lidn_ret:
    pop r13
    pop r12
    pop rbx
    ret

# void InfoDialog_layout(InfoDialog *this, int x, int y, int cols, int rows)
InfoDialog_layout:
    mov eax, ecx
    sub eax, 4
    cmp eax, 76
    jle .Lidl_wok
    mov eax, 76
.Lidl_wok:
    cmp eax, 44
    jge .Lidl_wmin
    mov eax, 44
.Lidl_wmin:
    mov [rdi + Widget.w], eax
    mov r9d, 13
    mov [rdi + Widget.h], r9d
    sub ecx, eax
    sar ecx, 1
    mov [rdi + Widget.x], ecx
    sub r8d, r9d
    sar r8d, 1
    mov [rdi + Widget.y], r8d
    jmp dlg_layout_right_buttons

# Helper: void id_hex32(uint32_t v, char *out9)
id_hex32:
    lea r8, [rip + str_hex_tbl]
    mov ecx, 7
.Lidh_loop:
    mov eax, edi
    and eax, 0x0F
    mov al, [r8 + rax]
    mov [rsi + rcx], al
    shr edi, 4
    dec ecx
    jns .Lidh_loop
    mov byte ptr [rsi + 8], 0
    ret

# Helper: void id_draw_kv(InfoDialog *this, ScreenBuffer *scr, int row_off, const char *lbl, const char *val)
id_draw_kv:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    push r8
    mov edx, [rbx + Widget.y]
    add edx, r13d
    mov esi, [rbx + Widget.x]
    add esi, 3
    mov rdi, r12
    mov r8d, 9
    call ScreenBuffer_draw_text
    pop rcx
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 11
    mov edx, [rbx + Widget.y]
    add edx, r13d
    mov r8d, [rbx + Widget.w]
    sub r8d, 14
    call ScreenBuffer_draw_text
    pop r13
    pop r12
    pop rbx
    ret

# void InfoDialog_render(InfoDialog *this, ScreenBuffer *scr, Theme *theme)
InfoDialog_render:
    push rbx
    push r12
    push r13
    sub rsp, 64
    call InfoDialog_render__id_draw_kv
    call InfoDialog_render__id_draw_kv_2
    add rsp, 64
    pop r13
    pop r12
    pop rbx
    ret

# InfoDialog_render step: id_draw_kv (runs on the caller's frame)
InfoDialog_render__id_draw_kv:
    lea rsp, [rsp - 8]
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx

    call i18n_get
    mov rcx, [rax + LangStrings.dlg_btn_close]
    xor r8d, r8d
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call Dialog_draw_frame

    mov rdi, r12
    mov esi, [r13 + Theme.text]
    mov edx, [r13 + Theme.dialog_bg]
    xor ecx, ecx
    call ScreenBuffer_set_pen

    lea rdi, [rbx + InfoDialog.target_path]
    call path_basename
    mov r8, rax
    mov rdi, rbx
    mov rsi, r12
    mov edx, 2
    lea rcx, [rip + str_inf_path]
    call id_draw_kv

    mov rdi, [rbx + InfoDialog.st + FileStat.size]
    lea rsi, [rsp + 16]
    call u64_to_dec
    mov rdi, rbx
    mov rsi, r12
    mov edx, 3
    lea rcx, [rip + str_inf_size]
    lea r8, [rsp + 16]
    call id_draw_kv

    mov rdi, [rbx + InfoDialog.st + FileStat.ino]
    lea rsi, [rsp + 16]
    call u64_to_dec
    mov rdi, rbx
    mov rsi, r12
    mov edx, 4
    lea rcx, [rip + str_inf_ino]
    lea r8, [rsp + 16]
    call id_draw_kv

    mov rdi, [rbx + InfoDialog.st + FileStat.nlink]
    lea rsi, [rsp + 16]
    call u64_to_dec
    mov rdi, rbx
    mov rsi, r12
    mov edx, 5
    lea rcx, [rip + str_inf_nlink]
    lea r8, [rsp + 16]
    call id_draw_kv

.LInfoDialog_render__id_draw_kv_ret:
    lea rsp, [rsp + 8]
    ret

# InfoDialog_render step: id_draw_kv (runs on the caller's frame)
InfoDialog_render__id_draw_kv_2:
    lea rsp, [rsp - 8]
    mov edi, [rbx + InfoDialog.st + FileStat.uid]
    lea rsi, [rsp + 16]
    call u64_to_dec
    mov byte ptr [rsp + rax + 16], ':'
    mov edi, [rbx + InfoDialog.st + FileStat.gid]
    lea rsi, [rsp + rax + 1 + 16]
    call u64_to_dec
    mov rdi, rbx
    mov rsi, r12
    mov edx, 6
    lea rcx, [rip + str_inf_uidgid]
    lea r8, [rsp + 16]
    call id_draw_kv

    cmp dword ptr [rbx + InfoDialog.hash_ok], 0
    je .Lidr_na
    mov edi, [rbx + InfoDialog.crc32]
    lea rsi, [rsp + 16]
    call id_hex32
    mov rdi, rbx
    mov rsi, r12
    mov edx, 7
    lea rcx, [rip + str_inf_crc]
    lea r8, [rsp + 16]
    call id_draw_kv

    mov rdi, rbx
    mov rsi, r12
    mov edx, 8
    lea rcx, [rip + str_inf_sha]
    lea r8, [rbx + InfoDialog.sha_hex]
    call id_draw_kv
    jmp .Lidr_done

.Lidr_na:
    mov rdi, rbx
    mov rsi, r12
    mov edx, 7
    lea rcx, [rip + str_inf_crc]
    lea r8, [rip + str_inf_na]
    call id_draw_kv

.Lidr_done:
.LInfoDialog_render__id_draw_kv_2_ret:
    lea rsp, [rsp + 8]
    ret

# void InfoDialog_on_key(InfoDialog *this, Event *ev)
InfoDialog_on_key:
    mov eax, [rsi + Event.lat]
    cmp eax, KEY_ESC
    je Dialog_on_cancel
    cmp eax, KEY_ENTER
    je Dialog_on_cancel
    cmp eax, 'q'
    je Dialog_on_cancel
    ret
