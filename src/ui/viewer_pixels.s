# ViewerDialog picture output in the best available form: the decoded image is scaled to the
# window (cached per size) and drawn as quadrant / half blocks, or encoded once into a Sixel /
# Kitty stream (cached per protocol and size) that the overlay places over the window.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .text
.global vim_draw_picture
.global vim_place

# void vim_draw_picture(ViewerDialog *v, ScreenBuffer *scr, Theme *theme)
vim_draw_picture:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 72                       # ImgView / ImgPlace, [56] = Kitty cols
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    call term_img_proto
    mov r14d, eax
    mov edi, [rbx + Widget.w]
    sub edi, 2
    mov esi, [rbx + Widget.h]
    sub esi, 3
    mov edx, r14d
    call img_box_pixels               # eax = box px w, edx = box px h, ecx = Kitty cols
    cmp r14d, IMG_PROTO_SIXEL
    jae 4f
    cmp dword ptr [rbx + ViewerDialog.img_braille], 0
    je 4f
    mov edx, [rbx + Widget.h]
    sub edx, 3
    shl edx, 2                        # 2x4 Braille: 4 vertical subpixels per cell
4:  mov [rsp + 48], eax
    mov [rsp + 52], edx
    mov [rsp + 56], ecx
    mov rdi, rbx
    mov esi, r14d
    mov rdx, rsp
    call vim_kitty_pan
    test eax, eax
    jnz .Ldp_ret
    mov rdi, rbx
    mov esi, [rsp + 48]
    mov edx, [rsp + 52]
    xor ecx, ecx
    cmp r14d, IMG_PROTO_SIXEL
    setb cl                           # block output fills the window, pixels never upscale
    call vim_fit_thumb
    test eax, eax
    jz .Ldp_ret
    cmp r14d, IMG_PROTO_SIXEL
    jae .Ldp_pixels
    mov rax, [rbx + ViewerDialog.thumb]
    mov [rsp], rax
    mov eax, [rbx + ViewerDialog.thumb_w]
    mov [rsp + 8], eax
    mov eax, [rbx + ViewerDialog.thumb_h]
    mov [rsp + 12], eax
    mov eax, [r13 + Theme.dialog_bg]
    mov [rsp + 16], eax
    mov rdi, r12
    mov rsi, rbx
    mov edx, r14d
    lea rcx, [rsp]
    call vim_block_box
    jmp .Ldp_ret
.Ldp_pixels:
    mov rdi, rbx
    mov esi, r14d
    mov rdx, rsp
    mov ecx, [r13 + Theme.dialog_bg]
    call vim_encode
    test eax, eax
    jz .Ldp_ret
    mov rdi, rbx
    mov rsi, rsp
    call vim_place
    mov rdi, rsp
    call img_overlay_show
.Ldp_ret:
    add rsp, 72
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: void vim_block_box(ScreenBuffer *scr, ViewerDialog *v, int proto, const ImgView *view)
vim_block_box:
    push rbx
    mov rbx, rsi
    mov r10d, edx
    mov r9, rcx
    mov esi, [rbx + Widget.x]
    inc esi
    mov edx, [rbx + Widget.y]
    inc edx
    mov ecx, [rbx + Widget.w]
    sub ecx, 2
    mov r8d, [rbx + Widget.h]
    sub r8d, 3
    cmp dword ptr [rbx + ViewerDialog.img_zoom], 0
    je .Lbb_draw
    mov eax, [rbx + ViewerDialog.thumb_w]
    cmp r10d, IMG_PROTO_HALF
    je 1f
    inc eax
    shr eax, 1
1:  cmp eax, ecx
    jge 2f
    mov r11d, ecx
    sub r11d, eax
    sar r11d, 1
    add esi, r11d
    mov ecx, eax
2:  mov eax, [rbx + ViewerDialog.thumb_h]
    cmp dword ptr [rbx + ViewerDialog.img_braille], 0
    je 3f
    add eax, 3
    shr eax, 2
    jmp 4f
3:  inc eax
    shr eax, 1
