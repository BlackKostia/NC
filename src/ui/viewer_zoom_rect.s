# ViewerDialog image zoom crop geometry and zoom badge rendering.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .text
.global vim_zoom_rect
.global vim_draw_zoom_badge

# Internal: void vz_axis_crop(int img_dim, int box_dim, int zoom, int *pan, int *out_t, int *out_s)
vz_axis_crop:
    push rbx
    mov rbx, r9                       # out_s
    mov r10d, edx                     # zoom
    mov eax, edi
    imul eax, r10d
    xor edx, edx
    push rcx
    mov ecx, 100
    div ecx
    pop rcx
    test eax, eax; jnz 1f; mov eax, 1
1:  cmp eax, esi; jbe 2f; mov eax, esi
2:  mov [r8], eax                     # *out_t
    imul eax, 100
    xor edx, edx
    div r10d
    test eax, eax; jnz 3f; mov eax, 1
3:  cmp eax, edi; jbe 4f; mov eax, edi
4:  mov [rbx], eax                    # *out_s
    sub edi, eax                      # max_pan = img_dim - sw
    mov eax, [rcx]
    test eax, eax; jns 5f; xor eax, eax
5:  cmp eax, edi; jle 6f; mov eax, edi
6:  mov [rcx], eax                    # *pan = clamped
    pop rbx
    ret

# void vim_zoom_rect(ViewerDialog *v, int box_w, int box_h, int upscale,
#                    int *out_tw, int *out_th, int *out_rect /*x,y,w,h*/)
vim_zoom_rect:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, 24                       # [0]=out_tw [8]=out_th [16]=out_rect
    mov rbx, rdi; mov r12d, esi; mov r13d, edx; mov r14d, ecx
    mov [rsp], r8; mov [rsp + 8], r9
    mov rax, [rsp + 72]; mov [rsp + 16], rax
    mov [rbx + ViewerDialog.img_box_w], r12d
    mov [rbx + ViewerDialog.img_box_h], r13d
    mov r15d, [rbx + ViewerDialog.img_zoom]
    test r15d, r15d
    jnz .Lzr_zoomed
    mov eax, [rbx + ViewerDialog.img + Image.w]
    mov r8d, [rbx + ViewerDialog.img + Image.h]
    test r14d, r14d; jnz .Lzr_fit
    cmp eax, r12d; ja .Lzr_fit
    cmp r8d, r13d; jbe .Lzr_fit_ok
.Lzr_fit:
    mov edi, eax; mov esi, r8d; mov edx, r12d; mov ecx, r13d
    call img_fit
    mov r8d, edx
.Lzr_fit_ok:
    mov rcx, [rsp]; mov [rcx], eax
    mov rcx, [rsp + 8]; mov [rcx], r8d
    mov rcx, [rsp + 16]
    mov dword ptr [rcx], 0; mov dword ptr [rcx + 4], 0
    mov eax, [rbx + ViewerDialog.img + Image.w]; mov [rcx + 8], eax
    mov eax, [rbx + ViewerDialog.img + Image.h]; mov [rcx + 12], eax
    jmp .Lzr_done
.Lzr_zoomed:
    mov r14, [rsp + 16]               # out_rect
    mov edi, [rbx + ViewerDialog.img + Image.w]
    mov esi, r12d; mov edx, r15d
    lea rcx, [rbx + ViewerDialog.img_pan_x]
    mov r8, [rsp]; lea r9, [r14 + 8]
    call vz_axis_crop
    mov eax, [rbx + ViewerDialog.img_pan_x]; mov [r14], eax
    mov edi, [rbx + ViewerDialog.img + Image.h]
    mov esi, r13d; mov edx, r15d
    lea rcx, [rbx + ViewerDialog.img_pan_y]
    mov r8, [rsp + 8]; lea r9, [r14 + 12]
    call vz_axis_crop
    mov eax, [rbx + ViewerDialog.img_pan_y]; mov [r14 + 4], eax
.Lzr_done:
    add rsp, 24
    pop r15; pop r14; pop r13; pop r12; pop rbx
    ret

# void vim_draw_zoom_badge(ViewerDialog *v, ScreenBuffer *scr, Theme *th)
vim_draw_zoom_badge:
    push rbx; push r12; push r13; push r14
    sub rsp, 56
    mov rbx, rdi; mov r12, rsi; mov r13, rdx
    cmp dword ptr [rbx + ViewerDialog.img_state], 1
    jne .Lzb_ret
    mov r14, rsp
    mov edi, [rbx + ViewerDialog.img + Image.w]
    mov rsi, r14; call u64_to_dec; add r14, rax
    mov byte ptr [r14], 'x'; inc r14
    mov edi, [rbx + ViewerDialog.img + Image.h]
    mov rsi, r14; call u64_to_dec; add r14, rax
    mov word ptr [r14], 0x5B20        # " ["
    add r14, 2
    mov edi, [rbx + ViewerDialog.img_zoom]
    test edi, edi
    jz .Lzb_fit
    mov rsi, r14; call u64_to_dec; add r14, rax
    mov byte ptr [r14], '%'; inc r14
    jmp .Lzb_end
.Lzb_fit:
    call i18n_get
    mov rsi, [rax + LangStrings.img_fit]
    mov rdi, r14; mov edx, 24; call str_copy
    add r14, rax
.Lzb_end:
    mov word ptr [r14], 0x005D        # "]\0"
    mov rdi, r12; mov esi, [r13 + Theme.accent]
    mov edx, [r13 + Theme.dialog_bg]; xor ecx, ecx
    call ScreenBuffer_set_pen
    mov rdi, rsp; call utf8_display_width; mov r8d, eax
    mov esi, [rbx + Widget.x]; add esi, [rbx + Widget.w]; sub esi, r8d; sub esi, 2
    mov edx, [rbx + Widget.y]; add edx, [rbx + Widget.h]; sub edx, 2
    mov rdi, r12; mov rcx, rsp
    call ScreenBuffer_draw_text
.Lzb_ret:
    add rsp, 56
    pop r14; pop r13; pop r12; pop rbx
    ret
