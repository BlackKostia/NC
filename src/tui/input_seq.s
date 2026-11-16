# Input CSI/SS3 & Mouse Sequence Parser (split from input_parse.s)

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .rodata
.align 4
ss3_key_tbl:
    .byte 'P', 0, 0, 0; .long KEY_F1
    .byte 'Q', 0, 0, 0; .long KEY_F2
    .byte 'R', 0, 0, 0; .long KEY_F3
    .byte 'S', 0, 0, 0; .long KEY_F4
    .byte 'H', 0, 0, 0; .long KEY_HOME
    .byte 'F', 0, 0, 0; .long KEY_END
    .byte 'A', 0, 0, 0; .long KEY_UP
    .byte 'B', 0, 0, 0; .long KEY_DOWN
    .byte 'C', 0, 0, 0; .long KEY_RIGHT
    .byte 'D', 0, 0, 0; .long KEY_LEFT
    .byte 0,   0, 0, 0; .long 0

csi_key_tbl:
    .byte 'A', 0, 0, 0; .long KEY_UP
    .byte 'B', 0, 0, 0; .long KEY_DOWN
    .byte 'C', 0, 0, 0; .long KEY_RIGHT
    .byte 'D', 0, 0, 0; .long KEY_LEFT
    .byte 'H', 0, 0, 0; .long KEY_HOME
    .byte 'F', 0, 0, 0; .long KEY_END
    .byte 'Z', 0, 0, 0; .long KEY_BTAB
    .byte 'P', 0, 0, 0; .long KEY_F1
    .byte 'Q', 0, 0, 0; .long KEY_F2
    .byte 'R', 0, 0, 0; .long KEY_F3
    .byte 'S', 0, 0, 0; .long KEY_F4
    .byte 0,   0, 0, 0; .long 0

csi_tilde_tbl:
    .long 1, KEY_HOME, 7, KEY_HOME, 2, KEY_INSERT, 3, KEY_DELETE
    .long 4, KEY_END,  8, KEY_END,  5, KEY_PGUP,   6, KEY_PGDN
    .long 11, KEY_F1, 12, KEY_F2, 13, KEY_F3, 14, KEY_F4
    .long 15, KEY_F5, 17, KEY_F6, 18, KEY_F7, 19, KEY_F8
    .long 20, KEY_F9, 21, KEY_F10, 23, KEY_F11, 24, KEY_F12
    .long 0, 0

.section .text
.global input_parse_csi
.global input_parse_ss3

input_bare_esc:
    inc dword ptr [rip + in_pos]
    mov dword ptr [rdi + Event.type], EVT_KEY
    mov dword ptr [rdi + Event.key], KEY_ESC
    mov eax, 1
    ret

# int input_parse_ss3(Event *evt)
input_parse_ss3:
    push rbx; mov rbx, rdi
    mov eax, [rip + in_pos]
    mov r8d, [rip + in_len]; sub r8d, eax
    cmp r8d, 3; jae .Lpss3_ready
    mov edi, 15; call wait_and_read
    mov eax, [rip + in_pos]
    mov r8d, [rip + in_len]; sub r8d, eax
    cmp r8d, 3; jb .Lpss3_bare
.Lpss3_ready:
    lea rcx, [rip + in_buf]
    movzx eax, byte ptr [rcx + rax + 2]
    add dword ptr [rip + in_pos], 3
    mov dword ptr [rbx + Event.type], EVT_KEY
    lea rdx, [rip + ss3_key_tbl]
.Lpss3_scan:
    movzx ecx, byte ptr [rdx]
    test ecx, ecx; jz .Lpss3_none
    cmp ecx, eax; je .Lpss3_hit
    add rdx, 8; jmp .Lpss3_scan
.Lpss3_hit:
    mov eax, [rdx + 4]; mov [rbx + Event.key], eax
    mov eax, 1; pop rbx; ret
.Lpss3_none:
    xor eax, eax; pop rbx; ret
.Lpss3_bare:
    mov rdi, rbx; call input_bare_esc; pop rbx; ret

# int input_csi_dispatch(Event *evt, const char *params, const char *fin, uint32_t final_ch)
input_csi_dispatch:
    push rbx; push r12; push r14; push r15; sub rsp, 8
    mov rbx, rdi; mov rdi, rsi; mov r14, rdx; mov r15d, ecx
    xor r12d, r12d; xor r8d, r8d
    cmp rdi, r14; jae .Licd_mods
    call parse_uint; mov r12d, eax
    cmp rdi, r14; jae .Licd_mods
    cmp byte ptr [rdi], ';'; jne .Licd_mods
    inc rdi
    cmp rdi, r14; jae .Licd_mods
    push r12; call parse_uint; pop r12; mov r8d, eax
