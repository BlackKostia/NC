# Async Preview Reader: a tiny helper process reads file heads for the live preview
#
# The UI never touches the disk for previews: it writes {seq, path} requests into a
# non-blocking pipe and receives {seq, err, len, data[len]} replies on another pipe that the
# event loop polls. Files are opened O_NONBLOCK (a FIFO under the cursor cannot hang), and a
# helper stuck on a dead filesystem is killed and respawned after PV_STUCK_MS, so the UI stays
# responsive no matter what the storage does. Stale replies are filtered by sequence number.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.equ PV_STUCK_MS, 1000
.equ PV_HDR,      12          # u32 seq, i32 err, u32 len

.section .bss
.align 8
g_pv_sent_ms: .space 8
g_pv_pipes:   .space 16       # int[2] req, int[2] resp scratch
g_pv_pid:     .space 4
g_pv_req1:    .space 4        # request write end + 1 (UI)
g_pv_resp1:   .space 4        # reply read end + 1 (UI, non-blocking)
g_pv_seq:     .space 4        # last issued sequence number
g_pv_busy:    .space 4        # a request for g_pv_seq is outstanding

.section .text
.global fs_preview_request
.global fs_preview_fd
.global fs_preview_receive
.global fs_preview_stop

# ------------------------------------------------------------------------------
# Helper process main loop (never returns). r12d = request fd, r13d = reply fd.
# ------------------------------------------------------------------------------
pv_helper_main:
    and rsp, -16
    sub rsp, PATH_MAX + PREVIEW_BUF_SIZE + 64
    # [0..15] = request header / reply header, [64..] = path, [64+PATH_MAX..] = data
    call os_signals_worker_mode
.Lph_loop:
    mov edi, r12d
    mov rsi, rsp
    mov edx, 8
    call pv_read_exact
    test rax, rax
    jle .Lph_exit
    mov ecx, [rsp + 4]                # path length
    cmp ecx, PATH_MAX - 1
    ja .Lph_exit
    mov edi, r12d
    lea rsi, [rsp + 64]
    mov edx, ecx
    call pv_read_exact
    test rax, rax
    js .Lph_exit
    mov ecx, [rsp + 4]
    mov byte ptr [rsp + 64 + rcx], 0
    mov dword ptr [rsp + 8], 0        # len
    mov edi, AT_FDCWD
    lea rsi, [rsp + 64]
    mov edx, O_RDONLY | O_NONBLOCK | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    mov [rsp + 4], eax                # err (fd if >= 0)
    test rax, rax
    js .Lph_reply
    mov r14d, eax
    xor r15d, r15d                    # bytes read
.Lph_read:
    cmp r15d, PREVIEW_BUF_SIZE
    jae .Lph_close
    mov edi, r14d
    lea rsi, [rsp + 64 + PATH_MAX]
    add rsi, r15
    mov edx, PREVIEW_BUF_SIZE
    sub edx, r15d
    OS_READ
    cmp rax, -EINTR
    je .Lph_read
    test rax, rax
    jle .Lph_close                    # EOF, error or EAGAIN (empty FIFO)
    add r15d, eax
    jmp .Lph_read
.Lph_close:
    mov edi, r14d
    OS_CLOSE
    mov dword ptr [rsp + 4], 0
    mov [rsp + 8], r15d
.Lph_reply:
    # reply header at [64+PATH_MAX-12] so header + data are one contiguous write
    lea rsi, [rsp + 64 + PATH_MAX - PV_HDR]
    mov eax, [rsp]
    mov [rsi], eax
    mov eax, [rsp + 4]
    mov [rsi + 4], eax
    mov eax, [rsp + 8]
    mov [rsi + 8], eax
    mov edx, eax
    add edx, PV_HDR
    mov edi, r13d
    call sys_write_all
    test rax, rax
    js .Lph_exit
    jmp .Lph_loop
.Lph_exit:
    xor edi, edi
    OS_EXIT

