# Image preview placement: half-block thumbnail in the preview pane or a Kitty Graphics Protocol
# transfer of the PNG itself (queued during render, written after the frame flush).

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"
.equ IMG_MAX_RAW, 262144      # 256 KiB max PNG payload
.extern env_getenv
.extern str_casecmp
.extern str_contains_ci
.extern str_copy
.extern u64_to_dec
.extern sys_write_all
.extern fs_read_file_head
.extern mem_alloc
.extern mem_free
.extern ScreenBuffer_set_pen
.extern ScreenBuffer_set_cell

.section .bss
.align 4
g_kitty_active:  .space 4
g_kitty_pending: .space 4
g_kitty_x:       .space 4
g_kitty_y:       .space 4
g_kitty_w:       .space 4
g_kitty_h:       .space 4
g_kitty_path:    .space PATH_MAX

.section .rodata
seq_kitty_del:  .asciz "\x1b_Ga=d,d=A,q=2\x1b\\"
seq_kitty_hdr1: .asciz "\x1b["
seq_kitty_hdr2: .asciz "H\x1b_Ga=T,f=100,i=1,c="
seq_kitty_hdr3: .asciz ",r="
seq_kitty_hdr4: .asciz ",q=2;"

.section .text
.global img_preview_try_render
.global img_preview_pre_flush
.global img_preview_post_flush

# int img_preview_try_render(PreviewPane *pv, ScreenBuffer *sb, Theme *th)
# Draws the decoded thumbnail (Kitty: the PNG itself), or a note for an undecodable image.
img_preview_try_render:
    xor eax, eax
    cmp dword ptr [rdi + PreviewPane.thumb_len], IMG_THUMB_HDR
    jb .Liptr_ret
    push rbx
    push r12
    push r13
    sub rsp, 32                       # ImgView { rgba, iw, ih, bg }
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rax, [rbx + PreviewPane.buf]
    add rax, PV_THUMB_OFF
    movzx ecx, word ptr [rax + 12]
    test ecx, ecx
    jz .Liptr_unsup
    cmp dword ptr [rax], IMG_FMT_PNG
    jne .Liptr_hb
    cmp qword ptr [rbx + PreviewPane.file_size], IMG_MAX_RAW
    ja .Liptr_hb
    mov rdi, rbx
    call img_is_kitty_mode
    test eax, eax
    jz .Liptr_hb
    mov rdi, rbx
    call iptr_kitty_queue
    jmp .Liptr_done
.Liptr_hb:
    mov rax, [rbx + PreviewPane.buf]
    add rax, PV_THUMB_OFF
    lea rcx, [rax + IMG_THUMB_HDR]
    mov [rsp], rcx
    movzx ecx, word ptr [rax + 12]
    mov [rsp + 8], ecx
    movzx ecx, word ptr [rax + 14]
    mov [rsp + 12], ecx
    mov ecx, [r13 + Theme.surface]
    mov [rsp + 16], ecx
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    inc esi
    mov edx, [rbx + Widget.y]
    add edx, 3
    mov ecx, [rbx + Widget.w]
    sub ecx, 2
    mov r8d, [rbx + Widget.h]
    sub r8d, 5                        # keep the bottom border free for the mode bar
    mov r9, rsp
    call img_draw_rgba
    jmp .Liptr_done
.Liptr_unsup:
    mov rdi, r12
    mov esi, [r13 + Theme.warn_fg]
    mov edx, [r13 + Theme.surface]
    xor ecx, ecx
    call ScreenBuffer_set_pen
    call i18n_get
    mov rcx, [rax + LangStrings.img_unsup]
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 2
    mov edx, [rbx + Widget.y]
    add edx, 3
    mov r8d, [rbx + Widget.w]
    sub r8d, 4
    call ScreenBuffer_draw_text
.Liptr_done:
    mov eax, 1
    add rsp, 32
    pop r13
    pop r12
    pop rbx
.Liptr_ret:
    ret

