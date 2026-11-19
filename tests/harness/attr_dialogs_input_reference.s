# Frozen reference oracle: original src/ui/attr_dialogs_input.s before C23 migration (v2.6.50).
# src/ui/attr_dialogs.s - ChmodDialog (clickable rwx bits, octal mode, uid:gid) — attr dialogs input (split from attr_dialogs.s)

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"
.extern Dialog_vtbl
.extern Dialog_init
.extern Dialog_dtor
.extern Dialog_draw_frame
.extern Dialog_on_confirm
.extern Dialog_on_cancel
.extern Dialog_on_mouse
.extern dlg_layout_right_buttons
.extern Widget_on_focus
.extern Widget_hit_test
.extern ScreenBuffer_set_pen
.extern ScreenBuffer_draw_text
.extern ScreenBuffer_set_cell
.extern i18n_get
.extern os_statat
.extern str_copy
.extern str_len
.extern u64_to_dec
.extern path_basename
.extern mem_alloc

.section .rodata
str_rwx_hdr:     .asciz "Owner   Group   Other     Octal:"
str_owner_lbl:   .asciz "uid:gid: "

.section .text
.global ChmodDialog_render
.global ChmodDialog_on_key
.global ChmodDialog_on_mouse

# void ChmodDialog_render(ChmodDialog *this, ScreenBuffer *scr, Theme *theme)
ChmodDialog_render:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    call ChmodDialog_render__draw_text
    call ChmodDialog_render__draw_text_2
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# ChmodDialog_render step: draw_text (runs on the caller's frame)
ChmodDialog_render__draw_text:
    lea rsp, [rsp - 8]
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx

    call i18n_get
    mov r14, rax
    mov rcx, [r14 + LangStrings.dlg_btn_ok]
    mov r8, [r14 + LangStrings.dlg_btn_cancel]
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call Dialog_draw_frame

    mov rdi, r12
    mov esi, [r13 + Theme.text]
    mov edx, [r13 + Theme.dialog_bg]
    xor ecx, ecx
    call ScreenBuffer_set_pen

    lea rdi, [rbx + ChmodDialog.target_path]
    call path_basename
    mov rcx, rax
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 3
    mov edx, [rbx + Widget.y]
    add edx, 2
    mov r8d, [rbx + Widget.w]
    sub r8d, 6
    call ScreenBuffer_draw_text

    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 3
    mov edx, [rbx + Widget.y]
    add edx, 3
    lea rcx, [rip + str_rwx_hdr]
    mov r8d, 36
    call ScreenBuffer_draw_text

    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call cd_draw_bits

    mov rdi, r12
    mov esi, [r13 + Theme.text]
    mov edx, [r13 + Theme.dialog_bg]
    xor ecx, ecx
    call ScreenBuffer_set_pen
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 3
    mov edx, [rbx + Widget.y]
    add edx, 6
    lea rcx, [rip + str_owner_lbl]
    mov r8d, 9
    call ScreenBuffer_draw_text

.LChmodDialog_render__draw_text_ret:
    lea rsp, [rsp + 8]
    ret

# ChmodDialog_render step: draw_text (runs on the caller's frame)
ChmodDialog_render__draw_text_2:
    lea rsp, [rsp - 8]
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 12
    mov edx, [rbx + Widget.y]
    add edx, 6
    lea rcx, [rbx + ChmodDialog.owner_buf]
    mov r8d, 24
    call ScreenBuffer_draw_text

    mov rdi, r12
    mov esi, [r13 + Theme.muted]
    mov edx, [r13 + Theme.dialog_bg]
    xor ecx, ecx
    call ScreenBuffer_set_pen
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 2
    mov edx, [rbx + Widget.y]
    add edx, [rbx + Widget.h]
    sub edx, 2
    mov rcx, [r14 + LangStrings.chm_hint]
    mov r8d, [rbx + Widget.w]
    sub r8d, 24
    call ScreenBuffer_draw_text

.LChmodDialog_render__draw_text_2_ret:
    lea rsp, [rsp + 8]
    ret

# void ChmodDialog_on_key(ChmodDialog *this, Event *ev)
ChmodDialog_on_key:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    mov eax, [r12 + Event.key]

    cmp eax, KEY_ENTER; je .Lcdk_ok
    cmp eax, KEY_ESC;   je .Lcdk_esc
    cmp eax, KEY_LEFT;  je .Lcdk_left
    cmp eax, KEY_RIGHT; je .Lcdk_right
    cmp eax, ' ';       je .Lcdk_space
    cmp eax, 'u';       je .Lcdk_owner
    cmp eax, 'g';       je .Lcdk_owner

    cmp eax, '1'
    jb .Lcdk_chk_edit
    cmp eax, '9'
    ja .Lcdk_chk_edit
    cmp dword ptr [rbx + ChmodDialog.edit_owner], 0
    jne .Lcdk_chk_edit
    call ChmodDialog_on_key__part1
    jmp .Lcdk_redr

