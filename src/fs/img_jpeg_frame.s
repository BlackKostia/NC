# Baseline JPEG frame layer: SOF0/1 component setup (sampling factors, MCU-padded planes)
# and the SOS scan header.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"
.include "img_jpeg.inc"

.section .text
.global jpeg_sof
.global jpeg_sos

# (int status, 0) jpeg_sof(Jpeg *j, const uint8_t *seg, int len)
jpeg_sof:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    mov r12, rsi
    cmp dword ptr [rbx + Jpeg.frame], 0
    je .Lsf_chk
    push rdx
    xor r14d, r14d
10: cmp r14d, 4; jge 11f
    imul rax, r14, JC._size
    mov rdi, [rbx + Jpeg.comp + rax + JC.plane]
    mov qword ptr [rbx + Jpeg.comp + rax + JC.plane], 0
    call mem_free
    inc r14d; jmp 10b
11: mov rdi, [rbx + Jpeg.out]; call img_free
    mov dword ptr [rbx + Jpeg.frame], 0
    pop rdx
.Lsf_chk:
    mov eax, IMG_E_CORRUPT
    cmp edx, 6
    jl .Lsf_ret
    mov eax, IMG_E_UNSUP
    cmp byte ptr [r12], 8             # 8-bit samples only
    jne .Lsf_ret
    movzx ecx, byte ptr [r12 + 5]     # components: gray or YCbCr
    cmp ecx, 1
    je 1f
    cmp ecx, 3
    jne .Lsf_ret
1:  mov [rbx + Jpeg.ncomp], ecx
    lea eax, [ecx + ecx * 2 + 6]
    cmp edx, eax
    mov eax, IMG_E_CORRUPT
    jl .Lsf_ret
    movzx eax, word ptr [r12 + 1]
    rol ax, 8
    test eax, eax; jz .Lsf_ret
    cmp eax, IMG_MAX_DIM; ja .Lsf_ret
    mov [rbx + Jpeg.h], eax
    movzx eax, word ptr [r12 + 3]
    rol ax, 8
    test eax, eax; jz .Lsf_ret
    cmp eax, IMG_MAX_DIM; ja .Lsf_ret
    mov [rbx + Jpeg.w], eax
    mov rdi, rbx
    lea rsi, [r12 + 6]
    call jsof_components
    test eax, eax
    jnz .Lsf_ret
    mov rdi, rbx
    call jsof_planes
    test eax, eax
    jnz .Lsf_ret
    mov rdi, [rbx + Jpeg.out]
    mov esi, [rbx + Jpeg.w]
    mov edx, [rbx + Jpeg.h]
    call img_alloc
    test eax, eax
    jnz .Lsf_ret
    mov dword ptr [rbx + Jpeg.frame], 1
.Lsf_ret:
    xor edx, edx
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: int jsof_components(Jpeg *j, const uint8_t *specs) -- ids, sampling, quant tables
jsof_components:
    xor ecx, ecx
    mov dword ptr [rdi + Jpeg.hmax], 1
    mov dword ptr [rdi + Jpeg.vmax], 1
.Lsc_loop:
    cmp ecx, [rdi + Jpeg.ncomp]
    jge .Lsc_ok
    imul r8, rcx, JC._size
    lea r8, [rdi + Jpeg.comp + r8]
    movzx eax, byte ptr [rsi];     mov [r8 + JC.id], eax
    movzx eax, byte ptr [rsi + 1]
    mov edx, eax
    shr eax, 4
    and edx, 15
    mov [r8 + JC.h], eax
    mov [r8 + JC.v], edx
    test eax, eax
    jz .Lsc_bad
    test edx, edx
    jz .Lsc_bad
    cmp eax, 4
    ja .Lsc_bad
    cmp edx, 4
    ja .Lsc_bad
    cmp eax, [rdi + Jpeg.hmax]
    jbe 1f
    mov [rdi + Jpeg.hmax], eax
1:  cmp edx, [rdi + Jpeg.vmax]
    jbe 2f
    mov [rdi + Jpeg.vmax], edx
2:  movzx eax, byte ptr [rsi + 2]
    and eax, 3
    mov [r8 + JC.tq], eax
    add rsi, 3
    inc ecx
    jmp .Lsc_loop
.Lsc_ok:
    xor eax, eax
    ret
.Lsc_bad:
    mov eax, IMG_E_CORRUPT
    ret

# Internal: int jsof_planes(Jpeg *j) -- MCU grid, per-component planes and upsampling shifts
jsof_planes:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov eax, [rbx + Jpeg.hmax]        # mcux = ceil(w / (8 * hmax))
    shl eax, 3
    mov ecx, eax
    mov eax, [rbx + Jpeg.w]
    add eax, ecx
    dec eax
    xor edx, edx
    div ecx
    mov [rbx + Jpeg.mcux], eax
    mov eax, [rbx + Jpeg.vmax]
    shl eax, 3
    mov ecx, eax
    mov eax, [rbx + Jpeg.h]
    add eax, ecx
    dec eax
    xor edx, edx
    div ecx
    mov [rbx + Jpeg.mcuy], eax
    xor r12d, r12d
