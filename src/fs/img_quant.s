# Adaptive palette quantizer for Sixel: alpha is blended over the background, colors are binned
# to 15 bits (5-5-5) and the 255 most frequent bins (bin means, not centres) become the palette;
# every other used bin maps to its nearest palette entry.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.equ QB_N,     32768
.equ QW_CNT,   0                       # u32 counts[32768]
.equ QW_R,     QB_N * 4                # u32 sums
.equ QW_G,     QB_N * 8
.equ QW_B,     QB_N * 12
.equ QW_MAP,   QB_N * 16               # u8 bin -> palette index
.equ QW_SIZE,  QB_N * 17
.equ Q_MAXPAL, 255

.section .text
.global img_quantize

# int img_quantize(const uint8_t *rgba, size_t n, uint32_t bg /*0xRRGGBB*/, uint8_t *idx,
#                  uint32_t *pal /*256 x 0x00RRGGBB*/) -> palette size (0 on OOM)
img_quantize:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16
    mov rbx, rdi
    mov r12, rsi
    mov [rsp], edx
    mov r13, rcx
    mov r14, r8
    mov edi, QW_SIZE
    call mem_alloc
    test rax, rax
    jz .Lq_fail
    mov r15, rax
    mov rdi, rbx
    mov rsi, r12
    mov edx, [rsp]
    mov rcx, r15
    call q_histogram
    mov rdi, r15
    mov rsi, r14
    call q_palette                    # eax = palette size
    mov [rsp + 4], eax
    mov rdi, rbx
    mov rsi, r12
    mov edx, [rsp]
    mov rcx, r15
    mov r8, r13
    call q_map_pixels
    mov rdi, r15
    call mem_free
    mov eax, [rsp + 4]
    jmp .Lq_ret
.Lq_fail:
    xor eax, eax
.Lq_ret:
    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: uint32_t q_pixel(uint32_t rgba /*eax*/, uint32_t bg /*edx*/) -> eax = 0x00RRGGBB blended
q_pixel:
    mov ecx, eax
    shr ecx, 24
    cmp ecx, 255
    jne .Lqp_blend
    mov ecx, eax                      # opaque: R,G,B bytes -> 0xRRGGBB
    and ecx, 0xFF
    shl ecx, 16
    mov r8d, eax
    and r8d, 0xFF00
    or ecx, r8d
    shr eax, 16
    and eax, 0xFF
    or eax, ecx
    ret
.Lqp_blend:
    push rbx
    push r12
    mov r12d, ecx                     # alpha
    xor r11d, r11d
    mov r10d, 16                      # destination shift: R=16, G=8, B=0
.Lqp_ch:
    movzx r9d, al
    imul r9d, r12d
    mov ebx, edx
    mov ecx, r10d
    shr ebx, cl
    and ebx, 0xFF
    mov ecx, 255
    sub ecx, r12d
    imul ebx, ecx
    add r9d, ebx
    imul r9d, r9d, 257
    add r9d, 257
    shr r9d, 16
    mov ecx, r10d
    shl r9d, cl
    or r11d, r9d
    shr eax, 8
    sub r10d, 8
    jns .Lqp_ch
    mov eax, r11d
    pop r12
    pop rbx
    ret

# Internal: bin = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3) for 0xRRGGBB in eax -> ecx
q_bin:
    mov ecx, eax
    shr ecx, 9
    and ecx, 0x7C00
    mov r8d, eax
    shr r8d, 6
    and r8d, 0x03E0
    or ecx, r8d
    mov r8d, eax
    shr r8d, 3
    and r8d, 0x1F
    or ecx, r8d
    ret

# Internal: void q_histogram(const uint8_t *rgba, size_t n, uint32_t bg, void *work)
q_histogram:
    push rbx
    push r12
    push r13
    push r14
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov r14, rcx
.Lqh_px:
    test r12, r12
    jz .Lqh_done
    mov eax, [rbx]
    mov edx, r13d
    call q_pixel
    call q_bin
    inc dword ptr [r14 + QW_CNT + rcx * 4]
    mov edx, eax
    shr edx, 16
    and edx, 0xFF
    add [r14 + QW_R + rcx * 4], edx
    mov edx, eax
    shr edx, 8
    and edx, 0xFF
    add [r14 + QW_G + rcx * 4], edx
    and eax, 0xFF
    add [r14 + QW_B + rcx * 4], eax
    add rbx, 4
    dec r12
    jmp .Lqh_px
