# Frozen reference oracle: src/ui/progress_dialog.s (before C23 migration to src/ui/progress_dialog.c).
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
str_pd_per_s:       .asciz "/s"
str_pd_eta_unk:     .asciz "--:--"

ProgressDialog_vtbl:
    DIALOG_VTBL_SLOTS str_ProgressDialog, Dialog_vtbl, ProgressDialog._size, Dialog_dtor, ProgressDialog_layout, ProgressDialog_render, ProgressDialog_on_key, ProgressDialog_on_mouse, Widget_on_focus, Widget_hit_test, ProgressDialog_on_hide, ProgressDialog_on_hide

.section .text
.global ProgressDialog_new
.global ProgressDialog_layout
.global ProgressDialog_title_for
.global pd_cat_u64
.global pd_cat_size
.global pd_cat
.global pd_format_state
.global ProgressDialog_format_summary
.global pd_layout_buttons
.global str_pd_sp
.global str_pd_pct
.global str_pd_dot
.global ProgressDialog_vtbl

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
