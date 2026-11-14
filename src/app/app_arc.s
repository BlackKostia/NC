# src/app/app_arc.s - App/FilePane UI glue for Archive VFS
.intel_syntax noprefix

.include "classes.inc"

.section .text
.global arc_nav_up
.global arc_handle_enter
.global arc_extract_selected

.extern arc_nav_up_model
.extern arc_enter_model
.extern arc_extract_entry
.extern FilePane_get_selected_entry
.extern FilePane_ensure_visible

# int arc_nav_up(FilePane *fp) -> 1 if handled
arc_nav_up:
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + FilePane.model]
    call arc_nav_up_model
    test eax, eax
    js .Lanu_no
    mov [rbx + FilePane.cursor], eax
    mov dword ptr [rbx + FilePane.scroll], 0
    mov rdi, rbx
    call FilePane_ensure_visible
    mov eax, 1
    pop rbx
    ret
.Lanu_no:
    xor eax, eax
    pop rbx
    ret

# int arc_handle_enter(App *app) -> 1 if handled
arc_handle_enter:
    push rbx; push r12
    mov rbx, rdi
    mov r12, [rbx + App.active_pane]
    mov rdi, r12
    call FilePane_get_selected_entry
    mov rdi, [r12 + FilePane.model]
    mov rsi, rax
    call arc_enter_model
    test eax, eax
    jz .Lahe_no
    cmp eax, 2
    jne .Lahe_reset
    mov rdi, r12
    call arc_nav_up
    jmp .Lahe_ok
.Lahe_reset:
    mov dword ptr [r12 + FilePane.cursor], 0
    mov dword ptr [r12 + FilePane.scroll], 0
.Lahe_ok:
    mov dword ptr [rbx + App.need_redraw], 1
    mov eax, 1
    pop r12; pop rbx
    ret
.Lahe_no:
    xor eax, eax
    pop r12; pop rbx
    ret

# int arc_extract_selected(FilePane *fp, char *out_tmp_path) -> 0 on ok, -1 on err
arc_extract_selected:
    push rbx; push r12
    mov rbx, rdi; mov r12, rsi
    mov rdi, rbx
    call FilePane_get_selected_entry
    mov rdi, [rbx + FilePane.model]
    mov rsi, rax
    mov rdx, r12
    call arc_extract_entry
    pop r12; pop rbx
    ret
