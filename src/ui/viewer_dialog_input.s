# ViewerDialog (Inherits from Dialog): built-in Text / Hex file viewer for files of ANY size — viewer dialog input (split from viewer_dialog.s)

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"
.equ VW_LINE_MAX, 248

.section .text
.global ViewerDialog_on_key
.global ViewerDialog_on_mouse

# int ViewerDialog_on_key(ViewerDialog *this, Event *evt)
ViewerDialog_on_key:
    push rbx
    mov rbx, rdi
    push rsi
    call hex_edit_on_key
    pop rsi
    test eax, eax
    jnz .Lvk_ret
    push rsi
    mov rdi, rbx
    call viewer_mode_key              # i / h / t: Image / Hex / Text
    pop rsi
    test eax, eax
    jnz .Lvk_ret
    push rsi
    mov rdi, rbx
    call vim_zoom_key                 # +/-/1/0/arrows in image mode
    pop rsi
    test eax, eax
    jnz .Lvk_ret
    mov eax, [rsi + Event.lat]
    cmp eax, KEY_ESC;   je .Lvk_close
    cmp eax, 'q';       je .Lvk_close; cmp eax, 'Q'; je .Lvk_close
    cmp eax, KEY_F3;    je .Lvk_close; cmp eax, KEY_F10; je .Lvk_close
    cmp eax, 'h';       je .Lvk_hex;   cmp eax, 'H'; je .Lvk_hex
    cmp eax, KEY_UP;    je .Lvk_up;    cmp eax, 'k'; je .Lvk_up
    cmp eax, KEY_DOWN;  je .Lvk_dn;    cmp eax, 'j'; je .Lvk_dn
    cmp eax, KEY_PGUP;  je .Lvk_pgup
    cmp eax, KEY_PGDN;  je .Lvk_pgdn;  cmp eax, ' '; je .Lvk_pgdn
    cmp eax, KEY_HOME;  je .Lvk_home;  cmp eax, KEY_END; je .Lvk_end
    jmp .Lvk_ret
.Lvk_close:
    mov rdi, rbx
    VCALL DialogVtbl.on_cancel
    jmp .Lvk_ret
.Lvk_hex:
    mov rdi, rbx
    call ViewerDialog_on_btn0
    jmp .Lvk_ret
.Lvk_up:
    mov rsi, -1
    jmp .Lvk_scroll
.Lvk_dn:
    mov esi, 1
    jmp .Lvk_scroll
.Lvk_pgup:
    movsxd rsi, dword ptr [rbx + ViewerDialog.vis_rows]
    dec rsi
    neg rsi
    jmp .Lvk_scroll
.Lvk_pgdn:
    movsxd rsi, dword ptr [rbx + ViewerDialog.vis_rows]
    dec rsi
.Lvk_scroll:
    mov rdi, rbx
    call vw_scroll
    jmp .Lvk_ret
.Lvk_home:
    mov rdi, rbx
    call vw_home
    jmp .Lvk_ret
.Lvk_end:
    mov rdi, rbx
    call vw_end
.Lvk_ret:
    mov eax, 1
    pop rbx
    ret

# int ViewerDialog_on_mouse(ViewerDialog *this, Event *evt)
ViewerDialog_on_mouse:
    push rdi
    push rsi
    call vim_zoom_mouse
    pop rsi
    pop rdi
    test eax, eax
    jz 1f
    mov eax, 1
    ret
1:  cmp dword ptr [rsi + Event.mouse_kind], MACT_WHEEL
    jne Dialog_on_mouse
    push rbx
    mov rbx, rdi
    mov eax, [rsi + Event.mouse_btn]
    mov esi, 3
    cmp eax, MOUSE_WHEEL_UP
    jne .Lvm_go
    mov rsi, -3
.Lvm_go:
    mov rdi, rbx
    call vw_scroll
    mov eax, 1
    pop rbx
    ret
