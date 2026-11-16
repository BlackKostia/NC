# Baseline JPEG decoder, marker layer: SOI..EOI walk, DQT, DHT (canonical tables + 8-bit
# lookup), SOF0/SOF1 frame setup, DRI and SOS. Progressive / arithmetic / CMYK files are
# reported as IMG_E_UNSUP. Entropy decoding: img_jpeg_scan.s; IDCT + color: img_jpeg_idct.s.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"
.include "img_jpeg.inc"

.section .text
.global img_jpeg_decode

# int img_jpeg_decode(const uint8_t *d, size_t n, Image *out)
img_jpeg_decode:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    lea r13, [rdi + rsi]
    mov r14, rdx
    mov edi, Jpeg._size
    call mem_alloc
    test rax, rax
    jz .Ljd_nomem
    mov rbx, rax
    mov [rbx + Jpeg.out], r14
    lea rsi, [r12 + 2]
    mov rdi, rbx
    mov rdx, r13
    call jpeg_markers
    mov r15d, eax
    test eax, eax
    jnz .Ljd_free
    mov eax, IMG_E_CORRUPT
    cmp dword ptr [rbx + Jpeg.frame], 0
    je .Ljd_keep
    mov rdi, rbx
    call jpeg_color
    xor eax, eax
.Ljd_keep:
    mov r15d, eax
.Ljd_free:
    mov rdi, rbx
    call jpeg_free
    mov eax, r15d
    jmp .Ljd_ret
.Ljd_nomem:
    mov eax, IMG_E_NOMEM
.Ljd_ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: void jpeg_free(Jpeg *j) -- component planes + context
jpeg_free:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    xor r12d, r12d
.Ljf_loop:
    cmp r12d, 4
    jge .Ljf_ctx
    imul rax, r12, JC._size
    mov rdi, [rbx + Jpeg.comp + rax + JC.plane]
    call mem_free
    inc r12d
    jmp .Ljf_loop
.Ljf_ctx:
    mov rdi, rbx
    call mem_free
    add rsp, 8
    pop r12
    pop rbx
    ret

# Internal: int jpeg_markers(Jpeg *j, const uint8_t *p, const uint8_t *end)
jpeg_markers:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov [rbx + Jpeg.end], r13
.Ljm_find:
    cmp r12, r13
    jae .Ljm_ok
    cmp byte ptr [r12], 0xFF
    je .Ljm_ff
    inc r12
    jmp .Ljm_find
.Ljm_ff:
    inc r12
    cmp r12, r13
    jae .Ljm_ok
    movzx r14d, byte ptr [r12]
    cmp r14d, 0xFF
    je .Ljm_ff                        # fill bytes
    inc r12
    cmp r14d, 0xD9
    je .Ljm_ok                        # EOI
    cmp r14d, 0xD8
    je .Ljm_find
    mov eax, r14d
    and eax, 0xF8
    cmp eax, 0xD0
    je .Ljm_find                      # stray RSTn
    lea rax, [r12 + 2]
    cmp rax, r13
    ja .Ljm_ok
    movzx r15d, word ptr [r12]
    rol r15w, 8                       # segment length (BE16, includes itself)
    cmp r15d, 2
    jb .Ljm_bad
    lea rax, [r12 + r15]
    cmp rax, r13
    ja .Ljm_bad
    mov rdi, rbx
    lea rsi, [r12 + 2]
    lea edx, [r15d - 2]
    mov ecx, r14d
    call jpeg_segment                 # -> eax status, rdx = resume point (0 = after segment)
    test eax, eax
    jnz .Ljm_ret
    add r12, r15
    test rdx, rdx
    jz .Ljm_find
    mov r12, rdx                      # after entropy-coded scan data
    jmp .Ljm_find
.Ljm_bad:
    mov eax, IMG_E_CORRUPT
    jmp .Ljm_ret
.Ljm_ok:
    xor eax, eax
.Ljm_ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: (int status, uint8_t *resume) jpeg_segment(Jpeg *j, const uint8_t *seg, int len, int marker)
jpeg_segment:
    cmp ecx, 0xDB
    je jpeg_dqt
    cmp ecx, 0xC4
    je jpeg_dht
    cmp ecx, 0xC0
    je jpeg_sof
    cmp ecx, 0xC1
    je jpeg_sof
    cmp ecx, 0xDD
    je .Lsg_dri
    cmp ecx, 0xDA
    je jpeg_sos
    mov eax, ecx
    and eax, 0xF0
    cmp eax, 0xC0                     # other SOFn (progressive, lossless, arithmetic)
    jne .Lsg_skip
    mov eax, IMG_E_UNSUP
    xor edx, edx
    ret
.Lsg_dri:
    cmp edx, 2
    jb .Lsg_bad
    movzx eax, word ptr [rsi]
    rol ax, 8
    mov [rdi + Jpeg.rst], eax
.Lsg_skip:
    xor eax, eax
    xor edx, edx
    ret
.Lsg_bad:
    mov eax, IMG_E_CORRUPT
    xor edx, edx
    ret

# Internal: int jpeg_dqt(Jpeg *j, const uint8_t *seg, int len) -- 8/16-bit quantization tables
jpeg_dqt:
    lea r8, [rsi + rdx]
