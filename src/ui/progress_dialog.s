# ProgressDialog (Inherits from Dialog)
# Non-modal-in-spirit progress view of the background worker: current item, progress bar,
# bytes / entries, speed, ETA and [Pause|Resume] [Background] [Cancel] buttons (EN/UA,
# keyboard incl. Ukrainian layout letters, SGR mouse). Reads App.task_snap every frame.

.intel_syntax noprefix
.include "classes.inc"

.equ PD_W_MAX,  66
.equ PD_W_MIN,  44
.equ PD_H,      9
.equ PD_BTNS,   3
.equ PD_BUF,    192

.section .rodata
str_ProgressDialog: .asciz "ProgressDialog"
str_pd_spinner:     .asciz " ⟳ "
str_pd_sp:          .asciz " "
str_pd_pct:         .asciz "%"
str_pd_dot:         .asciz "  ·  "
str_pd_slash:       .asciz " / "
str_pd_per_s:       .asciz "/s"
str_pd_eta_unk:     .asciz "--:--"

.global ProgressDialog_vtbl
ProgressDialog_vtbl:
    DIALOG_VTBL_SLOTS str_ProgressDialog, Dialog_vtbl, ProgressDialog._size, Dialog_dtor, ProgressDialog_layout, ProgressDialog_render, ProgressDialog_on_key, ProgressDialog_on_mouse, Widget_on_focus, Widget_hit_test, ProgressDialog_on_hide, ProgressDialog_on_hide

.section .text
.global ProgressDialog_new
.global ProgressDialog_layout
.global ProgressDialog_render
.global ProgressDialog_on_key
.global ProgressDialog_on_mouse
.global ProgressDialog_title_for
.global ProgressDialog_format_summary

# ProgressDialog *ProgressDialog_new(App *app)
ProgressDialog_new:
    push rbx
    push r12
    sub rsp, 8
    mov r12, rdi
    NEW_OBJ ProgressDialog_vtbl, ProgressDialog._size
    test rax, rax
    jz .Lpdn_done
    mov rbx, rax
    mov rdi, rbx
    mov rsi, r12
    xor edx, edx              # title resolved per frame (language may switch)
    mov ecx, OP_PROGRESS
    call Dialog_init
    mov dword ptr [rbx + Dialog.focus_btn], 1   # safe default: Background
    mov rdi, rbx
    xor esi, esi
    xor edx, edx
    mov ecx, [r12 + App.term_w]
    mov r8d, [r12 + App.term_h]
    call ProgressDialog_layout
    mov rax, rbx
.Lpdn_done:
    add rsp, 8
    pop r12
    pop rbx
    ret

# void ProgressDialog_layout(ProgressDialog *this, int x, int y, int w, int h)
ProgressDialog_layout:
    mov r9d, ecx
    sub r9d, 6
    cmp r9d, PD_W_MAX
    jle .Lpdl_wmin
    mov r9d, PD_W_MAX
.Lpdl_wmin:
    cmp r9d, PD_W_MIN
    jge .Lpdl_wok
    mov r9d, ecx
.Lpdl_wok:
    mov r10d, PD_H
    cmp r10d, r8d
    jle .Lpdl_hok
    mov r10d, r8d
.Lpdl_hok:
    mov eax, ecx
    sub eax, r9d
    sar eax, 1
    add eax, esi
    mov r11d, r8d
    sub r11d, r10d
    sar r11d, 1
    add r11d, edx
    mov esi, eax
    mov edx, r11d
    mov ecx, r9d
    mov r8d, r10d
    jmp Widget_layout

# const char *ProgressDialog_title_for(int op) -- localized "Copying" / "Moving" / "Deleting"
ProgressDialog_title_for:
    call i18n_get
    cmp edi, TASK_OP_MOVE
    je .Lpdt_move
    cmp edi, TASK_OP_DELETE
    je .Lpdt_del
    mov rax, [rax + LangStrings.task_title_copy]
    ret
.Lpdt_move:
    mov rax, [rax + LangStrings.task_title_move]
    ret
.Lpdt_del:
    mov rax, [rax + LangStrings.task_title_delete]
    ret