# Internal: void iptr_kitty_queue(PreviewPane *pv) -- remember where to place the Kitty image
iptr_kitty_queue:
    push rbx
    mov rbx, rdi
    mov eax, [rbx + Widget.x]; inc eax;    mov [rip + g_kitty_x], eax
    mov eax, [rbx + Widget.y]; add eax, 3; mov [rip + g_kitty_y], eax
    mov eax, [rbx + Widget.w]; sub eax, 2; mov [rip + g_kitty_w], eax
    mov eax, [rbx + Widget.h]; sub eax, 5; mov [rip + g_kitty_h], eax
    lea rdi, [rip + g_kitty_path]
    lea rsi, [rbx + PreviewPane.target_path]
    mov edx, PATH_MAX
    call str_copy
    mov dword ptr [rip + g_kitty_pending], 1
    pop rbx
    ret

# void img_preview_pre_flush(App *app)
img_preview_pre_flush:
    cmp dword ptr [rip + g_kitty_active], 0
    je .Lippf_ret
    cmp qword ptr [rdi + App.active_dialog], 0
    jne .Lippf_del
    cmp dword ptr [rip + g_kitty_pending], 0
    jne .Lippf_ret
.Lippf_del:
    mov edi, 1
    lea rsi, [rip + seq_kitty_del]
    mov edx, 16
    call sys_write_all
    mov dword ptr [rip + g_kitty_active], 0
.Lippf_ret:
    ret

# void img_preview_post_flush(App *app)
img_preview_post_flush:
    cmp dword ptr [rip + g_kitty_pending], 0
    je .Lipof_done
    cmp qword ptr [rdi + App.active_dialog], 0
    jne .Lipof_clr
    push rbx; push r12; push r13; sub rsp, 128
    mov edi, IMG_MAX_RAW; call mem_alloc; test rax, rax; jz .Lipof_out
    mov rbx, rax
    lea rdi, [rip + g_kitty_path]; mov rsi, rbx; mov edx, IMG_MAX_RAW; lea rcx, [rsp]
    call fs_read_file_head
    test rax, rax; js .Lipof_f1
    mov r12, [rsp]            # raw len
    lea rdi, [r12 * 2 + 64]; call mem_alloc; test rax, rax; jz .Lipof_f1
    mov r13, rax
    # Build "\x1b[<row>;<col>H\x1b_Ga=T,f=100,i=1,c=<w>,r=<h>,q=2;"
    mov rdi, r13; lea rsi, [rip + seq_kitty_hdr1]; mov edx, 16; call str_copy
    mov edi, [rip + g_kitty_y]; inc edi; lea rsi, [r13 + rax]; push rax; call u64_to_dec; pop rcx; add rax, rcx
    mov byte ptr [r13 + rax], ';'; inc rax
    mov edi, [rip + g_kitty_x]; inc edi; lea rsi, [r13 + rax]; push rax; call u64_to_dec; pop rcx; add rax, rcx
    lea rdi, [r13 + rax]; lea rsi, [rip + seq_kitty_hdr2]; mov edx, 32; push rax; call str_copy; pop rcx; add rax, rcx
    mov edi, [rip + g_kitty_w]; lea rsi, [r13 + rax]; push rax; call u64_to_dec; pop rcx; add rax, rcx
    lea rdi, [r13 + rax]; lea rsi, [rip + seq_kitty_hdr3]; mov edx, 8; push rax; call str_copy; pop rcx; add rax, rcx
    mov edi, [rip + g_kitty_h]; lea rsi, [r13 + rax]; push rax; call u64_to_dec; pop rcx; add rax, rcx
    lea rdi, [r13 + rax]; lea rsi, [rip + seq_kitty_hdr4]; mov edx, 8; push rax; call str_copy; pop rcx; add rax, rcx
    mov rdi, rbx; mov rsi, r12; lea rdx, [r13 + rax]; lea rcx, [rsp + 8]; push rax
    call b64_encode; pop rax; add rax, [rsp + 8]
    mov byte ptr [r13 + rax], 0x1b; mov byte ptr [r13 + rax + 1], '\\'; add rax, 2
    mov edi, 1; mov rsi, r13; mov rdx, rax; call sys_write_all
    mov dword ptr [rip + g_kitty_active], 1
    mov rdi, r13; call mem_free
.Lipof_f1:
    mov rdi, rbx; call mem_free
.Lipof_out:
    add rsp, 128; pop r13; pop r12; pop rbx
.Lipof_clr:
    mov dword ptr [rip + g_kitty_pending], 0
.Lipof_done:
    ret
