# ViewerDialog scrollbars (vertical & horizontal for zoomed images; vertical for text/hex).

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .text
.global vw_draw_img_scrollbars
.global vw_draw_text_scrollbar
.global vw_img_scrollbar_mouse

# Internal: void vw_draw_bar(ScreenBuffer *scr, Theme *th, int x, int y, int track_len,
#                            int horiz, long pos, long vis, long total)
vw_draw_bar:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, 48                       # [0]=x [4]=y [8]=len [12]=horiz [16]=tpos [20]=tlen [24]=i
    mov rbx, rdi; mov r12, rsi
    mov [rsp], edx; mov [rsp + 4], ecx; mov [rsp + 8], r8d; mov [rsp + 12], r9d
    mov r13, [rsp + 96]               # arg7: pos
    mov r14, [rsp + 104]              # arg8: vis
    mov r15, [rsp + 112]              # arg9: total
    test r8d, r8d; jle .Ldb_ret
    cmp r15, r14; jle .Ldb_ret
    test r14, r14; jle .Ldb_ret
    mov eax, r8d; imul rax, r14
    xor edx, edx; div r15
    test eax, eax; jnz 1f; mov eax, 1
1:  cmp eax, [rsp + 8]; jle 2f; mov eax, [rsp + 8]
2:  mov [rsp + 20], eax               # thumb_len
    mov ecx, [rsp + 8]; sub ecx, eax  # travel = track_len - thumb_len
    xor eax, eax
    test ecx, ecx; jle 3f
    mov rax, r15; sub rax, r14        # max_pos = total - vis
    mov r10, rax
    mov rax, r13; imul rax, rcx
    xor edx, edx; div r10
    cmp eax, ecx; jle 3f; mov eax, ecx
3:  mov [rsp + 16], eax               # thumb_pos
    mov dword ptr [rsp + 24], 0
.Ldb_lp:
    mov r13d, [rsp + 24]
    cmp r13d, [rsp + 8]; jge .Ldb_ret
    mov esi, [r12 + Theme.scroll_track]
    mov r14d, CH_SHADE_LIGHT
    mov eax, [rsp + 16]
    cmp r13d, eax; jl 4f
    add eax, [rsp + 20]
    cmp r13d, eax; jge 4f
    mov esi, [r12 + Theme.scroll_thumb]
    mov r14d, CH_BLOCK_FULL
4:  mov rdi, rbx; mov edx, [r12 + Theme.dialog_bg]; xor ecx, ecx
    call ScreenBuffer_set_pen
    mov esi, [rsp]; mov edx, [rsp + 4]
    cmp dword ptr [rsp + 12], 0
    je 5f
    add esi, r13d; jmp 6f
5:  add edx, r13d
6:  mov rdi, rbx; mov ecx, r14d
    call ScreenBuffer_set_cell_pen
    inc dword ptr [rsp + 24]
    jmp .Ldb_lp
.Ldb_ret:
    add rsp, 48
    pop r15; pop r14; pop r13; pop r12; pop rbx
    ret

# void vw_draw_img_scrollbars(ViewerDialog *v, ScreenBuffer *scr, Theme *th)
vw_draw_img_scrollbars:
    cmp dword ptr [rdi + ViewerDialog.img_state], 1
    jne .Ldis_ret
    mov r8d, [rdi + ViewerDialog.img_zoom]
    test r8d, r8d; jz .Ldis_ret
    push rbx; push r12; push r13
    mov rbx, rdi; mov r12, rsi; mov r13, rdx
    mov eax, [rbx + ViewerDialog.img_box_h]; imul eax, 100
    xor edx, edx; div r8d
    test eax, eax; jnz 1f; mov eax, 1
1:  mov edx, [rbx + ViewerDialog.img + Image.h]
    cmp eax, edx; jle 2f; mov eax, edx
2:  push rdx                          # total_h
    push rax                          # vis_h
    mov eax, [rbx + ViewerDialog.img_pan_y]
    push rax                          # pos_y
    mov rdi, r12; mov rsi, r13
    mov edx, [rbx + Widget.x]; add edx, [rbx + Widget.w]; dec edx
    mov ecx, [rbx + Widget.y]; inc ecx
    mov r8d, [rbx + Widget.h]; sub r8d, 3
    xor r9d, r9d
    call vw_draw_bar
    add rsp, 24
    mov r8d, [rbx + ViewerDialog.img_zoom]
    mov eax, [rbx + ViewerDialog.img_box_w]; imul eax, 100
    xor edx, edx; div r8d
    test eax, eax; jnz 3f; mov eax, 1
3:  mov edx, [rbx + ViewerDialog.img + Image.w]
    cmp eax, edx; jle 4f; mov eax, edx
