# PreviewPane presentation modes: Image / Hex / Text for the file under the cursor (Alt+V),
# thumbnail geometry for the async decoder and the mode bar drawn on the bottom border.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .rodata
str_altv:  .asciz " Alt+V "
str_sep:   .asciz " "

.section .text
.global PreviewPane_thumb_dims
.global PreviewPane_cycle_mode
.global pv_mode_dispatch

# uint32_t PreviewPane_thumb_dims(PreviewPane *this) -> tw | th << 16 (half-block pixels), 0 = none
PreviewPane_thumb_dims:
    mov eax, [rdi + Widget.w]
    sub eax, 2
    jle .Ltd_none
    cmp eax, IMG_THUMB_MAXW
    jbe 1f
    mov eax, IMG_THUMB_MAXW
1:  mov ecx, [rdi + Widget.h]
    sub ecx, 4
    jle .Ltd_none
    shl ecx, 1
    cmp ecx, IMG_THUMB_MAXH
    jbe 2f
    mov ecx, IMG_THUMB_MAXH
2:  shl ecx, 16
    or eax, ecx
    ret
.Ltd_none:
    xor eax, eax
    ret

# Internal: int pv_effective_mode(PreviewPane *this) -> PV_MODE_IMAGE / HEX / TEXT
pv_effective_mode:
    mov eax, [rdi + PreviewPane.view_mode]
    cmp dword ptr [rdi + PreviewPane.thumb_len], IMG_THUMB_HDR
    jb .Lem_plain
    test eax, eax
    jnz .Lem_ret
    mov eax, PV_MODE_IMAGE
    ret
.Lem_plain:
    cmp eax, PV_MODE_IMAGE
    je 1f
    test eax, eax
    jnz .Lem_ret
1:  mov eax, PV_MODE_TEXT
    cmp dword ptr [rdi + PreviewPane.is_binary], 0
    je .Lem_ret
    mov eax, PV_MODE_HEX
.Lem_ret:
    ret

# void PreviewPane_cycle_mode(PreviewPane *this) -- images: Image -> Hex -> Text; other files: Hex <-> Text
PreviewPane_cycle_mode:
    push rbx
    mov rbx, rdi
    call pv_effective_mode
    mov ecx, PV_MODE_TEXT
    cmp eax, PV_MODE_HEX
    je .Lcm_set
    mov ecx, PV_MODE_HEX
    cmp eax, PV_MODE_TEXT
    jne .Lcm_set
    mov ecx, PV_MODE_HEX              # text -> image (images) / hex (other files)
    cmp dword ptr [rbx + PreviewPane.thumb_len], IMG_THUMB_HDR
    jb .Lcm_set
    mov ecx, PV_MODE_IMAGE
.Lcm_set:
    mov [rbx + PreviewPane.view_mode], ecx
    mov dword ptr [rbx + PreviewPane.scroll], 0
    mov rax, [rbx + PreviewPane.app]
    mov dword ptr [rax + App.need_redraw], 1
    pop rbx
    ret

# int pv_mode_dispatch(PreviewPane *this, ScreenBuffer *scr, Theme *theme)
# -> 0 when the content was drawn here (image / ELF summary), 1 = draw hex, 2 = draw text
pv_mode_dispatch:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    call pv_effective_mode
    mov r14d, eax
    cmp dword ptr [rbx + PreviewPane.thumb_len], IMG_THUMB_HDR
    jb .Lmd_plain
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov ecx, r14d
    call pv_draw_mode_bar
    cmp r14d, PV_MODE_IMAGE
    jne .Lmd_kind
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call img_preview_try_render
    xor eax, eax
    jmp .Lmd_ret
.Lmd_plain:
    cmp dword ptr [rbx + PreviewPane.view_mode], PV_MODE_AUTO
    jne .Lmd_kind
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call elf_preview_try_render
    test eax, eax
    jz .Lmd_kind
    xor eax, eax
    jmp .Lmd_ret
.Lmd_kind:
    mov eax, 1
    cmp r14d, PV_MODE_HEX
    je .Lmd_ret
    mov eax, 2
.Lmd_ret:
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: void pv_draw_mode_bar(PreviewPane *this, ScreenBuffer *scr, Theme *theme, int mode)
# " Alt+V  Image  Hex  Text " on the bottom border, the active mode highlighted.
pv_draw_mode_bar:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov [rsp + 8], ecx
    mov r14d, [rbx + Widget.x]
    add r14d, 2
    mov rdi, r12
    mov esi, [r13 + Theme.muted]
    mov edx, [r13 + Theme.surface]
    xor ecx, ecx
    call ScreenBuffer_set_pen
    lea rcx, [rip + str_altv]
    call pmb_text
    mov r15d, PV_MODE_IMAGE
.Lmb_item:
    cmp r15d, PV_MODE_TEXT
    jg .Lmb_done
    call i18n_get
    mov rcx, [rax + LangStrings.vas_image]
    cmp r15d, PV_MODE_HEX
    jne 1f
    mov rcx, [rax + LangStrings.vas_hex]
1:  cmp r15d, PV_MODE_TEXT
    jne 2f
    mov rcx, [rax + LangStrings.vas_text]
2:  mov [rsp], rcx
    mov rdi, r12
    mov esi, [r13 + Theme.text]
    mov edx, [r13 + Theme.surface]
    xor ecx, ecx
    cmp r15d, [rsp + 8]
    jne 3f
    mov esi, [r13 + Theme.accent_fg]
    mov edx, [r13 + Theme.accent]
    mov ecx, ATTR_BOLD
3:  call ScreenBuffer_set_pen
    lea rcx, [rip + str_sep]
    call pmb_text
    mov rcx, [rsp]
    call pmb_text
    lea rcx, [rip + str_sep]
    call pmb_text
    inc r15d
    jmp .Lmb_item
.Lmb_done:
    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: draw rcx at (r14d, bottom border of rbx) on r12, advance r14d by its display width
pmb_text:
    push rcx
    mov rdi, r12
    mov esi, r14d
    mov edx, [rbx + Widget.y]
    add edx, [rbx + Widget.h]
    dec edx
    mov r8d, [rbx + Widget.x]
    add r8d, [rbx + Widget.w]
    sub r8d, r14d
    dec r8d
    jle .Lpt_skip
    call ScreenBuffer_draw_text
.Lpt_skip:
    mov rdi, [rsp]
    call utf8_display_width
    add r14d, eax
    pop rcx
    ret
