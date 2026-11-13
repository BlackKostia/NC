# Input Event Decoder: Keyboard (CSI/SS3/UTF-8/Ctrl/Alt) + SGR 1006 & X10 Mouse

.intel_syntax noprefix
.include "linux_sys.inc"
.include "classes.inc"

.section .bss
.align 8
in_buf:
    .space 512
in_pos:
    .space 4
in_len:
    .space 4

.section .text
.global input_poll_event

# Internal: int wait_and_read(int timeout_ms)
# Appends incoming bytes to in_buf (compacting if needed). Returns bytes read, 0 on timeout, -1 on EINTR.
wait_and_read:
    push rbx
    sub rsp, 16               # struct pollfd (8 bytes)
    mov ebx, edi              # timeout_ms

    # Compact buffer if needed
    mov eax, [rip + in_pos]
    mov ecx, [rip + in_len]
    cmp eax, ecx
    jb .Lwar_compact
    mov dword ptr [rip + in_pos], 0
    mov dword ptr [rip + in_len], 0
    jmp .Lwar_poll
.Lwar_compact:
    test eax, eax
    jz .Lwar_poll
    sub ecx, eax              # remaining
    push rcx
    lea rdi, [rip + in_buf]
    lea rsi, [rdi + rax]
    mov edx, ecx
    call mem_move
    pop rcx
    mov dword ptr [rip + in_pos], 0
    mov [rip + in_len], ecx

.Lwar_poll:
    mov dword ptr [rsp + POLLFD_FD], STDIN_FD
    mov word ptr [rsp + POLLFD_EVENTS], POLLIN
    mov word ptr [rsp + POLLFD_REVENTS], 0

    mov rdi, rsp
    mov esi, 1
    mov edx, ebx
    mov rax, SYS_poll
    syscall

    cmp rax, -EINTR
    je .Lwar_eintr
    test rax, rax
    jle .Lwar_none

    mov r8d, [rip + in_len]
    mov edx, 512
    sub edx, r8d
    jle .Lwar_none
    mov edi, STDIN_FD
    lea rsi, [rip + in_buf]
    add rsi, r8
    call sys_read_retry
    test rax, rax
    jle .Lwar_none
    add [rip + in_len], eax
    add rsp, 16
    pop rbx
    ret

.Lwar_eintr:
    mov eax, -1
    add rsp, 16
    pop rbx
    ret
.Lwar_none:
    xor eax, eax
    add rsp, 16
    pop rbx
    ret

# Helper: parse unsigned decimal integer starting at rdi, returns value in eax, updated ptr in rdi
parse_uint:
    xor eax, eax
.Lpu_loop:
    movzx ecx, byte ptr [rdi]
    sub ecx, '0'
    cmp ecx, 9
    ja .Lpu_done
    imul eax, eax, 10
    add eax, ecx
    inc rdi
    jmp .Lpu_loop
.Lpu_done:
    ret

# int input_poll_event(Event *evt, int timeout_ms)
# Returns 1 if an event was populated, 0 on timeout/none.
input_poll_event:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi              # evt
    mov r12d, esi             # timeout_ms

    # Zero Event struct
    mov rdi, rbx
    mov esi, Event._size
    call mem_zero

    # Check pending SIGWINCH
    cmp dword ptr [rip + g_sigwinch], 0
    je .Lipe_chk_buf
    mov dword ptr [rip + g_sigwinch], 0
    mov dword ptr [rbx + Event.type], EVT_RESIZE
    mov eax, 1
    jmp .Lipe_ret

.Lipe_chk_buf:
    mov eax, [rip + in_pos]
    cmp eax, [rip + in_len]
    jb .Lipe_have_data

    mov edi, r12d
    call wait_and_read
    cmp eax, -1
    je .Lipe_check_sig_after_poll
    test eax, eax
    jle .Lipe_none
    jmp .Lipe_have_data

.Lipe_check_sig_after_poll:
    cmp dword ptr [rip + g_sigwinch], 0
    je .Lipe_none
    mov dword ptr [rip + g_sigwinch], 0
    mov dword ptr [rbx + Event.type], EVT_RESIZE
    mov eax, 1
    jmp .Lipe_ret

