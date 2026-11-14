# App Controller Class (Inherits from Object) — app loop (split from app.s)

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .text
.global App_run

# Internal: handle mouse event
handle_mouse:
    push rbx
    push r12
    call handle_mouse__part1
    # Modal dialog captures all mouse input
    mov rdi, [rbx + App.active_dialog]
    test rdi, rdi
    jz .Lhm_check_drag
    mov rsi, r12
    VCALL WidgetVtbl.on_mouse
    jmp .Lhm_done

.Lhm_check_drag:
    # Forward drag/release to whichever pane is dragging its scrollbar
    mov rdi, [rbx + App.left_pane]
    cmp dword ptr [rdi + FilePane.dragging_scroll], 0
    jne .Lhm_fwd_drag
    mov rdi, [rbx + App.right_pane]
    cmp dword ptr [rdi + FilePane.dragging_scroll], 0
    je .Lhm_route
.Lhm_fwd_drag:
    mov rsi, r12
    VCALL WidgetVtbl.on_mouse
    jmp .Lhm_done

.Lhm_route:
    mov rdi, rbx
    mov rsi, r12
    call pane_mouse_ext
    test eax, eax
    jnz .Lhm_done
    # On MACT_MOVE, let HeaderBar, FunctionBar, and panes update hover states cleanly
    cmp dword ptr [r12 + Event.mouse_kind], MACT_MOVE
    jne .Lhm_hit_test
    mov rdi, rbx
    mov rsi, r12
    call app_mouse_hover
    jmp .Lhm_done

.Lhm_hit_test:
    cmp dword ptr [rbx + App.task_active], 0
    je .Lhm_ht_hdr
    cmp dword ptr [r12 + Event.mouse_kind], MACT_PRESS
    jne .Lhm_ht_hdr
    mov rax, [rbx + App.status_bar]
    mov ecx, [rax + Widget.y]
    cmp ecx, [r12 + Event.mouse_y]
    jne .Lhm_ht_hdr
    mov rdi, rbx
    call App_task_show
    jmp .Lhm_done

.Lhm_ht_hdr:
    call handle_mouse__part2
.Lhm_done:
    pop r12
    pop rbx
    ret

# handle_mouse step (runs on the caller's frame)
handle_mouse__part1:
    lea rsp, [rsp - 8]
    mov rbx, rdi
    mov r12, rsi

    mov eax, [r12 + Event.mouse_x]
    mov [rbx + App.mouse_x], eax
    mov eax, [r12 + Event.mouse_y]
    mov [rbx + App.mouse_y], eax

.Lhandle_mouse__part1_ret:
    lea rsp, [rsp + 8]
    ret

# handle_mouse step (runs on the caller's frame)
handle_mouse__part2:
    lea rsp, [rsp - 8]
    mov r8d, [r12 + Event.mouse_x]
    mov r9d, [r12 + Event.mouse_y]

    mov rdi, [rbx + App.header_bar]
    mov esi, r8d
    mov edx, r9d
    VCALL WidgetVtbl.hit_test
    test eax, eax
    jz .Lhm_ht_func
    mov rdi, [rbx + App.header_bar]
    mov rsi, r12
    VCALL WidgetVtbl.on_mouse
    test eax, eax
    jnz .Lhandle_mouse__part2_ret

.Lhm_ht_func:
    mov rdi, [rbx + App.func_bar]
    mov esi, r8d
    mov edx, r9d
    VCALL WidgetVtbl.hit_test
    test eax, eax
    jz .Lhm_ht_left
    mov rdi, [rbx + App.func_bar]
    mov rsi, r12
    VCALL WidgetVtbl.on_mouse
    test eax, eax
    jnz .Lhandle_mouse__part2_ret

.Lhm_ht_left:
    mov rdi, [rbx + App.left_pane]
    mov esi, r8d
    mov edx, r9d
    VCALL WidgetVtbl.hit_test
    test eax, eax
    jz .Lhm_ht_right
    mov rdi, [rbx + App.left_pane]
    mov rsi, r12
    VCALL WidgetVtbl.on_mouse
    jmp .Lhandle_mouse__part2_ret