# Internal: void pd_fmt_eta(int64_t sec, char *buf) -- "m:ss" / "h:mm:ss" / "--:--"
pd_fmt_eta:
    push rbx
    push r12
    push r13
    sub rsp, 32
    mov rbx, rsi
    test rdi, rdi
    jns .Lpfe_known
    mov rdi, rbx
    lea rsi, [rip + str_pd_eta_unk]
    mov edx, 8
    call str_copy
    jmp .Lpfe_done
.Lpfe_known:
    mov rax, rdi
    xor edx, edx
    mov ecx, 60
    div rcx
    mov r12, rdx              # seconds
    xor edx, edx
    div rcx
    mov r13, rdx              # minutes
    test rax, rax
    jz .Lpfe_min
    mov rdi, rax              # hours
    mov rsi, rbx
    call u64_to_dec
    add rbx, rax
    mov byte ptr [rbx], ':'
    inc rbx
    cmp r13, 10
    jae .Lpfe_min
    mov byte ptr [rbx], '0'
    inc rbx
.Lpfe_min:
    mov rdi, r13
    mov rsi, rbx
    call u64_to_dec
    add rbx, rax
    mov byte ptr [rbx], ':'
    inc rbx
    cmp r12, 10
    jae .Lpfe_sec
    mov byte ptr [rbx], '0'
    inc rbx
.Lpfe_sec:
    mov rdi, r12
    mov rsi, rbx
    call u64_to_dec
.Lpfe_done:
    add rsp, 32
    pop r13
    pop r12
    pop rbx
    ret

# Internal: void pd_cat_u64(char *buf, uint64_t v) -- appends decimal (buf cap PD_BUF)
pd_cat_u64:
    push rbx
    sub rsp, 32
    mov rbx, rdi
    mov rdi, rsi
    mov rsi, rsp
    call u64_to_dec
    mov rdi, rbx
    mov rsi, rsp
    mov edx, PD_BUF
    call str_cat
    add rsp, 32
    pop rbx
    ret

# Internal: void pd_cat_size(char *buf, int64_t bytes) -- appends human-readable size
pd_cat_size:
    push rbx
    sub rsp, 32
    mov rbx, rdi
    mov rdi, rsi
    mov rsi, rsp
    call format_size
    mov rdi, rbx
    mov rsi, rsp
    mov edx, PD_BUF
    call str_cat
    add rsp, 32
    pop rbx
    ret

# Internal: void pd_cat(char *buf, const char *s)
pd_cat:
    mov edx, PD_BUF
    jmp str_cat

# Internal: void pd_format_state(const TaskSnap *s, char *buf) -- appends the state tail:
# "Canceling…" | "Paused" | "Scanning… N" | "[<speed>/s  ·  ]ETA m:ss"
pd_format_state:
    push rbx
    push r12
    push r13
    sub rsp, 32
    mov rbx, rdi              # snap
    mov r12, rsi              # buf
    call i18n_get
    mov r13, rax
    cmp dword ptr [rbx + TaskSnap.canceling], 0
    je .Lpfs_paused
    mov rdi, r12
    mov rsi, [r13 + LangStrings.task_lbl_canceling]
    call pd_cat
    jmp .Lpfs_done
.Lpfs_paused:
    cmp dword ptr [rbx + TaskSnap.paused], 0
    je .Lpfs_scan
    mov rdi, r12
    mov rsi, [r13 + LangStrings.task_lbl_paused]
    call pd_cat
    jmp .Lpfs_done
.Lpfs_scan:
    cmp dword ptr [rbx + TaskSnap.phase], TASK_PHASE_SCAN
    jne .Lpfs_rate
    mov rdi, r12
    mov rsi, [r13 + LangStrings.task_lbl_scan]
    call pd_cat
    mov rdi, r12
    mov rsi, [rbx + TaskSnap.total_files]
    call pd_cat_u64
    jmp .Lpfs_done
.Lpfs_rate:
    cmp dword ptr [rbx + TaskSnap.op], TASK_OP_DELETE
    je .Lpfs_eta
    mov rdi, r12
    mov rsi, [rbx + TaskSnap.speed_bps]
    call pd_cat_size
    mov rdi, r12
    lea rsi, [rip + str_pd_per_s]
    call pd_cat
    mov rdi, r12
    lea rsi, [rip + str_pd_dot]
    call pd_cat