.Lipe_have_data:
    mov eax, [rip + in_pos]
    lea r13, [rip + in_buf]
    movzx ecx, byte ptr [r13 + rax]

    cmp ecx, 0x1B
    je .Lipe_esc

    # --- Non-ESC single byte / UTF-8 ---
    cmp ecx, 0x09
    je .Lipe_tab
    cmp ecx, 0x0D
    je .Lipe_enter
    cmp ecx, 0x0A
    je .Lipe_enter
    cmp ecx, 0x7F
    je .Lipe_bs
    cmp ecx, 0x08
    je .Lipe_bs

    cmp ecx, 0x01
    jb .Lipe_ctrl_zero
    cmp ecx, 0x1A
    jbe .Lipe_ctrl_letter

.Lipe_utf8:
    # Ensure full UTF-8 sequence if multibyte
    mov r8d, [rip + in_len]
    sub r8d, eax              # avail bytes
    cmp ecx, 0xC0
    jb .Lipe_decode_utf8
    cmp r8d, 4
    jae .Lipe_decode_utf8
    mov edi, 10
    call wait_and_read
    mov eax, [rip + in_pos]
.Lipe_decode_utf8:
    # Temporarily NUL-terminate in_buf at in_len (buf is 512, max read keeps slack, or clamp)
    mov r8d, [rip + in_len]
    cmp r8d, 511
    ja .Lipe_utf8_single
    mov byte ptr [r13 + r8], 0
    lea rdi, [r13 + rax]
    call utf8_decode          # eax = cp, edx = bytes
    test edx, edx
    jnz .Lipe_utf8_ok
.Lipe_utf8_single:
    mov eax, [rip + in_pos]
    movzx eax, byte ptr [r13 + rax]
    mov edx, 1
.Lipe_utf8_ok:
    add [rip + in_pos], edx
    mov dword ptr [rbx + Event.type], EVT_KEY
    mov [rbx + Event.key], eax
    mov eax, 1
    jmp .Lipe_ret

.Lipe_ctrl_zero:
    inc dword ptr [rip + in_pos]
    jmp .Lipe_none

.Lipe_tab:
    inc dword ptr [rip + in_pos]
    mov dword ptr [rbx + Event.type], EVT_KEY
    mov dword ptr [rbx + Event.key], KEY_TAB
    mov eax, 1
    jmp .Lipe_ret

.Lipe_enter:
    inc dword ptr [rip + in_pos]
    mov dword ptr [rbx + Event.type], EVT_KEY
    mov dword ptr [rbx + Event.key], KEY_ENTER
    mov eax, 1
    jmp .Lipe_ret

.Lipe_bs:
    inc dword ptr [rip + in_pos]
    mov dword ptr [rbx + Event.type], EVT_KEY
    mov dword ptr [rbx + Event.key], KEY_BACKSPACE
    mov eax, 1
    jmp .Lipe_ret

.Lipe_ctrl_letter:
    inc dword ptr [rip + in_pos]
    add ecx, ('a' - 1)
    mov dword ptr [rbx + Event.type], EVT_KEY
    mov [rbx + Event.key], ecx
    mov dword ptr [rbx + Event.mods], MOD_CTRL
    mov eax, 1
    jmp .Lipe_ret

    # --- ESC Sequence Parsing ---
.Lipe_esc:
    mov r8d, [rip + in_len]
    sub r8d, eax              # bytes available starting at ESC
    cmp r8d, 1
    ja .Lipe_esc_has_more
    mov edi, 25               # 25ms wait to disambiguate bare ESC
    call wait_and_read
    mov eax, [rip + in_pos]
    mov r8d, [rip + in_len]
    sub r8d, eax
    cmp r8d, 1
    ja .Lipe_esc_has_more

    # Bare ESC
    inc dword ptr [rip + in_pos]
    mov dword ptr [rbx + Event.type], EVT_KEY
    mov dword ptr [rbx + Event.key], KEY_ESC
    mov eax, 1
    jmp .Lipe_ret

.Lipe_esc_has_more:
    movzx ecx, byte ptr [r13 + rax + 1]
    cmp ecx, '['
    je .Lipe_csi
    cmp ecx, 'O'
    je .Lipe_ss3
    cmp ecx, 0x1B
    je .Lipe_bare_esc_consume1

    # Alt + character (single ASCII byte or multibyte UTF-8 letter)
    cmp ecx, 0xC0
    jb .Lipe_alt_ascii
    mov r8d, [rip + in_len]
    sub r8d, eax
    cmp r8d, 4
    jae .Lipe_alt_u8_ready
    mov edi, 10
    call wait_and_read
    mov eax, [rip + in_pos]