.Lhm_ht_right:
    mov rdi, [rbx + App.right_pane]
    cmp dword ptr [rbx + App.right_mode], RIGHT_MODE_PREVIEW
    jne .Lhm_ht_rtest
    mov rdi, [rbx + App.preview_pane]
.Lhm_ht_rtest:
    push rdi
    mov esi, r8d
    mov edx, r9d
    VCALL WidgetVtbl.hit_test
    pop rdi
    test eax, eax
    jz .Lhandle_mouse__part2_ret
    mov rsi, r12
    VCALL WidgetVtbl.on_mouse

.Lhandle_mouse__part2_ret:
    lea rsp, [rsp + 8]
    ret

# void App_run(App *this)
App_run:
    push rbx
    sub rsp, Event._size + 16
    call App_run__events_init
.Larun_loop:
    cmp dword ptr [rbx + App.running], 0
    je .Larun_exit
    cmp dword ptr [rip + g_sigterm], 0
    jne .Larun_exit

    # Non-blocking poll (0ms) while streaming large dirs so UI/Esc stay responsive
    call App_run__non_blocking_poll_while
    # Check if temporary status message expired
    call App_run__check_temporary_status_message
    call App_run__drain_queued_events
    cmp dword ptr [rbx + App.running], 0
    je .Larun_exit
    call App_run__stream_both_panes_concurrently
    cmp dword ptr [rbx + App.need_redraw], 0
    je .Larun_loop
    mov rdi, rbx
    call App_render
    jmp .Larun_loop

.Larun_exit:
    mov rdi, rbx
    call App_task_shutdown
    mov rdi, rbx
    call App_events_shutdown
    add rsp, Event._size + 16
    pop rbx
    ret

# App_run step: events_init (runs on the caller's frame)
App_run__events_init:
    lea rsp, [rsp - 8]
    mov rbx, rdi
    mov qword ptr [rsp + Event._size + 16], 0

    call App_events_init
    mov rdi, rbx
    call App_render

.LApp_run__events_init_ret:
    lea rsp, [rsp + 8]
    ret

# App_run step: Non blocking poll while streaming large dirs so UI Esc stay responsive (runs on the caller's frame)
App_run__non_blocking_poll_while:
    lea rsp, [rsp - 8]
    mov rcx, [rbx + App.left_pane]
    mov rcx, [rcx + FilePane.model]
    mov edx, [rcx + DirModel.is_loading]
    mov rcx, [rbx + App.right_pane]
    mov rcx, [rcx + FilePane.model]
    or edx, [rcx + DirModel.is_loading]
    xor esi, esi
    test edx, edx
    jnz .Larun_poll
    mov rdi, rbx
    call App_events_timeout           # -1 when idle: no periodic wake-ups at all
    mov esi, eax
.Larun_poll:
    lea rdi, [rsp + 16]
    call input_poll_event

.LApp_run__non_blocking_poll_while_ret:
    lea rsp, [rsp + 8]
    ret

# App_run step: Check if temporary status message expired (runs on the caller's frame)
App_run__check_temporary_status_message:
    lea rsp, [rsp - 8]
    mov rcx, [rbx + App.status_bar]
    cmp qword ptr [rcx + StatusBar.msg_expire_ms], 0
    je .Larun_chk_evt
    push rax
    call sys_clock_ms
    mov rcx, [rbx + App.status_bar]
    cmp rax, [rcx + StatusBar.msg_expire_ms]
    jb .Larun_msg_active
    mov qword ptr [rcx + StatusBar.msg_expire_ms], 0
    mov dword ptr [rbx + App.need_redraw], 1
.Larun_msg_active:
    pop rax

.Larun_chk_evt:
    test eax, eax
    jz .Larun_stream_step

    mov eax, [rsp + Event.type + 16]
    cmp eax, EVT_RESIZE
    je .Larun_resize
    cmp eax, EVT_KEY
    je .Larun_key
    cmp eax, EVT_MOUSE
    je .Larun_mouse
    jmp .Larun_stream_step

