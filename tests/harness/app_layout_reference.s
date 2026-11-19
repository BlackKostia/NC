# Frozen reference oracle: original src/app/app_layout.s before migration to src/app/app_layout.c.
# App Controller Class (Inherits from Object) — app layout (split from app.s)

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .text
.global App_layout
.global App_render
.global App_set_status
.global App_set_active_pane
.global get_inactive_pane
.global App_sync_preview
.global App_preview_fire

# void App_layout(App *this)
App_layout:
    push rbx
    push r12
    push r13
    push r14
    push r15
    call App_layout__resize
    # main_h = max(6, term_h - 3 - term_height)
    call App_layout__main_h
    # HeaderBar: (0, 0, term_w, 1)
    call App_layout__headerbar
    # Left FilePane: (0, 1, left_w, main_h)
    call App_layout__left_filepane
    # Right FilePane & PreviewPane: (left_w, 1, term_w - left_w, main_h)
    call App_layout__right_filepane_previewpane
    # StatusBar: (0, term_h - 2, term_w, 1)
    call App_layout__statusbar
    # FunctionBar: (0, term_h - 1, term_w, 1)
    call App_layout__functionbar
    # Active modal dialog (if any)
    call App_layout__active_modal_dialog
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# App_layout step: resize (runs on the caller's frame)
App_layout__resize:
    lea rsp, [rsp - 8]
    mov rbx, rdi

    mov r12d, [rbx + App.term_w]
    mov r13d, [rbx + App.term_h]

    mov rdi, [rbx + App.screen]
    mov esi, r12d
    mov edx, r13d
    call ScreenBuffer_resize

.LApp_layout__resize_ret:
    lea rsp, [rsp + 8]
    ret

# App_layout step: main_h (runs on the caller's frame)
App_layout__main_h:
    lea rsp, [rsp - 8]
    mov r14d, r13d
    sub r14d, 3
    mov edi, r14d
    call term_height
    sub r14d, eax
    cmp r14d, 6
    jge .Lal_mh_ok
    mov r14d, 6
.Lal_mh_ok:
    mov r15d, r12d
    shr r15d, 1               # left_w = term_w / 2

.LApp_layout__main_h_ret:
    lea rsp, [rsp + 8]
    ret

# App_layout step: HeaderBar (runs on the caller's frame)
App_layout__headerbar:
    lea rsp, [rsp - 8]
    mov rdi, [rbx + App.header_bar]
    xor esi, esi
    xor edx, edx
    mov ecx, r12d
    mov r8d, 1
    VCALL WidgetVtbl.layout

.LApp_layout__headerbar_ret:
    lea rsp, [rsp + 8]
    ret

# App_layout step: Left FilePane (runs on the caller's frame)
App_layout__left_filepane:
    lea rsp, [rsp - 8]
    mov rdi, [rbx + App.left_pane]
    xor esi, esi
    mov edx, 1
    mov ecx, r15d
    mov r8d, r14d
    VCALL WidgetVtbl.layout

.LApp_layout__left_filepane_ret:
    lea rsp, [rsp + 8]
    ret

# App_layout step: Right FilePane PreviewPane (runs on the caller's frame)
App_layout__right_filepane_previewpane:
    lea rsp, [rsp - 8]
    mov ecx, r12d
    sub ecx, r15d
    push rcx
    mov rdi, [rbx + App.right_pane]
    mov esi, r15d
    mov edx, 1
    mov r8d, r14d
    VCALL WidgetVtbl.layout
    pop rcx

    mov rdi, [rbx + App.preview_pane]
    mov esi, r15d
    mov edx, 1
    mov r8d, r14d
    VCALL WidgetVtbl.layout

.LApp_layout__right_filepane_previewpane_ret:
    lea rsp, [rsp + 8]
    ret

# App_layout step: StatusBar (runs on the caller's frame)
App_layout__statusbar:
    lea rsp, [rsp - 8]
    mov rdi, [rbx + App.status_bar]
    xor esi, esi
    lea edx, [r13d - 2]
    mov ecx, r12d
    mov r8d, 1
    VCALL WidgetVtbl.layout

.LApp_layout__statusbar_ret:
    lea rsp, [rsp + 8]
    ret

# App_layout step: FunctionBar (runs on the caller's frame)
App_layout__functionbar:
    lea rsp, [rsp - 8]
    mov rdi, [rbx + App.func_bar]
    xor esi, esi
    lea edx, [r13d - 1]
    mov ecx, r12d
    mov r8d, 1
    VCALL WidgetVtbl.layout

.LApp_layout__functionbar_ret:
    lea rsp, [rsp + 8]
    ret

# App_layout step: Active modal dialog (runs on the caller's frame)
App_layout__active_modal_dialog:
    lea rsp, [rsp - 8]
    mov rdi, [rbx + App.active_dialog]
    test rdi, rdi
    jz .Lal_done
    xor esi, esi
    xor edx, edx
    mov ecx, r12d
    mov r8d, r13d
    VCALL WidgetVtbl.layout

.Lal_done:
.LApp_layout__active_modal_dialog_ret:
    lea rsp, [rsp + 8]
    ret