# Internal: ssize_t pv_read_exact(int fd, void *buf, size_t n) -- blocking; 0 on EOF
pv_read_exact:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    mov ebx, edi
    mov r12, rsi
    mov r13, rdx
    xor r14d, r14d
.Lpre_loop:
    cmp r14, r13
    jae .Lpre_ok
    mov edi, ebx
    lea rsi, [r12 + r14]
    mov rdx, r13
    sub rdx, r14
    OS_READ
    cmp rax, -EINTR
    je .Lpre_loop
    cmp rax, -EAGAIN
    je .Lpre_wait
    test rax, rax
    jle .Lpre_ret
    add r14, rax
    jmp .Lpre_loop
.Lpre_wait:
    mov edi, ebx
    mov esi, 200
    call os_poll_in
    test rax, rax
    jg .Lpre_loop
    mov rax, -EIO                     # writer stalled mid-message
    jmp .Lpre_ret
.Lpre_ok:
    mov rax, r14
.Lpre_ret:
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: int pv_start(void) -> 0 or -errno
pv_start:
    push rbx
    push r12
    push r13
    lea rdi, [rip + g_pv_pipes]
    call os_pipe_cloexec
    test rax, rax
    js .Lps_ret
    lea rdi, [rip + g_pv_pipes + 8]
    call os_pipe_cloexec
    test rax, rax
    js .Lps_close_req
    OS_FORK
    test rax, rax
    js .Lps_close_all
    jz .Lps_child
    mov [rip + g_pv_pid], eax
    mov edi, [rip + g_pv_pipes]       # helper's request read end
    OS_CLOSE
    mov edi, [rip + g_pv_pipes + 12]  # helper's reply write end
    OS_CLOSE
    mov edi, [rip + g_pv_pipes + 4]
    call os_set_nonblock              # UI never blocks on a stuck helper
    mov edi, [rip + g_pv_pipes + 8]
    call os_set_nonblock
    mov eax, [rip + g_pv_pipes + 4]
    inc eax
    mov [rip + g_pv_req1], eax
    mov eax, [rip + g_pv_pipes + 8]
    inc eax
    mov [rip + g_pv_resp1], eax
    mov dword ptr [rip + g_pv_busy], 0
    xor eax, eax
    jmp .Lps_ret
.Lps_child:
    mov edi, [rip + g_pv_pipes + 4]
    OS_CLOSE
    mov edi, [rip + g_pv_pipes + 8]
    OS_CLOSE
    mov r12d, [rip + g_pv_pipes]
    mov r13d, [rip + g_pv_pipes + 12]
    jmp pv_helper_main
.Lps_close_all:
    mov rbx, rax
    mov edi, [rip + g_pv_pipes + 8]
    OS_CLOSE
    mov edi, [rip + g_pv_pipes + 12]
    OS_CLOSE
    mov rax, rbx
.Lps_close_req:
    mov rbx, rax
    mov edi, [rip + g_pv_pipes]
    OS_CLOSE
    mov edi, [rip + g_pv_pipes + 4]
    OS_CLOSE
    mov rax, rbx
.Lps_ret:
    pop r13
    pop r12
    pop rbx
    ret

# void fs_preview_stop(void) -- close the request pipe (helper exits) and reap it
fs_preview_stop:
    push rbx
    sub rsp, 16
    cmp dword ptr [rip + g_pv_pid], 0
    je .Lpst_ret
    mov edi, [rip + g_pv_req1]
    dec edi
    OS_CLOSE
    mov edi, [rip + g_pv_resp1]
    dec edi
    OS_CLOSE
    movsxd rdi, dword ptr [rip + g_pv_pid]
    mov esi, SIGKILL
    OS_KILL
.Lpst_wait:
    movsxd rdi, dword ptr [rip + g_pv_pid]
    mov rsi, rsp
    xor edx, edx
    xor r10d, r10d
    OS_WAIT4
    cmp rax, -EINTR
    je .Lpst_wait
    xor eax, eax
    mov [rip + g_pv_pid], eax
    mov [rip + g_pv_req1], eax
    mov [rip + g_pv_resp1], eax
    mov [rip + g_pv_busy], eax