.Larun_resize:
    lea rdi, [rbx + App.term_w]
    lea rsi, [rbx + App.term_h]
    call sys_get_winsize
    mov edi, [rbx + App.term_w]
    mov esi, [rbx + App.term_h]
    call term_caps_refresh            # cell pixels may change with the window / font
    mov rdi, rbx
    call App_layout
    mov rdi, rbx
    call App_sync_preview             # thumbnails are sized for the preview box
    mov dword ptr [rbx + App.need_redraw], 1
    jmp .Larun_stream_step

.Larun_key:
    mov rdi, rbx
    lea rsi, [rsp + 16]
    call handle_key
    jmp .Larun_stream_step

.Larun_mouse:
    mov rdi, rbx
    lea rsi, [rsp + 16]
    call handle_mouse

.Larun_stream_step:
.LApp_run__check_temporary_status_message_ret:
    lea rsp, [rsp + 8]
    ret

# App_run step: Stream both panes concurrently alternate batches when both are loading (runs on the caller's frame)
App_run__stream_both_panes_concurrently:
    lea rsp, [rsp - 8]
    mov rdi, rbx
    call App_task_tick
    mov rdi, rbx
    call App_events_tick
    # Stream both panes concurrently: alternate batches when both are loading
    mov rax, [rbx + App.left_pane]
    mov rdi, [rax + FilePane.model]
    mov rax, [rbx + App.right_pane]
    mov rsi, [rax + FilePane.model]
    mov ecx, [rdi + DirModel.is_loading]
    mov edx, [rsi + DirModel.is_loading]
    test ecx, ecx
    jz .Larun_only_right
    test edx, edx
    jz .Larun_do_step
    xor dword ptr [rbx + App.stream_turn], 1
    cmp dword ptr [rbx + App.stream_turn], 0
    je .Larun_do_step
    mov rdi, rsi
    jmp .Larun_do_step
.Larun_only_right:
    test edx, edx
    jz .Larun_redraw
    mov rdi, rsi

.Larun_do_step:
    xor esi, esi
    call DirModel_step_load
    test rax, rax
    jz .Larun_stream_finished

    # Throttle progress footer redraws (~30 FPS) to keep 1M scan at max speed
    call sys_clock_ms
    mov rcx, rax
    sub rcx, [rsp + Event._size + 16]
    cmp rcx, 33
    jb .Larun_redraw
    mov [rsp + Event._size + 16], rax
    mov dword ptr [rbx + App.need_redraw], 1
    jmp .Larun_redraw

.Larun_stream_finished:
    mov rdi, rbx
    call App_sync_preview
    mov dword ptr [rbx + App.need_redraw], 1

.Larun_redraw:
.LApp_run__stream_both_panes_concurrently_ret:
    lea rsp, [rsp + 8]
    ret

# App_run step: coalesce burst of already-queued key/mouse events before rendering
App_run__drain_queued_events:
    push r12
    mov r12d, 16
.Ldq_lp:
    cmp dword ptr [rbx + App.running], 0
    je .Ldq_ret
    dec r12d
    js .Ldq_ret
    lea rdi, [rsp + 16]               # Event on App_run's frame (+8 ret, +8 push r12)
    xor esi, esi                      # timeout = 0 (non-blocking)
    call input_poll_event
    test eax, eax
    jz .Ldq_ret
    mov eax, [rsp + 16 + Event.type]
    cmp eax, EVT_KEY
    je .Ldq_key
    cmp eax, EVT_MOUSE
    je .Ldq_mouse
    jmp .Ldq_ret
.Ldq_key:
    mov rdi, rbx
    lea rsi, [rsp + 16]
    call handle_key
    jmp .Ldq_lp
.Ldq_mouse:
    mov rdi, rbx
    lea rsi, [rsp + 16]
    call handle_mouse
    jmp .Ldq_lp
.Ldq_ret:
    pop r12
    ret
