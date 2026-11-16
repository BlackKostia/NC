# App Event Sources: exact poll timeouts, debounced preview, async preview replies and
# inotify-driven auto-refresh of both panes.
#
# The main loop sleeps in one ppoll over stdin + background task pipe + directory watch +
# preview reply pipe with a timeout that is either infinite (truly idle: 0 wake-ups) or
# exactly the nearest deadline (status toast expiry, preview debounce, refresh debounce,
# task progress tick).

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .text
.global App_events_init
.global App_events_timeout
.global App_events_tick
.global App_events_shutdown

# void App_events_init(App *app)
App_events_init:
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + App.envp]         # image protocol: environment, then DA1 / cell-size replies
    call term_caps_init
    call term_caps_query
    mov edi, [rbx + App.term_w]
    mov esi, [rbx + App.term_h]
    call term_caps_refresh
    call dirwatch_init
    call dirwatch_fd
    mov esi, eax
    mov edi, 1
    call input_set_aux_fd
    pop rbx
    ret

# void App_events_shutdown(App *app)
App_events_shutdown:
    sub rsp, 8
    call term_shutdown
    add rsp, 8
    jmp fs_preview_stop

# Internal: rax = min(rax, deadline - now) for a pending deadline (rsi = deadline, rdx = now)
# Encoded as: edi = current timeout (-1 = infinite) -> returns eax
ev_min_deadline:
    test rsi, rsi
    jz .Lemd_keep
    mov rax, rsi
    sub rax, rdx
    jns .Lemd_pos
    xor eax, eax
.Lemd_pos:
    cmp rax, 0x7FFFFFFF
    jbe .Lemd_have
    mov eax, 0x7FFFFFFF
.Lemd_have:
    test edi, edi
    js .Lemd_take
    cmp eax, edi
    jae .Lemd_keep
.Lemd_take:
    ret
.Lemd_keep:
    mov eax, edi
    ret

# int App_events_timeout(App *app) -> poll timeout in ms (-1 = sleep until an event)
App_events_timeout:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    call sys_clock_ms
    mov r13, rax                      # now
    mov r12d, -1
    cmp dword ptr [rbx + App.task_active], 0
    je .Let_status
    mov r12d, TASK_TICK_MS
.Let_status:
    mov rax, [rbx + App.status_bar]
    mov edi, r12d
    mov rsi, [rax + StatusBar.msg_expire_ms]
    mov rdx, r13
    call ev_min_deadline
    mov edi, eax
    mov rsi, [rbx + App.preview_due]
    mov rdx, r13
    call ev_min_deadline
    mov edi, eax
    mov rsi, [rbx + App.watch_due]
    mov rdx, r13
    call ev_min_deadline
    mov edi, eax
    mov rsi, [rbx + App.watch_due + 8]
    mov rdx, r13
    call ev_min_deadline
    pop r13
    pop r12
    pop rbx
    ret

# Internal: void ev_schedule_watch(App *app, int slot, int kind, int64 now)
ev_schedule_watch:
    or [rdi + App.watch_kind + rsi * 4], edx
    cmp qword ptr [rdi + App.watch_due + rsi * 8], 0
    jne .Lesw_ret
    lea rax, [rcx + WATCH_DEBOUNCE_MS]
    mov r8, [rdi + App.watch_last + rsi * 8]
    add r8, WATCH_MIN_GAP_MS
    cmp rax, r8
    jae .Lesw_set
    mov rax, r8
.Lesw_set:
    mov [rdi + App.watch_due + rsi * 8], rax
.Lesw_ret:
    ret

# Internal: void ev_refresh_pane(App *app, int slot, int64 now)
ev_refresh_pane:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov r14, [rbx + App.left_pane]
    test r12d, r12d
    jz .Lerp_pane
    mov r14, [rbx + App.right_pane]
.Lerp_pane:
    mov rdi, [r14 + FilePane.model]
    cmp dword ptr [rdi + DirModel.is_loading], 0
    je .Lerp_go
    lea rax, [r13 + WATCH_DEBOUNCE_MS]      # still streaming: try again shortly
    mov [rbx + App.watch_due + r12 * 8], rax
    jmp .Lerp_ret
.Lerp_go:
    mov qword ptr [rbx + App.watch_due + r12 * 8], 0
    mov [rbx + App.watch_last + r12 * 8], r13
    mov eax, [rbx + App.watch_kind + r12 * 4]
    mov dword ptr [rbx + App.watch_kind + r12 * 4], 0
    test eax, 1
    jz .Lerp_content
    # Structural change: reload unless the user has marks there (never wipe a selection)
    # or the listing is huge (explicit Ctrl+R only).
    cmp dword ptr [rdi + DirModel.huge_mode], 0
    jne .Lerp_content
    push rdi
    sub rsp, 8
    xor esi, esi
    call DirModel_count_selected
    add rsp, 8
    pop rdi
    test rax, rax
    jnz .Lerp_content
    mov rdi, r14
    xor esi, esi
    call FilePane_reload_keep_cursor
    jmp .Lerp_done
