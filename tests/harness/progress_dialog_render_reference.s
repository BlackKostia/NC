# Frozen reference oracle: src/ui/progress_dialog_render.s (before C23 migration to src/ui/progress_dialog.c).
# ProgressDialog (Inherits from Dialog) — progress dialog render (split from progress_dialog.s)

.intel_syntax noprefix
.include "classes.inc"
.equ PD_W_MAX,  66
.equ PD_W_MIN,  44
.equ PD_H,      9
.equ PD_BTNS,   3
.equ PD_BUF,    192

.section .rodata
str_pd_slash:       .asciz " / "

.section .text
.global ProgressDialog_render
.global pd_activate
.global ProgressDialog_on_hide

# void ProgressDialog_render(ProgressDialog *this, ScreenBuffer *scr, Theme *theme)
ProgressDialog_render:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 256              # [0..191] line, [192..239] tmp
    call ProgressDialog_render__frame_title_pill
    # Row 2: current item
    call ProgressDialog_render__row_current_item
    # Row 3: progress bar (bar_w = w - 11) + percentage
    mov r15d, [rbx + Widget.w]
    sub r15d, 11
    jle .Lpdr_counts
    call ProgressDialog_render__filled_cells
    add edx, 3
    mov rcx, rsp
    mov r8d, 4
    call ScreenBuffer_draw_text

.Lpdr_counts:
    # Row 4: "<done> / <total>  ·  Files: a / b"
    call ProgressDialog_render__row
    # Row 5: state (speed / ETA, paused, scanning, canceling)
    call ProgressDialog_render__row_state
.Lpdr_done:
    add rsp, 256
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# ProgressDialog_render step: Frame title pill (runs on the caller's frame)
ProgressDialog_render__frame_title_pill:
    lea rsp, [rsp - 8]
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, [rbx + Dialog.app]
    lea r14, [r14 + App.task_snap]

    mov rdi, rbx
    call pd_layout_buttons

    # Frame + title pill
    mov rdi, r12
    mov esi, [r13 + Theme.dialog_border]
    mov edx, [r13 + Theme.dialog_bg]
    mov ecx, ATTR_BOLD
    call ScreenBuffer_set_pen
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    mov edx, [rbx + Widget.y]
    mov ecx, [rbx + Widget.w]
    mov r8d, [rbx + Widget.h]
    mov r9d, 1
    call ScreenBuffer_draw_box

    mov edi, [r14 + TaskSnap.op]
    call ProgressDialog_title_for
    mov [rbx + Dialog.title], rax
    lea rdi, [rsp + 16]
    lea rsi, [rip + str_pd_sp]
    mov edx, PD_BUF
    call str_copy
    lea rdi, [rsp + 16]
    mov rsi, [rbx + Dialog.title]
    call pd_cat
    lea rdi, [rsp + 16]
    lea rsi, [rip + str_pd_sp]
    call pd_cat
    mov rdi, r12
    mov esi, [r13 + Theme.accent_fg]
    mov edx, [r13 + Theme.dialog_border]
    mov ecx, ATTR_BOLD
    call ScreenBuffer_set_pen
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 3
    mov edx, [rbx + Widget.y]
    lea rcx, [rsp + 16]
    mov r8d, [rbx + Widget.w]
    sub r8d, 6
    call ScreenBuffer_draw_text

.LProgressDialog_render__frame_title_pill_ret:
    lea rsp, [rsp + 8]
    ret

# ProgressDialog_render step: Row current item (runs on the caller's frame)
ProgressDialog_render__row_current_item:
    lea rsp, [rsp - 8]
    mov rdi, r12
    mov esi, [r13 + Theme.text]
    mov edx, [r13 + Theme.dialog_bg]
    mov ecx, ATTR_BOLD
    call ScreenBuffer_set_pen
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 3
    mov edx, [rbx + Widget.y]
    add edx, 2
    lea rcx, [r14 + TaskSnap.cur_name]
    mov r8d, [rbx + Widget.w]
    sub r8d, 6
    call ScreenBuffer_draw_text

.LProgressDialog_render__row_current_item_ret:
    lea rsp, [rsp + 8]
    ret

# ProgressDialog_render step: filled cells (runs on the caller's frame)
ProgressDialog_render__filled_cells:
    lea rsp, [rsp - 8]
    mov eax, [r14 + TaskSnap.percent]
    cmp eax, 100
    jbe .Lpdr_pct_ok
    mov eax, 100
.Lpdr_pct_ok:
    imul eax, r15d
    xor edx, edx
    mov ecx, 100
    div ecx
    mov [rsp + 240 + 16], eax  # filled cells

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
    mov ecx, [rsp + 240 + 16]
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
    add esi, [rsp + 240 + 16]
    mov edx, [rbx + Widget.y]
    add edx, 3
    mov ecx, r15d
    sub ecx, [rsp + 240 + 16]
    mov r8d, 1
    mov r9d, CH_SHADE_LIGHT
    call ScreenBuffer_fill_rect

    mov byte ptr [rsp + 16], 0
    lea rdi, [rsp + 16]
    mov esi, [r14 + TaskSnap.percent]
    call pd_cat_u64
    lea rdi, [rsp + 16]
    lea rsi, [rip + str_pd_pct]
    call pd_cat
    mov rdi, r12
    mov esi, [r13 + Theme.text]
    mov edx, [r13 + Theme.dialog_bg]
    mov ecx, ATTR_BOLD
    call ScreenBuffer_set_pen
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 4
    add esi, r15d
    mov edx, [rbx + Widget.y]
