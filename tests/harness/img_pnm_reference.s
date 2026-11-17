# Frozen reference oracle: the hand-written asm that src/fs/img_pnm.c replaced (tests/test_c_img.py diffs against it)
# Netpbm decoder (binary P5 graymap / P6 pixmap, maxval up to 65535) and QOI decoder.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .text
.global img_pnm_decode
.global img_qoi_decode

# int img_pnm_decode(const uint8_t *d, size_t n, Image *out)
img_pnm_decode:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32                       # [0]=w [4]=h [8]=maxval [12]=channels [16]=bytes/sample
    mov r13, rdx
    lea r12, [rdi + rsi]              # end
    movzx eax, byte ptr [rdi + 1]
    mov dword ptr [rsp + 12], 1
    cmp eax, '6'
    jne 1f
    mov dword ptr [rsp + 12], 3
1:  lea rbx, [rdi + 2]                # cursor
    mov r14d, 0
.Lpn_hdr:
    mov rdi, rbx
    mov rsi, r12
    call pnm_uint                     # rax = value (-1 = none), rdx = cursor
    mov rbx, rdx
    test rax, rax
    jle .Lpn_bad
    mov [rsp + r14 * 4], eax
    inc r14d
    cmp r14d, 3
    jl .Lpn_hdr
    inc rbx                           # single whitespace before the raster
    mov dword ptr [rsp + 16], 1
    cmp dword ptr [rsp + 8], 255
    jbe 2f
    mov dword ptr [rsp + 16], 2
2:  mov rdi, r13
    mov esi, [rsp]
    mov edx, [rsp + 4]
    call img_alloc
    test eax, eax
    jnz .Lpn_ret
    mov r15, [r13 + Image.px]
    mov r14d, [rsp]
    imul r14d, [rsp + 4]              # pixels left
.Lpn_px:
    test r14d, r14d
    jz .Lpn_ok
    mov eax, [rsp + 12]
    imul eax, [rsp + 16]
    lea rcx, [rbx + rax]
    cmp rcx, r12
    ja .Lpn_ok                        # truncated: keep what was decoded
    mov rdi, rbx
    mov rsi, rsp
    call pnm_pixel
    mov [r15], eax
    add r15, 4
    mov eax, [rsp + 12]
    imul eax, [rsp + 16]
    add rbx, rax
    dec r14d
    jmp .Lpn_px
.Lpn_ok:
    xor eax, eax
    jmp .Lpn_ret
.Lpn_bad:
    mov eax, IMG_E_FORMAT
.Lpn_ret:
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: (int64 v, uint8_t *cur) pnm_uint(uint8_t *p, uint8_t *end) -- skips blanks and # comments
pnm_uint:
    mov rax, -1
.Lpu_skip:
    cmp rdi, rsi
    jae .Lpu_ret
    movzx ecx, byte ptr [rdi]
    cmp ecx, '#'
    je .Lpu_comment
    cmp ecx, ' '
    ja .Lpu_digits
    inc rdi
    jmp .Lpu_skip
.Lpu_comment:
    cmp rdi, rsi
    jae .Lpu_ret
    movzx ecx, byte ptr [rdi]
    inc rdi
    cmp ecx, 10
    jne .Lpu_comment
    jmp .Lpu_skip
.Lpu_digits:
    xor eax, eax
.Lpu_dig:
    cmp rdi, rsi
    jae .Lpu_ret
    movzx ecx, byte ptr [rdi]
    sub ecx, '0'
    cmp ecx, 9
    ja .Lpu_ret
    imul rax, rax, 10
    add rax, rcx
    cmp rax, 0x7FFFFFFF
    ja .Lpu_ovf
    inc rdi
    jmp .Lpu_dig
.Lpu_ovf:
    mov rax, -1
.Lpu_ret:
    mov rdx, rdi
    ret

# Internal: uint32_t pnm_pixel(const uint8_t *p, const int hdr[5]) -> RGBA
pnm_pixel:
    push rbx
    xor r11d, r11d                    # packed RGB
    xor ebx, ebx                      # channel
.Lpp_ch:
    cmp ebx, [rsi + 12]
    jge .Lpp_pack
    movzx eax, byte ptr [rdi]
    cmp dword ptr [rsi + 16], 2
    jne 1f
    shl eax, 8
    movzx ecx, byte ptr [rdi + 1]
    or eax, ecx
1:  mov ecx, [rsi + 16]               # next sample
    add rdi, rcx
    imul eax, eax, 255                # scale to 8 bits
    xor edx, edx
    div dword ptr [rsi + 8]
    mov ecx, ebx
    shl ecx, 3
    shl eax, cl
    or r11d, eax
    inc ebx
    jmp .Lpp_ch
