# Frozen reference oracle: original src/app/app_du.s before migration to src/app/app_du.c.
# App side of the Disk Usage progress: the callback that du_parallel_walk runs on the main thread
# about every 100 ms while worker threads walk folders. After DUOP_DU_PROGRESS_MS (default 300 ms)
# it shows DuProgressDialog over the redrawn screen; Esc cancels the walk (status message), other
# input is dropped, terminal resizes are applied, and the final call closes the window.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .rodata
env_du_delay:   .asciz "DUOP_DU_PROGRESS_MS="

.section .bss
.align 8
g_du_dlg:       .space 8              # DuProgressDialog while shown
g_du_delay:     .space 8              # ms before the window appears

.section .text
.global App_du_init
.global du_toggle

# void App_du_init(App *app) -- register the progress callback (read DUOP_DU_PROGRESS_MS)
App_du_init:
    push rbx
    mov rbx, rdi
    mov qword ptr [rip + g_du_delay], DU_PROGRESS_MS
    mov rdi, [rbx + App.envp]
    lea rsi, [rip + env_du_delay]
    call cfg_getenv
    test rax, rax
    jz .Ldi_reg
    cmp byte ptr [rax], 0
    je .Ldi_reg
    mov rdi, rax
    call parse_uint
    mov [rip + g_du_delay], rax
.Ldi_reg:
    lea rdi, [rip + App_du_progress]
    mov rsi, rbx
    call du_set_progress
    pop rbx
    ret

# Internal: int App_du_progress(App *app, DuProgress *p) -> 1 to cancel the walk
App_du_progress:
    push rbx
    push r12
    push r13
    sub rsp, Event._size + 16
    mov rbx, rdi
    mov r12, rsi
    cmp dword ptr [r12 + DuProgress.phase], DU_PHASE_DONE
    je .Ldp_done
    xor r13d, r13d                    # Esc seen
.Ldp_input:
    mov rdi, rsp
    xor esi, esi
    call input_poll_event             # queued input only (timeout 0)
    test eax, eax
    jz .Ldp_draw
    call adu_event
    jmp .Ldp_input
.Ldp_draw:
    test r13d, r13d
    jnz .Ldp_cancel
    call adu_maybe_render
    mov edi, STDIN_FD
    mov esi, 100
    call os_poll_in                   # the pace of the progress ticks
    xor eax, eax
    jmp .Ldp_ret
.Ldp_cancel:
    call i18n_get
    mov rsi, [rax + LangStrings.msg_du_canceled]
    mov rdi, rbx
    mov edx, MSG_INFO
    call App_set_status
    mov eax, 1
    jmp .Ldp_ret
.Ldp_done:
    mov rdi, rbx
    call adu_close
    xor eax, eax
.Ldp_ret:
    add rsp, Event._size + 16
    pop r13
    pop r12
    pop rbx
    ret

# App_du_progress step: one queued event at [caller rsp] -- Esc cancels, resize re-lays out
adu_event:
    lea rsp, [rsp - 8]
    mov eax, [rsp + 16 + Event.type]
    cmp eax, EVT_RESIZE
    je .Lae_resize
    cmp eax, EVT_KEY
    jne .Lae_ret
    cmp dword ptr [rsp + 16 + Event.key], KEY_ESC
    jne .Lae_ret
    mov r13d, 1
    jmp .Lae_ret
.Lae_resize:
    lea rdi, [rbx + App.term_w]
    lea rsi, [rbx + App.term_h]
    call sys_get_winsize
    mov edi, [rbx + App.term_w]
    mov esi, [rbx + App.term_h]
    call term_caps_refresh
    mov rdi, rbx
    call App_layout
    mov dword ptr [rbx + App.need_redraw], 1
    mov rdi, [rip + g_du_dlg]
    test rdi, rdi
    jz .Lae_ret
    xor esi, esi
    xor edx, edx
    mov ecx, [rbx + App.term_w]
    mov r8d, [rbx + App.term_h]
    call DuProgressDialog_layout
.Lae_ret:
    lea rsp, [rsp + 8]
    ret

# App_du_progress step: once the walk is older than the delay, show the window and redraw
adu_maybe_render:
    lea rsp, [rsp - 8]
    call os_clock_ms
    sub rax, [r12 + DuProgress.start_ms]
    cmp rax, [rip + g_du_delay]
    jl .Lmr_ret
    cmp qword ptr [rip + g_du_dlg], 0
    jne .Lmr_render
    cmp qword ptr [rbx + App.active_dialog], 0
    jne .Lmr_ret                      # another dialog owns the screen: stay quiet
    mov rdi, rbx
    call DuProgressDialog_new
    test rax, rax
    jz .Lmr_ret
    mov [rip + g_du_dlg], rax
    mov [rbx + App.active_dialog], rax
.Lmr_render:
    mov rdi, rbx
    call App_render
.Lmr_ret:
    lea rsp, [rsp + 8]
    ret

# Internal: void adu_close(App *app) -- remove the window after the walk
adu_close:
    push rbx
    mov rbx, rdi
    mov rdi, [rip + g_du_dlg]
    test rdi, rdi
    jz .Lac_ret
    mov qword ptr [rip + g_du_dlg], 0
    mov qword ptr [rbx + App.active_dialog], 0
    DELETE_OBJ rdi
    mov dword ptr [rbx + App.need_redraw], 1
.Lac_ret:
    pop rbx
    ret

# void du_toggle(App *app) -- Disk Usage on/off for the active pane: measure the listing, or back to the plain one
du_toggle:
    push rbx
    push r12
    sub rsp, 8                        # 16-byte aligned calls: the C callees may use aligned stack stores
    mov rbx, rdi
    mov rax, [rbx + App.active_pane]
    mov r12, [rax + FilePane.model]
    cmp dword ptr [r12 + DirModel.du_mode], 0
    jne .Ldut_off
    mov rdi, r12
    call dir_du_populate
    jmp .Ldut_done
.Ldut_off:
    mov rdi, r12
    call du_leave
.Ldut_done:
    mov dword ptr [rbx + App.need_redraw], 1
    add rsp, 8
    pop r12
    pop rbx
    ret