.Ldq_tab:
    cmp rsi, r8
    jae .Ldq_ok
    movzx eax, byte ptr [rsi]
    inc rsi
    mov ecx, eax
    and ecx, 3
    shl ecx, 7
    lea r9, [rdi + Jpeg.qt + rcx]     # table base (64 x u16)
    shr eax, 4
    mov edx, 64
    test eax, eax
    jz 2f
    mov edx, 128
2:  mov r10, r8
    sub r10, rsi
    cmp r10, rdx
    jb .Ldq_bad
    xor ecx, ecx
.Ldq_val:
    cmp ecx, 64
    jge .Ldq_tab
    movzx r10d, byte ptr [rsi]
    inc rsi
    test eax, eax
    jz 1f
    shl r10d, 8
    movzx r11d, byte ptr [rsi]
    inc rsi
    or r10d, r11d
1:  mov [r9 + rcx * 2], r10w
    inc ecx
    jmp .Ldq_val
.Ldq_bad:
    mov eax, IMG_E_CORRUPT
    xor edx, edx
    ret
.Ldq_ok:
    xor eax, eax
    xor edx, edx
    ret

# Internal: int jpeg_dht(Jpeg *j, const uint8_t *seg, int len)
jpeg_dht:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    lea r13, [rsi + rdx]
.Ldh_tab:
    lea rax, [r12 + 17]
    cmp rax, r13
    ja .Ldh_done_chk
    xor r8d, r8d
    xor ecx, ecx
.Ldh_sum:
    movzx eax, byte ptr [r12 + 1 + rcx]
    add r8d, eax
    inc ecx
    cmp ecx, 16
    jb .Ldh_sum
    cmp r8d, 256
    ja .Ldh_bad
    lea r9, [r12 + r8 + 17]
    cmp r9, r13
    ja .Ldh_bad
    movzx eax, byte ptr [r12]         # Tc << 4 | Th
    mov ecx, eax
    and ecx, 3
    shr eax, 4
    and eax, 1
    lea eax, [eax * 4 + ecx]
    imul rax, rax, HT._size
    lea rdi, [rbx + Jpeg.huff + rax]
    lea rsi, [r12 + 1]                # counts[16], then symbols
    call jpeg_build_huff              # -> eax = symbol count or -1
    test eax, eax
    js .Ldh_bad
    lea r12, [r12 + rax + 17]
    jmp .Ldh_tab
.Ldh_done_chk:
    cmp r12, r13
    jne .Ldh_bad
.Ldh_ok:
    xor eax, eax
    xor edx, edx
    pop r13
    pop r12
    pop rbx
    ret
.Ldh_bad:
    mov eax, IMG_E_CORRUPT
    xor edx, edx
    pop r13
    pop r12
    pop rbx
    ret

# Internal: int jpeg_build_huff(HuffTable *t, const uint8_t *counts /* + symbols */) -> symbols
jpeg_build_huff:
    push rbx
    push r12
    push r13
    push r14
    mov rbx, rdi
    mov r12, rsi
    xor eax, eax                      # clear lookup
    mov ecx, 256
    lea r8, [rbx + HT.look]
1:  mov word ptr [r8 + rcx * 2 - 2], ax
    loop 1b
    xor r13d, r13d                    # code
    xor r14d, r14d                    # symbol index k
    mov ecx, 1                        # length l
.Lbh_len:
    cmp ecx, 16
    jg .Lbh_end
    movzx r9d, byte ptr [r12 + rcx - 1]
    mov [rbx + HT.valptr + rcx * 4], r14d
    mov [rbx + HT.mincode + rcx * 4], r13d
    mov dword ptr [rbx + HT.maxcode + rcx * 4], -1
    test r9d, r9d
    jz .Lbh_next
    lea eax, [r13d + r9d - 1]
    mov [rbx + HT.maxcode + rcx * 4], eax
.Lbh_sym:
    test r9d, r9d
    jz .Lbh_next
    cmp r14d, 256
    jae .Lbh_end
    movzx eax, byte ptr [r12 + r14 + 16]
    mov [rbx + HT.vals + r14], al
    cmp ecx, 8
    jg 2f
    call jbh_lookup                   # fill the 8-bit fast table for this code
    test eax, eax
    js .Lbh_bad
2:  inc r13d
    inc r14d
    dec r9d
    jmp .Lbh_sym
.Lbh_next:
    shl r13d, 1
    inc ecx
    jmp .Lbh_len
.Lbh_end:
    mov dword ptr [rbx + HT.maxcode + 17 * 4], 0x7FFFFFFF
    mov eax, r14d
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.Lbh_bad:
    mov eax, -1
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: look[code << (8 - l) .. +(1 << (8 - l))] = l << 8 | sym (eax), rbx = table
jbh_lookup:
    push rcx
    mov r10d, ecx                     # l
    cmp r10d, 1
    jb .Ljbl_bad
    cmp r10d, 8
    ja .Ljbl_bad
    mov r11d, eax
    mov eax, r10d
    shl eax, 8
    or r11d, eax                      # entry
    mov ecx, 8
    sub ecx, r10d
    mov eax, r13d
    shl eax, cl
    mov edx, 1
    shl edx, cl                       # run length
    lea r8, [rax + rdx]
    cmp r8, 256
    ja .Ljbl_bad
3:  mov [rbx + HT.look + rax * 2], r11w
    inc eax
    dec edx
    jnz 3b
    xor eax, eax
    pop rcx
    ret
.Ljbl_bad:
    mov eax, -1
    pop rcx
    ret
