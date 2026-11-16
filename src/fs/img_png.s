# PNG container decoder: IHDR validation, PLTE/tRNS/IDAT collection, zlib inflate and the
# plain / Adam7 pass schedule. Scanline filtering and pixel formats live in img_png_px.s.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"
.include "img_png.inc"

.section .rodata
# allowed bit depths per color type (bit d set = depth d valid), samples per pixel
png_ct_mask: .long 0x10116, 0, 0x10100, 0x116, 0x10100, 0, 0x10100
png_ct_ch:   .byte 1, 0, 3, 1, 2, 0, 4, 0
# Adam7: x0, y0, dx, dy per pass
png_adam7:   .byte 0,0,8,8, 4,0,8,8, 0,4,4,8, 2,0,4,4, 0,2,2,4, 1,0,2,2, 0,1,1,2

.section .text
.global img_png_decode

# int img_png_decode(const uint8_t *d, size_t n, Image *out) -> 0 or IMG_E_*
img_png_decode:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, PngCtx._size
    mov rbx, rsp
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov rdi, rbx
    mov esi, PngCtx._size
    call mem_zero
    mov [rbx + PngCtx.out], r14
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call png_parse_ihdr
    test eax, eax
    jnz .Lpd_ret
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call png_collect
    test eax, eax
    jnz .Lpd_free
    mov rdi, rbx
    call png_inflate
    test eax, eax
    jnz .Lpd_free
    mov rdi, r14
    mov esi, [rbx + PngCtx.w]
    mov edx, [rbx + PngCtx.h]
    call img_alloc
    test eax, eax
    jnz .Lpd_free
    mov rdi, rbx
    call png_emit_all
    xor eax, eax
.Lpd_free:
    mov r15d, eax
    mov rdi, [rbx + PngCtx.idat]
    call mem_free
    mov rdi, [rbx + PngCtx.raw]
    call mem_free
    mov eax, r15d
.Lpd_ret:
    add rsp, PngCtx._size
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: int png_parse_ihdr(PngCtx *c, const uint8_t *d, size_t n)
png_parse_ihdr:
    mov eax, IMG_E_FORMAT
    cmp rdx, 33
    jb .Lpih_ret
    cmp dword ptr [rsi + 12], 0x52444849    # "IHDR"
    jne .Lpih_ret
    mov eax, [rsi + 16]
    bswap eax
    test eax, eax; jz .Lpih_bad
    cmp eax, IMG_MAX_DIM; ja .Lpih_bad
    mov [rdi + PngCtx.w], eax
    mov ecx, eax
    mov eax, [rsi + 20]
    bswap eax
    test eax, eax; jz .Lpih_bad
    cmp eax, IMG_MAX_DIM; ja .Lpih_bad
    mov [rdi + PngCtx.h], eax
    imul rax, rcx
    cmp rax, IMG_MAX_PIXELS
    ja .Lpih_unsup
    movzx ecx, byte ptr [rsi + 24]
    mov [rdi + PngCtx.depth], ecx
    movzx edx, byte ptr [rsi + 25]
    mov [rdi + PngCtx.ctype], edx
    movzx eax, byte ptr [rsi + 28]
    mov [rdi + PngCtx.ilace], eax
    mov eax, IMG_E_UNSUP
    cmp edx, 6
    ja .Lpih_ret
    cmp ecx, 16
    ja .Lpih_ret
    lea r8, [rip + png_ct_mask]
    mov r8d, [r8 + rdx * 4]
    bt r8d, ecx
    jnc .Lpih_ret
    cmp dword ptr [rdi + PngCtx.ilace], 1
    ja .Lpih_ret
    lea r8, [rip + png_ct_ch]
    movzx r8d, byte ptr [r8 + rdx]
    mov [rdi + PngCtx.ch], r8d
    imul r8d, ecx
    mov [rdi + PngCtx.bits], r8d
    shr r8d, 3
    jnz 1f
    mov r8d, 1
1:  mov [rdi + PngCtx.fbpp], r8d
    xor eax, eax
    ret
.Lpih_bad:
    mov eax, IMG_E_CORRUPT
    ret
