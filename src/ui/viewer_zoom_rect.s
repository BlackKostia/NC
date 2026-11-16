# ViewerDialog image zoom crop geometry and zoom badge rendering.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .text
.global vim_zoom_rect
.global vim_draw_zoom_badge
.global vim_kitty_pan

# Internal: void vz_axis_crop(int img_dim, int box_dim, int zoom, int *pan, int *out_t, int *out_s)
vz_axis_crop:
    push rbx
    test edi, edi; jg 0f; mov edi, 1
0:  test esi, esi; jg 10f; mov esi, 1
10: mov rbx, r9                       # out_s
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
    cmp dword ptr [rbx + ViewerDialog.img_braille], 0
    je 1f
    mov word ptr [r14], 0x4220        # " B"
    add r14, 2
1:  mov word ptr [r14], 0x005D        # "]\0"
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

# int vim_kitty_pan(ViewerDialog *v, int proto, ImgPlace *p) -> 1 if handled
vim_kitty_pan:
    cmp esi, IMG_PROTO_KITTY; jne .Lkp_no
    cmp dword ptr [rdi + ViewerDialog.img_zoom], 0; jne 0f
    sub rsp, 8; xor edi, edi; call img_overlay_kitty_mark; add rsp, 8
.Lkp_no:
    xor eax, eax; ret
0:  mov eax, [rdi + ViewerDialog.img + Image.w]; imul eax, [rdi + ViewerDialog.img + Image.h]
    cmp eax, 16777216; ja .Lkp_no
    push rbx; push r12; push r13; sub rsp, 48
    mov rbx, rdi; mov r12, rdx
    mov esi, [r12 + 48]; mov edx, [r12 + 52]; xor ecx, ecx
    lea r8, [rsp + 32]; lea r9, [rsp + 36]; lea rax, [rsp + 16]; mov [rsp], rax
    call vim_zoom_rect
    mov rdi, [rbx + ViewerDialog.img + Image.px]
    call img_overlay_kitty_ready; test eax, eax; jnz .Lkp_enc
    mov eax, [rbx + ViewerDialog.img + Image.w]; imul eax, [rbx + ViewerDialog.img + Image.h]
    lea r13, [rax * 8 + 65536]; mov rdi, r13; call mem_alloc
    test rax, rax; jz .Lkp_fail; mov r13, rax
    mov rdi, [rbx + ViewerDialog.img + Image.px]
    mov esi, [rbx + ViewerDialog.img + Image.w]; mov edx, [rbx + ViewerDialog.img + Image.h]
    mov ecx, -1; mov r8, r13; mov eax, [rbx + ViewerDialog.img + Image.w]
    imul eax, [rbx + ViewerDialog.img + Image.h]; lea r9, [rax * 8 + 65536]
    call img_kitty_encode; mov [rsp + 40], rax
    test rax, rax; jz 1f
    mov edi, STDOUT_FD; mov rsi, r13; mov rdx, rax; call sys_write_all
    mov rdi, [rbx + ViewerDialog.img + Image.px]; call img_overlay_kitty_mark
1:  mov rdi, r13; call mem_free; mov rax, [rsp + 40]; test rax, rax; jz .Lkp_fail
.Lkp_enc:
    mov rax, 0x4B50414E
    cmp qword ptr [rbx + ViewerDialog.enc], 0; je 2f
    cmp rax, [rbx + ViewerDialog.enc_key]; je 3f
2:  mov rdi, [rbx + ViewerDialog.enc]; call mem_free
    mov edi, 128; call mem_alloc; mov [rbx + ViewerDialog.enc], rax
    test rax, rax; jz .Lkp_fail
    mov qword ptr [rbx + ViewerDialog.enc_key], 0x4B50414E
3:  mov eax, [rsp + 32]; mov [rbx + ViewerDialog.thumb_w], eax
    mov eax, [rsp + 36]; mov [rbx + ViewerDialog.thumb_h], eax
    mov eax, [rbx + ViewerDialog.img_zoom]; shl rax, 32
    mov ecx, [rbx + ViewerDialog.img_pan_y]; and ecx, 0xFFFF; shl rcx, 16; or rax, rcx
    mov ecx, [rbx + ViewerDialog.img_pan_x]; and ecx, 0xFFFF; or rax, rcx
    mov [rbx + ViewerDialog.img_cache_key], rax
    mov rdi, rbx; mov rsi, r12; call vim_place
    mov rdi, [rbx + ViewerDialog.enc]; lea rsi, [rsp + 16]
    mov edx, [r12 + ImgPlace.w]; mov ecx, [r12 + ImgPlace.h]; call img_kitty_place
    mov [rbx + ViewerDialog.enc_len], rax; mov [r12 + ImgPlace.len], rax
    mov rdi, r12; call img_overlay_show; mov eax, 1; jmp .Lkp_ret
.Lkp_fail: xor eax, eax
.Lkp_ret: add rsp, 48; pop r13; pop r12; pop rbx; ret
