# F3 on a file: images first ask "Open as" (Image / Hex / Text), everything else opens the
# built-in viewer directly; the dialog's choice opens the viewer in that mode.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .text
.global App_open_viewer
.global App_view_as_done
.global App_cmd_view_mode

# void App_open_viewer(App *app, const char *path)
App_open_viewer:
    push rbx
    push r12
    sub rsp, 72                       # [0..47] head bytes, [48] bytes read
    mov rbx, rdi
    mov r12, rsi
    mov qword ptr [rsp + 48], 0
    mov rdi, r12
    mov rsi, rsp
    mov edx, 32
    lea rcx, [rsp + 48]
    call fs_read_file_head
    mov rdi, rsp
    mov rsi, [rsp + 48]
    mov rdx, r12
    call img_detect
    test eax, eax
    jz .Lov_plain
    mov rdi, rbx
    mov rsi, r12
    mov edx, eax
    call ViewAsDialog_new
    jmp .Lov_set
.Lov_plain:
    mov rdi, rbx
    mov rsi, r12
    call ViewerDialog_new
.Lov_set:
    mov [rbx + App.active_dialog], rax
    mov dword ptr [rbx + App.need_redraw], 1
    add rsp, 72
    pop r12
    pop rbx
    ret

# void App_view_as_done(App *app, ViewAsDialog *dlg) -- open the viewer in the chosen mode
App_view_as_done:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rbx
    lea rsi, [r12 + ViewAsDialog.path]
    call ViewerDialog_new
    test rax, rax
    jz .Lvd_ret
    mov r13, rax
    mov rdi, r13
    mov esi, [r12 + ViewAsDialog.choice]
    call ViewerDialog_set_mode
    mov [rbx + App.active_dialog], r13
    mov dword ptr [rbx + App.need_redraw], 1
.Lvd_ret:
    pop r13
    pop r12
    pop rbx
    ret

# int App_cmd_view_mode(App *app) -- Alt+V: cycle the preview's Image / Hex / Text view
App_cmd_view_mode:
    cmp dword ptr [rdi + App.right_mode], RIGHT_MODE_PREVIEW
    jne .Lvm_ret
    sub rsp, 8
    mov rdi, [rdi + App.preview_pane]
    call PreviewPane_cycle_mode
    add rsp, 8
.Lvm_ret:
    mov eax, 1
    ret