.Licd_mods:
    xor edx, edx
    cmp r8d, 1; jle .Licd_m_ok
    lea eax, [r8d - 1]
    test eax, 1; jz 1f; or edx, MOD_SHIFT
1:  test eax, 2; jz 2f; or edx, MOD_ALT
2:  test eax, 4; jz .Licd_m_ok; or edx, MOD_CTRL
.Licd_m_ok:
    mov [rbx + Event.mods], edx
    mov dword ptr [rbx + Event.type], EVT_KEY
    cmp r15d, '~'; je .Licd_tilde
    lea rdx, [rip + csi_key_tbl]
.Licd_kt:
    movzx eax, byte ptr [rdx]
    test eax, eax; jz .Licd_none
    cmp eax, r15d; je .Licd_hit
    add rdx, 8; jmp .Licd_kt
.Licd_tilde:
    lea rdx, [rip + csi_tilde_tbl]
.Licd_tt:
    mov eax, [rdx]
    test eax, eax; jz .Licd_none
    cmp eax, r12d; je .Licd_hit
    add rdx, 8; jmp .Licd_tt
.Licd_hit:
    mov eax, [rdx + 4]; mov [rbx + Event.key], eax
    mov eax, 1; jmp .Licd_ret
.Licd_none:
    xor eax, eax
.Licd_ret:
    add rsp, 8; pop r15; pop r14; pop r12; pop rbx; ret

# int input_sgr_finish(Event *evt, uint32_t btn, int col, int row, uint32_t ch)
input_sgr_finish:
    dec edx; jns 1f; xor edx, edx
1:  dec ecx; jns 2f; xor ecx, ecx
2:  mov dword ptr [rdi + Event.type], EVT_MOUSE
    mov [rdi + Event.mouse_x], edx
    mov [rdi + Event.mouse_y], ecx
    xor r9d, r9d
    test esi, 4;  jz 3f; or r9d, MOD_SHIFT
3:  test esi, 8;  jz 4f; or r9d, MOD_ALT
4:  test esi, 16; jz 5f; or r9d, MOD_CTRL
5:  mov [rdi + Event.mods], r9d
    test esi, 64; jz .Lisf_not_wheel
    mov dword ptr [rdi + Event.mouse_kind], MACT_WHEEL
    mov eax, MOUSE_WHEEL_UP
    test esi, 1; jz 6f; mov eax, MOUSE_WHEEL_DOWN
6:  mov [rdi + Event.mouse_btn], eax
    mov eax, 1; ret
.Lisf_not_wheel:
    mov eax, esi; and eax, 3; mov [rdi + Event.mouse_btn], eax
    test esi, 32; jz .Lisf_click
    cmp eax, 3; je .Lisf_move
    mov dword ptr [rdi + Event.mouse_kind], MACT_DRAG
    mov eax, 1; ret
.Lisf_move:
    mov dword ptr [rdi + Event.mouse_kind], MACT_MOVE
    mov eax, 1; ret
.Lisf_click:
    mov ecx, MACT_PRESS
    cmp r8d, 'm'; jne 7f; mov ecx, MACT_RELEASE
7:  mov [rdi + Event.mouse_kind], ecx
    mov eax, 1; ret

# int input_parse_sgr_mouse(Event *evt)
input_parse_sgr_mouse:
    push rbx; push r12; push r13; push r14; push r15
    mov rbx, rdi; lea r13, [rip + in_buf]; mov r12d, 3
.Lpsg_loop:
    mov eax, [rip + in_pos]; mov edx, [rip + in_len]
    lea ecx, [eax + r12d]
    cmp ecx, edx; jb .Lpsg_chk
    sub edx, eax; cmp edx, 512; jae .Lpsg_bare
    mov edi, 15; call wait_and_read
    test eax, eax; jle .Lpsg_bare
    jmp .Lpsg_loop
.Lpsg_chk:
    movzx r15d, byte ptr [r13 + rcx]
    cmp r15d, 'M'; je .Lpsg_parse
    cmp r15d, 'm'; je .Lpsg_parse
    inc r12d; cmp r12d, 510; jae .Lpsg_bare
    jmp .Lpsg_loop
.Lpsg_parse:
    lea rdi, [r13 + rax + 3]
    lea r14, [r13 + rcx]
    inc ecx; mov [rip + in_pos], ecx
    cmp rdi, r14; jae .Lpsg_none
    call parse_uint; mov r12d, eax
    cmp rdi, r14; jae .Lpsg_none
    cmp byte ptr [rdi], ';'; jne .Lpsg_none
    inc rdi; call parse_uint; mov r8d, eax
    cmp rdi, r14; jae .Lpsg_none
    cmp byte ptr [rdi], ';'; jne .Lpsg_none
    inc rdi
    push r8; call parse_uint; pop rdx   # rdx=col, eax=row
    mov ecx, eax; mov rdi, rbx; mov esi, r12d; mov r8d, r15d
    call input_sgr_finish; jmp .Lpsg_ret