.Lpp_pack:
    cmp dword ptr [rsi + 12], 1
    jne 2f
    imul r11d, r11d, 0x010101         # gray
2:  mov eax, r11d
    or eax, 0xFF000000
    pop rbx
    ret

# int img_qoi_decode(const uint8_t *d, size_t n, Image *out) -- "Quite OK Image" format
img_qoi_decode:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 256                      # color index[64]
    mov rbx, rdi
    lea r12, [rdi + rsi]
    mov r13, rdx
    mov eax, IMG_E_FORMAT
    cmp rsi, 22
    jb .Lqd_ret
    mov rdi, rsp
    mov esi, 256
    call mem_zero
    mov rdi, r13
    mov esi, [rbx + 4]
    bswap esi
    mov edx, [rbx + 8]
    bswap edx
    call img_alloc
    test eax, eax
    jnz .Lqd_ret
    mov r14d, [r13 + Image.w]
    imul r14d, [r13 + Image.h]        # pixels left
    mov r15, [r13 + Image.px]
    add rbx, 14
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r15
    mov ecx, r14d
    mov r8, rsp
    call qoi_stream
    xor eax, eax
.Lqd_ret:
    add rsp, 256
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: void qoi_stream(const uint8_t *p, const uint8_t *end, uint32_t *dst, int count, uint32_t *index)
qoi_stream:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15d, ecx
    mov rbx, r8
    mov r9d, 0xFF000000               # current pixel
    xor r10d, r10d                    # run
.Lqs_px:
    test r15d, r15d
    jz .Lqs_done
    test r10d, r10d
    jz .Lqs_op
    dec r10d
    jmp .Lqs_emit
.Lqs_op:
    cmp r12, r13
    jae .Lqs_done
    movzx eax, byte ptr [r12]
    inc r12
    call qoi_op                       # updates r9d (pixel), r10d (run), r12 (cursor)
.Lqs_emit:
    mov [r14], r9d
    add r14, 4
    dec r15d
    jmp .Lqs_px
.Lqs_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: decode one QOI op (tag byte in eax); r9d = pixel, r10d = run, r12 = cursor, rbx = index
qoi_op:
    cmp eax, 0xFE; je qoi_op_rgb
    cmp eax, 0xFF; je qoi_op_rgba
    mov ecx, eax; shr ecx, 6; and eax, 0x3F
    cmp ecx, 0; je .Lqo_index
    cmp ecx, 3; je .Lqo_run
    cmp ecx, 1; je .Lqo_diff
    cmp r12, r13; jae qoi_op_eof
    movzx edx, byte ptr [r12]; inc r12
    sub eax, 32
    mov ecx, edx; shr ecx, 4; lea ecx, [ecx + eax - 8]
    and edx, 15; lea edx, [edx + eax - 8]
    mov r8d, eax; jmp .Lqo_add
.Lqo_diff:
    mov ecx, eax; shr ecx, 4; and ecx, 3; sub ecx, 2
    mov r8d, eax; shr r8d, 2; and r8d, 3; sub r8d, 2
    mov edx, eax; and edx, 3; sub edx, 2
.Lqo_add:
    add cl, r9b
    mov r11d, r9d; shr r11d, 8; add r8b, r11b
    shr r11d, 8; add dl, r11b
    and r9d, 0xFF000000
    movzx ecx, cl; or r9d, ecx
    movzx r8d, r8b; shl r8d, 8; or r9d, r8d
    movzx edx, dl; shl edx, 16; or r9d, edx
    jmp qoi_remember
.Lqo_index:
    mov r9d, [rbx + rax * 4]; jmp qoi_remember
.Lqo_run:
    mov r10d, eax; jmp qoi_remember

qoi_op_rgb:
    mov rax, r13; sub rax, r12; cmp rax, 3; jb qoi_op_eof
    and r9d, 0xFF000000
    movzx eax, word ptr [r12]; or r9d, eax
    movzx eax, byte ptr [r12 + 2]; shl eax, 16; or r9d, eax
    add r12, 3; jmp qoi_remember
qoi_op_rgba:
    mov rax, r13; sub rax, r12; cmp rax, 4; jb qoi_op_eof
    mov r9d, [r12]; add r12, 4; jmp qoi_remember
qoi_op_eof:
    mov r12, r13; ret

# Internal: index[(r*3 + g*5 + b*7 + a*11) % 64] = r9d
qoi_remember:
    movzx eax, r9b
    imul eax, eax, 3
    mov ecx, r9d
    shr ecx, 8
    movzx edx, cl
    imul edx, edx, 5
    add eax, edx
    shr ecx, 8
    movzx edx, cl
    imul edx, edx, 7
    add eax, edx
    shr ecx, 8
    imul ecx, ecx, 11
    add eax, ecx
    and eax, 63
    mov [rbx + rax * 4], r9d
    ret
