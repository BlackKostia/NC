# Baseline JPEG bit layer: MSB-first reader with 0xFF00 unstuffing that stops (feeding zeros) at
# the next marker, magnitude extension and Huffman decoding (8-bit lookup + canonical fallback).

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"
.include "img_jpeg.inc"

.section .text
.global jb_huff
.global jb_extend

# int jb_extend(Jpeg *j, int s) -- receive s bits as a signed JPEG magnitude
jb_extend:
    xor eax, eax
    test esi, esi
    jz .Lbx_ret
    push rbx
    mov ebx, esi
    call jb_bits
    mov ecx, ebx
    dec ecx
    mov edx, 1
    shl edx, cl                       # 1 << (s - 1)
    cmp eax, edx
    jge .Lbx_pos
    mov ecx, ebx
    mov edx, 1
    shl edx, cl
    sub eax, edx
    inc eax                           # v - (1 << s) + 1
.Lbx_pos:
    pop rbx
.Lbx_ret:
    ret

# Internal: int jb_bits(Jpeg *j, int n /*esi, 1..16*/)
jb_bits:
    cmp [rdi + Jpeg.nbits], esi
    jge 1f
    push rsi
    call jb_fill
    pop rsi
1:  mov ecx, [rdi + Jpeg.nbits]
    sub ecx, esi
    mov [rdi + Jpeg.nbits], ecx
    mov rax, [rdi + Jpeg.bits]
    shr rax, cl
    mov ecx, esi
    mov edx, 1
    shl edx, cl
    dec edx
    and eax, edx
    ret

# int jb_huff(Jpeg *j, const HuffTable *t)
jb_huff:
    push rbx
    mov rbx, rsi
    cmp dword ptr [rdi + Jpeg.nbits], 16
    jge 1f
    call jb_fill
1:  mov ecx, [rdi + Jpeg.nbits]
    sub ecx, 8
    mov rax, [rdi + Jpeg.bits]
    shr rax, cl
    movzx eax, al
    movzx eax, word ptr [rbx + HT.look + rax * 2]
    test eax, eax
    jz .Lhf_slow
    mov ecx, eax
    shr ecx, 8
    sub [rdi + Jpeg.nbits], ecx
    movzx eax, al
    pop rbx
    ret
.Lhf_slow:
    mov esi, 9                        # canonical decode, code lengths 9..16
.Lhf_len:
    cmp esi, 16
    jg .Lhf_fail
    mov ecx, [rdi + Jpeg.nbits]
    sub ecx, esi
    mov rax, [rdi + Jpeg.bits]
    shr rax, cl
    mov ecx, esi
    mov edx, 1
    shl edx, cl
    dec edx
    and eax, edx
    cmp eax, [rbx + HT.maxcode + rsi * 4]
    jle .Lhf_hit
    inc esi
    jmp .Lhf_len
.Lhf_hit:
    sub [rdi + Jpeg.nbits], esi
    sub eax, [rbx + HT.mincode + rsi * 4]
    add eax, [rbx + HT.valptr + rsi * 4]
    and eax, 0xFF
    movzx eax, byte ptr [rbx + HT.vals + rax]
    pop rbx
    ret
.Lhf_fail:
    xor eax, eax
    pop rbx
    ret

# Internal: void jb_fill(Jpeg *j) -- top the bit buffer up to > 56 bits (zeros after a marker)
jb_fill:
    mov rsi, [rdi + Jpeg.p]
    mov r8, [rdi + Jpeg.end]
.Lfl_loop:
    cmp dword ptr [rdi + Jpeg.nbits], 56
    jg .Lfl_done
    xor eax, eax
    cmp dword ptr [rdi + Jpeg.marker], 0
    jne .Lfl_push
    cmp rsi, r8
    jae .Lfl_stop
    movzx eax, byte ptr [rsi]
    cmp eax, 0xFF
    je .Lfl_ff
    inc rsi
    jmp .Lfl_push
.Lfl_ff:
    lea rdx, [rsi + 1]
    cmp rdx, r8
    jae .Lfl_stop
    cmp byte ptr [rsi + 1], 0
    jne .Lfl_stop                     # a real marker: stay on it
    add rsi, 2
    jmp .Lfl_push
.Lfl_stop:
    mov dword ptr [rdi + Jpeg.marker], 1
    xor eax, eax
.Lfl_push:
    mov rdx, [rdi + Jpeg.bits]
    shl rdx, 8
    or rdx, rax
    mov [rdi + Jpeg.bits], rdx
    add dword ptr [rdi + Jpeg.nbits], 8
    jmp .Lfl_loop
.Lfl_done:
    mov [rdi + Jpeg.p], rsi
    ret