.Lipe_alt_u8_ready:
    mov r8d, [rip + in_len]
    cmp r8d, 511
    ja .Lipe_alt_ascii
    mov byte ptr [r13 + r8], 0
    lea rdi, [r13 + rax + 1]
    call utf8_decode          # eax = cp, edx = bytes
    test edx, edx
    jz .Lipe_alt_ascii
    inc edx                   # include leading ESC
    add [rip + in_pos], edx
    mov dword ptr [rbx + Event.type], EVT_KEY
    mov dword ptr [rbx + Event.mods], MOD_ALT
    mov [rbx + Event.key], eax
    mov eax, 1
    jmp .Lipe_ret

.Lipe_alt_ascii:
    mov eax, [rip + in_pos]
    movzx ecx, byte ptr [r13 + rax + 1]
    add dword ptr [rip + in_pos], 2
    mov dword ptr [rbx + Event.type], EVT_KEY
    mov dword ptr [rbx + Event.mods], MOD_ALT
    mov [rbx + Event.key], ecx
    mov eax, 1
    jmp .Lipe_ret

.Lipe_bare_esc_consume1:
    inc dword ptr [rip + in_pos]
    mov dword ptr [rbx + Event.type], EVT_KEY
    mov dword ptr [rbx + Event.key], KEY_ESC
    mov eax, 1
    jmp .Lipe_ret

    # --- SS3: ESC O <ch> ---
.Lipe_ss3:
    cmp r8d, 3
    jae .Lipe_ss3_ready
    mov edi, 15
    call wait_and_read
    mov eax, [rip + in_pos]
    mov r8d, [rip + in_len]
    sub r8d, eax
    cmp r8d, 3
    jb .Lipe_bare_esc_consume1
.Lipe_ss3_ready:
    movzx ecx, byte ptr [r13 + rax + 2]
    add dword ptr [rip + in_pos], 3
    mov dword ptr [rbx + Event.type], EVT_KEY
    cmp ecx, 'P'
    je .Lipe_k_f1
    cmp ecx, 'Q'
    je .Lipe_k_f2
    cmp ecx, 'R'
    je .Lipe_k_f3
    cmp ecx, 'S'
    je .Lipe_k_f4
    cmp ecx, 'H'
    je .Lipe_k_home
    cmp ecx, 'F'
    je .Lipe_k_end
    cmp ecx, 'A'
    je .Lipe_k_up
    cmp ecx, 'B'
    je .Lipe_k_down
    cmp ecx, 'C'
    je .Lipe_k_right
    cmp ecx, 'D'
    je .Lipe_k_left
    jmp .Lipe_none

    # --- CSI: ESC [ ... ---
.Lipe_csi:
    cmp r8d, 3
    jae .Lipe_csi_check_type
    mov edi, 15
    call wait_and_read
    mov eax, [rip + in_pos]
    mov r8d, [rip + in_len]
    sub r8d, eax
    cmp r8d, 3
    jb .Lipe_bare_esc_consume1

.Lipe_csi_check_type:
    movzx ecx, byte ptr [r13 + rax + 2]
    cmp ecx, '<'
    je .Lipe_sgr_mouse
    cmp ecx, 'M'
    je .Lipe_x10_mouse

    # Generic CSI sequence: scan up to final byte 0x40..0x7E
    lea r14, [r13 + rax + 2]  # scan start
    lea r15, [r13 + rax]
    add r15, r8               # buffer end
.Lipe_csi_find_fin:
    cmp r14, r15
    jb .Lipe_csi_chk_byte
    # Try waiting once for rest of CSI
    mov edi, 15
    call wait_and_read
    test eax, eax
    jle .Lipe_bare_esc_consume1
    mov eax, [rip + in_pos]
    mov r8d, [rip + in_len]
    lea r15, [r13 + r8]
.Lipe_csi_chk_byte:
    movzx ecx, byte ptr [r14]
    cmp ecx, 0x40
    jb .Lipe_csi_adv
    cmp ecx, 0x7E
    jbe .Lipe_csi_got_fin
