# src/ui/pkg_dialog.s - TUI Package Manager Dialog (Alt+K)
.intel_syntax noprefix
.include "classes.inc"

.equ PKGD_ENTRIES, Dialog._size
.equ PKGD_COUNT,   Dialog._size + 8
.equ PKGD_CURSOR,  Dialog._size + 12
.equ PKGD_SCROLL,  Dialog._size + 16
.equ PKGD_TAB,     Dialog._size + 20
.equ PKGD_SIZE,    Dialog._size + 24
.equ PKG_ENTRY_SZ, 296
.equ PKG_MAX_UI,   32

.section .rodata
str_PkgDialog: .asciz "PkgDialog"
str_pkd_sep:   .asciz "  "

.align 8
PkgDialog_vtbl:
    DIALOG_VTBL_SLOTS str_PkgDialog, Dialog_vtbl, PKGD_SIZE, PkgDialog_dtor, PkgDialog_layout, PkgDialog_render, PkgDialog_handle_key, PkgDialog_handle_mouse, Widget_on_focus, Widget_hit_test, Dialog_on_confirm, Dialog_on_cancel

.section .text
.global PkgDialog_new
.global PkgDialog_vtbl
.global App_cmd_packages
.global App_pkg_install_confirm

.extern App_close_dialog
.extern App_run_pkg_action
.extern App_set_status
.extern Dialog_draw_frame
.extern Dialog_dtor
.extern Dialog_init
.extern Dialog_on_cancel
.extern Dialog_on_confirm
.extern InputDialog_new
.extern ScreenBuffer_draw_text
.extern ScreenBuffer_fill_rect
.extern ScreenBuffer_set_pen
.extern Widget_hit_test
.extern Widget_on_focus
.extern i18n_get
.extern mem_alloc
.extern mem_free
.extern pkg_action_find
.extern pkg_install_archive
.extern pkg_list
.extern pkg_registry_find
.extern pkg_registry_list
.extern pkg_remove
.extern pkg_verify
.extern str_cat
.extern str_copy

pkd_refresh:
    push rbx; push r12; push r13; push r14
    mov rbx, rdi
    mov rax, [rbx + Dialog.app]
    mov rdi, [rax + App.envp]
    cmp dword ptr [rbx + PKGD_TAB], 0; jne .Lpdr_avail
    mov rsi, [rbx + PKGD_ENTRIES]
    mov edx, PKG_MAX_UI
    call pkg_list
    jmp .Lpdr_cnt
.Lpdr_avail:
    push rdi
    mov edi, PKG_MAX_UI * 512; call mem_alloc
    pop rdi
    test rax, rax; jz .Lpdr_zero
    mov r12, rax
    mov rsi, r12; mov edx, PKG_MAX_UI; call pkg_registry_list
    mov r13d, eax; xor r14d, r14d
.Lpdr_cp:
    cmp r14d, r13d; jge .Lpdr_free
    imul rsi, r14, 512; add rsi, r12
    imul rdi, r14, PKG_ENTRY_SZ; add rdi, [rbx + PKGD_ENTRIES]
    push rdi; push rsi; mov edx, 64; call str_copy; pop rsi; pop rdi
    push rdi; push rsi; add rdi, 64; add rsi, 64; mov edx, 32; call str_copy; pop rsi; pop rdi
    push rdi; push rsi; add rdi, 96; add rsi, 96; mov edx, 16; call str_copy; pop rsi; pop rdi
    add rdi, 112; add rsi, 384; mov edx, 112; call str_copy
    inc r14d; jmp .Lpdr_cp
.Lpdr_free:
    mov rdi, r12; call mem_free
    mov eax, r13d; jmp .Lpdr_cnt
.Lpdr_zero:
    xor eax, eax
.Lpdr_cnt:
    mov [rbx + PKGD_COUNT], eax
    mov ecx, [rbx + PKGD_CURSOR]
    cmp ecx, eax; jl .Lpdr_ok
    dec eax; test eax, eax; jns .Lpdr_set
    xor eax, eax
.Lpdr_set:
    mov [rbx + PKGD_CURSOR], eax
.Lpdr_ok:
    pop r14; pop r13; pop r12; pop rbx; ret

PkgDialog_new:
    push rbx; push r12
    mov r12, rdi
    mov edi, PKGD_SIZE; call mem_alloc
    test rax, rax; jz .Lpdn_ret
    mov rbx, rax
    lea rax, [rip + PkgDialog_vtbl]; mov [rbx], rax
    call i18n_get
    mov rdx, [rax + LangStrings.pkg_title]
    mov rdi, rbx; mov rsi, r12; xor ecx, ecx; call Dialog_init
    mov edi, PKG_MAX_UI * PKG_ENTRY_SZ; call mem_alloc
    mov [rbx + PKGD_ENTRIES], rax
    mov dword ptr [rbx + PKGD_COUNT], 0
    mov dword ptr [rbx + PKGD_CURSOR], 0
    mov dword ptr [rbx + PKGD_SCROLL], 0
    mov dword ptr [rbx + Widget.w], 70
    mov dword ptr [rbx + Widget.h], 18
    test rax, rax; jz .Lpdn_lay
    mov rdi, rbx; call pkd_refresh