.Lpih_unsup:
    mov eax, IMG_E_UNSUP
.Lpih_ret:
    ret

# Internal: int png_collect(PngCtx *c, const uint8_t *d, size_t n) -- PLTE, tRNS, IDAT
png_collect:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    xor ecx, ecx                      # pass 1: measure IDAT
    call png_walk
    test rax, rax
    jz .Lpc_bad
    mov [rbx + PngCtx.idat_n], rax
    mov rdi, rax
    call mem_alloc
    test rax, rax
    jz .Lpc_nomem
    mov [rbx + PngCtx.idat], rax
    mov rcx, rax                      # pass 2: copy IDAT
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call png_walk
    xor eax, eax
    jmp .Lpc_ret
.Lpc_bad:
    mov eax, IMG_E_CORRUPT
    jmp .Lpc_ret
.Lpc_nomem:
    mov eax, IMG_E_NOMEM
.Lpc_ret:
    pop r13
    pop r12
    pop rbx
    ret

# Internal: size_t png_walk(PngCtx *c, const uint8_t *d, size_t n, uint8_t *idat_dst /*or 0*/)
# Walks the chunk list, records PLTE/tRNS, returns total IDAT bytes (copied when dst != 0).
png_walk:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    xor r15d, r15d                    # IDAT bytes
    mov r8d, 8                        # offset
.Lpw_loop:
    lea rax, [r8 + 12]
    cmp rax, r13
    ja .Lpw_done
    mov ecx, [r12 + r8]
    bswap ecx                         # chunk length
    lea rax, [r8 + rcx + 12]
    cmp rax, r13
    jbe .Lpw_fits
    mov rcx, r13                      # truncated file: keep what is there
    sub rcx, r8
    sub rcx, 12
.Lpw_fits:
    lea r9, [r12 + r8 + 8]            # payload
    mov eax, [r12 + r8 + 4]
    cmp eax, 0x54414449               # IDAT
    je .Lpw_idat
    cmp eax, 0x45544C50               # PLTE
    je .Lpw_plte
    cmp eax, 0x534E5274               # tRNS
    je .Lpw_trns
    cmp eax, 0x444E4549               # IEND
    je .Lpw_done
.Lpw_next:
    lea r8, [r8 + rcx + 12]
    jmp .Lpw_loop
.Lpw_idat:
    test r14, r14
    jz .Lpw_count
    push r8
    push rcx
    lea rdi, [r14 + r15]
    mov rsi, r9
    mov rdx, rcx
    call mem_copy
    pop rcx
    pop r8
.Lpw_count:
    add r15, rcx
    jmp .Lpw_next
.Lpw_plte:
    mov [rbx + PngCtx.plte], r9
    mov eax, ecx
    xor edx, edx
    mov r10d, 3
    div r10d
    mov [rbx + PngCtx.plte_n], eax
    jmp .Lpw_next
.Lpw_trns:
    mov [rbx + PngCtx.trns], r9
    mov [rbx + PngCtx.trns_n], ecx
    jmp .Lpw_next
.Lpw_done:
    mov rax, r15
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: size_t png_pass_bytes(PngCtx *c, int pw, int ph) -> ph * (1 + rowbytes(pw))
png_pass_bytes:
    movsxd rax, esi
    movsxd rcx, dword ptr [rdi + PngCtx.bits]
    imul rax, rcx
    add rax, 7
    shr rax, 3
    inc rax
    movsxd rdx, edx
    imul rax, rdx
    ret

# Internal: void png_pass_geom(PngCtx *c, int pass /*-1 = plain*/, PngPass *out)
png_pass_geom:
    mov r8d, [rdi + PngCtx.w]
    mov r9d, [rdi + PngCtx.h]
    test esi, esi
    jns .Lpg_adam
    mov dword ptr [rdx + PngPass.x0], 0
    mov dword ptr [rdx + PngPass.y0], 0
    mov dword ptr [rdx + PngPass.dx], 1
    mov dword ptr [rdx + PngPass.dy], 1
    mov [rdx + PngPass.pw], r8d
    mov [rdx + PngPass.ph], r9d
    ret
