# ViewerDialog image zoom & pan input: +/-/1/0/arrows/mouse wheel.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .rodata
.align 4
zoom_steps: .long 25, 33, 50, 67, 75, 100, 125, 150, 200, 300, 400, 600, 800
.equ ZOOM_STEP_CNT, 13

.section .text
.global vim_zoom_key
.global vim_zoom_mouse
.global vz_invalidate

# int vim_zoom_key(ViewerDialog *v, Event *e) -> 1 if handled
vim_zoom_key:
    cmp dword ptr [rdi + ViewerDialog.img_mode], 0
    je .Lzk_no
    cmp dword ptr [rdi + ViewerDialog.img_state], 1
    jne .Lzk_no
    push rbx
    mov rbx, rdi
    mov eax, [rsi + Event.lat]
    cmp eax, '+';      je .Lzk_in
    cmp eax, '=';      je .Lzk_in
    cmp eax, '-';      je .Lzk_out
    cmp eax, '_';      je .Lzk_out
    cmp eax, '1';      je .Lzk_100
    cmp eax, '0';      je .Lzk_fit
    cmp eax, 'f';      je .Lzk_fit
    cmp eax, 'b';      je .Lzk_braille
    cmp eax, 'B';      je .Lzk_braille
    cmp eax, 'o';      je .Lzk_open
    cmp eax, 'O';      je .Lzk_open
    mov esi, -1; xor edx, edx; cmp eax, KEY_LEFT;  je .Lzk_pan
    mov esi, 1;  xor edx, edx; cmp eax, KEY_RIGHT; je .Lzk_pan
    xor esi, esi; mov edx, -1; cmp eax, KEY_UP;    je .Lzk_pan
    xor esi, esi; mov edx, 1;  cmp eax, KEY_DOWN;  je .Lzk_pan
    xor esi, esi; mov edx, -4; cmp eax, KEY_PGUP;  je .Lzk_pan
    xor esi, esi; mov edx, 4;  cmp eax, KEY_PGDN;  je .Lzk_pan
    cmp eax, KEY_HOME; je .Lzk_home
    cmp eax, KEY_END;  je .Lzk_end
    pop rbx
.Lzk_no:
    xor eax, eax
    ret
.Lzk_in:
    mov esi, 1;  jmp .Lzk_step
.Lzk_out:
    mov esi, -1
.Lzk_step:
    mov rdi, rbx; call vz_step_zoom; jmp .Lzk_yes
.Lzk_100:
    mov rdi, rbx; mov esi, 100; call vz_set_zoom; jmp .Lzk_yes
.Lzk_fit:
    mov rdi, rbx; xor esi, esi; call vz_set_zoom; jmp .Lzk_yes
.Lzk_braille:
    xor dword ptr [rbx + ViewerDialog.img_braille], 1
    jmp .Lzk_inv
.Lzk_open:
    lea rdi, [rbx + ViewerDialog.path]
    mov rax, [rbx + Dialog.app]
    mov rsi, [rax + App.envp]
    call sys_open_external
    jmp .Lzk_yes
.Lzk_home:
    mov dword ptr [rbx + ViewerDialog.img_pan_x], 0
    mov dword ptr [rbx + ViewerDialog.img_pan_y], 0
    jmp .Lzk_inv
.Lzk_end:
    mov eax, [rbx + ViewerDialog.img + Image.w]
    mov [rbx + ViewerDialog.img_pan_x], eax
    mov eax, [rbx + ViewerDialog.img + Image.h]
    mov [rbx + ViewerDialog.img_pan_y], eax
    jmp .Lzk_inv
.Lzk_pan:
    mov rdi, rbx; call vz_pan
.Lzk_inv:
    mov rdi, rbx; call vz_invalidate
.Lzk_yes:
    mov eax, 1
    pop rbx
    ret

# int vim_zoom_mouse(ViewerDialog *v, Event *e) -> 1 if handled
vim_zoom_mouse:
    cmp dword ptr [rdi + ViewerDialog.img_mode], 0
    je .Lzm_no
    cmp dword ptr [rdi + ViewerDialog.img_state], 1
    jne .Lzm_no
    cmp dword ptr [rsi + Event.mouse_kind], MACT_WHEEL
    jne vw_img_scrollbar_mouse
    push rbx
    mov rbx, rdi
    mov ecx, [rsi + Event.mods]
    mov eax, [rbx + ViewerDialog.img_zoom]
    test eax, eax; jz .Lzm_zoom
    test ecx, MOD_CTRL; jnz .Lzm_zoom
    mov edx, 1
    cmp dword ptr [rsi + Event.mouse_btn], MOUSE_WHEEL_UP
    jne 1f
    mov edx, -1
1:  test ecx, MOD_SHIFT; jnz .Lzm_horiz
    mov eax, [rbx + ViewerDialog.img_box_h]; imul eax, 100
    push rdx; xor edx, edx; div dword ptr [rbx + ViewerDialog.img_zoom]; pop rdx
    cmp eax, [rbx + ViewerDialog.img + Image.h]
    jge .Lzm_horiz
    xor esi, esi; jmp .Lzm_pan
.Lzm_horiz:
    mov esi, edx; xor edx, edx
.Lzm_pan:
    mov rdi, rbx; call vz_pan
    mov rdi, rbx; call vz_invalidate
    jmp .Lzm_yes
.Lzm_zoom:
    mov eax, [rsi + Event.mouse_btn]
    mov esi, 1
    cmp eax, MOUSE_WHEEL_UP
    je 2f
    mov esi, -1