.Lpdn_lay:
    mov rdi, rbx; xor esi, esi; xor edx, edx
    mov ecx, [r12 + App.term_w]; mov r8d, [r12 + App.term_h]
    call PkgDialog_layout
    mov rax, rbx
.Lpdn_ret:
    pop r12; pop rbx; ret

PkgDialog_dtor:
    push rbx; mov rbx, rdi
    mov rdi, [rbx + PKGD_ENTRIES]; test rdi, rdi; jz .Lpdd_base
    call mem_free
    mov qword ptr [rbx + PKGD_ENTRIES], 0
.Lpdd_base:
    mov rdi, rbx; pop rbx; jmp Dialog_dtor

PkgDialog_layout:
    mov eax, ecx; sub eax, 6; cmp eax, 70; jle .Lpdl_w
    mov eax, 70
.Lpdl_w:
    cmp eax, 30; jge .Lpdl_w2
    mov eax, 30
.Lpdl_w2:
    mov [rdi + Widget.w], eax
    mov r9d, r8d; sub r9d, 4; cmp r9d, 18; jle .Lpdl_h
    mov r9d, 18
.Lpdl_h:
    cmp r9d, 8; jge .Lpdl_h2
    mov r9d, 8
.Lpdl_h2:
    mov [rdi + Widget.h], r9d
    sub ecx, eax; sar ecx, 1; mov [rdi + Widget.x], ecx
    sub r8d, r9d; sar r8d, 1; mov [rdi + Widget.y], r8d
    ret

PkgDialog_render:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, 168
    mov rbx, rdi; mov r12, rsi; mov r13, rdx
    xor ecx, ecx; xor r8d, r8d; call Dialog_draw_frame
    mov r14d, [rbx + PKGD_COUNT]
    test r14d, r14d; jnz .Lpdr_rows
    mov rdi, r12; mov esi, [r13 + Theme.text]; mov edx, [r13 + Theme.surface]; xor ecx, ecx
    call ScreenBuffer_set_pen
    call i18n_get
    mov rcx, [rax + LangStrings.pkg_empty]
    mov rdi, r12; mov esi, [rbx + Widget.x]; add esi, 3
    mov edx, [rbx + Widget.y]; add edx, 3
    mov r8d, [rbx + Widget.w]; sub r8d, 6
    call ScreenBuffer_draw_text
    jmp .Lpdr_hint
.Lpdr_rows:
    mov r15d, 0                       # row index
.Lpdr_loop:
    mov eax, [rbx + Widget.h]; sub eax, 5
    cmp r15d, eax; jge .Lpdr_hint
    mov eax, r15d; add eax, [rbx + PKGD_SCROLL]
    cmp eax, r14d; jge .Lpdr_hint
    imul rcx, rax, PKG_ENTRY_SZ; add rcx, [rbx + PKGD_ENTRIES]
    mov [rsp + 160], rcx
    mov rdi, rsp; mov rsi, rcx; mov edx, 160; call str_copy
    mov rdi, rsp; lea rsi, [rip + str_pkd_sep]; mov edx, 160; call str_cat
    mov rcx, [rsp + 160]; mov rdi, rsp; lea rsi, [rcx + 64]; mov edx, 160; call str_cat
    mov rdi, rsp; lea rsi, [rip + str_pkd_sep]; mov edx, 160; call str_cat
    mov rcx, [rsp + 160]; mov rdi, rsp; lea rsi, [rcx + 96]; mov edx, 160; call str_cat
    mov rdi, rsp; lea rsi, [rip + str_pkd_sep]; mov edx, 160; call str_cat
    mov rcx, [rsp + 160]; mov rdi, rsp; lea rsi, [rcx + 112]; mov edx, 160; call str_cat
    mov esi, [r13 + Theme.text]; mov edx, [r13 + Theme.surface]
    mov eax, r15d; add eax, [rbx + PKGD_SCROLL]
    cmp eax, [rbx + PKGD_CURSOR]; jne .Lpdr_draw
    mov esi, [r13 + Theme.selected_fg]; mov edx, [r13 + Theme.selected_bg]
    push rsi; push rdx
    mov rdi, r12; mov esi, [rbx + Widget.x]; add esi, 2
    mov edx, [rbx + Widget.y]; add edx, 2; add edx, r15d
    mov ecx, [rbx + Widget.w]; sub ecx, 4
    mov r8d, 1; call ScreenBuffer_fill_rect
    pop rdx; pop rsi