.Lcdk_chk_edit:
    cmp dword ptr [rbx + ChmodDialog.edit_owner], 0
    je .Lcdk_done
    cmp eax, KEY_BACKSPACE
    je .Lcdk_bs
    cmp eax, ':'
    je .Lcdk_app
    cmp eax, '0'
    jb .Lcdk_done
    cmp eax, '9'
    ja .Lcdk_done
.Lcdk_app:
    mov ecx, [rbx + ChmodDialog.owner_len]
    cmp ecx, 30
    jae .Lcdk_done
    mov [rbx + ChmodDialog.owner_buf + rcx], al
    inc ecx
    mov byte ptr [rbx + ChmodDialog.owner_buf + rcx], 0
    mov [rbx + ChmodDialog.owner_len], ecx
    jmp .Lcdk_redr
.Lcdk_bs:
    mov ecx, [rbx + ChmodDialog.owner_len]
    test ecx, ecx
    jz .Lcdk_done
    dec ecx
    mov byte ptr [rbx + ChmodDialog.owner_buf + rcx], 0
    mov [rbx + ChmodDialog.owner_len], ecx
    jmp .Lcdk_redr

.Lcdk_owner:
    xor dword ptr [rbx + ChmodDialog.edit_owner], 1
    jmp .Lcdk_redr
.Lcdk_left:
    cmp dword ptr [rbx + ChmodDialog.cursor], 0
    jle .Lcdk_done
    dec dword ptr [rbx + ChmodDialog.cursor]
    jmp .Lcdk_redr
.Lcdk_right:
    cmp dword ptr [rbx + ChmodDialog.cursor], 8
    jge .Lcdk_done
    inc dword ptr [rbx + ChmodDialog.cursor]
    jmp .Lcdk_redr
.Lcdk_space:
    mov ecx, 8
    sub ecx, [rbx + ChmodDialog.cursor]
    mov edx, 1
    shl edx, cl
    xor [rbx + ChmodDialog.mode], edx
.Lcdk_redr:
    mov rax, [rbx + Dialog.app]
    mov dword ptr [rax + App.need_redraw], 1
.Lcdk_done:
    add rsp, 8
    pop r12
    pop rbx
    ret
.Lcdk_ok:
    mov rdi, rbx
    call Dialog_on_confirm
    jmp .Lcdk_done
.Lcdk_esc:
    mov rdi, rbx
    call Dialog_on_cancel
    jmp .Lcdk_done

# ChmodDialog_on_key step (runs on the caller's frame)
ChmodDialog_on_key__part1:
    lea rsp, [rsp - 8]
    sub eax, '1'
    mov ecx, 8
    sub ecx, eax
    mov edx, 1
    shl edx, cl
    xor [rbx + ChmodDialog.mode], edx
    mov [rbx + ChmodDialog.cursor], eax
.LChmodDialog_on_key__part1_ret:
    lea rsp, [rsp + 8]
    ret

# void ChmodDialog_on_mouse(ChmodDialog *this, Event *ev)
ChmodDialog_on_mouse:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    cmp dword ptr [r12 + Event.mouse_kind], MACT_PRESS
    jne .Lcdm_base
    cmp dword ptr [r12 + Event.mouse_btn], MOUSE_LEFT
    jne .Lcdm_base
    mov eax, [rbx + Widget.y]
    add eax, 4
    cmp [r12 + Event.mouse_y], eax
    jne .Lcdm_base

    xor ecx, ecx
.Lcdm_chk:
    mov eax, ecx
    xor edx, edx
    mov r8d, 3
    div r8d
    lea r9d, [ecx*2 + 3]
    lea r9d, [r9d + eax*2]
    add r9d, [rbx + Widget.x]
    cmp [r12 + Event.mouse_x], r9d
    je .Lcdm_hit
    inc ecx
    cmp ecx, 9
    jb .Lcdm_chk
    jmp .Lcdm_base
.Lcdm_hit:
    mov [rbx + ChmodDialog.cursor], ecx
    mov edx, ecx
    mov ecx, 8
    sub ecx, edx
    mov eax, 1
    shl eax, cl
    xor [rbx + ChmodDialog.mode], eax
    mov rax, [rbx + Dialog.app]
    mov dword ptr [rax + App.need_redraw], 1
    jmp .Lcdm_done
.Lcdm_base:
    mov rdi, rbx
    mov rsi, r12
    call Dialog_on_mouse
.Lcdm_done:
    add rsp, 8
    pop r12
    pop rbx
    ret
