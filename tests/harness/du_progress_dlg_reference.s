# Frozen reference oracle: src/ui/du_progress_dlg.s (before C23 migration to src/ui/du_progress_dlg.c).
# DuProgressDialog (Inherits from Dialog): the "Scanning disk usage" window shown while a long
# Disk Usage walk runs -- folders done / total with a bar, then dirs / files / bytes scanned so far
# and the Esc hint. It only renders: the app's progress callback (app_du.s) owns its lifetime and
# input, reading live counters from du_progress().

.intel_syntax noprefix
.include "classes.inc"
.equ DPD_W_MAX, 64
.equ DPD_W_MIN, 40
.equ DPD_H,     9
.equ DPD_BUF,   192

.section .rodata
str_DuProgressDialog: .asciz "DuProgressDialog"
str_dpd_slash:        .asciz " / "
str_dpd_sep:          .asciz "  "
str_dpd_dot:          .asciz " · "
str_dpd_sp:           .asciz " "

.align 8
DuProgressDialog_vtbl:
    DIALOG_VTBL_SLOTS str_DuProgressDialog, Dialog_vtbl, Dialog._size, Dialog_dtor, DuProgressDialog_layout, DuProgressDialog_render, Dialog_on_key, Dialog_on_mouse, Widget_on_focus, Widget_hit_test, Dialog_on_confirm, Dialog_on_cancel

.section .text
.global DuProgressDialog_new
.global DuProgressDialog_layout

# Dialog *DuProgressDialog_new(App *app)
DuProgressDialog_new:
    push rbx
    push r12
    sub rsp, 8
    mov r12, rdi
    NEW_OBJ DuProgressDialog_vtbl, Dialog._size
    test rax, rax
    jz .Ldn_ret
    mov rbx, rax
    call i18n_get
    mov rdx, [rax + LangStrings.du_scan_title]
    mov rdi, rbx
    mov rsi, r12
    xor ecx, ecx
    call Dialog_init
    mov rdi, rbx
    xor esi, esi
    xor edx, edx
    mov ecx, [r12 + App.term_w]
    mov r8d, [r12 + App.term_h]
    call DuProgressDialog_layout
    mov rax, rbx
.Ldn_ret:
    add rsp, 8
    pop r12
    pop rbx
    ret

# void DuProgressDialog_layout(Dialog *this, int x, int y, int w, int h) -- centred, DPD_H rows
DuProgressDialog_layout:
    mov eax, ecx
    sub eax, 4
    cmp eax, DPD_W_MAX
    jle 1f
    mov eax, DPD_W_MAX
1:  cmp eax, DPD_W_MIN
    jge 2f
    mov eax, DPD_W_MIN
2:  mov [rdi + Widget.w], eax
    mov dword ptr [rdi + Widget.h], DPD_H
    sub ecx, eax
    sar ecx, 1
    mov [rdi + Widget.x], ecx
    sub r8d, DPD_H
    sar r8d, 1
    mov [rdi + Widget.y], r8d
    ret

# void DuProgressDialog_render(Dialog *this, ScreenBuffer *scr)
DuProgressDialog_render:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, DPD_BUF + 32             # [0..DPD_BUF) text, [DPD_BUF] number scratch
    mov rbx, rdi
    mov r12, rsi
    mov rax, [rbx + Dialog.app]
    mov r13, [rax + App.theme]
    call du_progress
    mov r14, rax
    call i18n_get
    mov r15, rax
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    xor ecx, ecx
    xor r8d, r8d
    call Dialog_draw_frame
    call dpd_folders_line
    call dpd_bar
    call dpd_scanned_line
    mov rdi, r12
    mov esi, [r13 + Theme.muted]
    mov edx, [r13 + Theme.dialog_bg]
    xor ecx, ecx
    call ScreenBuffer_set_pen
    mov rcx, [r15 + LangStrings.du_scan_hint]
    mov edx, 6
    call dpd_text_at
    add rsp, DPD_BUF + 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# render step: "<Folders>  done / total" on row 2 (bold)
dpd_folders_line:
    lea rsp, [rsp - 8]
    mov rdi, r12
    mov esi, [r13 + Theme.text]
    mov edx, [r13 + Theme.dialog_bg]
    mov ecx, ATTR_BOLD
    call ScreenBuffer_set_pen
    lea rdi, [rsp + 16]
    mov rsi, [r15 + LangStrings.du_lbl_folders]
    mov edx, DPD_BUF
    call str_copy
    lea rsi, [rip + str_dpd_sep]
    call dpd_cat
    mov eax, [r14 + DuProgress.done]
    call dpd_cat_u64
    lea rsi, [rip + str_dpd_slash]
    call dpd_cat
    mov eax, [r14 + DuProgress.total]
    call dpd_cat_u64
    lea rcx, [rsp + 16]
    mov edx, 2
    call dpd_text_at
    lea rsp, [rsp + 8]
    ret

