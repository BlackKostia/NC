# Input Event Decoder: Keyboard (CSI/SS3/UTF-8/Ctrl/Alt) + SGR 1006 & X10 Mouse

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .bss
.align 8
in_buf:
    .space 512
in_pos:
    .space 4
in_len:
    .space 4
in_aux1:
    .space 4 * 4              # auxiliary wake fds + 1 (0 = none): task pipe, dir watch, preview

.section .text
.global input_next_event
.global input_set_wake_fd
.global input_set_aux_fd
.global wait_and_read
.global wait_and_read_fd
.global parse_uint
.global in_buf
.global in_pos
.global in_len

# int input_next_event(Event *evt, int timeout_ms) -> 1 if an event was populated, 0 on timeout
# Decodes one event (input_poll_event) and sets Event.lat: for keys, the Latin key under the
# pressed one according to the *.layout files (kbd_layout.s), so hotkeys work in any layout.
input_next_event:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    call input_poll_event
    mov r12d, eax
    mov edi, [rbx + Event.key]
    mov [rbx + Event.lat], edi
    cmp dword ptr [rbx + Event.type], EVT_KEY
    jne .Lipv_ret
    call kbd_latin
    mov [rbx + Event.lat], eax
.Lipv_ret:
    mov eax, r12d
    add rsp, 8
    pop r12
    pop rbx
    ret

# void input_set_wake_fd(int fd) -- aux slot 0 (background task pipe)
input_set_wake_fd:
    mov esi, edi
    xor edi, edi
# void input_set_aux_fd(int slot /*0..3*/, int fd /*-1 = none*/)
# Registers descriptors whose readability/hang-up ends the idle wait of input_poll_event
# early (returning "no event"), so the app loop reacts to them instantly.
input_set_aux_fd:
    and edi, 3
    inc esi
    lea rax, [rip + in_aux1]
    mov [rax + rdi * 4], esi
    ret

# Internal: int wait_and_read(int timeout_ms)
# Appends incoming bytes to in_buf (compacting if needed). Returns bytes read, 0 on timeout, -1 on EINTR.
wait_and_read:
    xor esi, esi
# Internal: int wait_and_read_fd(int timeout_ms, int use_aux)
# Same as wait_and_read, but also returns 0 early when an aux fd becomes ready.
wait_and_read_fd:
    push rbx
    push r12
    sub rsp, 40               # [0..19] = fds[5]
    call wait_and_read_fd__compact_buffer_needed
    cmp rax, -EINTR
    je .Lwar_eintr
    test rax, rax
    js .Lwar_fatal
    jz .Lwar_none
    test eax, 1               # only the wake fd fired -> let the app loop run its tick
    jz .Lwar_none

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
    mov [rsp + 24], eax
    lea rdi, [rip + in_buf]           # terminal replies (DA1, cell size) never reach the parser
    mov edx, [rip + in_len]
    mov esi, edx
    sub esi, eax
    call term_caps_filter
    sub [rip + in_len], eax
    neg eax
    add eax, [rsp + 24]               # bytes left for the key parser (0 = only replies)
    add rsp, 40
    pop r12
    pop rbx
    ret

.Lwar_eintr:
    mov eax, -1
    add rsp, 40
    pop r12
    pop rbx
    ret
.Lwar_fatal:
    mov eax, -2
    add rsp, 40
    pop r12
    pop rbx
    ret
.Lwar_none:
    xor eax, eax
    add rsp, 40
    pop r12
    pop rbx
    ret

# wait_and_read_fd step: Compact buffer if needed (runs on the caller's frame)
wait_and_read_fd__compact_buffer_needed:
    lea rsp, [rsp - 8]
    mov ebx, edi              # timeout_ms
    mov r12d, esi             # use aux fds?

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
    mov dword ptr [rsp + 16], STDIN_FD
    lea rax, [rip + in_aux1]
    xor ecx, ecx
.Lwar_fds:
    mov edx, [rax + rcx * 4]
    dec edx                   # stored fd + 1 -> fd / -1
    test r12d, r12d
    jnz .Lwar_fd_put
    mov edx, -1
.Lwar_fd_put:
    mov [rsp + 4 + rcx * 4 + 16], edx
    inc ecx
    cmp ecx, 4
    jb .Lwar_fds
    lea rdi, [rsp + 16]
    mov esi, 5
    mov edx, ebx
    call os_poll_many

.Lwait_and_read_fd__compact_buffer_needed_ret:
    lea rsp, [rsp + 8]
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