.Lqh_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: int q_palette(void *work, uint32_t *pal) -- pick bins, fill map[] -> palette size
q_palette:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    mov r12, rsi
    xor r13d, r13d                    # palette size
.Lpl_pick:
    cmp r13d, Q_MAXPAL
    jge .Lpl_rest
    xor ecx, ecx                      # most frequent unpicked bin
    xor r14d, r14d                    # best count
    mov r15d, -1
.Lpl_scan:
    mov eax, [rbx + QW_CNT + rcx * 4]
    cmp eax, r14d
    jbe 1f
    mov r14d, eax
    mov r15d, ecx
1:  inc ecx
    cmp ecx, QB_N
    jb .Lpl_scan
    test r15d, r15d
    js .Lpl_rest                      # every used bin is in the palette
    mov rdi, rbx
    mov esi, r15d
    mov edx, r14d
    call q_bin_mean                   # eax = mean color
    mov [r12 + r13 * 4], eax
    mov [rbx + QW_MAP + r15], r13b
    mov dword ptr [rbx + QW_CNT + r15 * 4], 0                 # picked: out of the race
    inc r13d
    jmp .Lpl_pick
.Lpl_rest:
    mov rdi, rbx
    mov rsi, r12
    mov edx, r13d
    call q_map_rest
    mov eax, r13d
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: uint32_t q_bin_mean(void *work, int bin, uint32_t count) -> 0xRRGGBB
q_bin_mean:
    mov r8d, edx
    mov eax, [rdi + QW_R + rsi * 4]
    xor edx, edx
    div r8d
    mov r9d, eax
    shl r9d, 16
    mov eax, [rdi + QW_G + rsi * 4]
    xor edx, edx
    div r8d
    shl eax, 8
    or r9d, eax
    mov eax, [rdi + QW_B + rsi * 4]
    xor edx, edx
    div r8d
    or eax, r9d
    ret

# Internal: void q_map_rest(void *work, const uint32_t *pal, int n) -- nearest entry for unpicked bins
q_map_rest:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    xor r14d, r14d                    # bin
.Lmr_bin:
    cmp r14d, QB_N
    jge .Lmr_done
    cmp dword ptr [rbx + QW_CNT + r14 * 4], 0
    je .Lmr_next                      # unused or already picked
    mov rdi, rbx
    mov esi, r14d
    mov edx, [rbx + QW_CNT + r14 * 4]
    call q_bin_mean
    mov rdi, r12
    mov esi, r13d
    mov edx, eax
    call q_nearest
    mov [rbx + QW_MAP + r14], al
.Lmr_next:
    inc r14d
    jmp .Lmr_bin
.Lmr_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# Internal: int q_nearest(const uint32_t *pal, int n, uint32_t rgb) -> index of the closest entry
q_nearest:
    push rbx
    push r12
    xor eax, eax                      # best index
    mov r8d, -1                       # best distance (unsigned max)
    xor ecx, ecx
.Lqn_loop:
    cmp ecx, esi
    jge .Lqn_ret
    mov r9d, [rdi + rcx * 4]
    xor r10d, r10d
    mov r11d, 16
.Lqn_ch:
    push rcx
    mov ecx, r11d
    mov ebx, r9d
    shr ebx, cl
    and ebx, 0xFF
    mov r12d, edx
    shr r12d, cl
    and r12d, 0xFF
    pop rcx
    sub ebx, r12d
    imul ebx, ebx
    add r10d, ebx
    sub r11d, 8
    jns .Lqn_ch
    cmp r10d, r8d
    jae 1f
    mov r8d, r10d
    mov eax, ecx
1:  inc ecx
    jmp .Lqn_loop
.Lqn_ret:
    pop r12
    pop rbx
    ret

# Internal: void q_map_pixels(const uint8_t *rgba, size_t n, uint32_t bg, void *work, uint8_t *idx)
q_map_pixels:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov r14, rcx
    mov r15, r8
.Lmp_px:
    test r12, r12
    jz .Lmp_done
    mov eax, [rbx]
    mov edx, r13d
    call q_pixel
    call q_bin
    movzx eax, byte ptr [r14 + QW_MAP + rcx]
    mov [r15], al
    add rbx, 4
    inc r15
    dec r12
    jmp .Lmp_px
.Lmp_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
