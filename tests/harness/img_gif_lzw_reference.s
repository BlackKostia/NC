# Frozen reference oracle: the hand-written asm that src/fs/img_gif.c replaced (tests/test_c_img_gif.py diffs against it)
# GIF LZW stage: variable-width code reader (LSB first), dictionary with KwKwK handling and
# pixel placement (interlace row order, transparency, clipping to the logical screen).

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"
.include "img_gif.inc"

.equ GL_BITS,  0               # locals of gif_lzw
.equ GL_SIZE,  4
.equ GL_CLEAR, 8
.equ GL_NEXT,  12
.equ GL_OLD,   16
.equ GL_FIRST, 20

.section .text
.global gif_lzw

# void gif_lzw(GifCtx *c) -- decodes c->data into the canvas
gif_lzw:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    mov rbx, rdi
    mov r12, [rbx + GC_DATA]
    mov r13, r12
    add r13, [rbx + GC_DLEN]
    xor r14d, r14d                    # bit buffer
    mov dword ptr [rsp + GL_BITS], 0
    mov ecx, [rbx + GC_MCS]
    cmp ecx, 2
    jb .Lgl_done
    cmp ecx, 11
    ja .Lgl_done
    mov eax, 1
    shl eax, cl
    mov [rsp + GL_CLEAR], eax
.Lgl_reset:
    mov eax, [rbx + GC_MCS]
    inc eax
    mov [rsp + GL_SIZE], eax
    mov eax, [rsp + GL_CLEAR]
    add eax, 2
    mov [rsp + GL_NEXT], eax
    mov dword ptr [rsp + GL_OLD], -1
.Lgl_code:
    call gl_read_code                 # eax = code, -1 at end of data
    test eax, eax
    js .Lgl_done
    mov r15d, eax
    cmp eax, [rsp + GL_CLEAR]
    je .Lgl_reset
    mov ecx, [rsp + GL_CLEAR]
    inc ecx
    cmp eax, ecx
    je .Lgl_done                      # end-of-information
    cmp dword ptr [rsp + GL_OLD], 0
    jge .Lgl_chain
    cmp eax, [rsp + GL_CLEAR]
    jae .Lgl_done
    mov [rsp + GL_OLD], eax
    mov [rsp + GL_FIRST], eax
    mov rdi, rbx
    mov esi, eax
    call gif_put
    jmp .Lgl_code
.Lgl_chain:
    call gl_step
    test eax, eax
    jz .Lgl_code
.Lgl_done:
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal (gif_lzw frame, rsp + 8 = locals): read one code -> eax (-1 = no more data)
gl_read_code:
    mov ecx, [rsp + 8 + GL_SIZE]
.Lrc_fill:
    cmp [rsp + 8 + GL_BITS], ecx
    jae .Lrc_take
    cmp r12, r13
    jae .Lrc_eof
    movzx eax, byte ptr [r12]
    inc r12
    push rcx
    mov ecx, [rsp + 16 + GL_BITS]
    shl rax, cl
    or r14, rax
    pop rcx
    add dword ptr [rsp + 8 + GL_BITS], 8
    jmp .Lrc_fill
.Lrc_take:
    mov eax, 1
    shl eax, cl
    dec eax
    and eax, r14d
    shr r14, cl
    sub [rsp + 8 + GL_BITS], ecx
    ret
.Lrc_eof:
    mov eax, -1
    ret

# Internal (gif_lzw frame): emit the string of code r15d, grow the dictionary -> eax = 1 to stop
gl_step:
    sub rsp, 8
    mov eax, [rsp + 16 + GL_NEXT]
    cmp r15d, eax
    ja .Lst_stop                      # code beyond the dictionary: corrupt stream
    jb .Lst_known
    mov rdi, rbx                      # KwKwK: string(old) + first(string(old))
    mov esi, [rsp + 16 + GL_OLD]
    call gif_emit
    mov [rsp + 16 + GL_FIRST], eax
    mov rdi, rbx
    mov esi, eax
    call gif_put
    jmp .Lst_add
.Lst_known:
    mov rdi, rbx
    mov esi, r15d
    call gif_emit
    mov [rsp + 16 + GL_FIRST], eax