.Lsp_comp:
    cmp r12d, [rbx + Jpeg.ncomp]
    jge .Lsp_ok
    imul r13, r12, JC._size
    lea r13, [rbx + Jpeg.comp + r13]
    mov rdi, rbx
    mov rsi, r13
    call jsof_plane
    test eax, eax
    jnz .Lsp_ret
    inc r12d
    jmp .Lsp_comp
.Lsp_ok:
    xor eax, eax
.Lsp_ret:
    pop r13
    pop r12
    pop rbx
    ret

# Internal: int jsof_plane(Jpeg *j, JComp *c)
jsof_plane:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    mov eax, [rbx + Jpeg.hmax]        # sx = log2(hmax / h): only power-of-two ratios
    xor edx, edx
    div dword ptr [r12 + JC.h]
    test edx, edx
    jnz .Lpl_unsup
    test eax, eax
    jz .Lpl_unsup
    lea ecx, [eax - 1]
    test eax, ecx
    jnz .Lpl_unsup
    bsf ecx, eax
    mov [r12 + JC.sx], ecx
    mov eax, [rbx + Jpeg.vmax]
    xor edx, edx
    div dword ptr [r12 + JC.v]
    test edx, edx
    jnz .Lpl_unsup
    test eax, eax
    jz .Lpl_unsup
    lea ecx, [eax - 1]
    test eax, ecx
    jnz .Lpl_unsup
    bsf ecx, eax
    mov [r12 + JC.sy], ecx
    mov eax, [rbx + Jpeg.mcux]
    imul eax, [r12 + JC.h]
    shl eax, 3
    mov [r12 + JC.bw], eax
    mov ecx, [rbx + Jpeg.mcuy]
    imul ecx, [r12 + JC.v]
    shl ecx, 3
    mov [r12 + JC.bh], ecx
    imul rax, rcx
    cmp rax, IMG_MAX_PIXELS
    ja .Lpl_unsup
    mov rdi, rax
    call mem_alloc
    mov [r12 + JC.plane], rax
    test rax, rax
    jz .Lpl_nomem
    xor eax, eax
    jmp .Lpl_ret
.Lpl_unsup:
    mov eax, IMG_E_UNSUP
    jmp .Lpl_ret
.Lpl_nomem:
    mov eax, IMG_E_NOMEM
.Lpl_ret:
    add rsp, 8
    pop r12
    pop rbx
    ret

# (int status, uint8_t *resume) jpeg_sos(Jpeg *j, const uint8_t *seg, int len)
jpeg_sos:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov eax, IMG_E_CORRUPT
    cmp dword ptr [rbx + Jpeg.frame], 0
    je .Lss_fail
    movzx ecx, byte ptr [r12]
    test ecx, ecx
    jz .Lss_fail
    cmp ecx, 4
    ja .Lss_fail
    lea eax, [ecx + ecx + 4]
    cmp r13d, eax
    jl .Lss_fail
    mov [rbx + Jpeg.sncomp], ecx
    mov rdi, rbx
    lea rsi, [r12 + 1]
    call jsos_select
    test eax, eax
    jnz .Lss_fail
    mov rdi, rbx
    lea rsi, [r12 + r13]              # entropy-coded data follows the header
    call jpeg_scan
    mov rdx, [rbx + Jpeg.p]
    jmp .Lss_ret
.Lss_fail:
    xor edx, edx
.Lss_ret:
    pop r13
    pop r12
    pop rbx
    ret

# Internal: int jsos_select(Jpeg *j, const uint8_t *sel) -- map scan components, Huffman ids
jsos_select:
    xor ecx, ecx
.Lsl_scan:
    cmp ecx, [rdi + Jpeg.sncomp]
    jge .Lsl_ok
    movzx eax, byte ptr [rsi + rcx * 2]
    xor r8d, r8d
.Lsl_find:
    cmp r8d, [rdi + Jpeg.ncomp]
    jge .Lsl_bad
    imul r9, r8, JC._size
    lea r9, [rdi + Jpeg.comp + r9]
    cmp eax, [r9 + JC.id]
    je .Lsl_hit
    inc r8d
    jmp .Lsl_find
.Lsl_hit:
    mov [rdi + Jpeg.scomp + rcx * 4], r8d
    movzx eax, byte ptr [rsi + rcx * 2 + 1]
    mov edx, eax
    shr eax, 4
    and eax, 3
    and edx, 3
    mov [r9 + JC.td], eax
    mov [r9 + JC.ta], edx
    mov dword ptr [r9 + JC.pred], 0
    inc ecx
    jmp .Lsl_scan
.Lsl_ok:
    xor eax, eax
    ret
.Lsl_bad:
    mov eax, IMG_E_CORRUPT
    ret