.Lipe_csi_adv:
    inc r14
    jmp .Lipe_csi_find_fin

.Lipe_csi_got_fin:
    # r14 points to final byte (cl); parse params from [r13 + in_pos + 2 .. r14)
    mov eax, [rip + in_pos]
    lea rdi, [r13 + rax + 2]
    # Advance in_pos past r14
    mov rdx, r14
    sub rdx, r13
    inc rdx
    mov [rip + in_pos], edx

    mov r15d, ecx             # final byte
    xor r12d, r12d            # p1 = 0
    xor r8d, r8d              # p2 = 0

    cmp rdi, r14
    jae .Lipe_csi_dispatch
    call parse_uint
    mov r12d, eax             # p1
    cmp rdi, r14
    jae .Lipe_csi_dispatch
    cmp byte ptr [rdi], ';'
    jne .Lipe_csi_dispatch
    inc rdi
    call parse_uint
    mov r8d, eax              # p2

.Lipe_csi_dispatch:
    # Apply xterm modifiers if p2 > 1
    xor edx, edx
    cmp r8d, 1
    jle .Lipe_csi_mods_ok
    mov eax, r8d
    dec eax
    test eax, 1
    jz .Lipe_cm_alt
    or edx, MOD_SHIFT
.Lipe_cm_alt:
    test eax, 2
    jz .Lipe_cm_ctrl
    or edx, MOD_ALT
.Lipe_cm_ctrl:
    test eax, 4
    jz .Lipe_csi_mods_ok
    or edx, MOD_CTRL
.Lipe_csi_mods_ok:
    mov [rbx + Event.mods], edx
    mov dword ptr [rbx + Event.type], EVT_KEY

    cmp r15d, 'A'
    je .Lipe_k_up
    cmp r15d, 'B'
    je .Lipe_k_down
    cmp r15d, 'C'
    je .Lipe_k_right
    cmp r15d, 'D'
    je .Lipe_k_left
    cmp r15d, 'H'
    je .Lipe_k_home
    cmp r15d, 'F'
    je .Lipe_k_end
    cmp r15d, 'Z'
    je .Lipe_k_btab
    cmp r15d, 'P'
    je .Lipe_k_f1
    cmp r15d, 'Q'
    je .Lipe_k_f2
    cmp r15d, 'R'
    je .Lipe_k_f3
    cmp r15d, 'S'
    je .Lipe_k_f4
    cmp r15d, '~'
    je .Lipe_csi_tilde
    jmp .Lipe_none

.Lipe_csi_tilde:
    cmp r12d, 1
    je .Lipe_k_home
    cmp r12d, 7
    je .Lipe_k_home
    cmp r12d, 2
    je .Lipe_k_ins
    cmp r12d, 3
    je .Lipe_k_del
    cmp r12d, 4
    je .Lipe_k_end
    cmp r12d, 8
    je .Lipe_k_end
    cmp r12d, 5
    je .Lipe_k_pgup
    cmp r12d, 6
    je .Lipe_k_pgdn
    cmp r12d, 11
    je .Lipe_k_f1
    cmp r12d, 12
    je .Lipe_k_f2
    cmp r12d, 13
    je .Lipe_k_f3
    cmp r12d, 14
    je .Lipe_k_f4
    cmp r12d, 15
    je .Lipe_k_f5
    cmp r12d, 17
    je .Lipe_k_f6
    cmp r12d, 18
    je .Lipe_k_f7
    cmp r12d, 19
    je .Lipe_k_f8
    cmp r12d, 20
    je .Lipe_k_f9
    cmp r12d, 21
    je .Lipe_k_f10
    cmp r12d, 23
    je .Lipe_k_f11
    cmp r12d, 24
    je .Lipe_k_f12
    jmp .Lipe_none