2:  mov rdi, rbx; call vz_step_zoom
.Lzm_yes:
    mov eax, 1
    pop rbx
    ret
.Lzm_no:
    xor eax, eax
    ret

# Internal: int vz_cur_pct(ViewerDialog *v)
vz_cur_pct:
    mov eax, [rdi + ViewerDialog.img_zoom]
    test eax, eax
    jnz 1f
    push rdi
    mov edx, [rdi + ViewerDialog.img_box_w]
    mov ecx, [rdi + ViewerDialog.img_box_h]
    test edx, edx; jz 2f
    test ecx, ecx; jz 2f
    mov esi, [rdi + ViewerDialog.img + Image.h]
    mov edi, [rdi + ViewerDialog.img + Image.w]
    call img_fit
    pop rdi
    imul eax, 100
    xor edx, edx
    div dword ptr [rdi + ViewerDialog.img + Image.w]
    cmp eax, 10
    jge 1f
    mov eax, 10
    ret
2:  pop rdi
    mov eax, 100
1:  ret

# Internal: void vz_step_zoom(ViewerDialog *v, int dir)
vz_step_zoom:
    push rbx; push r12
    mov rbx, rdi; mov r12d, esi
    call vz_cur_pct
    lea r8, [rip + zoom_steps]
    test r12d, r12d; js .Lsz_down
    xor ecx, ecx
.Lsz_up:
    cmp ecx, ZOOM_STEP_CNT; jge .Lsz_max
    mov edx, [r8 + rcx * 4]
    cmp edx, eax; jg .Lsz_apply
    inc ecx; jmp .Lsz_up
.Lsz_max:
    mov edx, 800; jmp .Lsz_apply
.Lsz_down:
    mov ecx, ZOOM_STEP_CNT - 1
.Lsz_dn:
    test ecx, ecx; js .Lsz_fit
    mov edx, [r8 + rcx * 4]
    cmp edx, eax; jl .Lsz_apply
    dec ecx; jmp .Lsz_dn
.Lsz_fit:
    xor edx, edx
.Lsz_apply:
    mov rdi, rbx; mov esi, edx; call vz_set_zoom
    pop r12; pop rbx; ret

# Internal: void vz_set_zoom(ViewerDialog *v, int pct)
vz_set_zoom:
    push rbx
    mov rbx, rdi
    mov eax, [rbx + ViewerDialog.img_zoom]
    mov [rbx + ViewerDialog.img_zoom], esi
    test esi, esi
    jnz 1f
    mov dword ptr [rbx + ViewerDialog.img_pan_x], 0
    mov dword ptr [rbx + ViewerDialog.img_pan_y], 0
    jmp 2f
1:  test eax, eax; jnz 2f
    mov eax, [rbx + ViewerDialog.img_box_w]; imul eax, 100
    xor edx, edx; div esi
    mov ecx, [rbx + ViewerDialog.img + Image.w]; sub ecx, eax; sar ecx, 1
    test ecx, ecx; jns 3f; xor ecx, ecx
3:  mov [rbx + ViewerDialog.img_pan_x], ecx
    mov eax, [rbx + ViewerDialog.img_box_h]; imul eax, 100
    xor edx, edx; div esi
    mov ecx, [rbx + ViewerDialog.img + Image.h]; sub ecx, eax; sar ecx, 1
    test ecx, ecx; jns 4f; xor ecx, ecx
4:  mov [rbx + ViewerDialog.img_pan_y], ecx
2:  mov rdi, rbx; call vz_invalidate
    pop rbx; ret

# Internal: void vz_pan(ViewerDialog *v, int dx, int dy)
vz_pan:
    mov r8d, [rdi + ViewerDialog.img_zoom]
    test r8d, r8d; jz .Lvp_ret
    mov r9d, edx
    mov eax, [rdi + ViewerDialog.img_box_w]; imul eax, 100
    xor edx, edx; div r8d
    test eax, eax; jnz 1f; mov eax, 1
1:  mov ecx, eax; shr ecx, 4; test ecx, ecx; jnz 2f; mov ecx, 1
2:  imul esi, ecx; add esi, [rdi + ViewerDialog.img_pan_x]
    mov ecx, [rdi + ViewerDialog.img + Image.w]; sub ecx, eax
    test ecx, ecx; jns 3f; xor ecx, ecx
3:  test esi, esi; jns 4f; xor esi, esi
4:  cmp esi, ecx; jle 5f; mov esi, ecx
5:  mov [rdi + ViewerDialog.img_pan_x], esi
    mov eax, [rdi + ViewerDialog.img_box_h]; imul eax, 100
    xor edx, edx; div r8d
    test eax, eax; jnz 6f; mov eax, 1
6:  mov ecx, eax; shr ecx, 4; test ecx, ecx; jnz 7f; mov ecx, 1
7:  imul r9d, ecx; add r9d, [rdi + ViewerDialog.img_pan_y]
    mov ecx, [rdi + ViewerDialog.img + Image.h]; sub ecx, eax
    test ecx, ecx; jns 8f; xor ecx, ecx
8:  test r9d, r9d; jns 9f; xor r9d, r9d
9:  cmp r9d, ecx; jle 10f; mov r9d, ecx
10: mov [rdi + ViewerDialog.img_pan_y], r9d
.Lvp_ret:
    ret

# Internal: void vz_invalidate(ViewerDialog *v)
vz_invalidate:
    mov qword ptr [rdi + ViewerDialog.img_cache_key], -1
    mov qword ptr [rdi + ViewerDialog.enc_key], 0
    mov rax, [rdi + Dialog.app]
    mov dword ptr [rax + App.need_redraw], 1
    ret
