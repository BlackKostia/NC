# Pixel-protocol image overlay (Sixel / Kitty) for one picture at a time. Renderers announce the
# picture every frame (img_overlay_show); around ScreenBuffer_flush the overlay decides whether
# to (re)send it: new picture, moved, cells under a Sixel image rewritten, or a dialog closed.
# A Kitty image is deleted and a Sixel area repainted (cells invalidated) when it disappears.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .rodata
seq_kitty_del: .ascii "\x1b_Ga=d,d=A,q=2\x1b\\"
.equ SEQ_KITTY_DEL_LEN, 16

.section .bss
.align 8
ov_cur:        .space ImgPlace._size      # announced during this frame's render
ov_last:       .space ImgPlace._size      # currently on screen
ov_cur_on:     .space 4
ov_last_on:    .space 4
ov_last_proto: .space 4
ov_emit:       .space 4

.section .text
.global img_overlay_show
.global img_preview_pre_flush
.global img_preview_post_flush

# void img_overlay_show(const ImgPlace *p) -- call from render; valid for the current frame only
img_overlay_show:
    mov rsi, rdi
    lea rdi, [rip + ov_cur]
    mov edx, ImgPlace._size
    mov dword ptr [rip + ov_cur_on], 1
    jmp mem_copy

# void img_preview_pre_flush(App *app)
img_preview_pre_flush:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov dword ptr [rip + ov_emit], 0
    xor r12d, r12d                    # visible this frame?
    cmp dword ptr [rip + ov_cur_on], 0
    je .Lpf_hide
    mov rax, [rbx + App.active_dialog]
    test rax, rax
    jz 1f
    cmp rax, [rip + ov_cur + ImgPlace.owner]
    jne .Lpf_hide                     # another dialog covers the picture
1:  mov r12d, 1
.Lpf_hide:
    mov dword ptr [rip + ov_cur_on], 0
    cmp dword ptr [rip + ov_last_on], 0
    je .Lpf_show
    test r12d, r12d
    jz .Lpf_drop
    call ov_same
    test eax, eax
    jnz .Lpf_keep
.Lpf_drop:
    mov rdi, rbx
    call ov_remove
.Lpf_show:
    mov [rip + ov_emit], r12d         # not on screen yet: send it if visible
    jmp .Lpf_ret
.Lpf_keep:
    cmp dword ptr [rip + ov_last_proto], IMG_PROTO_SIXEL
    jne .Lpf_ret                      # Kitty images live above the cells
    mov rdi, [rbx + App.screen]
    mov esi, [rip + ov_cur + ImgPlace.x]
    mov edx, [rip + ov_cur + ImgPlace.y]
    mov ecx, [rip + ov_cur + ImgPlace.w]
    mov r8d, [rip + ov_cur + ImgPlace.h]
    call ScreenBuffer_rect_changed    # cells under the Sixel will be rewritten: resend after flush
    mov [rip + ov_emit], eax
.Lpf_ret:
    add rsp, 8
    pop r12
    pop rbx
    ret

# Internal: int ov_same(void) -- the announced picture is the one on screen (same data and place)
ov_same:
    xor eax, eax
    mov rcx, [rip + ov_cur + ImgPlace.key]
    cmp rcx, [rip + ov_last + ImgPlace.key]
    jne 1f
    mov rcx, [rip + ov_cur + ImgPlace.data]
    cmp rcx, [rip + ov_last + ImgPlace.data]
    jne 1f
    mov rcx, [rip + ov_cur + ImgPlace.x]          # x, y
    cmp rcx, [rip + ov_last + ImgPlace.x]
    jne 1f
    mov rcx, [rip + ov_cur + ImgPlace.w]          # w, h
    cmp rcx, [rip + ov_last + ImgPlace.w]
    jne 1f
    mov eax, 1
1:  ret

# Internal: void ov_remove(App *app) -- take the on-screen picture away
ov_remove:
    push rbx
    mov rbx, rdi
    mov dword ptr [rip + ov_last_on], 0
    cmp dword ptr [rip + ov_last_proto], IMG_PROTO_KITTY
    jne .Lrm_sixel
    mov edi, STDOUT_FD
    lea rsi, [rip + seq_kitty_del]
    mov edx, SEQ_KITTY_DEL_LEN
    call sys_write_all
    pop rbx
    ret
.Lrm_sixel:
    mov rdi, [rbx + App.screen]       # repaint the cells the Sixel pixels covered
    mov esi, [rip + ov_last + ImgPlace.x]
    mov edx, [rip + ov_last + ImgPlace.y]
    mov ecx, [rip + ov_last + ImgPlace.w]
    mov r8d, [rip + ov_last + ImgPlace.h]
    call ScreenBuffer_rect_invalidate
    pop rbx
    ret

# void img_preview_post_flush(App *app) -- send the picture after the cells were flushed
img_preview_post_flush:
    cmp dword ptr [rip + ov_emit], 0
    je .Lpo_ret
    push rbx
    sub rsp, 48                       # "ESC [ row ; col H"
    mov word ptr [rsp], 0x5B1B
    lea rbx, [rsp + 2]
    mov edi, [rip + ov_cur + ImgPlace.y]
    inc edi
    mov rsi, rbx
    call u64_to_dec
    add rbx, rax
    mov byte ptr [rbx], ';'
    inc rbx
    mov edi, [rip + ov_cur + ImgPlace.x]
    inc edi
    mov rsi, rbx
    call u64_to_dec
    add rbx, rax
    mov byte ptr [rbx], 'H'
    inc rbx
    mov rdx, rbx
    sub rdx, rsp
    mov edi, STDOUT_FD
    mov rsi, rsp
    call sys_write_all
    mov edi, STDOUT_FD
    mov rsi, [rip + ov_cur + ImgPlace.data]
    mov rdx, [rip + ov_cur + ImgPlace.len]
    call sys_write_all
    lea rdi, [rip + ov_last]
    lea rsi, [rip + ov_cur]
    mov edx, ImgPlace._size
    call mem_copy
    mov dword ptr [rip + ov_last_on], 1
    call term_img_proto
    mov [rip + ov_last_proto], eax
    mov dword ptr [rip + ov_emit], 0
    add rsp, 48
    pop rbx
.Lpo_ret:
    ret