# void App_render(App *this)
App_render:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, [rbx + App.screen]
    mov r13, [rbx + App.theme]

    mov rdi, r12
    mov esi, [r13 + Theme.text]
    mov edx, [r13 + Theme.bg]
    call ScreenBuffer_clear

    mov rdi, [rbx + App.header_bar]
    mov rsi, r12
    mov rdx, r13
    VCALL WidgetVtbl.render

    mov rdi, [rbx + App.left_pane]
    mov rsi, r12
    mov rdx, r13
    VCALL WidgetVtbl.render

    cmp dword ptr [rbx + App.right_mode], RIGHT_MODE_PREVIEW
    je .Lar_preview
    mov rdi, [rbx + App.right_pane]
    jmp .Lar_right_draw
.Lar_preview:
    mov rdi, [rbx + App.preview_pane]
.Lar_right_draw:
    mov rsi, r12
    mov rdx, r13
    VCALL WidgetVtbl.render

    mov rdi, [rbx + App.status_bar]
    mov rsi, r12
    mov rdx, r13
    VCALL WidgetVtbl.render

    mov rdi, [rbx + App.func_bar]
    mov rsi, r12
    mov rdx, r13
    VCALL WidgetVtbl.render

    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call term_render

    mov rdi, [rbx + App.active_dialog]
    test rdi, rdi
    jz .Lar_flush
    mov rsi, r12
    mov rdx, r13
    VCALL WidgetVtbl.render

.Lar_flush:
    mov rdi, rbx
    call img_preview_pre_flush
    mov rdi, r12
    call ScreenBuffer_flush
    mov rdi, rbx
    call img_preview_post_flush
    mov dword ptr [rbx + App.need_redraw], 0

    pop r13
    pop r12
    pop rbx
    ret

# void App_set_status(App *this, const char *msg, int kind)
App_set_status:
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + App.status_bar]
    # rsi = msg, edx = kind
    mov ecx, 3500             # 3.5s display
    call StatusBar_set_message
    mov dword ptr [rbx + App.need_redraw], 1
    pop rbx
    ret

# void App_set_active_pane(App *this, FilePane *pane)
App_set_active_pane:
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    cmp r12, [rbx + App.active_pane]
    je .Lsap_done

    mov rdi, [rbx + App.left_pane]
    xor esi, esi
    VCALL WidgetVtbl.on_focus

    mov rdi, [rbx + App.right_pane]
    xor esi, esi
    VCALL WidgetVtbl.on_focus

    mov [rbx + App.active_pane], r12
    mov rdi, r12
    mov esi, 1
    VCALL WidgetVtbl.on_focus

    mov rdi, rbx
    call App_sync_preview
    mov dword ptr [rbx + App.need_redraw], 1
.Lsap_done:
    pop r12
    pop rbx
    ret

# FilePane *get_inactive_pane(App *this)
get_inactive_pane:
    mov rax, [rdi + App.left_pane]
    cmp rax, [rdi + App.active_pane]
    jne .Lgip_done
    mov rax, [rdi + App.right_pane]
.Lgip_done:
    ret

# void App_sync_preview(App *this) -- debounced: schedules App_preview_fire
App_sync_preview:
    cmp dword ptr [rdi + App.right_mode], RIGHT_MODE_PREVIEW
    jne .Lasp_ret
    push rdi
    call sys_clock_ms
    pop rdi
    add rax, PREVIEW_DEBOUNCE_MS
    mov [rdi + App.preview_due], rax
.Lasp_ret:
    ret

# void App_preview_fire(App *this) -- load preview now; file heads come from the async reader
App_preview_fire:
    mov qword ptr [rdi + App.preview_due], 0
    cmp dword ptr [rdi + App.right_mode], RIGHT_MODE_PREVIEW
    jne .Lasp_done
    push rbx
    push r12
    sub rsp, PATH_MAX + 16
    mov rbx, rdi
    mov r12, [rbx + App.active_pane]
    mov rdi, r12
    call FilePane_get_selected_entry
    test rax, rax
    jz .Lasp_empty

    push rax                  # FileEntry *
    sub rsp, 8
    mov rdi, [r12 + FilePane.model]
    mov rsi, rax
    call DirModel_entry_name
    mov rdx, rax
    lea rdi, [rsp + 16]
    mov rcx, [r12 + FilePane.model]
    lea rsi, [rcx + DirModel.path]
    mov ecx, PATH_MAX
    call path_join
    add rsp, 8
    pop rdx                   # FileEntry *
    mov rdi, [rbx + App.preview_pane]
    mov rsi, rsp
    call PreviewPane_load
    test eax, eax
    jz .Lasp_exit
    mov rdi, [rbx + App.preview_pane]
    lea rsi, [rsp + PATH_MAX]         # PvThumbReq after the path
    call PreviewPane_thumb_req
    mov esi, eax
    mov edx, [rsp + PATH_MAX + 4]
    mov ecx, [rsp + PATH_MAX + 8]
    mov rdi, rsp
    call fs_preview_request
    test eax, eax
    jg .Lasp_async
    mov rdi, [rbx + App.preview_pane]
    call PreviewPane_read_sync
    jmp .Lasp_exit
.Lasp_async:
    mov [rbx + App.preview_seq], eax
    jmp .Lasp_exit
.Lasp_empty:
    mov rdi, [rbx + App.preview_pane]
    xor esi, esi
    xor edx, edx
    call PreviewPane_load
.Lasp_exit:
    mov dword ptr [rbx + App.need_redraw], 1
    add rsp, PATH_MAX + 16
    pop r12
    pop rbx
.Lasp_done:
    ret
