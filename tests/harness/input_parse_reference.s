# Frozen reference oracle: the hand-written asm that src/tui/input_parse.c replaced (tests/test_c_input.py diffs against it)
# Input Event Decoder: Keyboard (CSI/SS3/UTF-8/Ctrl/Alt) + SGR 1006 & X10 Mouse — input parse (split from input.s)

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .text
.global input_poll_event

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
    mov esi, 1
    call wait_and_read_fd
    cmp eax, -1; je .Lipe_check_sig_after_poll
    cmp eax, -2; je .Lipe_ret
    test eax, eax; jle .Lipe_none
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
    mov rdi, rbx
    call input_parse_ss3
    jmp .Lipe_ret

    # --- CSI: ESC [ ... ---
.Lipe_csi:
    mov rdi, rbx
    call input_parse_csi
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