.LProgressDialog_render__filled_cells_ret:
    lea rsp, [rsp + 8]
    ret

# ProgressDialog_render step: Row (runs on the caller's frame)
ProgressDialog_render__row:
    lea rsp, [rsp - 8]
    mov byte ptr [rsp + 16], 0
    cmp dword ptr [r14 + TaskSnap.op], TASK_OP_DELETE
    je .Lpdr_files
    lea rdi, [rsp + 16]
    mov rsi, [r14 + TaskSnap.done_bytes]
    call pd_cat_size
    cmp qword ptr [r14 + TaskSnap.total_bytes], 0
    je .Lpdr_bytes_end
    lea rdi, [rsp + 16]
    lea rsi, [rip + str_pd_slash]
    call pd_cat
    lea rdi, [rsp + 16]
    mov rsi, [r14 + TaskSnap.total_bytes]
    call pd_cat_size
.Lpdr_bytes_end:
    lea rdi, [rsp + 16]
    lea rsi, [rip + str_pd_dot]
    call pd_cat
.Lpdr_files:
    call i18n_get
    mov rsi, [rax + LangStrings.task_lbl_files]
    lea rdi, [rsp + 16]
    call pd_cat
    lea rdi, [rsp + 16]
    mov rsi, [r14 + TaskSnap.done_files]
    mov rax, [r14 + TaskSnap.total_files]
    cmp rsi, rax
    jbe .Lpdr_df_ok
    mov rsi, rax
.Lpdr_df_ok:
    call pd_cat_u64
    lea rdi, [rsp + 16]
    lea rsi, [rip + str_pd_slash]
    call pd_cat
    lea rdi, [rsp + 16]
    mov rsi, [r14 + TaskSnap.total_files]
    call pd_cat_u64
    mov rdi, r12
    mov esi, [r13 + Theme.text]
    mov edx, [r13 + Theme.dialog_bg]
    xor ecx, ecx
    call ScreenBuffer_set_pen
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 3
    mov edx, [rbx + Widget.y]
    add edx, 4
    lea rcx, [rsp + 16]
    mov r8d, [rbx + Widget.w]
    sub r8d, 6
    call ScreenBuffer_draw_text

.LProgressDialog_render__row_ret:
    lea rsp, [rsp + 8]
    ret

# ProgressDialog_render step: Row state (runs on the caller's frame)
ProgressDialog_render__row_state:
    lea rsp, [rsp - 8]
    mov byte ptr [rsp + 16], 0
    mov rdi, r14
    lea rsi, [rsp + 16]
    call pd_format_state
    mov esi, [r13 + Theme.muted]
    xor ecx, ecx
    mov eax, [r14 + TaskSnap.paused]
    or eax, [r14 + TaskSnap.canceling]
    jz .Lpdr_state_pen
    mov esi, [r13 + Theme.warn_fg]
    mov ecx, ATTR_BOLD
.Lpdr_state_pen:
    mov rdi, r12
    mov edx, [r13 + Theme.dialog_bg]
    call ScreenBuffer_set_pen
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 3
    mov edx, [rbx + Widget.y]
    add edx, 5
    lea rcx, [rsp + 16]
    mov r8d, [rbx + Widget.w]
    sub r8d, 6
    call ScreenBuffer_draw_text

    # Buttons (focus > hover > idle styles)
    xor r15d, r15d
.Lpdr_btn:
    cmp r15d, PD_BTNS
    jge .LProgressDialog_render__row_state_ret
    mov esi, [r13 + Theme.badge_fg]
    mov edx, [r13 + Theme.badge_bg]
    xor ecx, ecx
    cmp r15d, [rbx + Dialog.focus_btn]
    jne .Lpdr_btn_hov
    mov esi, [r13 + Theme.accent_fg]
    mov edx, [r13 + Theme.accent]
    mov ecx, ATTR_BOLD
    jmp .Lpdr_btn_pen
.Lpdr_btn_hov:
    cmp r15d, [rbx + Dialog.hovered_btn]
    jne .Lpdr_btn_pen
    mov edx, [r13 + Theme.badge_hover_bg]
    mov ecx, ATTR_BOLD
.Lpdr_btn_pen:
    mov rdi, r12
    call ScreenBuffer_set_pen
    imul rax, r15, HitZone._size
    lea r8, [rbx + Dialog.btns + rax]
    movsx esi, word ptr [r8 + HitZone.x1]
    movsx edx, word ptr [r8 + HitZone.y]
    movsx eax, word ptr [r8 + HitZone.x2]
    sub eax, esi
    mov rcx, [rbx + ProgressDialog.btn_lbl + r15*8]
    mov r8d, eax
    mov rdi, r12
    call ScreenBuffer_draw_text_pad
    inc r15d
    jmp .Lpdr_btn

.LProgressDialog_render__row_state_ret:
    lea rsp, [rsp + 8]
    ret

# Internal: void pd_activate(ProgressDialog *this, int idx) -- 0 pause, 1 background, 2 cancel
pd_activate:
    mov rax, rdi
    mov rdi, [rax + Dialog.app]
    cmp esi, 0
    je App_task_toggle_pause
    cmp esi, 1
    je App_task_hide          # closes (frees) this dialog
    cmp esi, 2
    je App_task_cancel
    ret

# Dialog on_confirm / on_cancel: both send the dialog to background (never destructive)
ProgressDialog_on_hide:
    mov rdi, [rdi + Dialog.app]
    jmp App_task_hide
