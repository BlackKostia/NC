# Frozen reference oracle: the hand-written asm that src/ui/dialogs_input_keys.c replaced (tests/test_c_dialogs_input_keys.py diffs against it)
# Modal Dialog Class Hierarchy (Dialog -> ConfirmDialog, InputDialog, HelpDialog; ViewerDialog: viewer_dialog.s) — dialogs input keys (split from dialogs.s)

.intel_syntax noprefix
.include "classes.inc"
.equ HELP_LINE_COUNT, 22

.section .text
.global InputDialog_on_key

InputDialog_on_key:
    push rbx
    push r12
    sub rsp, 16
    call InputDialog_on_key__part1
    # Ctrl+U clears buffer
    test ecx, MOD_CTRL
    jz .Lidk_plain
    cmp eax, 'u'
    jne .Lidk_handled
    mov dword ptr [rbx + InputDialog.len], 0
    mov dword ptr [rbx + InputDialog.cursor], 0
    mov byte ptr [rbx + InputDialog.buf], 0
    jmp .Lidk_dirty

.Lidk_plain:
    cmp eax, KEY_ESC
    je .Lidk_cancel
    cmp eax, KEY_ENTER
    je .Lidk_enter
    cmp eax, KEY_TAB
    je .Lidk_tab
    cmp eax, KEY_HOME
    je .Lidk_home
    cmp eax, KEY_END
    je .Lidk_end
    cmp eax, KEY_LEFT
    je .Lidk_left
    cmp eax, KEY_RIGHT
    je .Lidk_right
    cmp eax, KEY_BACKSPACE
    je .Lidk_bs
    cmp eax, KEY_DELETE
    je .Lidk_del

    # Printable Unicode/ASCII?
    cmp eax, 0x20
    jb .Lidk_handled
    cmp eax, 0x10FFFF
    ja .Lidk_handled

    # Encode key as UTF-8 into [rsp]
    call InputDialog_on_key__eax
    jae .Lidk_handled

    # Shift tail [cursor..len] right by eax
    call InputDialog_on_key__shift_tail_right_by
    # Copy encoded bytes into cursor slot
    call InputDialog_on_key__copy_encoded_bytes_into
    jmp .Lidk_dirty

.Lidk_tab:
    xor dword ptr [rbx + Dialog.focus_btn], 1
    jmp .Lidk_dirty
.Lidk_home:
    mov dword ptr [rbx + InputDialog.cursor], 0
    jmp .Lidk_dirty
.Lidk_end:
    mov eax, [rbx + InputDialog.len]
    mov [rbx + InputDialog.cursor], eax
    jmp .Lidk_dirty
.Lidk_left:
    mov ecx, [rbx + InputDialog.cursor]
    test ecx, ecx
    jz .Lidk_handled
.Lidk_lstep:
    dec ecx
    jz .Lidk_lset
    mov al, byte ptr [rbx + InputDialog.buf + rcx]
    and al, 0xC0
    cmp al, 0x80
    je .Lidk_lstep
.Lidk_lset:
    mov [rbx + InputDialog.cursor], ecx
    jmp .Lidk_dirty

.Lidk_right:
    mov ecx, [rbx + InputDialog.cursor]
    cmp ecx, [rbx + InputDialog.len]
    jae .Lidk_handled
.Lidk_rstep:
    inc ecx
    cmp ecx, [rbx + InputDialog.len]
    jae .Lidk_rset
    mov al, byte ptr [rbx + InputDialog.buf + rcx]
    and al, 0xC0
    cmp al, 0x80
    je .Lidk_rstep
.Lidk_rset:
    mov [rbx + InputDialog.cursor], ecx
    jmp .Lidk_dirty

.Lidk_bs:
    mov ecx, [rbx + InputDialog.cursor]
    test ecx, ecx
    jz .Lidk_handled
    call InputDialog_on_key__old_cursor
    jmp .Lidk_dirty

.Lidk_del:
    mov ecx, [rbx + InputDialog.cursor]
    cmp ecx, [rbx + InputDialog.len]
    jae .Lidk_handled
    call InputDialog_on_key__mem_move
    jmp .Lidk_dirty

.Lidk_enter:
    cmp dword ptr [rbx + Dialog.focus_btn], 0
    jne .Lidk_cancel
    mov rdi, rbx
    VCALL DialogVtbl.on_confirm
    jmp .Lidk_handled
.Lidk_cancel:
    mov rdi, rbx
    VCALL DialogVtbl.on_cancel
    jmp .Lidk_handled