.Lpst_ret:
    add rsp, 16
    pop rbx
    ret

# int fs_preview_fd(void) -> reply fd to poll, or -1
fs_preview_fd:
    mov eax, [rip + g_pv_resp1]
    dec eax
    ret

# int fs_preview_request(const char *path) -> sequence number (> 0), or -1 (caller reads sync)
fs_preview_request:
    push rbx
    push r12
    push r13
    sub rsp, PATH_MAX + 16
    mov r12, rdi
    call os_clock_ms
    mov r13, rax
    cmp dword ptr [rip + g_pv_pid], 0
    je .Lpr_start
    cmp dword ptr [rip + g_pv_busy], 0
    je .Lpr_send
    mov rax, r13
    sub rax, [rip + g_pv_sent_ms]
    cmp rax, PV_STUCK_MS
    jb .Lpr_send
    call fs_preview_stop              # helper hung on dead storage: replace it
.Lpr_start:
    call pv_start
    test rax, rax
    js .Lpr_fail
.Lpr_send:
    mov rdi, r12
    call str_len
    cmp rax, PATH_MAX - 1
    ja .Lpr_fail
    mov rbx, rax
    inc dword ptr [rip + g_pv_seq]
    mov eax, [rip + g_pv_seq]
    mov [rsp], eax
    mov [rsp + 4], ebx
    lea rdi, [rsp + 8]
    mov rsi, r12
    mov rdx, rbx
    call mem_copy
    mov edi, [rip + g_pv_req1]
    dec edi
    mov rsi, rsp
    lea rdx, [rbx + 8]
    OS_WRITE
    lea rcx, [rbx + 8]
    cmp rax, rcx
    jne .Lpr_restart                  # pipe full / broken: helper is not keeping up
    mov dword ptr [rip + g_pv_busy], 1
    mov [rip + g_pv_sent_ms], r13
    mov eax, [rip + g_pv_seq]
    jmp .Lpr_ret
.Lpr_restart:
    call fs_preview_stop
.Lpr_fail:
    mov eax, -1
.Lpr_ret:
    add rsp, PATH_MAX + 16
    pop r13
    pop r12
    pop rbx
    ret

# int fs_preview_receive(void *buf, size_t cap, uint32_t *out_seq, size_t *out_len)
# Non-blocking: returns 1 with one complete reply copied into buf, or 0 when none is ready.
# Replies to older requests are consumed too (caller compares seq).
fs_preview_receive:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    mov ebx, [rip + g_pv_resp1]
    dec ebx
    js .Lprv_none
    mov edi, ebx
    mov rsi, rsp
    mov edx, PV_HDR
    OS_READ
    cmp rax, 0
    jle .Lprv_none                    # -EAGAIN: nothing yet (or helper gone)
    cmp rax, PV_HDR
    je .Lprv_hdr
    mov rdx, PV_HDR
    sub rdx, rax
    lea rsi, [rsp + rax]
    mov edi, ebx
    call pv_read_exact
    test rax, rax
    jle .Lprv_broken
.Lprv_hdr:
    mov edx, [rsp + 8]                # len
    cmp rdx, r13
    ja .Lprv_broken
    mov [r15], rdx
    test edx, edx
    jz .Lprv_done
    mov edi, ebx
    mov rsi, r12
    call pv_read_exact
    test rax, rax
    jle .Lprv_broken
.Lprv_done:
    mov eax, [rsp]
    mov [r14], eax
    cmp eax, [rip + g_pv_seq]
    jne .Lprv_one
    mov dword ptr [rip + g_pv_busy], 0
.Lprv_one:
    mov eax, 1
    jmp .Lprv_ret
.Lprv_broken:
    call fs_preview_stop              # desynchronized stream: restart on next request
.Lprv_none:
    xor eax, eax
.Lprv_ret:
    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