4:  cmp eax, r8d
    jge .Lbb_draw
    mov r11d, r8d
    sub r11d, eax
    sar r11d, 1
    add edx, r11d
    mov r8d, eax
.Lbb_draw:
    cmp dword ptr [rbx + ViewerDialog.img_braille], 0
    je 5f
    pop rbx
    jmp img_draw_braille
5:  pop rbx
    cmp r10d, IMG_PROTO_HALF
    je img_draw_rgba
    jmp img_draw_quad

# Internal: int vim_fit_thumb(ViewerDialog *v, int pw, int ph /*edx*/, int upscale /*ecx*/)
# -> 0 on OOM; v->thumb = image scaled into pw x ph (aspect kept; small images stay native
#    unless upscale)
vim_fit_thumb:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 56                       # [0]=rect*, [16..31]=rect[4], [32]=tw, [36]=th
    mov rbx, rdi
    lea r8, [rsp + 32]
    lea r9, [rsp + 36]
    lea rax, [rsp + 16]
    mov [rsp], rax
    call vim_zoom_rect
    mov r12d, [rsp + 32]
    mov r13d, [rsp + 36]
    mov eax, [rbx + ViewerDialog.img_zoom]
    shl rax, 32
    mov ecx, [rbx + ViewerDialog.img_pan_y]
    and ecx, 0xFFFF
    shl rcx, 16
    or rax, rcx
    mov ecx, [rbx + ViewerDialog.img_pan_x]
    and ecx, 0xFFFF
    or rax, rcx
    mov r14, rax                      # desired img_cache_key
    cmp qword ptr [rbx + ViewerDialog.thumb], 0
    je .Lft_new
    cmp r12d, [rbx + ViewerDialog.thumb_w]
    jne .Lft_new
    cmp r13d, [rbx + ViewerDialog.thumb_h]
    jne .Lft_new
    cmp r14, [rbx + ViewerDialog.img_cache_key]
    je .Lft_ok
.Lft_new:
    mov rdi, [rbx + ViewerDialog.thumb]
    call mem_free
    mov qword ptr [rbx + ViewerDialog.thumb], 0
    mov dword ptr [rbx + ViewerDialog.thumb_w], 0
    mov dword ptr [rbx + ViewerDialog.thumb_h], 0
    test r12d, r12d; jle .Lft_fail
    test r13d, r13d; jle .Lft_fail
    mov eax, r12d
    movsxd rcx, r13d
    imul rax, rcx
    cmp rax, IMG_MAX_PIXELS
    ja .Lft_fail
    lea rdi, [rax * 4]
    call mem_alloc
    mov [rbx + ViewerDialog.thumb], rax
    test rax, rax
    jz .Lft_fail
    mov [rbx + ViewerDialog.thumb_w], r12d
    mov [rbx + ViewerDialog.thumb_h], r13d
    mov [rbx + ViewerDialog.img_cache_key], r14
    lea rdi, [rbx + ViewerDialog.img]
    mov rsi, rax
    mov edx, r12d
    mov ecx, r13d
    lea r8, [rsp + 16]
    call img_scale_rect
.Lft_ok:
    mov eax, 1
    jmp .Lft_ret
.Lft_fail:
    xor eax, eax
.Lft_ret:
    add rsp, 56
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: int vim_encode(ViewerDialog *v, int proto, const int *box /*[48] w px, [52] h px,
#                          [56] Kitty cols*/, uint32_t bg) -> enc_len (cached per protocol/size)
vim_encode:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov r14d, ecx
    mov eax, [rbx + ViewerDialog.thumb_w]
    shl rax, 8
    or eax, r12d
    mov ecx, [rbx + ViewerDialog.thumb_h]
    shl rcx, 32
    or rax, rcx
    mov r15, rax                      # key
    cmp qword ptr [rbx + ViewerDialog.enc], 0
    je .Len_build
    cmp r15, [rbx + ViewerDialog.enc_key]
    je .Len_have