.Lpdr_draw:
    mov rdi, r12; xor ecx, ecx; call ScreenBuffer_set_pen
    mov rdi, r12; mov esi, [rbx + Widget.x]; add esi, 3
    mov edx, [rbx + Widget.y]; add edx, 2; add edx, r15d
    mov rcx, rsp; mov r8d, [rbx + Widget.w]; sub r8d, 6
    call ScreenBuffer_draw_text
    inc r15d; jmp .Lpdr_loop
.Lpdr_hint:
    mov rdi, r12; mov esi, [r13 + Theme.muted]; mov edx, [r13 + Theme.surface]; xor ecx, ecx
    call ScreenBuffer_set_pen
    call i18n_get
    mov rcx, [rax + LangStrings.pkg_hint]
    mov rdi, r12; mov esi, [rbx + Widget.x]; add esi, 2
    mov edx, [rbx + Widget.y]; add edx, [rbx + Widget.h]; sub edx, 2
    mov r8d, [rbx + Widget.w]; sub r8d, 4
    call ScreenBuffer_draw_text
    add rsp, 168; pop r15; pop r14; pop r13; pop r12; pop rbx; ret

pkd_install_avail:
    sub rsp, 512
    mov r12, [rbx + Dialog.app]
    mov eax, [rbx + PKGD_CURSOR]; imul rax, PKG_ENTRY_SZ; add rax, [rbx + PKGD_ENTRIES]
    mov rdi, [r12 + App.envp]; mov rsi, rax; mov rdx, rsp; call pkg_registry_find
    test eax, eax; jnz .Lpia_err
    mov rdi, [r12 + App.envp]; lea rsi, [rsp + 192]; lea rdx, [rsp + 112]; call pkg_install_archive
    add rsp, 512; ret
.Lpia_err:
    add rsp, 512; mov eax, -1; ret

pkd_run_selected:
    sub rsp, 576
    mov r12, [rbx + Dialog.app]
    mov eax, [rbx + PKGD_CURSOR]; imul rax, PKG_ENTRY_SZ; add rax, [rbx + PKGD_ENTRIES]
    mov rdi, [r12 + App.envp]; mov rsi, rax; mov rdx, rsp; call pkg_action_find
    test eax, eax; jnz .Lprs_err
    mov rdi, r12; xor esi, esi; call App_close_dialog
    mov rdi, r12; mov rsi, rsp; call App_run_pkg_action
    add rsp, 576; xor eax, eax; ret
.Lprs_err:
    add rsp, 576; mov eax, -1; ret

PkgDialog_handle_key:
    push rbx; push r12
    mov rbx, rdi; mov r12, rsi
    mov eax, [r12 + Event.key]
    cmp eax, KEY_ESC; je .Lpdk_close
    cmp eax, 'q'; je .Lpdk_close
    cmp eax, KEY_UP; je .Lpdk_up
    cmp eax, 'k'; je .Lpdk_up
    cmp eax, KEY_DOWN; je .Lpdk_down
    cmp eax, 'j'; je .Lpdk_down
    cmp eax, 'v'; je .Lpdk_verify
    cmp eax, KEY_ENTER; je .Lpdk_enter
    cmp eax, KEY_TAB; je .Lpdk_tab
    cmp eax, 'd'; je .Lpdk_rem
    cmp eax, KEY_DELETE; je .Lpdk_rem
    cmp eax, 'i'; je .Lpdk_inst
    cmp eax, 'r'; je .Lpdk_run
    xor eax, eax; pop r12; pop rbx; ret
.Lpdk_close:
    mov rdi, [rbx + Dialog.app]; xor esi, esi; call App_close_dialog
    mov eax, 1; pop r12; pop rbx; ret
.Lpdk_up:
    mov eax, [rbx + PKGD_CURSOR]; test eax, eax; jle .Lpdk_ok
    dec eax; mov [rbx + PKGD_CURSOR], eax; jmp .Lpdk_redraw
.Lpdk_down:
    mov eax, [rbx + PKGD_CURSOR]; inc eax
    cmp eax, [rbx + PKGD_COUNT]; jge .Lpdk_ok
    mov [rbx + PKGD_CURSOR], eax; jmp .Lpdk_redraw
.Lpdk_tab:
    xor dword ptr [rbx + PKGD_TAB], 1; mov dword ptr [rbx + PKGD_CURSOR], 0
    mov dword ptr [rbx + PKGD_SCROLL], 0; mov rdi, rbx; call pkd_refresh; jmp .Lpdk_redraw