.Lpsg_bare:
    mov rdi, rbx; call input_bare_esc; jmp .Lpsg_ret
.Lpsg_none:
    xor eax, eax
.Lpsg_ret:
    pop r15; pop r14; pop r13; pop r12; pop rbx; ret

# int input_parse_x10_mouse(Event *evt)
input_parse_x10_mouse:
    push rbx; mov rbx, rdi
    mov eax, [rip + in_pos]; mov r8d, [rip + in_len]; sub r8d, eax
    cmp r8d, 6; jae .Lpx_ready
    mov edi, 15; call wait_and_read
    mov eax, [rip + in_pos]; mov r8d, [rip + in_len]; sub r8d, eax
    cmp r8d, 6; jb .Lpx_bare
.Lpx_ready:
    lea r10, [rip + in_buf]
    movzx r9d, byte ptr [r10 + rax + 3]
    movzx edx, byte ptr [r10 + rax + 4]
    movzx ecx, byte ptr [r10 + rax + 5]
    add dword ptr [rip + in_pos], 6
    sub r9d, 32; sub edx, 33; jns 1f; xor edx, edx
1:  sub ecx, 33; jns 2f; xor ecx, ecx
2:  mov dword ptr [rbx + Event.type], EVT_MOUSE
    mov [rbx + Event.mouse_x], edx; mov [rbx + Event.mouse_y], ecx
    test r9d, 64; jz .Lpx_btn
    mov dword ptr [rbx + Event.mouse_kind], MACT_WHEEL
    mov eax, MOUSE_WHEEL_UP; test r9d, 1; jz 3f; mov eax, MOUSE_WHEEL_DOWN
3:  mov [rbx + Event.mouse_btn], eax; mov eax, 1; pop rbx; ret
.Lpx_btn:
    mov eax, r9d; and eax, 3; mov [rbx + Event.mouse_btn], eax
    mov ecx, MACT_PRESS; cmp eax, 3; jne 4f; mov ecx, MACT_RELEASE
4:  mov [rbx + Event.mouse_kind], ecx; mov eax, 1; pop rbx; ret
.Lpx_bare:
    mov rdi, rbx; call input_bare_esc; pop rbx; ret

# int input_parse_csi(Event *evt)
input_parse_csi:
    push rbx; push r12; push r13
    mov rbx, rdi
    mov eax, [rip + in_pos]; mov r8d, [rip + in_len]; sub r8d, eax
    cmp r8d, 3; jae .Lipc_chk
    mov edi, 15; call wait_and_read
    mov eax, [rip + in_pos]; mov r8d, [rip + in_len]; sub r8d, eax
    cmp r8d, 3; jb .Lipc_bare
.Lipc_chk:
    lea r13, [rip + in_buf]
    movzx ecx, byte ptr [r13 + rax + 2]
    cmp ecx, '<'; je .Lipc_sgr
    cmp ecx, 'M'; je .Lipc_x10
    mov r12d, 2
.Lipc_loop:
    mov eax, [rip + in_pos]; mov edx, [rip + in_len]
    lea ecx, [eax + r12d]
    cmp ecx, edx; jb .Lipc_byte
    sub edx, eax; cmp edx, 512; jae .Lipc_bare
    mov edi, 15; call wait_and_read
    test eax, eax; jle .Lipc_bare
    jmp .Lipc_loop
.Lipc_byte:
    movzx edx, byte ptr [r13 + rcx]
    cmp edx, 0x40; jb .Lipc_adv
    cmp edx, 0x7E; jbe .Lipc_fin
.Lipc_adv:
    inc r12d; cmp r12d, 510; jae .Lipc_bare
    jmp .Lipc_loop
.Lipc_fin:
    lea rsi, [r13 + rax + 2]
    lea r8, [r13 + rcx]
    inc ecx; mov [rip + in_pos], ecx
    mov rdi, rbx; mov ecx, edx; mov rdx, r8
    call input_csi_dispatch; jmp .Lipc_ret
.Lipc_sgr:
    mov rdi, rbx; call input_parse_sgr_mouse; jmp .Lipc_ret
.Lipc_x10:
    mov rdi, rbx; call input_parse_x10_mouse; jmp .Lipc_ret
.Lipc_bare:
    mov rdi, rbx; call input_bare_esc
.Lipc_ret:
    pop r13; pop r12; pop rbx; ret