.Lipe_k_up:    mov dword ptr [rbx + Event.key], KEY_UP;    mov eax, 1; jmp .Lipe_ret
.Lipe_k_down:  mov dword ptr [rbx + Event.key], KEY_DOWN;  mov eax, 1; jmp .Lipe_ret
.Lipe_k_left:  mov dword ptr [rbx + Event.key], KEY_LEFT;  mov eax, 1; jmp .Lipe_ret
.Lipe_k_right: mov dword ptr [rbx + Event.key], KEY_RIGHT; mov eax, 1; jmp .Lipe_ret
.Lipe_k_home:  mov dword ptr [rbx + Event.key], KEY_HOME;  mov eax, 1; jmp .Lipe_ret
.Lipe_k_end:   mov dword ptr [rbx + Event.key], KEY_END;   mov eax, 1; jmp .Lipe_ret
.Lipe_k_pgup:  mov dword ptr [rbx + Event.key], KEY_PGUP;  mov eax, 1; jmp .Lipe_ret
.Lipe_k_pgdn:  mov dword ptr [rbx + Event.key], KEY_PGDN;  mov eax, 1; jmp .Lipe_ret
.Lipe_k_ins:   mov dword ptr [rbx + Event.key], KEY_INSERT; mov eax, 1; jmp .Lipe_ret
.Lipe_k_del:   mov dword ptr [rbx + Event.key], KEY_DELETE; mov eax, 1; jmp .Lipe_ret
.Lipe_k_btab:  mov dword ptr [rbx + Event.key], KEY_BTAB;  mov eax, 1; jmp .Lipe_ret
.Lipe_k_f1:    mov dword ptr [rbx + Event.key], KEY_F1;    mov eax, 1; jmp .Lipe_ret
.Lipe_k_f2:    mov dword ptr [rbx + Event.key], KEY_F2;    mov eax, 1; jmp .Lipe_ret
.Lipe_k_f3:    mov dword ptr [rbx + Event.key], KEY_F3;    mov eax, 1; jmp .Lipe_ret
.Lipe_k_f4:    mov dword ptr [rbx + Event.key], KEY_F4;    mov eax, 1; jmp .Lipe_ret
.Lipe_k_f5:    mov dword ptr [rbx + Event.key], KEY_F5;    mov eax, 1; jmp .Lipe_ret
.Lipe_k_f6:    mov dword ptr [rbx + Event.key], KEY_F6;    mov eax, 1; jmp .Lipe_ret
.Lipe_k_f7:    mov dword ptr [rbx + Event.key], KEY_F7;    mov eax, 1; jmp .Lipe_ret
.Lipe_k_f8:    mov dword ptr [rbx + Event.key], KEY_F8;    mov eax, 1; jmp .Lipe_ret
.Lipe_k_f9:    mov dword ptr [rbx + Event.key], KEY_F9;    mov eax, 1; jmp .Lipe_ret
.Lipe_k_f10:   mov dword ptr [rbx + Event.key], KEY_F10;   mov eax, 1; jmp .Lipe_ret
.Lipe_k_f11:   mov dword ptr [rbx + Event.key], KEY_F11;   mov eax, 1; jmp .Lipe_ret
.Lipe_k_f12:   mov dword ptr [rbx + Event.key], KEY_F12;   mov eax, 1; jmp .Lipe_ret

    # --- SGR 1006 Mouse: ESC [ < btn ; col ; row (M|m) ---
.Lipe_sgr_mouse:
    lea r14, [r13 + rax + 3]
    mov r8d, [rip + in_len]
    lea r15, [r13 + r8]
.Lipe_sgr_find:
    cmp r14, r15
    jb .Lipe_sgr_chk
    mov edi, 15
    call wait_and_read
    test eax, eax
    jle .Lipe_bare_esc_consume1
    mov r8d, [rip + in_len]
    lea r15, [r13 + r8]
.Lipe_sgr_chk:
    movzx ecx, byte ptr [r14]
    cmp ecx, 'M'
    je .Lipe_sgr_parse
    cmp ecx, 'm'
    je .Lipe_sgr_parse
    inc r14
    jmp .Lipe_sgr_find

.Lipe_sgr_parse:
    mov eax, [rip + in_pos]
    lea rdi, [r13 + rax + 3]  # start of btn
    mov rdx, r14
    sub rdx, r13
    inc rdx
    mov [rip + in_pos], edx

    mov r15d, ecx             # 'M' or 'm'
    call parse_uint
    mov r12d, eax             # btn
    cmp byte ptr [rdi], ';'
    jne .Lipe_none
    inc rdi
    call parse_uint
    mov r8d, eax              # col (1-based)
    cmp byte ptr [rdi], ';'
    jne .Lipe_none
    inc rdi
    call parse_uint
    mov r9d, eax              # row (1-based)

    dec r8d
    jns .Lipe_mx_ok
    xor r8d, r8d