.Lidk_dirty:
    mov rax, [rbx + Dialog.app]
    mov dword ptr [rax + App.need_redraw], 1
.Lidk_handled:
    mov eax, 1
    add rsp, 16
    pop r12
    pop rbx
    ret

# InputDialog_on_key step (runs on the caller's frame)
InputDialog_on_key__part1:
    lea rsp, [rsp - 8]
    mov rbx, rdi
    mov r12, rsi

    mov eax, [r12 + Event.key]
    mov ecx, [r12 + Event.mods]

.LInputDialog_on_key__part1_ret:
    lea rsp, [rsp + 8]
    ret

# InputDialog_on_key step: eax (runs on the caller's frame)
InputDialog_on_key__eax:
    lea rsp, [rsp - 8]
    mov edi, eax
    lea rsi, [rsp + 16]
    call utf8_encode          # eax = byte len (1..4)
    mov ecx, [rbx + InputDialog.len]
    add ecx, eax
    cmp ecx, INPUT_MAX - 1
.LInputDialog_on_key__eax_ret:
    lea rsp, [rsp + 8]
    ret

# InputDialog_on_key step: Shift tail right by eax (runs on the caller's frame)
InputDialog_on_key__shift_tail_right_by:
    lea rsp, [rsp - 8]
    push rax
    lea rdi, [rbx + InputDialog.buf]
    mov edx, [rbx + InputDialog.cursor]
    lea rsi, [rdi + rdx]
    add rdi, rdx
    add rdi, rax
    mov ecx, [rbx + InputDialog.len]
    sub ecx, edx
    inc ecx                   # include NUL
    mov rdx, rcx
    call mem_move
    pop rax

.LInputDialog_on_key__shift_tail_right_by_ret:
    lea rsp, [rsp + 8]
    ret

# InputDialog_on_key step: Copy encoded bytes into cursor slot (runs on the caller's frame)
InputDialog_on_key__copy_encoded_bytes_into:
    lea rsp, [rsp - 8]
    lea rdi, [rbx + InputDialog.buf]
    mov ecx, [rbx + InputDialog.cursor]
    add rdi, rcx
    lea rsi, [rsp + 16]
    mov edx, eax
    push rax
    call mem_copy
    pop rax
    add [rbx + InputDialog.len], eax
    add [rbx + InputDialog.cursor], eax
.LInputDialog_on_key__copy_encoded_bytes_into_ret:
    lea rsp, [rsp + 8]
    ret

# InputDialog_on_key step: old cursor (runs on the caller's frame)
InputDialog_on_key__old_cursor:
    lea rsp, [rsp - 8]
    mov edx, ecx              # old cursor
.Lidk_bs_step:
    dec ecx
    jz .Lidk_bs_cut
    mov al, byte ptr [rbx + InputDialog.buf + rcx]
    and al, 0xC0
    cmp al, 0x80
    je .Lidk_bs_step
.Lidk_bs_cut:
    mov r8d, edx
    sub r8d, ecx              # bytes removed
    push rcx
    push r8
    lea rdi, [rbx + InputDialog.buf + rcx]
    lea rsi, [rbx + InputDialog.buf + rdx]
    mov eax, [rbx + InputDialog.len]
    sub eax, edx
    inc eax
    mov edx, eax
    call mem_move
    pop r8
    pop rcx
    sub [rbx + InputDialog.len], r8d
    mov [rbx + InputDialog.cursor], ecx
.LInputDialog_on_key__old_cursor_ret:
    lea rsp, [rsp + 8]
    ret

# InputDialog_on_key step: mem_move (runs on the caller's frame)
InputDialog_on_key__mem_move:
    lea rsp, [rsp - 8]
    mov edx, ecx
.Lidk_del_step:
    inc edx
    cmp edx, [rbx + InputDialog.len]
    jae .Lidk_del_cut
    mov al, byte ptr [rbx + InputDialog.buf + rdx]
    and al, 0xC0
    cmp al, 0x80
    je .Lidk_del_step
.Lidk_del_cut:
    mov r8d, edx
    sub r8d, ecx
    push r8
    lea rdi, [rbx + InputDialog.buf + rcx]
    lea rsi, [rbx + InputDialog.buf + rdx]
    mov eax, [rbx + InputDialog.len]
    sub eax, edx
    inc eax
    mov edx, eax
    call mem_move
    pop r8
    sub [rbx + InputDialog.len], r8d
.LInputDialog_on_key__mem_move_ret:
    lea rsp, [rsp + 8]
    ret