.Lpdk_enter:
    cmp dword ptr [rbx + PKGD_TAB], 0; je .Lpdk_verify
    cmp dword ptr [rbx + PKGD_COUNT], 0; jle .Lpdk_ok
    call pkd_install_avail
    test eax, eax; jnz .Lpdk_err
    mov dword ptr [rbx + PKGD_TAB], 0; mov rdi, rbx; call pkd_refresh
    call i18n_get; mov rsi, [rax + LangStrings.pkg_installed]; mov edx, MSG_OK; jmp .Lpdk_st
.Lpdk_verify:
    cmp dword ptr [rbx + PKGD_COUNT], 0; jle .Lpdk_ok
    mov r12, [rbx + Dialog.app]
    mov eax, [rbx + PKGD_CURSOR]; imul rax, PKG_ENTRY_SZ; add rax, [rbx + PKGD_ENTRIES]
    mov rdi, [r12 + App.envp]; mov rsi, rax; call pkg_verify
    test eax, eax; jnz .Lpdk_err
    call i18n_get; mov rsi, [rax + LangStrings.pkg_verified]; mov edx, MSG_OK; jmp .Lpdk_st
.Lpdk_rem:
    cmp dword ptr [rbx + PKGD_COUNT], 0; jle .Lpdk_ok
    mov r12, [rbx + Dialog.app]
    mov eax, [rbx + PKGD_CURSOR]; imul rax, PKG_ENTRY_SZ; add rax, [rbx + PKGD_ENTRIES]
    mov rdi, [r12 + App.envp]; mov rsi, rax; call pkg_remove
    test eax, eax; jnz .Lpdk_err
    mov rdi, rbx; call pkd_refresh
    call i18n_get; mov rsi, [rax + LangStrings.pkg_removed]; mov edx, MSG_OK; jmp .Lpdk_st
.Lpdk_err:
    call i18n_get; mov rsi, [rax + LangStrings.pkg_err]; mov edx, MSG_ERR
.Lpdk_st:
    mov rdi, [rbx + Dialog.app]; call App_set_status
.Lpdk_redraw:
    mov rax, [rbx + Dialog.app]; mov dword ptr [rax + App.need_redraw], 1
.Lpdk_ok:
    mov eax, 1; pop r12; pop rbx; ret
.Lpdk_inst:
    mov r12, [rbx + Dialog.app]
    mov rdi, r12; xor esi, esi; call App_close_dialog
    call i18n_get
    mov rdx, [rax + LangStrings.pkg_title]
    mov rcx, [rax + LangStrings.pkg_install_prompt]
    mov rdi, r12; mov rsi, rdx; mov rdx, rcx; xor ecx, ecx; mov r8d, 25
    call InputDialog_new
    test rax, rax; jz .Lpdk_ok
    mov [r12 + App.active_dialog], rax
    mov dword ptr [r12 + App.need_redraw], 1
    mov eax, 1; pop r12; pop rbx; ret
.Lpdk_run:
    cmp dword ptr [rbx + PKGD_COUNT], 0; jle .Lpdk_ok
    call pkd_run_selected
    test eax, eax; jnz .Lpdk_err
    mov eax, 1; pop r12; pop rbx; ret

PkgDialog_handle_mouse:
    mov eax, [rsi + Event.mouse_btn]
    cmp eax, MOUSE_RIGHT; je .Lpdm_close
    mov eax, 1; ret
.Lpdm_close:
    mov rdi, [rdi + Dialog.app]; xor esi, esi; call App_close_dialog
    mov eax, 1; ret

# void App_cmd_packages(App *app)
App_cmd_packages:
    push rbx; mov rbx, rdi
    call PkgDialog_new
    test rax, rax; jz .Lacp_ret
    mov [rbx + App.active_dialog], rax
    mov dword ptr [rbx + App.need_redraw], 1
    mov eax, 1
.Lacp_ret:
    pop rbx; ret

# void App_pkg_install_confirm(App *app, InputDialog *dlg)
App_pkg_install_confirm:
    cmp byte ptr [rsi + InputDialog.buf], 0; je .Lapic_ret
    push rbx; mov rbx, rdi
    mov rdi, [rbx + App.envp]; lea rsi, [rsi + InputDialog.buf]; xor edx, edx
    call pkg_install_archive
    test eax, eax; jnz .Lapic_err
    call i18n_get; mov rsi, [rax + LangStrings.pkg_installed]; mov edx, MSG_OK
    jmp .Lapic_st
.Lapic_err:
    call i18n_get; mov rsi, [rax + LangStrings.pkg_err]; mov edx, MSG_ERR
.Lapic_st:
    mov rdi, rbx; call App_set_status; pop rbx
.Lapic_ret:
    ret
