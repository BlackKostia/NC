# Image core: format detection, decode dispatch, RGBA buffer management and area-averaged
# scaling used by the preview helper (thumbnails) and the viewer (fit to window).

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .rodata
str_tga_ext: .asciz ".tga"

.section .text
.global img_detect
.global img_decode
.global img_alloc
.global img_free
.global img_fit
.global img_scale

# int img_detect(const uint8_t *d, size_t n, const char *path) -> IMG_FMT_* (0 = not an image)
img_detect:
    xor eax, eax
    cmp rsi, 4
    jb .Lid_tga
    mov ecx, [rdi]
    cmp ecx, 0x474E5089               # \x89PNG
    je .Lid_png
    mov r8d, ecx
    and r8d, 0x00FFFFFF
    cmp r8d, 0x00FFD8FF
    je .Lid_jpeg
    cmp ecx, 0x38464947               # GIF8
    je .Lid_gif
    cmp ecx, 0x66696F71               # qoif
    je .Lid_qoi
    cmp cx, 0x4D42                    # BM
    je .Lid_bmp
    cmp cl, 'P'
    jne .Lid_riff
    movzx r8d, byte ptr [rdi + 1]
    cmp r8d, '5'
    je .Lid_pnm
    cmp r8d, '6'
    je .Lid_pnm
.Lid_riff:
    cmp ecx, 0x46464952               # RIFF....WEBP
    jne .Lid_tga
    cmp rsi, 12
    jb .Lid_tga
    cmp dword ptr [rdi + 8], 0x50424557
    jne .Lid_tga
    mov eax, IMG_FMT_WEBP
    ret
.Lid_tga:
    cmp rsi, 18
    jb .Lid_none
    test rdx, rdx
    jz .Lid_none
    mov rdi, rdx
    lea rsi, [rip + str_tga_ext]
    jmp img_path_has_ext              # -> IMG_FMT_TGA or 0
.Lid_png:  mov eax, IMG_FMT_PNG;  ret
.Lid_jpeg: mov eax, IMG_FMT_JPEG; ret
.Lid_gif:  mov eax, IMG_FMT_GIF;  ret
.Lid_qoi:  mov eax, IMG_FMT_QOI;  ret
.Lid_bmp:  mov eax, IMG_FMT_BMP;  ret
.Lid_pnm:  mov eax, IMG_FMT_PNM;  ret
.Lid_none:
    xor eax, eax
    ret

# Internal: int img_path_has_ext(const char *path, const char *ext) -> IMG_FMT_TGA or 0
img_path_has_ext:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    call str_len
    cmp rax, 4
    jb .Lphe_no
    lea rdi, [rbx + rax - 4]
    mov rsi, r12
    call str_casecmp
    test eax, eax
    jnz .Lphe_no
    mov eax, IMG_FMT_TGA
    jmp .Lphe_ret
.Lphe_no:
    xor eax, eax
.Lphe_ret:
    add rsp, 8
    pop r12
    pop rbx
    ret

# int img_decode(const uint8_t *d, size_t n, int fmt, Image *out) -> 0 or IMG_E_*
img_decode:
    push rbx
    mov rbx, rcx
    mov qword ptr [rcx + Image.px], 0
    mov [rcx + Image.fmt], edx
    mov rcx, rbx
    cmp edx, IMG_FMT_PNG;  je .Ldec_png
    cmp edx, IMG_FMT_JPEG; je .Ldec_jpeg
    cmp edx, IMG_FMT_GIF;  je .Ldec_gif
    cmp edx, IMG_FMT_BMP;  je .Ldec_bmp
    cmp edx, IMG_FMT_PNM;  je .Ldec_pnm
    cmp edx, IMG_FMT_TGA;  je .Ldec_tga
    cmp edx, IMG_FMT_QOI;  je .Ldec_qoi
    mov eax, IMG_E_UNSUP
    jmp .Ldec_ret
.Ldec_png:  mov rdx, rbx; call img_png_decode;  jmp .Ldec_chk
.Ldec_jpeg: mov rdx, rbx; call img_jpeg_decode; jmp .Ldec_chk
.Ldec_gif:  mov rdx, rbx; call img_gif_decode;  jmp .Ldec_chk
.Ldec_bmp:  mov rdx, rbx; call img_bmp_decode;  jmp .Ldec_chk
.Ldec_pnm:  mov rdx, rbx; call img_pnm_decode;  jmp .Ldec_chk
.Ldec_tga:  mov rdx, rbx; call img_tga_decode;  jmp .Ldec_chk
.Ldec_qoi:  mov rdx, rbx; call img_qoi_decode
.Ldec_chk:
    test eax, eax
    jz .Ldec_ret
    push rax
    mov rdi, rbx
    call img_free                     # never leak a half-decoded picture
    pop rax
.Ldec_ret:
    pop rbx
    ret

# int img_alloc(Image *img, int w, int h) -> 0, IMG_E_CORRUPT (bad size) or IMG_E_NOMEM
img_alloc:
    push rbx
    mov rbx, rdi
    mov eax, IMG_E_CORRUPT
    test esi, esi
    jle .Lia_ret
    test edx, edx
    jle .Lia_ret
    cmp esi, IMG_MAX_DIM
    ja .Lia_ret
    cmp edx, IMG_MAX_DIM
    ja .Lia_ret
    mov [rbx + Image.w], esi
    mov [rbx + Image.h], edx
    mov eax, esi
    imul rax, rdx
    cmp rax, IMG_MAX_PIXELS
    ja .Lia_big
    lea rdi, [rax * 4]
    call mem_alloc
    mov [rbx + Image.px], rax
    test rax, rax
    jz .Lia_nomem
    xor eax, eax
    jmp .Lia_ret
