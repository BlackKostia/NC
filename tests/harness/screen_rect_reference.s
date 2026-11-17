# Frozen reference oracle: the hand-written asm that src/tui/screen_rect.c replaced (tests/test_c_tui_data.py diffs against it)
# ScreenBuffer rectangle helpers for graphics overlays (Sixel / Kitty images drawn over cells):
# does the next flush rewrite any cell of a rect, and forcing a rect to be rewritten.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .text
.global ScreenBuffer_rect_changed
.global ScreenBuffer_rect_invalidate

# Internal: clip (x esi, y edx, w ecx, h r8d) to the buffer -> same registers, ZF = 1 if empty
sr_clip:
    test esi, esi
    jns 1f
    add ecx, esi
    xor esi, esi
1:  test edx, edx
    jns 2f
    add r8d, edx
    xor edx, edx
2:  mov eax, [rdi + ScreenBuffer.width]
    sub eax, esi
    cmp ecx, eax
    jle 3f
    mov ecx, eax
3:  mov eax, [rdi + ScreenBuffer.height]
    sub eax, edx
    cmp r8d, eax
    jle 4f
    mov r8d, eax
4:  xor eax, eax
    test ecx, ecx
    jle 5f
    test r8d, r8d
    jle 5f
    mov eax, 1
5:  test eax, eax
    ret

# int ScreenBuffer_rect_changed(ScreenBuffer *s, int x, int y, int w, int h)
ScreenBuffer_rect_changed:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov eax, 1
    cmp dword ptr [rdi + ScreenBuffer.force_full], 0
    jne .Lrcg_ret
    call sr_clip
    jz .Lrcg_ret
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    lea r15d, [edx + r8d]             # end row
.Lrcg_row:
    xor eax, eax
    cmp r13d, r15d
    jge .Lrcg_ret
    mov eax, r13d
    imul eax, [rbx + ScreenBuffer.width]
    add eax, r12d
    shl rax, 4
    mov rdi, [rbx + ScreenBuffer.back]
    add rdi, rax
    mov rsi, [rbx + ScreenBuffer.front]
    add rsi, rax
    mov edx, r14d
    call os_mem_mismatch16
    cmp rax, r14
    jb .Lrcg_yes
    inc r13d
    jmp .Lrcg_row
.Lrcg_yes:
    mov eax, 1
.Lrcg_ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# void ScreenBuffer_rect_invalidate(ScreenBuffer *s, int x, int y, int w, int h)
ScreenBuffer_rect_invalidate:
    call sr_clip
    jz .Lri_ret
    lea r9d, [edx + r8d]
.Lri_row:
    cmp edx, r9d
    jge .Lri_ret
    mov eax, edx
    imul eax, [rdi + ScreenBuffer.width]
    add eax, esi
    shl rax, 4
    add rax, [rdi + ScreenBuffer.front]
    mov r10d, ecx
.Lri_cell:
    mov dword ptr [rax + Cell.ch], 0xFFFFFFFF     # never equal to a real cell: rewritten
    add rax, Cell._size
    dec r10d
    jnz .Lri_cell
    inc edx
    jmp .Lri_row
.Lri_ret:
    ret
