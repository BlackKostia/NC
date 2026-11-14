# FilePane Widget (Inherits from Widget) — file pane keys (split from file_pane.s)

.intel_syntax noprefix
.include "classes.inc"
.equ FP_TAB_MAX,       8
.equ FP_TAB_PATH,      0
.equ FP_TAB_CURSOR,    4096
.equ FP_TAB_SCROLL,    4100
.equ FP_TAB_SORT_MODE, 4104
.equ FP_TAB_SORT_DESC, 4108
.equ FP_TAB_SHOW_HID,  4112
.equ FP_TAB_SIZE,      4384

.section .rodata
str_home_env:    .asciz "HOME"

.section .text
.global FilePane_on_key
.global scrub_scrollbar

# int FilePane_on_key(FilePane *this, Event *evt)
FilePane_on_key:
    push rbx
    push r12
    push r13
    call FilePane_on_key__part1
    # Ctrl+A -> toggle select all
    test ecx, MOD_CTRL
    jz .Lfpk_plain
    cmp eax, 'a'
    je .Lfpk_sel_all
    jmp .Lfpk_not_handled

.Lfpk_plain:
    cmp eax, KEY_UP
    je .Lfpk_up
    cmp eax, 'k'
    je .Lfpk_up
    cmp eax, KEY_DOWN
    je .Lfpk_down
    cmp eax, 'j'
    je .Lfpk_down
    cmp eax, KEY_PGUP
    je .Lfpk_pgup
    cmp eax, KEY_PGDN
    je .Lfpk_pgdn
    cmp eax, KEY_HOME
    je .Lfpk_home
    cmp eax, 'g'
    je .Lfpk_home
    cmp eax, KEY_END
    je .Lfpk_end
    cmp eax, 'G'
    je .Lfpk_end
    cmp eax, ' '
    je .Lfpk_toggle_sel
    cmp eax, KEY_INSERT
    je .Lfpk_toggle_sel
    cmp eax, '*'
    je .Lfpk_sel_all
    cmp eax, KEY_ENTER
    je .Lfpk_enter
    cmp eax, KEY_BACKSPACE
    je .Lfpk_parent
    cmp eax, '~'
    je .Lfpk_home_dir
    jmp .Lfpk_not_handled

.Lfpk_up:
    dec dword ptr [rbx + FilePane.cursor]
    jmp .Lfpk_sync
.Lfpk_down:
    inc dword ptr [rbx + FilePane.cursor]
    jmp .Lfpk_sync
.Lfpk_pgup:
    mov rdi, rbx
    call get_list_h
    sub [rbx + FilePane.cursor], eax
    jmp .Lfpk_sync
.Lfpk_pgdn:
    mov rdi, rbx
    call get_list_h
    add [rbx + FilePane.cursor], eax
    jmp .Lfpk_sync
.Lfpk_home:
    mov dword ptr [rbx + FilePane.cursor], 0
    jmp .Lfpk_sync
.Lfpk_end:
    mov rax, [r13 + DirModel.count]
    dec eax
    mov [rbx + FilePane.cursor], eax
    jmp .Lfpk_sync
.Lfpk_toggle_sel:
    mov rdi, r13
    mov esi, [rbx + FilePane.cursor]
    call DirModel_toggle_select
    inc dword ptr [rbx + FilePane.cursor]
    jmp .Lfpk_sync
.Lfpk_sel_all:
    mov rdi, r13
    call DirModel_select_all_toggle
    jmp .Lfpk_sync
.Lfpk_enter:
    mov rdi, [rbx + FilePane.app]
    mov rsi, rbx
    call App_open_selected_entry
    jmp .Lfpk_handled
.Lfpk_parent:
    mov rdi, rbx
    call FilePane_enter_parent
    mov rdi, [rbx + FilePane.app]
    call App_sync_preview
    jmp .Lfpk_handled
.Lfpk_home_dir:
    mov rcx, [rbx + FilePane.app]
    mov rdi, [rcx + App.envp]
    lea rsi, [rip + str_home_env]
    call env_getenv
    test rax, rax
    jz .Lfpk_handled
    call FilePane_on_key__chdir
.Lfpk_sync:
    mov rdi, rbx
    call FilePane_ensure_visible
    mov rdi, [rbx + FilePane.app]
    call App_sync_preview
.Lfpk_handled:
    mov rax, [rbx + FilePane.app]
    mov dword ptr [rax + App.need_redraw], 1
    mov eax, 1
    pop r13
    pop r12
    pop rbx
    ret

.Lfpk_not_handled:
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    ret

# FilePane_on_key step (runs on the caller's frame)
FilePane_on_key__part1:
    lea rsp, [rsp - 8]
    mov rbx, rdi
    mov r12, rsi
    mov r13, [rbx + FilePane.model]

    mov eax, [r12 + Event.lat]
    mov ecx, [r12 + Event.mods]

.LFilePane_on_key__part1_ret:
    lea rsp, [rsp + 8]
    ret

# FilePane_on_key step: chdir (runs on the caller's frame)
FilePane_on_key__chdir:
    lea rsp, [rsp - 8]
    mov rdi, r13
    mov rsi, rax
    call DirModel_chdir
    test rax, rax
    js .LFilePane_on_key__chdir_ret
    cmp dword ptr [r13 + DirModel.du_mode], 0
    je 1f
    mov rdi, r13
    call dir_du_populate
1:  mov dword ptr [rbx + FilePane.cursor], 0
    mov dword ptr [rbx + FilePane.scroll], 0
    jmp .LFilePane_on_key__chdir_ret

.LFilePane_on_key__chdir_ret:
    lea rsp, [rsp + 8]
    ret

# Helper: scrub scroll from mouse y along scrollbar
scrub_scrollbar:
    # rdi=this, esi=my
    push rbx
    mov rbx, rdi
    mov eax, esi
    sub eax, [rbx + Widget.y]
    sub eax, 3
    test eax, eax
    jns .Lssb_nonneg
    xor eax, eax
.Lssb_nonneg:
    push rax
    mov rdi, rbx
    call get_list_h           # eax = list_h
    mov r8d, eax
    pop rax
    cmp eax, r8d
    jl .Lssb_r_ok
    lea eax, [r8d - 1]
.Lssb_r_ok:
    mov r9, [rbx + FilePane.model]
    mov r9, [r9 + DirModel.count]
    sub r9d, r8d              # max_scroll
    cmp r9d, 0
    jle .Lssb_zero
    cmp r8d, 2
    jl .Lssb_zero
    imul eax, r9d
    lea ecx, [r8d - 1]
    xor edx, edx
    div ecx
    mov [rbx + FilePane.scroll], eax
    jmp .Lssb_done
.Lssb_zero:
    mov dword ptr [rbx + FilePane.scroll], 0
.Lssb_done:
    pop rbx
    ret