.Lia_big:
    mov eax, IMG_E_UNSUP
    jmp .Lia_ret
.Lia_nomem:
    mov eax, IMG_E_NOMEM
.Lia_ret:
    pop rbx
    ret

# void img_free(Image *img) -- safe on an empty image
img_free:
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + Image.px]
    call mem_free
    mov qword ptr [rbx + Image.px], 0
    pop rbx
    ret

# (int ow, int oh) img_fit(int iw, int ih, int bw, int bh) -> eax = ow, edx = oh
# Largest size with the source aspect ratio that fits the box (scales up and down), >= 1x1.
img_fit:
    mov r8d, edi                      # iw
    mov r9d, esi                      # ih
    mov r10d, edx                     # bw
    mov r11d, ecx                     # bh
    mov eax, r9d                      # width-bound: oh = ih * bw / iw
    imul rax, r10
    xor edx, edx
    div r8
    cmp rax, r11
    jbe .Lif_wb
    mov eax, r8d                      # height-bound: ow = iw * bh / ih
    imul rax, r11
    xor edx, edx
    div r9
    mov edx, r11d
    jmp .Lif_clamp
.Lif_wb:
    mov edx, eax
    mov eax, r10d
.Lif_clamp:
    test eax, eax
    jg .Lif_h
    mov eax, 1
.Lif_h:
    test edx, edx
    jg .Lif_ret
    mov edx, 1
.Lif_ret:
    ret

# void img_scale(const Image *src, uint8_t *dst_rgba, int ow, int oh)
# Area-averaged downscale / nearest upscale into an ow x oh RGBA buffer (<= 8x8 taps per pixel).
img_scale:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx                     # ow
    mov r14d, ecx                     # oh
    xor r15d, r15d                    # dy
.Lisc_row:
    cmp r15d, r14d
    jge .Lisc_done
    mov eax, r15d                     # sy0 = dy * ih / oh, sy1 = (dy + 1) * ih / oh
    mov edi, [rbx + Image.h]
    mov esi, r14d
    call isc_span
    mov [rsp], eax
    mov [rsp + 4], edx
    mov dword ptr [rsp + 8], 0        # dx
.Lisc_col:
    mov eax, [rsp + 8]
    cmp eax, r13d
    jge .Lisc_next_row
    mov edi, [rbx + Image.w]
    mov esi, r13d
    call isc_span                     # eax = sx0, edx = sx1
    mov rdi, [rbx + Image.px]
    mov esi, [rbx + Image.w]
    mov ecx, edx
    mov edx, eax
    mov r8d, [rsp]
    mov r9d, [rsp + 4]
    call isc_average
    mov [r12], eax
    add r12, 4
    inc dword ptr [rsp + 8]
    jmp .Lisc_col
.Lisc_next_row:
    inc r15d
    jmp .Lisc_row
.Lisc_done:
    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: (int s0, int s1) isc_span(int i /*eax*/, int src_len /*edi*/, int dst_len /*esi*/)
# s0 = i * src / dst, s1 = max(s0 + 1, (i + 1) * src / dst)
isc_span:
    mov ecx, eax
    imul rax, rdi
    xor edx, edx
    div rsi
    mov r8d, eax
    lea eax, [ecx + 1]
    imul rax, rdi
    xor edx, edx
    div rsi
    mov edx, eax
    mov eax, r8d
    cmp edx, eax
    jg .Lisp_ret
    lea edx, [eax + 1]
.Lisp_ret:
    ret

# Internal: uint32_t isc_average(const uint8_t *px, int iw, int sx0, int sx1, int sy0, int sy1)
isc_average:
    push rbx
    push r12
    push r13
    sub rsp, 32                       # [0]=R [8]=G [16]=B [24]=A sums (u64)
    mov qword ptr [rsp], 0
    mov qword ptr [rsp + 8], 0
    mov qword ptr [rsp + 16], 0
    mov qword ptr [rsp + 24], 0
    xor ebx, ebx                      # taps
    mov r10d, ecx                     # step_x = max(1, (sx1 - sx0) / 8)
    sub r10d, edx
    shr r10d, 3
    jnz 1f
    mov r10d, 1
1:  mov r11d, r9d                     # step_y
    sub r11d, r8d
    shr r11d, 3
    jnz 2f
    mov r11d, 1
2:
.Lisa_y:
    cmp r8d, r9d
    jge .Lisa_div
    mov r12d, edx
.Lisa_x:
    cmp r12d, ecx
    jge .Lisa_ny
    mov eax, r8d
    imul eax, esi
    add eax, r12d
    lea r13, [rdi + rax * 4]
    movzx eax, byte ptr [r13];     add [rsp], rax
    movzx eax, byte ptr [r13 + 1]; add [rsp + 8], rax
    movzx eax, byte ptr [r13 + 2]; add [rsp + 16], rax
    movzx eax, byte ptr [r13 + 3]; add [rsp + 24], rax
    inc ebx
    add r12d, r10d
    jmp .Lisa_x
.Lisa_ny:
    add r8d, r11d
    jmp .Lisa_y
.Lisa_div:
    xor r12d, r12d                    # packed result
    mov r13d, 3
.Lisa_ch:
    mov rax, [rsp + r13 * 8]
    xor edx, edx
    div rbx
    shl r12d, 8
    or r12d, eax
    dec r13d
    jns .Lisa_ch
    mov eax, r12d                     # A<<24 | B<<16 | G<<8 | R == bytes R,G,B,A in memory
    add rsp, 32
    pop r13
    pop r12
    pop rbx
    ret