.Lst_add:
    mov ecx, [rsp + 16 + GL_NEXT]
    cmp ecx, 4096
    jae .Lst_old
    mov rax, [rbx + GC_TAB]
    mov edx, [rsp + 16 + GL_OLD]
    mov [rax + rcx * 2], dx           # prefix
    mov edx, [rsp + 16 + GL_FIRST]
    mov [rax + 8192 + rcx], dl        # suffix
    inc ecx
    mov [rsp + 16 + GL_NEXT], ecx
    mov eax, 1
    push rcx
    mov ecx, [rsp + 24 + GL_SIZE]
    shl eax, cl
    pop rcx
    cmp ecx, eax
    jne .Lst_old
    cmp dword ptr [rsp + 16 + GL_SIZE], 12
    jae .Lst_old
    inc dword ptr [rsp + 16 + GL_SIZE]
.Lst_old:
    mov [rsp + 16 + GL_OLD], r15d
    xor eax, eax
    add rsp, 8
    ret
.Lst_stop:
    mov eax, 1
    add rsp, 8
    ret

# Internal: int gif_emit(GifCtx *c, int code) -> first (root) index of the emitted string
gif_emit:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    mov r12, [rbx + GC_TAB]
    mov ecx, [rbx + GC_MCS]
    mov r13d, 1
    shl r13d, cl                      # clear code: first non-root code
    xor r14d, r14d                    # stack depth
.Lem_walk:
    cmp esi, r13d
    jb .Lem_root
    cmp r14d, 4096
    jae .Lem_root
    movzx eax, byte ptr [r12 + 8192 + rsi]
    mov [r12 + 12288 + r14], al
    inc r14d
    movzx esi, word ptr [r12 + rsi * 2]
    jmp .Lem_walk
.Lem_root:
    and esi, 0xFFF
    mov r15d, esi
    mov rdi, rbx
    call gif_put
.Lem_out:
    test r14d, r14d
    jz .Lem_done
    dec r14d
    movzx esi, byte ptr [r12 + 12288 + r14]
    mov rdi, rbx
    call gif_put
    jmp .Lem_out
.Lem_done:
    mov eax, r15d
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: void gif_put(GifCtx *c, int index) -- next pixel of the frame
gif_put:
    mov eax, [rdi + GC_POS]
    inc dword ptr [rdi + GC_POS]
    mov ecx, [rdi + GC_IW]
    test ecx, ecx
    jz .Lgp_ret
    xor edx, edx
    div ecx                           # eax = row (sequential), edx = x
    cmp eax, [rdi + GC_IH]
    jae .Lgp_ret
    mov r8d, edx
    cmp dword ptr [rdi + GC_ILACE], 0
    je .Lgp_place
    call gif_lace_row
.Lgp_place:
    add eax, [rdi + GC_IY]
    cmp eax, [rdi + GC_CH]
    jae .Lgp_ret
    add r8d, [rdi + GC_IX]
    cmp r8d, [rdi + GC_CW]
    jae .Lgp_ret
    cmp esi, [rdi + GC_TRANS]
    je .Lgp_ret
    imul eax, [rdi + GC_CW]
    add eax, r8d
    mov r9d, 0xFF000000
    cmp esi, [rdi + GC_PALN]
    jae .Lgp_store
    lea ecx, [esi + esi * 2]
    mov rdx, [rdi + GC_PAL]
    movzx r10d, byte ptr [rdx + rcx]
    or r9d, r10d
    movzx r10d, byte ptr [rdx + rcx + 1]
    shl r10d, 8
    or r9d, r10d
    movzx r10d, byte ptr [rdx + rcx + 2]
    shl r10d, 16
    or r9d, r10d
.Lgp_store:
    mov rdx, [rdi + GC_PX]
    mov [rdx + rax * 4], r9d
.Lgp_ret:
    ret

# Internal: eax = image row for sequential row eax of an interlaced frame
gif_lace_row:
    cmp eax, [rdi + GC_C1]
    jae 1f
    shl eax, 3
    ret
1:  sub eax, [rdi + GC_C1]
    cmp eax, [rdi + GC_C2]
    jae 2f
    lea eax, [rax * 8 + 4]
    ret
2:  sub eax, [rdi + GC_C2]
    cmp eax, [rdi + GC_C3]
    jae 3f
    lea eax, [rax * 4 + 2]
    ret
3:  sub eax, [rdi + GC_C3]
    lea eax, [rax * 2 + 1]
    ret