# render step: done / total bar on row 3
dpd_bar:
    lea rsp, [rsp - 8]
    mov ecx, [rbx + Widget.w]
    sub ecx, 6                        # bar width
    mov eax, [r14 + DuProgress.done]
    imul eax, ecx
    mov r8d, [r14 + DuProgress.total]
    xor edx, edx
    test r8d, r8d
    jz 1f
    div r8d
    cmp eax, ecx
    jbe 2f
1:  xor eax, eax
2:  mov [rsp + 16 + DPD_BUF], eax     # filled cells
    mov [rsp + 16 + DPD_BUF + 4], ecx
    mov rdi, r12
    mov esi, [r13 + Theme.accent]
    mov edx, [r13 + Theme.dialog_bg]
    xor ecx, ecx
    call ScreenBuffer_set_pen
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 3
    mov edx, [rbx + Widget.y]
    add edx, 3
    mov ecx, [rsp + 16 + DPD_BUF]
    mov r8d, 1
    mov r9d, CH_BLOCK_FULL
    call ScreenBuffer_fill_rect
    mov rdi, r12
    mov esi, [r13 + Theme.muted]
    mov edx, [r13 + Theme.dialog_bg]
    xor ecx, ecx
    call ScreenBuffer_set_pen
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 3
    add esi, [rsp + 16 + DPD_BUF]
    mov edx, [rbx + Widget.y]
    add edx, 3
    mov ecx, [rsp + 16 + DPD_BUF + 4]
    sub ecx, [rsp + 16 + DPD_BUF]
    mov r8d, 1
    mov r9d, CH_SHADE_LIGHT
    call ScreenBuffer_fill_rect
    lea rsp, [rsp + 8]
    ret

# render step: "<Scanned>  N dirs · N files · size" on row 4
dpd_scanned_line:
    lea rsp, [rsp - 8]
    mov rdi, r12
    mov esi, [r13 + Theme.text]
    mov edx, [r13 + Theme.dialog_bg]
    xor ecx, ecx
    call ScreenBuffer_set_pen
    lea rdi, [rsp + 16]
    mov rsi, [r15 + LangStrings.du_lbl_scanned]
    mov edx, DPD_BUF
    call str_copy
    lea rsi, [rip + str_dpd_sep]
    call dpd_cat
    mov rax, [r14 + DuProgress.dirs]
    mov rsi, [r15 + LangStrings.du_unit_dirs]
    call dpd_cat_count
    lea rsi, [rip + str_dpd_dot]
    call dpd_cat
    mov rax, [r14 + DuProgress.files]
    mov rsi, [r15 + LangStrings.du_unit_files]
    call dpd_cat_count
    lea rsi, [rip + str_dpd_dot]
    call dpd_cat
    mov rdi, [r14 + DuProgress.bytes]
    lea rsi, [rsp + 16 + DPD_BUF]
    call format_size
    lea rsi, [rsp + 16 + DPD_BUF]
    call dpd_cat
    lea rcx, [rsp + 16]
    mov edx, 4
    call dpd_text_at
    lea rsp, [rsp + 8]
    ret

# Helpers below are called from the render steps (two calls deep): the text buffer is at rsp + 24.

# void dpd_cat(rsi = src) -- append to the render text buffer
dpd_cat:
    lea rdi, [rsp + 24]
    mov edx, DPD_BUF
    jmp str_cat

# void dpd_cat_u64(rax = value) -- append decimal digits
dpd_cat_u64:
    sub rsp, 40
    mov rdi, rax
    mov rsi, rsp
    call u64_to_dec
    lea rdi, [rsp + 40 + 24]
    mov rsi, rsp
    mov edx, DPD_BUF
    call str_cat
    add rsp, 40
    ret

# void dpd_cat_count(rax = value, rsi = unit) -- append "N unit"
dpd_cat_count:
    push rsi
    call dpd_cat_u64_deep
    lea rsi, [rip + str_dpd_sp]
    lea rdi, [rsp + 32]
    mov edx, DPD_BUF
    call str_cat
    pop rsi
    lea rdi, [rsp + 24]
    mov edx, DPD_BUF
    jmp str_cat

# dpd_cat_u64 with one more word on the stack (called from dpd_cat_count after push rsi)
dpd_cat_u64_deep:
    sub rsp, 40
    mov rdi, rax
    mov rsi, rsp
    call u64_to_dec
    lea rdi, [rsp + 40 + 40]
    mov rsi, rsp
    mov edx, DPD_BUF
    call str_cat
    add rsp, 40
    ret

# void dpd_text_at(rcx = text, edx = row) -- draw at (x + 3, y + row), clipped to the box
dpd_text_at:
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 3
    add edx, [rbx + Widget.y]
    mov r8d, [rbx + Widget.w]
    sub r8d, 6
    jmp ScreenBuffer_draw_text
