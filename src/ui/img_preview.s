# src/ui/img_preview.s - Terminal Image Preview (Kitty Graphics Protocol + Half-Block Fallback)

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"
.equ IMG_MAX_RAW, 262144      # 256 KiB max PNG payload
.extern env_getenv
.extern str_casecmp
.extern str_contains_ci
.extern str_copy
.extern u64_to_dec
.extern sys_write_all
.extern fs_read_file_head
.extern inflate_zlib
.extern mem_alloc
.extern mem_free
.extern ScreenBuffer_set_pen
.extern ScreenBuffer_set_cell

.section .rodata

b64_table:      .ascii "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
env_img_mode:   .asciz "DUOP_IMG_MODE"
val_halfblock:  .asciz "halfblock"
env_kitty_id:   .asciz "KITTY_WINDOW_ID"
env_term:       .asciz "TERM"
val_kitty:      .asciz "kitty"
seq_kitty_end:  .asciz "\x1b\\"

.section .text
.global img_is_kitty_mode
.global b64_encode
.global png_draw_halfblock

# int img_is_kitty_mode(PreviewPane *pv)
img_is_kitty_mode:
    push rbx
    mov rax, [rdi + PreviewPane.app]
    mov rbx, [rax + App.envp]
    mov rdi, rbx
    lea rsi, [rip + env_img_mode]
    call env_getenv
    test rax, rax
    jz .Likm_chk_env
    mov rdi, rax
    lea rsi, [rip + val_halfblock]
    call str_casecmp
    test eax, eax
    jz .Likm_no
.Likm_chk_env:
    mov rdi, rbx
    lea rsi, [rip + env_kitty_id]
    call env_getenv
    test rax, rax
    jnz .Likm_yes
    mov rdi, rbx
    lea rsi, [rip + env_term]
    call env_getenv
    test rax, rax
    jz .Likm_no
    mov rdi, rax
    lea rsi, [rip + val_kitty]
    call str_contains_ci
    test eax, eax
    jnz .Likm_yes
.Likm_no:
    xor eax, eax
    pop rbx
    ret
.Likm_yes:
    mov eax, 1
    pop rbx
    ret

# uint32_t read_be32(const uint8_t *p)
read_be32:
    mov eax, [rdi]
    bswap eax
    ret

# void b64_encode(const uint8_t *src, size_t len, char *dst, size_t *out_len)
b64_encode:
    push rbx
    push r12
    lea r8, [rip + b64_table]
    mov r9, rdx               # dst start
    xor r10d, r10d            # i = 0
.Lb64_loop:
    cmp r10, rsi
    jae .Lb64_done
    movzx eax, byte ptr [rdi + r10]
    shl eax, 16
    mov r11d, 1
    lea r12, [r10 + 1]
    cmp r12, rsi
    jae .Lb64_b2
    movzx ebx, byte ptr [rdi + r12]
    shl ebx, 8
    or eax, ebx
    inc r11d
.Lb64_b2:
    lea r12, [r10 + 2]
    cmp r12, rsi
    jae .Lb64_emit
    movzx ebx, byte ptr [rdi + r12]
    or eax, ebx
    inc r11d
.Lb64_emit:
    mov ebx, eax
    shr ebx, 18
    and ebx, 63
    mov bl, [r8 + rbx]
    mov [rdx], bl
    mov ebx, eax
    shr ebx, 12
    and ebx, 63
    mov bl, [r8 + rbx]
    mov [rdx + 1], bl
    mov bl, '='
    cmp r11d, 2
    jl .Lb64_p3
    mov ebx, eax
    shr ebx, 6
    and ebx, 63
    mov bl, [r8 + rbx]
.Lb64_p3:
    mov [rdx + 2], bl
    mov bl, '='
    cmp r11d, 3
    jl .Lb64_p4
    mov ebx, eax
    and ebx, 63
    mov bl, [r8 + rbx]
.Lb64_p4:
    mov [rdx + 3], bl
    add rdx, 4
    add r10, 3
    jmp .Lb64_loop
.Lb64_done:
    mov byte ptr [rdx], 0
    sub rdx, r9
    mov [rcx], rdx
    pop r12
    pop rbx
    ret

# Helper: int png_paeth(int a, int b, int c)
png_paeth:
    mov r8d, edi
    add r8d, esi
    sub r8d, edx              # p = a + b - c
    mov r9d, r8d; sub r9d, edi; jns .Lpp_a; neg r9d
.Lpp_a:
    mov r10d, r8d; sub r10d, esi; jns .Lpp_b; neg r10d
.Lpp_b:
    mov r11d, r8d; sub r11d, edx; jns .Lpp_c; neg r11d
.Lpp_c:
    cmp r9d, r10d; jg .Lpp_bc
    cmp r9d, r11d; jg .Lpp_rc
    mov eax, edi; ret
.Lpp_bc:
    cmp r10d, r11d; jg .Lpp_rc
    mov eax, esi; ret
.Lpp_rc:
    mov eax, edx; ret

