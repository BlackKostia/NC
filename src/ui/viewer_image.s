# ViewerDialog picture mode: decodes the mapped file once (img_decode), keeps a copy scaled to
# the window (rebuilt on resize) and draws it with half-blocks; i / h / t switch Image / Hex / Text.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .text
.global ViewerDialog_set_mode
.global ViewerDialog_render_image
.global viewer_mode_key
.global viewer_img_free

# void ViewerDialog_set_mode(ViewerDialog *v, int mode /*PV_MODE_IMAGE / HEX / TEXT*/)
ViewerDialog_set_mode:
    cmp esi, PV_MODE_IMAGE
    je viewer_img_enter
    cmp esi, PV_MODE_HEX
    jne .Lsm_ret
    cmp dword ptr [rdi + ViewerDialog.hex_mode], 0
    je ViewerDialog_on_btn0           # text -> hex
.Lsm_ret:
    ret

# Internal: void viewer_img_enter(ViewerDialog *v) -- decode on first use, switch to picture mode
viewer_img_enter:
    push rbx
    mov rbx, rdi
    mov dword ptr [rbx + ViewerDialog.img_mode], 1
    cmp dword ptr [rbx + ViewerDialog.img_state], 0
    jne .Lie_dirty
    mov rdi, [rbx + ViewerDialog.data]
    mov rsi, [rbx + ViewerDialog.data_len]
    lea rdx, [rbx + ViewerDialog.path]
    call img_detect
    mov ecx, IMG_E_FORMAT
    test eax, eax
    jz .Lie_state
    mov rdi, [rbx + ViewerDialog.data]
    mov rsi, [rbx + ViewerDialog.data_len]
    mov edx, eax
    lea rcx, [rbx + ViewerDialog.img]
    call img_decode
    mov ecx, eax
    test eax, eax
    jnz .Lie_state
    mov ecx, 1
.Lie_state:
    mov [rbx + ViewerDialog.img_state], ecx
.Lie_dirty:
    mov rax, [rbx + Dialog.app]
    mov dword ptr [rax + App.need_redraw], 1
    pop rbx
    ret

# void viewer_img_free(ViewerDialog *v)
viewer_img_free:
    push rbx
    mov rbx, rdi
    lea rdi, [rbx + ViewerDialog.img]
    call img_free
    mov rdi, [rbx + ViewerDialog.thumb]
    call mem_free
    mov qword ptr [rbx + ViewerDialog.thumb], 0
    mov rdi, [rbx + ViewerDialog.enc]
    call mem_free
    mov qword ptr [rbx + ViewerDialog.enc], 0
    pop rbx
    ret

# int viewer_mode_key(ViewerDialog *v, Event *e) -> 1 when the key switched the view mode
viewer_mode_key:
    push rbx
    mov rbx, rdi
    mov eax, [rsi + Event.key]
    or eax, 0x20
    cmp eax, 'i'
    je .Lmk_image
    cmp eax, 't'
    je .Lmk_text
    cmp eax, 'h'
    jne .Lmk_no
    cmp dword ptr [rbx + ViewerDialog.img_mode], 0
    je .Lmk_no                        # plain h: the viewer's own hex toggle
    mov dword ptr [rbx + ViewerDialog.img_mode], 0
    mov rdi, rbx
    mov esi, PV_MODE_HEX
    call ViewerDialog_set_mode
    jmp .Lmk_yes
.Lmk_image:
    cmp dword ptr [rbx + ViewerDialog.img_mode], 0
    jne .Lmk_text
    mov rdi, rbx
    call viewer_img_enter
    jmp .Lmk_yes
.Lmk_text:
    mov dword ptr [rbx + ViewerDialog.img_mode], 0
    cmp dword ptr [rbx + ViewerDialog.hex_mode], 0
    je .Lmk_dirty
    mov rdi, rbx
    call ViewerDialog_on_btn0         # hex -> text
.Lmk_dirty:
    mov rax, [rbx + Dialog.app]
    mov dword ptr [rax + App.need_redraw], 1
.Lmk_yes:
    mov eax, 1
    pop rbx
    ret
.Lmk_no:
    xor eax, eax
    pop rbx
    ret

# void ViewerDialog_render_image(ViewerDialog *v, ScreenBuffer *scr)
ViewerDialog_render_image:
    push rbx
    push r12
    push r13
    sub rsp, 32
    mov rbx, rdi
    mov r12, rsi
    mov rax, [rbx + Dialog.app]
    mov r13, [rax + App.theme]
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    xor ecx, ecx
    xor r8d, r8d
    call Dialog_draw_frame
    cmp dword ptr [rbx + ViewerDialog.img_state], 1
    jne .Lri_unsup
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call vim_draw_picture
    jmp .Lri_hint
.Lri_unsup:
    call i18n_get
    mov rcx, [rax + LangStrings.img_unsup]
    mov edx, 2
    mov esi, [r13 + Theme.warn_fg]
    call vim_line
.Lri_hint:
    call i18n_get
    mov rcx, [rax + LangStrings.vw_img_hint]
    mov edx, [rbx + Widget.h]
    sub edx, 2
    mov esi, [r13 + Theme.muted]
    call vim_line
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call vim_draw_zoom_badge
    add rsp, 32
    pop r13
    pop r12
    pop rbx
    ret

# Internal (render frame: rbx = v, r12 = scr, r13 = theme): text rcx in color esi at row y + edx
vim_line:
    push rcx
    push rdx
    sub rsp, 8
    mov rdi, r12
    mov edx, [r13 + Theme.dialog_bg]
    xor ecx, ecx
    call ScreenBuffer_set_pen
    add rsp, 8
    pop rdx
    pop rcx
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 2
    add edx, [rbx + Widget.y]
    mov r8d, [rbx + Widget.w]
    sub r8d, 4
    jmp ScreenBuffer_draw_text