.Lpg_adam:
    lea rax, [rip + png_adam7]
    lea rax, [rax + rsi * 4]
    movzx ecx, byte ptr [rax];     mov [rdx + PngPass.x0], ecx
    sub r8d, ecx                      # w - x0
    movzx ecx, byte ptr [rax + 1]; mov [rdx + PngPass.y0], ecx
    sub r9d, ecx                      # h - y0
    movzx ecx, byte ptr [rax + 2]; mov [rdx + PngPass.dx], ecx
    movzx r10d, byte ptr [rax + 3]; mov [rdx + PngPass.dy], r10d
    xor eax, eax                      # pw = ceil((w - x0) / dx), 0 if negative
    test r8d, r8d
    jle 1f
    lea eax, [r8d + ecx - 1]
    push rdx
    xor edx, edx
    div ecx
    pop rdx
1:  mov [rdx + PngPass.pw], eax
    xor eax, eax
    test r9d, r9d
    jle 2f
    lea eax, [r9d + r10d - 1]
    push rdx
    xor edx, edx
    div r10d
    pop rdx
2:  mov [rdx + PngPass.ph], eax
    ret

# Internal: int png_inflate(PngCtx *c) -- raw = inflate(IDAT), sized for all passes
png_inflate:
    push rbx
    push r12
    push r13
    sub rsp, PngPass._size + 8
    mov rbx, rdi
    xor r12d, r12d                    # total raw bytes
    mov r13d, -1
    cmp dword ptr [rbx + PngCtx.ilace], 0
    je .Lpi_one
    xor r13d, r13d
.Lpi_one:
    mov rdi, rbx
    mov esi, r13d
    mov rdx, rsp
    call png_pass_geom
    mov rdi, rbx
    mov esi, [rsp + PngPass.pw]
    mov edx, [rsp + PngPass.ph]
    test esi, esi
    jz .Lpi_skip
    call png_pass_bytes
    add r12, rax
.Lpi_skip:
    test r13d, r13d
    js .Lpi_sized
    inc r13d
    cmp r13d, 7
    jl .Lpi_one
.Lpi_sized:
    mov [rbx + PngCtx.raw_n], r12
    lea rdi, [r12 + 16]
    call mem_alloc
    mov [rbx + PngCtx.raw], rax
    test rax, rax
    jz .Lpi_nomem
    mov rdi, [rbx + PngCtx.idat]
    mov rsi, [rbx + PngCtx.idat_n]
    mov rdx, rax
    mov rcx, r12
    call inflate_zlib
    test rax, rax
    jle .Lpi_bad                      # nothing usable (a short stream keeps partial rows)
    xor eax, eax
    jmp .Lpi_ret
.Lpi_bad:
    mov eax, IMG_E_CORRUPT
    jmp .Lpi_ret
.Lpi_nomem:
    mov eax, IMG_E_NOMEM
.Lpi_ret:
    add rsp, PngPass._size + 8
    pop r13
    pop r12
    pop rbx
    ret

# Internal: void png_emit_all(PngCtx *c) -- unfilter + convert every pass into the image
png_emit_all:
    push rbx
    push r12
    push r13
    sub rsp, PngPass._size + 8
    mov rbx, rdi
    mov r12, [rbx + PngCtx.raw]
    mov r13d, -1
    cmp dword ptr [rbx + PngCtx.ilace], 0
    je .Lpe_pass
    xor r13d, r13d
.Lpe_pass:
    mov rdi, rbx
    mov esi, r13d
    mov rdx, rsp
    call png_pass_geom
    cmp dword ptr [rsp + PngPass.pw], 0
    je .Lpe_next
    cmp dword ptr [rsp + PngPass.ph], 0
    je .Lpe_next
    mov rdi, rbx
    mov rsi, r12
    mov rdx, rsp
    call png_run_pass                 # -> rax = next pass data
    mov r12, rax
.Lpe_next:
    test r13d, r13d
    js .Lpe_done
    inc r13d
    cmp r13d, 7
    jl .Lpe_pass
.Lpe_done:
    add rsp, PngPass._size + 8
    pop r13
    pop r12
    pop rbx
    ret