# Helper: void png_unfilter(uint8_t *raw, int w, int h, int bpp)
# Unfilters in-place; row stride = 1 + w * bpp
png_unfilter:
    push rbx; push r12; push r13; push r14; push r15
    mov rbx, rdi              # raw
    mov r12d, esi             # w
    mov r13d, edx             # h
    mov r14d, ecx             # bpp
    imul r12d, r14d           # row_bytes = w * bpp
    lea r15d, [r12d + 1]      # stride
    xor ecx, ecx              # y = 0
.Lpuf_y:
    cmp ecx, r13d; jge .Lpuf_done
    mov rax, rcx; imul rax, r15
    lea r8, [rbx + rax]       # row ptr
    movzx r9d, byte ptr [r8]  # filter type
    inc r8                    # pixels
    test r9d, r9d; jz .Lpuf_next_y
    xor edx, edx              # x = 0
.Lpuf_x:
    cmp edx, r12d; jge .Lpuf_next_y
    xor edi, edi              # a (left)
    cmp edx, r14d; jl .Lpuf_b
    mov eax, edx; sub eax, r14d
    movzx edi, byte ptr [r8 + rax]
.Lpuf_b:
    xor esi, esi              # b (up)
    test ecx, ecx; jz .Lpuf_c
    mov rax, r8; sub rax, r15
    movzx esi, byte ptr [rax + rdx]
.Lpuf_c:
    xor eax, eax              # c (up-left)
    test ecx, ecx; jz .Lpuf_apply
    cmp edx, r14d; jl .Lpuf_apply
    mov r10d, edx; sub r10d, r14d
    mov r11, r8; sub r11, r15
    movzx eax, byte ptr [r11 + r10]
.Lpuf_apply:
    cmp r9d, 1; jne .Lpuf_f2
    add [r8 + rdx], dil; jmp .Lpuf_nx
.Lpuf_f2:
    cmp r9d, 2; jne .Lpuf_f3
    add [r8 + rdx], sil; jmp .Lpuf_nx
.Lpuf_f3:
    cmp r9d, 3; jne .Lpuf_f4
    add edi, esi; shr edi, 1; add [r8 + rdx], dil; jmp .Lpuf_nx
.Lpuf_f4:
    cmp r9d, 4; jne .Lpuf_nx
    push rdx; push r8; push r9; push rcx
    mov edx, eax; call png_paeth
    pop rcx; pop r9; pop r8; pop rdx
    add [r8 + rdx], al
.Lpuf_nx:
    inc edx; jmp .Lpuf_x
.Lpuf_next_y:
    inc ecx; jmp .Lpuf_y
.Lpuf_done:
    pop r15; pop r14; pop r13; pop r12; pop rbx; ret

# Helper: uint32_t png_sample_rgb(uint8_t *raw, int img_w, int img_h, int bpp, int sx, int sy)
png_sample_rgb:
    mov r10d, [rsp + 8]       # sy
    cmp r10d, edx; jl .Lpsr_yok; mov r10d, edx; dec r10d
.Lpsr_yok:
    cmp r9d, esi; jl .Lpsr_xok; mov r9d, esi; dec r9d
.Lpsr_xok:
    mov eax, esi; imul eax, ecx; inc eax  # stride
    imul r10d, eax
    imul r9d, ecx
    add r10d, r9d
    inc r10d                  # skip filter byte
    movzx eax, byte ptr [rdi + r10]
    shl eax, 16
    movzx r8d, byte ptr [rdi + r10 + 1]
    shl r8d, 8
    or eax, r8d
    movzx r8d, byte ptr [rdi + r10 + 2]
    or eax, r8d
    ret

# Helper: int png_draw_halfblock(PreviewPane *pv, ScreenBuffer *sb)
png_draw_halfblock:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, 48
    # [rsp+0]=img_w, [4]=img_h, [8]=bpp, [16]=raw_ptr, [24]=idat_buf, [32]=box_w, [36]=box_h
    mov rbx, rdi; mov r12, rsi
    mov r13, [rbx + PreviewPane.buf]
    mov r14, [rbx + PreviewPane.buf_len]
    cmp r14, 33; jb .Lpdh_fail
    # Check IHDR at offset 8: len(4), "IHDR"(4), w(4), h(4), depth(1), ctype(1)
    cmp dword ptr [r13 + 12], 0x52444849  # "IHDR"
    jne .Lpdh_fail
    lea rdi, [r13 + 16]; call read_be32; mov [rsp], eax
    lea rdi, [r13 + 20]; call read_be32; mov [rsp + 4], eax
    test eax, eax; jz .Lpdh_fail
    cmp dword ptr [rsp], 0; jle .Lpdh_fail
    cmp byte ptr [r13 + 24], 8; jne .Lpdh_fail
    movzx eax, byte ptr [r13 + 25]
    mov ecx, 3; cmp eax, 2; je .Lpdh_bpp
    mov ecx, 4; cmp eax, 6; jne .Lpdh_fail
