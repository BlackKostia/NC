# PreviewPane presentation modes: Image / Hex / Text for the file under the cursor (Alt+V),
# thumbnail geometry for the async decoder and the mode bar drawn on the bottom border.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .rodata
str_altv:  .asciz " Alt+V "
str_sep:   .asciz " "

.section .text
.global PreviewPane_thumb_req
.global pv_box_pixels
.global img_box_pixels
.global PreviewPane_cycle_mode
.global pv_mode_dispatch

# uint32_t PreviewPane_thumb_req(PreviewPane *this, PvThumbReq *out) -> dims (0 = no image output)
# out = { w | h << 16 (pixels for the image box), IMG_PROTO_* | cols << 8, background 0xRRGGBB }
PreviewPane_thumb_req:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov rax, [rbx + PreviewPane.app]
    mov rax, [rax + App.theme]
    mov eax, [rax + Theme.surface]
    and eax, 0xFFFFFF
    mov [r12 + 8], eax
    call term_img_proto
    mov r13d, eax
    mov rdi, rbx
    mov esi, r13d
    call pv_box_pixels                # eax = w px, edx = h px, ecx = cols for Kitty scaling
    shl ecx, 8
    or ecx, r13d
    mov [r12 + 4], ecx
    mov [rbx + PreviewPane.req_mode], ecx
    test eax, eax
    jz .Ltr_none
    test edx, edx
    jz .Ltr_none
    shl edx, 16
    or eax, edx
    mov [r12], eax
    jmp .Ltr_ret
.Ltr_none:
    xor eax, eax
    mov [r12], eax
.Ltr_ret:
    pop r13
    pop r12
    pop rbx
    ret

# (int w, int h, int cols) pv_box_pixels(PreviewPane *this, int proto) -- the preview image box
pv_box_pixels:
    mov edx, esi
    mov esi, [rdi + Widget.h]
    sub esi, 5                        # rows (bottom border carries the mode bar)
    mov edi, [rdi + Widget.w]
    sub edi, 2                        # cols
    jmp img_box_pixels

# (int w, int h, int cols) img_box_pixels(int cols, int rows, int proto)
# Image box in output pixels: quadrants 2x2 per cell, half blocks 1x2, pixel protocols use the
# real cell size (Sixel guesses 6x12 when unknown; Kitty then asks the terminal to scale to cols).
img_box_pixels:
    mov r8d, edi
    mov r9d, esi
    mov esi, edx
    xor eax, eax
    xor edx, edx
    xor ecx, ecx
    test r8d, r8d
    jle .Lbp_ret
    test r9d, r9d
    jle .Lbp_ret
    cmp esi, IMG_PROTO_HALF
    je .Lbp_half
    cmp esi, IMG_PROTO_SIXEL
    jae .Lbp_px
    lea eax, [r8d * 2]                # quadrants
    lea edx, [r9d * 2]
    ret
.Lbp_half:
    mov eax, r8d
    lea edx, [r9d * 2]
    ret
.Lbp_px:
    push rsi
    call term_cell_px                 # eax = cw, edx = ch
    pop rsi
    xor ecx, ecx
    test eax, eax
    jz .Lbp_guess
    test edx, edx
    jnz .Lbp_scale
.Lbp_guess:
    mov eax, 6                        # Sixel must never overflow the box: assume tiny cells
    mov edx, 12
    cmp esi, IMG_PROTO_KITTY
    jne .Lbp_scale
    mov eax, 10                       # Kitty scales to the picture's cols itself (c=cols)
    mov edx, 20
    mov ecx, r8d
    cmp ecx, 255
    jbe .Lbp_scale
    mov ecx, 255
.Lbp_scale:
    imul eax, r8d
    imul edx, r9d
    cmp eax, IMG_PX_MAX
    jbe 1f
    mov eax, IMG_PX_MAX
1:  cmp edx, IMG_PX_MAX
    jbe .Lbp_ret
    mov edx, IMG_PX_MAX
.Lbp_ret:
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