.Lpfs_eta:
    mov rdi, r12
    mov rsi, [r13 + LangStrings.task_lbl_eta]
    call pd_cat
    mov rdi, [rbx + TaskSnap.eta_sec]
    mov rsi, rsp
    call pd_fmt_eta
    mov rdi, r12
    mov rsi, rsp
    call pd_cat
.Lpfs_done:
    add rsp, 32
    pop r13
    pop r12
    pop rbx
    ret

# void ProgressDialog_format_summary(const TaskSnap *s, char *buf)
# One-line summary for StatusBar / quit confirmation (buf >= PD_BUF bytes):
# " ⟳ Copying 45%  ·  5.1 M/s  ·  ETA 0:03"
ProgressDialog_format_summary:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    mov rdi, r12
    lea rsi, [rip + str_pd_spinner]
    mov edx, PD_BUF
    call str_copy
    mov edi, [rbx + TaskSnap.op]
    call ProgressDialog_title_for
    mov rdi, r12
    mov rsi, rax
    call pd_cat
    mov rdi, r12
    lea rsi, [rip + str_pd_sp]
    call pd_cat
    mov rdi, r12
    mov esi, [rbx + TaskSnap.percent]
    call pd_cat_u64
    mov rdi, r12
    lea rsi, [rip + str_pd_pct]
    call pd_cat
    mov rdi, r12
    lea rsi, [rip + str_pd_dot]
    call pd_cat
    mov rdi, rbx
    mov rsi, r12
    call pd_format_state
    add rsp, 8
    pop r12
    pop rbx
    ret

# Internal: void pd_layout_buttons(ProgressDialog *this)
# Centers [Pause|Resume] [Background] [Cancel] on row y + h - 2 using UTF-8 display widths.
pd_layout_buttons:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    call i18n_get
    mov r12, rax
    mov rcx, [rbx + Dialog.app]
    mov rax, [r12 + LangStrings.task_btn_pause]
    cmp dword ptr [rcx + App.task_snap + TaskSnap.paused], 0
    je .Lplb_l0
    mov rax, [r12 + LangStrings.task_btn_resume]
.Lplb_l0:
    mov [rbx + ProgressDialog.btn_lbl], rax
    mov rax, [r12 + LangStrings.task_btn_bg]
    mov [rbx + ProgressDialog.btn_lbl + 8], rax
    mov rax, [r12 + LangStrings.dlg_btn_cancel]
    mov [rbx + ProgressDialog.btn_lbl + 16], rax

    # total width = w0 + w1 + w2 + 4
    xor r13d, r13d
    xor r14d, r14d
.Lplb_wsum:
    cmp r14d, PD_BTNS
    jge .Lplb_place
    mov rdi, [rbx + ProgressDialog.btn_lbl + r14*8]
    call utf8_display_width
    add r13d, eax
    inc r14d
    jmp .Lplb_wsum
.Lplb_place:
    add r13d, 4
    mov r15d, [rbx + Widget.w]
    sub r15d, r13d
    sar r15d, 1
    add r15d, [rbx + Widget.x]          # x cursor
    mov dword ptr [rbx + Dialog.btn_count], PD_BTNS
    xor r14d, r14d
.Lplb_loop:
    cmp r14d, PD_BTNS
    jge .Lplb_done
    mov rdi, [rbx + ProgressDialog.btn_lbl + r14*8]
    call utf8_display_width
    lea r8, [rbx + Dialog.btns]
    imul rcx, r14, HitZone._size
    add r8, rcx
    mov [r8 + HitZone.x1], r15w
    add r15d, eax
    mov [r8 + HitZone.x2], r15w
    mov ecx, [rbx + Widget.y]
    add ecx, [rbx + Widget.h]
    sub ecx, 2
    mov [r8 + HitZone.y], cx
    mov [r8 + HitZone.id], r14w
    add r15d, 2
    inc r14d
    jmp .Lplb_loop
