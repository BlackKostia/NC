# HelpDialog input & scrolling (split from dialogs_help.s)

.intel_syntax noprefix
.include "classes.inc"
.equ HELP_LINE_COUNT,  22
.equ HELP_INSTR_COUNT, 36

.section .text
.global help_active_count
.global help_max_scroll
.global HelpDialog_on_key
.global HelpDialog_on_mouse

# int help_active_count(HelpDialog *this)
help_active_count:
    mov eax, HELP_LINE_COUNT
    cmp dword ptr [rdi + HelpDialog.tab], 0
    je .Lhac_ret
    mov eax, HELP_INSTR_COUNT
.Lhac_ret:
    ret

# int help_max_scroll(HelpDialog *this)
help_max_scroll:
    mov eax, [rdi + Widget.h]
    sub eax, 4
    cmp eax, 1
    jge .Lhms_vis_ok
    mov eax, 1
.Lhms_vis_ok:
    mov r8d, eax
    call help_active_count
    sub eax, r8d
    cmp eax, 0
    jge .Lhms_ret
    xor eax, eax
.Lhms_ret:
    ret

HelpDialog_on_key:
    mov eax, [rsi + Event.lat]
    cmp eax, KEY_ESC;   je .Lhdk_close
    cmp eax, KEY_ENTER; je .Lhdk_close
    cmp eax, 'q';       je .Lhdk_close
    cmp eax, KEY_F1;    je .Lhdk_close
    cmp eax, KEY_TAB;   je .Lhdk_toggle_tab
    cmp eax, KEY_BTAB;  je .Lhdk_toggle_tab
    cmp eax, KEY_LEFT;  je .Lhdk_tab0
    cmp eax, '1';       je .Lhdk_tab0
    cmp eax, KEY_RIGHT; je .Lhdk_tab1
    cmp eax, '2';       je .Lhdk_tab1
    cmp eax, KEY_UP;    je .Lhdk_up
    cmp eax, KEY_DOWN;  je .Lhdk_dn
    cmp eax, KEY_PGUP;  je .Lhdk_pgup
    cmp eax, KEY_PGDN;  je .Lhdk_pgdn
    cmp eax, KEY_HOME;  je .Lhdk_home
    cmp eax, KEY_END;   je .Lhdk_end
    mov eax, 1
    ret
.Lhdk_close:
    VCALL DialogVtbl.on_cancel
    mov eax, 1
    ret
.Lhdk_toggle_tab:
    xor dword ptr [rdi + HelpDialog.tab], 1
    mov dword ptr [rdi + HelpDialog.scroll], 0
    jmp .Lhdk_dirty
.Lhdk_tab0:
    xor eax, eax
    jmp .Lhdk_set_tab
.Lhdk_tab1:
    mov eax, 1
.Lhdk_set_tab:
    mov [rdi + HelpDialog.tab], eax
    mov dword ptr [rdi + HelpDialog.scroll], 0
    jmp .Lhdk_dirty
.Lhdk_up:
    dec dword ptr [rdi + HelpDialog.scroll]
    jns .Lhdk_dirty
    mov dword ptr [rdi + HelpDialog.scroll], 0
    jmp .Lhdk_dirty
.Lhdk_dn:
    call help_max_scroll
    cmp [rdi + HelpDialog.scroll], eax
    jge .Lhdk_dirty
    inc dword ptr [rdi + HelpDialog.scroll]
    jmp .Lhdk_dirty
.Lhdk_pgup:
    mov ecx, [rdi + Widget.h]
    sub ecx, 5
    cmp ecx, 1; jge 1f; mov ecx, 1
1:  sub [rdi + HelpDialog.scroll], ecx
    jns .Lhdk_dirty
    mov dword ptr [rdi + HelpDialog.scroll], 0
    jmp .Lhdk_dirty
.Lhdk_pgdn:
    call help_max_scroll
    mov ecx, [rdi + Widget.h]
    sub ecx, 5
    cmp ecx, 1; jge 1f; mov ecx, 1
1:  add [rdi + HelpDialog.scroll], ecx
    cmp [rdi + HelpDialog.scroll], eax
    jle .Lhdk_dirty
    mov [rdi + HelpDialog.scroll], eax
    jmp .Lhdk_dirty
.Lhdk_home:
    mov dword ptr [rdi + HelpDialog.scroll], 0
    jmp .Lhdk_dirty
.Lhdk_end:
    call help_max_scroll
    mov [rdi + HelpDialog.scroll], eax
.Lhdk_dirty:
    mov rax, [rdi + Dialog.app]
    mov dword ptr [rax + App.need_redraw], 1
    mov eax, 1
    ret

HelpDialog_on_mouse:
    cmp dword ptr [rsi + Event.mouse_kind], MACT_PRESS
    jne .Lhdm_not_press
    cmp dword ptr [rsi + Event.mouse_btn], MOUSE_LEFT
    jne .Lhdm_not_press
    push rbx; push r12
    mov rbx, rdi; mov r12, rsi
    lea rdi, [rbx + HelpDialog.tab_zones]
    mov esi, [r12 + Event.mouse_x]
    mov edx, [r12 + Event.mouse_y]
    call help_zone_hit
    test eax, eax
    jnz .Lhdm_hit0
    lea rdi, [rbx + HelpDialog.tab_zones + HitZone._size]
    mov esi, [r12 + Event.mouse_x]
    mov edx, [r12 + Event.mouse_y]
    call help_zone_hit
    test eax, eax
    jnz .Lhdm_hit1
    mov rdi, rbx; mov rsi, r12
    pop r12; pop rbx
    jmp Dialog_on_mouse
.Lhdm_hit0:
    xor eax, eax; jmp .Lhdm_set_tab
.Lhdm_hit1:
    mov eax, 1
.Lhdm_set_tab:
    mov [rbx + HelpDialog.tab], eax
    mov dword ptr [rbx + HelpDialog.scroll], 0
    mov rax, [rbx + Dialog.app]
    mov dword ptr [rax + App.need_redraw], 1
    pop r12; pop rbx
    mov eax, 1
    ret
.Lhdm_not_press:
    cmp dword ptr [rsi + Event.mouse_kind], MACT_WHEEL
    jne Dialog_on_mouse
    cmp dword ptr [rsi + Event.mouse_btn], MOUSE_WHEEL_UP
    jne .Lhdm_dn
    mov eax, [rdi + HelpDialog.scroll]
    dec eax
    jns .Lhdm_apply
    xor eax, eax
    jmp .Lhdm_apply
.Lhdm_dn:
    call help_max_scroll
    mov ecx, [rdi + HelpDialog.scroll]
    cmp ecx, eax
    jge .Lhdm_done
    lea eax, [rcx + 1]
.Lhdm_apply:
    mov [rdi + HelpDialog.scroll], eax
    mov rax, [rdi + Dialog.app]
    mov dword ptr [rax + App.need_redraw], 1
.Lhdm_done:
    mov eax, 1
    ret

# int help_zone_hit(HitZone *z, int mx, int my) -> 1 if inside, else 0
help_zone_hit:
    xor eax, eax
    movsx ecx, word ptr [rdi + HitZone.y]
    cmp edx, ecx
    jne .Lhzh_ret
    movsx ecx, word ptr [rdi + HitZone.x1]
    cmp esi, ecx
    jl .Lhzh_ret
    movsx ecx, word ptr [rdi + HitZone.x2]
    cmp esi, ecx
    jge .Lhzh_ret
    mov eax, 1
.Lhzh_ret:
    ret