.Len_build:
    mov rdi, [rbx + ViewerDialog.enc]
    call mem_free
    mov eax, [rbx + ViewerDialog.thumb_w]
    imul eax, [rbx + ViewerDialog.thumb_h]
    lea rdi, [rax * 8 + 1048576]      # generous: Sixel worst case / base64 RGBA + headers
    mov [rbx + ViewerDialog.enc_len], rdi
    call mem_alloc
    mov [rbx + ViewerDialog.enc], rax
    test rax, rax
    jz .Len_none
    mov [rbx + ViewerDialog.enc_key], r15
    mov rdi, rbx
    mov esi, r12d
    mov rdx, r13
    mov ecx, r14d
    call vim_encode_into
    mov [rbx + ViewerDialog.enc_len], rax
.Len_have:
    mov rax, [rbx + ViewerDialog.enc_len]
    jmp .Len_ret
.Len_none:
    xor eax, eax
    mov [rbx + ViewerDialog.enc_len], rax
.Len_ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: size_t vim_encode_into(ViewerDialog *v, int proto, const int *box, uint32_t bg)
vim_encode_into:
    mov r8, [rdi + ViewerDialog.enc]
    mov r9, [rdi + ViewerDialog.enc_len]       # capacity
    mov r10, rdi
    mov rdi, [r10 + ViewerDialog.thumb]
    mov eax, esi
    mov esi, [r10 + ViewerDialog.thumb_w]
    push rdx
    mov edx, [r10 + ViewerDialog.thumb_h]
    pop r11
    cmp eax, IMG_PROTO_KITTY
    je .Lei_kitty
    and ecx, 0xFFFFFF
    jmp img_sixel_encode
.Lei_kitty:
    mov ecx, [r11 + 56]               # box cols (0 = native pixel size)
    test ecx, ecx
    jz 1f
    cmp dword ptr [r11 + 48], 0
    jle .Lei_zero
    mov eax, esi                      # picture cols = ceil(w * cols / box px w)
    imul eax, ecx
    add eax, [r11 + 48]
    dec eax
    push rdx
    xor edx, edx
    div dword ptr [r11 + 48]
    pop rdx
    mov ecx, eax
1:  jmp img_kitty_encode
.Lei_zero:
    xor eax, eax
    ret

# Internal: void vim_place(ViewerDialog *v, ImgPlace *p /*box px at [48]/[52]*/) -- centred cells
vim_place:
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    mov r8d, [r12 + 48]               # box px
    mov r9d, [r12 + 52]
    test r8d, r8d; jg 1f; mov r8d, 1
1:  test r9d, r9d; jg 2f; mov r9d, 1
2:  mov [r12 + ImgPlace.owner], rbx
    mov rax, [rbx + ViewerDialog.enc]
    mov [r12 + ImgPlace.data], rax
    mov rax, [rbx + ViewerDialog.enc_len]
    mov [r12 + ImgPlace.len], rax
    mov rax, [rbx + ViewerDialog.enc_key]
    xor rax, [rbx + ViewerDialog.img_cache_key]
    xor rax, [rbx + ViewerDialog.enc]
    mov [r12 + ImgPlace.key], rax
    mov ecx, [rbx + Widget.w]
    sub ecx, 2                        # box cols
    mov eax, [rbx + ViewerDialog.thumb_w]
    imul eax, ecx
    add eax, r8d
    dec eax
    xor edx, edx
    div r8d
    mov [r12 + ImgPlace.w], eax
    sub ecx, eax
    sar ecx, 1
    add ecx, [rbx + Widget.x]
    inc ecx
    mov [r12 + ImgPlace.x], ecx
    mov ecx, [rbx + Widget.h]
    sub ecx, 3                        # box rows
    mov eax, [rbx + ViewerDialog.thumb_h]
    imul eax, ecx
    add eax, r9d
    dec eax
    xor edx, edx
    div r9d
    mov [r12 + ImgPlace.h], eax
    sub ecx, eax
    sar ecx, 1
    add ecx, [rbx + Widget.y]
    inc ecx
    mov [r12 + ImgPlace.y], ecx
    pop r12
    pop rbx
    ret