.Lplb_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# void ProgressDialog_render(ProgressDialog *this, ScreenBuffer *scr, Theme *theme)
ProgressDialog_render:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 256              # [0..191] line, [192..239] tmp
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
    mov rdi, rsp
    lea rsi, [rip + str_pd_sp]
    mov edx, PD_BUF
    call str_copy
    mov rdi, rsp
    mov rsi, [rbx + Dialog.title]
    call pd_cat
    mov rdi, rsp
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
    mov rcx, rsp
    mov r8d, [rbx + Widget.w]
    sub r8d, 6
    call ScreenBuffer_draw_text

    # Row 2: current item
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

    # Row 3: progress bar (bar_w = w - 11) + percentage
    mov r15d, [rbx + Widget.w]
    sub r15d, 11
    jle .Lpdr_counts
    mov eax, [r14 + TaskSnap.percent]
    cmp eax, 100
    jbe .Lpdr_pct_ok
    mov eax, 100
.Lpdr_pct_ok:
    imul eax, r15d
    xor edx, edx
    mov ecx, 100
    div ecx
    mov [rsp + 240], eax      # filled cells

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
    mov ecx, [rsp + 240]
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
    add esi, [rsp + 240]
    mov edx, [rbx + Widget.y]
    add edx, 3
    mov ecx, r15d
    sub ecx, [rsp + 240]
    mov r8d, 1
    mov r9d, CH_SHADE_LIGHT
    call ScreenBuffer_fill_rect

    mov byte ptr [rsp], 0
    mov rdi, rsp
    mov esi, [r14 + TaskSnap.percent]
    call pd_cat_u64
    mov rdi, rsp
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
    add edx, 3
    mov rcx, rsp
    mov r8d, 4
    call ScreenBuffer_draw_text

.Lpdr_counts:
    # Row 4: "<done> / <total>  ·  Files: a / b"
    mov byte ptr [rsp], 0
    cmp dword ptr [r14 + TaskSnap.op], TASK_OP_DELETE
    je .Lpdr_files
    mov rdi, rsp
    mov rsi, [r14 + TaskSnap.done_bytes]
    call pd_cat_size
    cmp qword ptr [r14 + TaskSnap.total_bytes], 0
    je .Lpdr_bytes_end
    mov rdi, rsp
    lea rsi, [rip + str_pd_slash]
    call pd_cat
    mov rdi, rsp
    mov rsi, [r14 + TaskSnap.total_bytes]
    call pd_cat_size
.Lpdr_bytes_end:
    mov rdi, rsp
    lea rsi, [rip + str_pd_dot]
    call pd_cat
.Lpdr_files:
    call i18n_get
    mov rsi, [rax + LangStrings.task_lbl_files]
    mov rdi, rsp
    call pd_cat
    mov rdi, rsp
    mov rsi, [r14 + TaskSnap.done_files]
    mov rax, [r14 + TaskSnap.total_files]
    cmp rsi, rax
    jbe .Lpdr_df_ok
    mov rsi, rax
.Lpdr_df_ok:
    call pd_cat_u64
    mov rdi, rsp
    lea rsi, [rip + str_pd_slash]
    call pd_cat
    mov rdi, rsp
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
    mov rcx, rsp
    mov r8d, [rbx + Widget.w]
    sub r8d, 6
    call ScreenBuffer_draw_text

    # Row 5: state (speed / ETA, paused, scanning, canceling)
    mov byte ptr [rsp], 0
    mov rdi, r14
    mov rsi, rsp
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
    mov rcx, rsp
    mov r8d, [rbx + Widget.w]
    sub r8d, 6
    call ScreenBuffer_draw_text

    # Buttons (focus > hover > idle styles)
    xor r15d, r15d
.Lpdr_btn:
    cmp r15d, PD_BTNS
    jge .Lpdr_done
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

.Lpdr_done:
    add rsp, 256
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
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

# int ProgressDialog_on_key(ProgressDialog *this, Event *evt)
ProgressDialog_on_key:
    push rbx
    mov rbx, rdi
    mov eax, [rsi + Event.key]
    mov ecx, [rsi + Event.mods]
    test ecx, MOD_ALT
    jz .Lpdk_plain
    cmp eax, 'j';    je .Lpdk_hide
    cmp eax, 'J';    je .Lpdk_hide
    cmp eax, 0x043E; je .Lpdk_hide   # Cyrillic 'о' (Alt+J on Ukrainian layout)
    cmp eax, 0x041E; je .Lpdk_hide   # Cyrillic 'О'
    jmp .Lpdk_swallow
