# Async Preview Reader: a tiny helper process reads file heads for the live preview
#
# The UI never touches the disk for previews: it writes {seq, path} requests into a
# non-blocking pipe and receives {seq, err, len, tlen, data[len], thumb[tlen]} replies (an image
# under the cursor is decoded here, in the helper, and sent as a small RGBA thumbnail) on a pipe the
# event loop polls. Files are opened O_NONBLOCK (a FIFO under the cursor cannot hang), and a
# helper stuck on a dead filesystem is killed and respawned after PV_STUCK_MS, so the UI stays
# responsive no matter what the storage does. Stale replies are filtered by sequence number.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.equ PV_STUCK_MS, 1000
.equ PV_HDR,      16          # u32 seq, i32 err, u32 len, u32 thumb len
.equ PV_REQ,      20          # u32 seq, path len, thumb dims (w | h << 16), proto | cols << 8, bg

.section .bss
.align 8
g_pv_sent_ms: .space 8
g_pv_pipes:   .space 16       # int[2] req, int[2] resp scratch
g_pv_pid:     .space 4
g_pv_req1:    .space 4        # request write end + 1 (UI)
g_pv_resp1:   .space 4        # reply read end + 1 (UI, non-blocking)
g_pv_seq:     .space 4        # last issued sequence number
g_pv_busy:    .space 4        # a request for g_pv_seq is outstanding
.align 8
g_pv_shm:     .space 8        # MAP_SHARED buffer the helper writes image payloads into

.section .text
.global fs_preview_request
.global fs_preview_fd
.global fs_preview_receive
.global fs_preview_stop
.global pv_read_exact
.global fs_preview_shm
.global fs_preview_shm_slot

# ssize_t pv_read_exact(int fd, void *buf, size_t n) -- blocking; 0 on EOF (also used by the helper)
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
    cmp rax, -EINTR
    je .Lpre_wait
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
    cmp qword ptr [rip + g_pv_shm], 0
    jne .Lps_pipes
    xor edi, edi                      # shared with every helper forked from now on
    mov esi, PV_SHM_CAP
    mov edx, PROT_RW
    OS_MMAP_SHARED_ANON
    cmp rax, -4095
    jae .Lps_pipes
    mov [rip + g_pv_shm], rax
.Lps_pipes:
    lea rdi, [rip + g_pv_pipes]
    call os_pipe_cloexec
    test rax, rax
    js .Lps_ret
    lea rdi, [rip + g_pv_pipes + 8]
    call os_pipe_cloexec
    test rax, rax
    js .Lps_close_req
    OS_GETPID                         # fault-checked: getpid always succeeds
    mov ebx, eax
    OS_FORK
    test rax, rax
    js .Lps_close_all
    jz .Lps_child
    mov edi, eax
    call pv_setup_parent_pipes
    jmp .Lps_ret
.Lps_child:
    call os_mark_child_forked
    call os_uring_atfork_reset
    mov edi, ebx
    mov esi, SIGKILL
    call os_set_pdeathsig
    test eax, eax
    jnz 1f
    xor edi, edi
    OS_EXIT                           # fault-checked: exit if UI already died
1:
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
    pop r13; pop r12; pop rbx
    ret

# Internal: int pv_setup_parent_pipes(int child_pid) -> 0 or -errno
pv_setup_parent_pipes:
    sub rsp, 8
    mov [rip + g_pv_pid], edi
    mov edi, [rip + g_pv_pipes]; OS_CLOSE # fault-checked: unused pipe end in parent
    mov edi, [rip + g_pv_pipes + 12]; OS_CLOSE # fault-checked: unused pipe end in parent
    mov edi, [rip + g_pv_pipes + 4]
    call os_set_nonblock
    test rax, rax; js .Lpspp_fail
    mov edi, [rip + g_pv_pipes + 8]
    call os_set_nonblock
    test rax, rax; js .Lpspp_fail
    mov eax, [rip + g_pv_pipes + 4]; inc eax; mov [rip + g_pv_req1], eax
    mov eax, [rip + g_pv_pipes + 8]; inc eax; mov [rip + g_pv_resp1], eax
    mov dword ptr [rip + g_pv_busy], 0
    xor eax, eax
    add rsp, 8; ret