.Lpdh_bpp:
    mov [rsp + 8], ecx
    # Gather IDAT chunks
    mov rdi, r14; call mem_alloc; mov [rsp + 24], rax
    test rax, rax; jz .Lpdh_fail
    call png_draw_halfblock__idat_len
    test r15d, r15d; jz .Lpdh_free_idat
    mov eax, [rsp]; imul eax, [rsp + 8]; inc eax; imul eax, [rsp + 4]
    cmp eax, 4194304; ja .Lpdh_free_idat
    mov edi, eax; push rax; call mem_alloc; pop rcx
    mov [rsp + 16], rax; test rax, rax; jz .Lpdh_free_idat
    mov rdi, [rsp + 24]; mov rsi, r15; mov rdx, rax
    call inflate_zlib
    test rax, rax; js .Lpdh_free_raw
    call png_draw_halfblock__render_half_blocks_preview
.Lpdh_cy:
    cmp r14d, [rsp + 36]; jge .Lpdh_ok
    xor r15d, r15d            # cx
.Lpdh_cx:
    cmp r15d, [rsp + 32]; jge .Lpdh_ny
    # sx = cx * img_w / box_w
    mov eax, r15d; imul eax, [rsp]; xor edx, edx; div dword ptr [rsp + 32]; mov r9d, eax
    # sy_top = (cy*2) * img_h / (box_h*2)
    mov eax, r14d; shl eax, 1; imul eax, [rsp + 4]; xor edx, edx
    mov ecx, [rsp + 36]; shl ecx, 1; div ecx
    push r9; push rax
    mov rdi, [rsp + 32]; mov esi, [rsp + 16]; mov edx, [rsp + 20]; mov ecx, [rsp + 24]
    mov r9d, [rsp + 8]
    call png_sample_rgb
    add rsp, 8; pop r9; push rax
    mov eax, r14d; shl eax, 1; inc eax; imul eax, [rsp + 12]; xor edx, edx
    mov ecx, [rsp + 44]; shl ecx, 1; div ecx
    push rax
    mov rdi, [rsp + 32]; mov esi, [rsp + 16]; mov edx, [rsp + 20]; mov ecx, [rsp + 24]
    call png_sample_rgb
    add rsp, 8; pop rsi       # rsi = top_rgb, eax = bot_rgb
    mov rdi, r12; mov edx, eax; xor ecx, ecx; call ScreenBuffer_set_pen
    mov rdi, r12; mov esi, [rbx + Widget.x]; inc esi; add esi, r15d
    mov edx, [rbx + Widget.y]; add edx, 3; add edx, r14d
    mov ecx, 0x2580; call ScreenBuffer_set_cell
    inc r15d; jmp .Lpdh_cx
.Lpdh_ny:
    inc r14d; jmp .Lpdh_cy
.Lpdh_ok:
    mov rdi, [rsp + 16]; call mem_free
    mov rdi, [rsp + 24]; call mem_free
    mov eax, 1; jmp .Lpdh_ret
.Lpdh_free_raw:
    mov rdi, [rsp + 16]; call mem_free
.Lpdh_free_idat:
    mov rdi, [rsp + 24]; call mem_free
.Lpdh_fail:
    xor eax, eax
.Lpdh_ret:
    add rsp, 48; pop r15; pop r14; pop r13; pop r12; pop rbx; ret

# png_draw_halfblock step: idat_len (runs on the caller's frame)
png_draw_halfblock__idat_len:
    lea rsp, [rsp - 8]
    xor r15d, r15d            # idat_len
    mov r8d, 8                # offset
.Lpdh_chk:
    lea r9, [r8 + 12]; cmp r9, r14; ja .Lpdh_inf
    lea rdi, [r13 + r8]; call read_be32; mov ecx, eax
    lea r9, [r8 + 12]; add r9, rcx; cmp r9, r14; ja .Lpdh_inf
    cmp dword ptr [r13 + r8 + 4], 0x54414449  # "IDAT"
    jne .Lpdh_next_chk
    lea r11, [r13 + r8 + 8]
    xor edx, edx
.Lpdh_cp_idat:
    cmp edx, ecx; jge .Lpdh_next_chk
    mov al, [r11 + rdx]
    mov r10, [rsp + 24 + 16]; mov [r10 + r15], al
    inc r15d; inc edx; jmp .Lpdh_cp_idat
.Lpdh_next_chk:
    lea r8d, [r8d + ecx + 12]; jmp .Lpdh_chk
.Lpdh_inf:
.Lpng_draw_halfblock__idat_len_ret:
    lea rsp, [rsp + 8]
    ret

# png_draw_halfblock step: Render half blocks in preview pane interior (runs on the caller's frame)
png_draw_halfblock__render_half_blocks_preview:
    lea rsp, [rsp - 8]
    mov rdi, [rsp + 16 + 16]; mov esi, [rsp + 16]; mov edx, [rsp + 4 + 16]; mov ecx, [rsp + 8 + 16]
    call png_unfilter
    # Render half-blocks in preview pane interior
    mov eax, [rbx + Widget.w]; sub eax, 2; mov [rsp + 32 + 16], eax
    mov eax, [rbx + Widget.h]; sub eax, 4; mov [rsp + 36 + 16], eax
    xor r14d, r14d            # cy
.Lpng_draw_halfblock__render_half_blocks_preview_ret:
    lea rsp, [rsp + 8]
    ret