.Lipe_mx_ok:
    dec r9d
    jns .Lipe_my_ok
    xor r9d, r9d
.Lipe_my_ok:
    mov dword ptr [rbx + Event.type], EVT_MOUSE
    mov [rbx + Event.mouse_x], r8d
    mov [rbx + Event.mouse_y], r9d

    # Modifiers
    xor edx, edx
    test r12d, 4
    jz .Lipe_mm_alt
    or edx, MOD_SHIFT
.Lipe_mm_alt:
    test r12d, 8
    jz .Lipe_mm_ctrl
    or edx, MOD_ALT
.Lipe_mm_ctrl:
    test r12d, 16
    jz .Lipe_mm_done
    or edx, MOD_CTRL
.Lipe_mm_done:
    mov [rbx + Event.mods], edx

    # Wheel? (bit 6 = 64)
    test r12d, 64
    jz .Lipe_sgr_not_wheel
    mov dword ptr [rbx + Event.mouse_kind], MACT_WHEEL
    mov eax, MOUSE_WHEEL_UP
    test r12d, 1
    jz .Lipe_sgr_wheel_ok
    mov eax, MOUSE_WHEEL_DOWN
.Lipe_sgr_wheel_ok:
    mov [rbx + Event.mouse_btn], eax
    mov eax, 1
    jmp .Lipe_ret

.Lipe_sgr_not_wheel:
    mov eax, r12d
    and eax, 3
    mov [rbx + Event.mouse_btn], eax
    test r12d, 32
    jz .Lipe_sgr_click
    cmp eax, 3
    je .Lipe_sgr_move
    mov dword ptr [rbx + Event.mouse_kind], MACT_DRAG
    mov eax, 1
    jmp .Lipe_ret
.Lipe_sgr_move:
    mov dword ptr [rbx + Event.mouse_kind], MACT_MOVE
    mov eax, 1
    jmp .Lipe_ret
.Lipe_sgr_click:
    mov ecx, MACT_PRESS
    cmp r15d, 'm'
    jne .Lipe_sgr_click_ok
    mov ecx, MACT_RELEASE
.Lipe_sgr_click_ok:
    mov [rbx + Event.mouse_kind], ecx
    mov eax, 1
    jmp .Lipe_ret

    # --- X10 Mouse Fallback: ESC [ M cb cx cy ---
.Lipe_x10_mouse:
    cmp r8d, 6
    jae .Lipe_x10_ready
    mov edi, 15
    call wait_and_read
    mov eax, [rip + in_pos]
    mov r8d, [rip + in_len]
    sub r8d, eax
    cmp r8d, 6
    jb .Lipe_bare_esc_consume1
.Lipe_x10_ready:
    movzx r12d, byte ptr [r13 + rax + 3]
    movzx r8d,  byte ptr [r13 + rax + 4]
    movzx r9d,  byte ptr [r13 + rax + 5]
    add dword ptr [rip + in_pos], 6
    sub r12d, 32
    sub r8d, 33
    jns .Lipe_x10_xok
    xor r8d, r8d
.Lipe_x10_xok:
    sub r9d, 33
    jns .Lipe_x10_yok
    xor r9d, r9d
.Lipe_x10_yok:
    mov dword ptr [rbx + Event.type], EVT_MOUSE
    mov [rbx + Event.mouse_x], r8d
    mov [rbx + Event.mouse_y], r9d
    test r12d, 64
    jz .Lipe_x10_btn
    mov dword ptr [rbx + Event.mouse_kind], MACT_WHEEL
    mov eax, MOUSE_WHEEL_UP
    test r12d, 1
    jz .Lipe_x10_wh
    mov eax, MOUSE_WHEEL_DOWN
.Lipe_x10_wh:
    mov [rbx + Event.mouse_btn], eax
    mov eax, 1
    jmp .Lipe_ret
.Lipe_x10_btn:
    mov eax, r12d
    and eax, 3
    mov [rbx + Event.mouse_btn], eax
    mov ecx, MACT_PRESS
    cmp eax, 3
    jne .Lipe_x10_kind
    mov ecx, MACT_RELEASE
.Lipe_x10_kind:
    mov [rbx + Event.mouse_kind], ecx
    mov eax, 1
    jmp .Lipe_ret

.Lipe_none:
    xor eax, eax
.Lipe_ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