.Lpspp_fail:
    mov rdi, rax
    call pv_cleanup_nonblock
    add rsp, 8; ret

pv_cleanup_nonblock:
    push rbx; mov rbx, rdi
    mov edi, [rip + g_pv_pipes + 4]; OS_CLOSE
    mov edi, [rip + g_pv_pipes + 8]; OS_CLOSE
    mov edi, [rip + g_pv_pid]; test edi, edi; jz 2f
    mov esi, SIGKILL; OS_KILL
1:  mov edi, [rip + g_pv_pid]; xor esi, esi; xor edx, edx; xor r10d, r10d; OS_WAIT4
    cmp rax, -EINTR; je 1b
    mov dword ptr [rip + g_pv_pid], 0
2:  mov rax, rbx; pop rbx; ret

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

# uint8_t *fs_preview_shm(void) -> image payload of the latest reply (valid while the helper idles)
fs_preview_shm:
    mov rax, [rip + g_pv_shm]
    ret

# uint8_t *fs_preview_shm_slot(uint32_t seq) -> ping-pong SHM slot for seq
fs_preview_shm_slot:
    and edi, 1
    imul edi, edi, PV_SHM_SLOT_SZ
    mov rax, [rip + g_pv_shm]
    test rax, rax
    jz 1f
    add rax, rdi
1:  ret

# int fs_preview_fd(void) -> reply fd to poll, or -1
fs_preview_fd:
    mov eax, [rip + g_pv_resp1]
    dec eax
    ret

# int fs_preview_request(const char *path, uint32_t dims /*w | h << 16, 0 = no image*/,
#                        uint32_t mode /*IMG_PROTO_* | cols << 8*/, uint32_t bg /*0xRRGGBB*/)
# -> sequence number (> 0), or -1 (caller reads sync)
fs_preview_request:
    push rbx
    push r12
    push r13
    sub rsp, PATH_MAX + 32
    mov r12, rdi
    mov [rsp + PATH_MAX + 20], esi
    mov [rsp + PATH_MAX + 24], edx
    mov [rsp + PATH_MAX + 28], ecx
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
    mov eax, [rsp + PATH_MAX + 20]
    mov [rsp + 8], eax
    mov eax, [rsp + PATH_MAX + 24]
    mov [rsp + 12], eax
    mov eax, [rsp + PATH_MAX + 28]
    mov [rsp + 16], eax
    lea rdi, [rsp + PV_REQ]
    mov rsi, r12
    mov rdx, rbx
    call mem_copy
    mov edi, [rip + g_pv_req1]
    dec edi
    mov rsi, rsp
    lea rdx, [rbx + PV_REQ]
    OS_WRITE
    lea rcx, [rbx + PV_REQ]
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
    add rsp, PATH_MAX + 32
    pop r13
    pop r12
    pop rbx
    ret

# int fs_preview_receive(void *buf, size_t cap, uint32_t *out_seq, size_t *out_len, size_t *out_tlen)
# buf receives the head bytes; the image payload (out_tlen bytes) is in fs_preview_shm().
# Non-blocking: returns 1 with one complete reply copied into buf, or 0 when none is ready.
# Replies to older requests are consumed too (caller compares seq).
fs_preview_receive:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    mov [rsp + 24], r8                # out_tlen
    mov ebx, [rip + g_pv_resp1]
    dec ebx
    js .Lprv_none
    mov edi, ebx
    mov rsi, rsp
    mov edx, PV_HDR
    OS_READ
    cmp rax, -EAGAIN; je .Lprv_none
    cmp rax, -EINTR;  je .Lprv_none
    test rax, rax
    jle .Lprv_broken                  # 0 = EOF (helper dead) or fatal read error
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
    mov [r15], rdx
    mov eax, [rsp + 12]               # thumb len
    mov rcx, [rsp + 24]
    test rcx, rcx
    jz 1f
    mov [rcx], rax
1:  cmp rdx, r13
    ja .Lprv_broken
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
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
