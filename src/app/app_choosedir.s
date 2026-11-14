# App Controller Class (Inherits from Object) — app choosedir (split from app.s)

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .text
.global App_write_choosedir
.global app_mouse_hover

# void App_write_choosedir(App *this, const char *out_path)
App_write_choosedir:
    test rsi, rsi
    jz .Lawc_ret
    cmp byte ptr [rsi], 0
    je .Lawc_ret
    push rbx
    push r12
    push r13
    sub rsp, 16
    mov rbx, rdi
    mov r12, rsi

    mov rax, [rbx + App.active_pane]
    test rax, rax
    jz .Lawc_done
    mov r13, [rax + FilePane.model]
    test r13, r13
    jz .Lawc_done

    mov edi, AT_FDCWD
    mov rsi, r12
    mov edx, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC
    mov r10d, 0644
    OS_OPENAT
    test rax, rax
    js .Lawc_done
    mov ebx, eax              # fd

    lea r13, [r13 + DirModel.path]
    mov rdi, r13
    call str_len
    mov rdx, rax
    mov edi, ebx
    mov rsi, r13
    call sys_write_all

    mov byte ptr [rsp], '\n'
    mov edi, ebx
    mov rsi, rsp
    mov edx, 1
    call sys_write_all

    mov edi, ebx
    OS_CLOSE
.Lawc_done:
    add rsp, 16
    pop r13
    pop r12
    pop rbx
.Lawc_ret:
    ret

# User menu & command expansion moved to src/app/app_menu.s

app_mouse_hover:
    push rbx; push r12
    sub rsp, 8
    mov rbx, rdi; mov r12, rsi
    mov rdi, [rbx + App.header_bar]; mov rsi, r12; VCALL WidgetVtbl.on_mouse
    mov rdi, [rbx + App.func_bar];   mov rsi, r12; VCALL WidgetVtbl.on_mouse
    mov rdi, [rbx + App.left_pane];  mov rsi, r12; VCALL WidgetVtbl.on_mouse
    cmp dword ptr [rbx + App.right_mode], RIGHT_MODE_PREVIEW
    je .Lamh_done
    mov rdi, [rbx + App.right_pane]; mov rsi, r12; VCALL WidgetVtbl.on_mouse
.Lamh_done:
    add rsp, 8; pop r12; pop rbx; ret