4:  push rdx                          # total_w
    push rax                          # vis_w
    mov eax, [rbx + ViewerDialog.img_pan_x]
    push rax                          # pos_x
    mov rdi, r12; mov rsi, r13
    mov edx, [rbx + Widget.x]; inc edx
    mov ecx, [rbx + Widget.y]; add ecx, [rbx + Widget.h]; dec ecx
    mov r8d, [rbx + Widget.w]; sub r8d, 2
    mov r9d, 1
    call vw_draw_bar
    add rsp, 24
    pop r13; pop r12; pop rbx
.Ldis_ret:
    ret

# void vw_draw_text_scrollbar(ViewerDialog *v, ScreenBuffer *scr, Theme *th, long end_off)
vw_draw_text_scrollbar:
    mov rax, [rdi + ViewerDialog.data_len]
    test rax, rax; jz .Ldts_ret
    mov r8d, [rdi + ViewerDialog.vis_rows]
    test r8d, r8d; jle .Ldts_ret
    cmp dword ptr [rdi + ViewerDialog.hex_mode], 0
    jne .Ldts_hex
    sub rcx, [rdi + ViewerDialog.top_off]
    cmp rcx, 1; jge 1f; mov ecx, 1
1:  mov r9, [rdi + ViewerDialog.top_off]
    jmp .Ldts_draw
.Ldts_hex:
    add rax, 15; shr rax, 4           # total rows
    movsxd rcx, r8d                   # vis rows
    mov r9, [rdi + ViewerDialog.hex_row]
.Ldts_draw:
    push rax                          # total
    push rcx                          # vis
    push r9                           # pos
    mov r10, rdi
    mov rdi, rsi; mov rsi, rdx
    mov edx, [r10 + Widget.x]; add edx, [r10 + Widget.w]; dec edx
    mov ecx, [r10 + Widget.y]; add ecx, 2
    xor r9d, r9d
    call vw_draw_bar
    add rsp, 24
.Ldts_ret:
    ret

# Internal: int vw_scrub_axis(int rel, int track, int img_dim, int box_dim, int zoom) -> clamped pan
vw_scrub_axis:
    push rbx
    mov ebx, edi
    mov eax, ecx; imul eax, 100
    xor edx, edx; div r8d
    test eax, eax; jnz 1f; mov eax, 1
1:  cmp eax, r9d; jle 2f; mov eax, r9d
2:  mov ecx, r9d; sub ecx, eax        # max_pan = img_dim - vis
    test ecx, ecx; jg 3f
    xor eax, eax; pop rbx; ret
3:  dec esi
    cmp esi, 1; jge 4f; mov esi, 1
4:  mov eax, ebx; imul eax, ecx
    xor edx, edx; div esi
    cmp eax, ecx; jle 5f; mov eax, ecx
5:  pop rbx
    ret

# int vw_img_scrollbar_mouse(ViewerDialog *v, Event *e) -> 1 if handled
vw_img_scrollbar_mouse:
    mov r8d, [rdi + ViewerDialog.img_zoom]
    test r8d, r8d; jz .Lsm_no
    mov eax, [rsi + Event.mouse_kind]
    cmp eax, MACT_PRESS; je 1f
    cmp eax, MACT_DRAG;  jne .Lsm_no
1:  cmp dword ptr [rsi + Event.mouse_btn], MOUSE_LEFT
    jne .Lsm_no
    mov ecx, [rsi + Event.mouse_x]
    mov edx, [rsi + Event.mouse_y]
    mov r9d, [rdi + Widget.x]; add r9d, [rdi + Widget.w]; dec r9d
    cmp ecx, r9d; jne .Lsm_chk_h
    mov r10d, [rdi + Widget.y]; inc r10d
    mov r11d, [rdi + Widget.h]; sub r11d, 3
    sub edx, r10d; js .Lsm_no
    cmp edx, r11d; jge .Lsm_no
    push rdi
    mov edi, edx; mov esi, r11d
    mov rcx, [rsp]; mov ecx, [rcx + ViewerDialog.img_box_h]
    mov r9, [rsp]; mov r9d, [r9 + ViewerDialog.img + Image.h]
    call vw_scrub_axis
    pop rdi
    mov [rdi + ViewerDialog.img_pan_y], eax
    call vz_invalidate
    mov eax, 1; ret
.Lsm_chk_h:
    mov r9d, [rdi + Widget.y]; add r9d, [rdi + Widget.h]; dec r9d
    cmp edx, r9d; jne .Lsm_no
    mov r10d, [rdi + Widget.x]; inc r10d
    mov r11d, [rdi + Widget.w]; sub r11d, 2
    sub ecx, r10d; js .Lsm_no
    cmp ecx, r11d; jge .Lsm_no
    push rdi
    mov edi, ecx; mov esi, r11d
    mov rcx, [rsp]; mov ecx, [rcx + ViewerDialog.img_box_w]
    mov r9, [rsp]; mov r9d, [r9 + ViewerDialog.img + Image.w]
    call vw_scrub_axis
    pop rdi
    mov [rdi + ViewerDialog.img_pan_x], eax
    call vz_invalidate
    mov eax, 1; ret
.Lsm_no:
    xor eax, eax
    ret
