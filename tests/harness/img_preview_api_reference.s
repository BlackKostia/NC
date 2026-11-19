# Frozen reference oracle: the hand-written asm that src/ui/img_preview_api.c replaced (tests/test_c_img_preview_api.py diffs against it)
# Image preview placement: the payload produced by the preview helper is drawn as quadrant or
# half blocks into cells, or handed to the overlay (Sixel / Kitty) centred in the image box.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .text
.global img_preview_try_render

# int img_preview_try_render(PreviewPane *pv, ScreenBuffer *sb, Theme *th)
img_preview_try_render:
    xor eax, eax
    cmp dword ptr [rdi + PreviewPane.thumb_len], IMG_THUMB_HDR
    jb .Liptr_ret
    push rbx
    push r12
    push r13
    sub rsp, 64                       # ImgView (24) | ImgPlace (48) reuse
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rax, [rbx + PreviewPane.thumb_ptr]
    cmp word ptr [rax + 12], 0
    je .Liptr_unsup
    movzx ecx, byte ptr [rbx + PreviewPane.thumb_mode]
    cmp ecx, IMG_PROTO_SIXEL
    jae .Liptr_pixels
    lea rcx, [rax + IMG_THUMB_HDR]
    mov [rsp], rcx
    movzx ecx, word ptr [rax + 12]
    mov [rsp + 8], ecx
    movzx ecx, word ptr [rax + 14]
    mov [rsp + 12], ecx
    mov ecx, [r13 + Theme.surface]
    mov [rsp + 16], ecx
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    inc esi
    mov edx, [rbx + Widget.y]
    add edx, 3
    mov ecx, [rbx + Widget.w]
    sub ecx, 2
    mov r8d, [rbx + Widget.h]
    sub r8d, 5
    mov r9, rsp
    cmp byte ptr [rbx + PreviewPane.thumb_mode], IMG_PROTO_HALF
    je .Liptr_half
    call img_draw_quad
    jmp .Liptr_done
.Liptr_half:
    call img_draw_rgba
    jmp .Liptr_done
.Liptr_pixels:
    cmp dword ptr [rbx + PreviewPane.thumb_len], IMG_THUMB_HDR + 16
    jb .Liptr_unsup
    mov rdi, rbx
    mov rsi, rsp
    call iptr_place
    mov rdi, rsp
    call img_overlay_show
    jmp .Liptr_done
.Liptr_unsup:
    mov rdi, r12
    mov esi, [r13 + Theme.warn_fg]
    mov edx, [r13 + Theme.surface]
    xor ecx, ecx
    call ScreenBuffer_set_pen
    call i18n_get
    mov rcx, [rax + LangStrings.img_unsup]
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 2
    mov edx, [rbx + Widget.y]
    add edx, 3
    mov r8d, [rbx + Widget.w]
    sub r8d, 4
    call ScreenBuffer_draw_text
.Liptr_done:
    mov eax, 1
    add rsp, 64
    pop r13
    pop r12
    pop rbx
.Liptr_ret:
    ret

# Internal: void iptr_place(PreviewPane *pv, ImgPlace *out) -- cells covered by the picture, centred
iptr_place:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    mov [r12 + ImgPlace.owner], rbx
    mov rax, [rbx + PreviewPane.thumb_ptr]
    lea rcx, [rax + IMG_THUMB_HDR]
    mov [r12 + ImgPlace.data], rcx
    mov ecx, [rbx + PreviewPane.thumb_len]
    sub ecx, IMG_THUMB_HDR
    mov [r12 + ImgPlace.len], rcx
    mov ecx, [rbx + PreviewPane.thumb_gen]
    mov [r12 + ImgPlace.key], rcx
    movzx r13d, word ptr [rax + 12]   # picture pixels
    movzx r14d, word ptr [rax + 14]
    mov rdi, rbx
    movzx esi, byte ptr [rbx + PreviewPane.thumb_mode]
    call pv_box_pixels                # eax = box px w, edx = box px h, ecx = Kitty cols
    mov r8d, [rbx + Widget.w]
    sub r8d, 2                        # box cols / rows
    mov r9d, [rbx + Widget.h]
    sub r9d, 5
    mov r10d, eax                     # pixels per cell = box px / box cells
    mov eax, r13d                     # cols = ceil(pic w * box cols / box px w)
    imul eax, r8d
    add eax, r10d
    dec eax
    push rdx
    xor edx, edx
    div r10d
    pop rdx
    mov [r12 + ImgPlace.w], eax
    mov r10d, edx
    mov eax, r14d                     # rows = ceil(pic h * box rows / box px h)
    imul eax, r9d
    add eax, r10d
    dec eax
    xor edx, edx
    div r10d
    mov [r12 + ImgPlace.h], eax
    mov eax, r8d                      # centre in the box
    sub eax, [r12 + ImgPlace.w]
    sar eax, 1
    add eax, [rbx + Widget.x]
    inc eax
    mov [r12 + ImgPlace.x], eax
    mov eax, r9d
    sub eax, [r12 + ImgPlace.h]
    sar eax, 1
    add eax, [rbx + Widget.y]
    add eax, 3
    mov [r12 + ImgPlace.y], eax
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