.Lerp_content:
    mov rdi, [r14 + FilePane.model]
    call DirModel_invalidate_stats
.Lerp_done:
    cmp r14, [rbx + App.active_pane]
    jne .Lerp_redraw
    mov rdi, rbx
    call App_sync_preview
.Lerp_redraw:
    mov dword ptr [rbx + App.need_redraw], 1
.Lerp_ret:
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# void App_events_tick(App *app) -- called once per loop iteration
App_events_tick:
    push rbx
    push r12
    push r13
    sub rsp, 32                       # [0]=seq, [8]=len, [16]=thumbnail len
    call App_events_tick__debounced_preview
    # Keep watches on the directories currently shown, collect change events
    call App_events_tick__keep_watches_directories_current
    call term_caps_changed            # protocol / cell size known now: redo the image preview
    test eax, eax
    jz 1f
    mov rdi, rbx
    call App_sync_preview
1:  add rsp, 32
    pop r13
    pop r12
    pop rbx
    ret

# App_events_tick step: Debounced preview (runs on the caller's frame)
App_events_tick__debounced_preview:
    lea rsp, [rsp - 8]
    mov rbx, rdi
    call sys_clock_ms
    mov r12, rax                      # now

    # Debounced preview
    mov rax, [rbx + App.preview_due]
    test rax, rax
    jz .Leti_replies
    cmp r12, rax
    jb .Leti_replies
    mov rdi, rbx
    call App_preview_fire
.Leti_replies:
    mov rdi, rbx
    call term_poll_read
    call fs_preview_fd
    mov esi, eax
    mov edi, 2
    call input_set_aux_fd
.Leti_recv:
    mov r13, [rbx + App.preview_pane]
    mov rdi, [r13 + PreviewPane.buf]
    mov esi, PREVIEW_BUF_SIZE
    lea rdx, [rsp + 16]
    lea rcx, [rsp + 8 + 16]
    lea r8, [rsp + 16 + 16]
    call fs_preview_receive
    test eax, eax
    jz .Leti_watch
    mov eax, [rsp + 16]
    cmp eax, [rbx + App.preview_seq]
    jne .Leti_recv
    cmp dword ptr [r13 + PreviewPane.pending], 0
    je .Leti_recv
    mov edi, [rsp + 16]
    call fs_preview_shm_slot
    mov rcx, rax
    mov rdi, r13
    mov rsi, [rsp + 8 + 16]
    mov rdx, [rsp + 16 + 16]
    call PreviewPane_accept
    mov dword ptr [rbx + App.need_redraw], 1
    jmp .Leti_recv

.Leti_watch:
    call fs_preview_fd
    mov esi, eax
    mov edi, 2
    call input_set_aux_fd
.LApp_events_tick__debounced_preview_ret:
    lea rsp, [rsp + 8]
    ret

# App_events_tick step: Keep watches on the directories currently shown collect change events (runs on the caller's frame)
App_events_tick__keep_watches_directories_current:
    lea rsp, [rsp - 8]
    mov rax, [rbx + App.left_pane]
    mov rsi, [rax + FilePane.model]
    lea rsi, [rsi + DirModel.path]
    xor edi, edi
    call dirwatch_set
    mov rax, [rbx + App.right_pane]
    mov rsi, [rax + FilePane.model]
    lea rsi, [rsi + DirModel.path]
    mov edi, 1
    call dirwatch_set
    call dirwatch_poll
    mov r13d, eax
    test r13d, 3
    jz .Leti_w1
    mov rdi, rbx
    xor esi, esi
    mov edx, r13d
    and edx, 3
    mov rcx, r12
    call ev_schedule_watch
.Leti_w1:
    test r13d, 12
    jz .Leti_due
    mov rdi, rbx
    mov esi, 1
    mov edx, r13d
    shr edx, 2
    and edx, 3
    mov rcx, r12
    call ev_schedule_watch
.Leti_due:
    xor r13d, r13d
.Leti_due_loop:
    cmp r13d, 2
    jae .Leti_ret
    mov rax, [rbx + App.watch_due + r13 * 8]
    test rax, rax
    jz .Leti_due_next
    cmp r12, rax
    jb .Leti_due_next
    mov rdi, rbx
    mov esi, r13d
    mov rdx, r12
    call ev_refresh_pane
.Leti_due_next:
    inc r13d
    jmp .Leti_due_loop
.Leti_ret:
.LApp_events_tick__keep_watches_directories_current_ret:
    lea rsp, [rsp + 8]
    ret