.Lpdk_plain:
    test ecx, MOD_CTRL
    jnz .Lpdk_swallow
    cmp eax, KEY_ESC;   je .Lpdk_hide
    cmp eax, KEY_TAB;   je .Lpdk_next
    cmp eax, KEY_RIGHT; je .Lpdk_next
    cmp eax, KEY_BTAB;  je .Lpdk_prev
    cmp eax, KEY_LEFT;  je .Lpdk_prev
    cmp eax, KEY_ENTER; je .Lpdk_enter
    cmp eax, ' ';       je .Lpdk_pause
    cmp eax, 'p';       je .Lpdk_pause
    cmp eax, 'P';       je .Lpdk_pause
    cmp eax, 0x0437;    je .Lpdk_pause   # 'з' (P key, Ukrainian layout)
    cmp eax, 0x0417;    je .Lpdk_pause   # 'З'
    cmp eax, 'b';       je .Lpdk_hide
    cmp eax, 'B';       je .Lpdk_hide
    cmp eax, 0x0438;    je .Lpdk_hide    # 'и' (B key)
    cmp eax, 0x0418;    je .Lpdk_hide    # 'И'
    cmp eax, 'c';       je .Lpdk_cancel
    cmp eax, 'C';       je .Lpdk_cancel
    cmp eax, 0x0441;    je .Lpdk_cancel  # 'с' (C key)
    cmp eax, 0x0421;    je .Lpdk_cancel  # 'С'
    jmp .Lpdk_swallow

.Lpdk_next:
    mov eax, [rbx + Dialog.focus_btn]
    inc eax
    jmp .Lpdk_focus
.Lpdk_prev:
    mov eax, [rbx + Dialog.focus_btn]
    add eax, PD_BTNS - 1
.Lpdk_focus:
    xor edx, edx
    mov ecx, PD_BTNS
    div ecx
    mov [rbx + Dialog.focus_btn], edx
    mov rax, [rbx + Dialog.app]
    mov dword ptr [rax + App.need_redraw], 1
    jmp .Lpdk_swallow
.Lpdk_enter:
    mov esi, [rbx + Dialog.focus_btn]
    jmp .Lpdk_act
.Lpdk_pause:
    xor esi, esi
    jmp .Lpdk_act
.Lpdk_hide:
    mov esi, 1
    jmp .Lpdk_act
.Lpdk_cancel:
    mov esi, 2
.Lpdk_act:
    mov rdi, rbx
    call pd_activate
.Lpdk_swallow:
    mov eax, 1
    pop rbx
    ret

# int ProgressDialog_on_mouse(ProgressDialog *this, Event *evt)
ProgressDialog_on_mouse:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r8d, [r12 + Event.mouse_x]
    mov r9d, [r12 + Event.mouse_y]
    mov r13d, -1
    xor ecx, ecx
.Lpdm_find:
    cmp ecx, [rbx + Dialog.btn_count]
    jge .Lpdm_found
    imul rax, rcx, HitZone._size
    lea r10, [rbx + Dialog.btns + rax]
    movsx edx, word ptr [r10 + HitZone.y]
    cmp r9d, edx
    jne .Lpdm_next
    movsx edx, word ptr [r10 + HitZone.x1]
    cmp r8d, edx
    jl .Lpdm_next
    movsx edx, word ptr [r10 + HitZone.x2]
    cmp r8d, edx
    jge .Lpdm_next
    movsx r13d, word ptr [r10 + HitZone.id]
    jmp .Lpdm_found
.Lpdm_next:
    inc ecx
    jmp .Lpdm_find
.Lpdm_found:
    mov eax, [r12 + Event.mouse_kind]
    cmp eax, MACT_MOVE
    je .Lpdm_hover
    cmp eax, MACT_PRESS
    jne .Lpdm_swallow
    cmp dword ptr [r12 + Event.mouse_btn], MOUSE_LEFT
    jne .Lpdm_swallow
    test r13d, r13d
    js .Lpdm_swallow
    mov rdi, rbx
    mov esi, r13d
    call pd_activate
    jmp .Lpdm_swallow
.Lpdm_hover:
    cmp r13d, [rbx + Dialog.hovered_btn]
    je .Lpdm_swallow
    mov [rbx + Dialog.hovered_btn], r13d
    mov rax, [rbx + Dialog.app]
    mov dword ptr [rax + App.need_redraw], 1
.Lpdm_swallow:
    mov eax, 1
    pop r13
    pop r12
    pop rbx
    ret
