# src/ui/img_preview.s - Terminal Image Preview (Kitty Graphics Protocol + Half-Block Fallback) — img preview api (split from img_preview.s)

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
.extern inflate_zlib
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
img_preview_try_render:
    cmp qword ptr [rdi + PreviewPane.buf_len], 8
    jb .Liptr_no
    mov rax, [rdi + PreviewPane.buf]
    mov rcx, 0x0A1A0A0D474E5089
    cmp [rax], rcx
    jne .Liptr_no
    push rbx; push r12
    mov rbx, rdi; mov r12, rsi
    mov rdi, rbx
    call img_is_kitty_mode
    test eax, eax
    jz .Liptr_hb
    mov eax, [rbx + Widget.x]; inc eax; mov [rip + g_kitty_x], eax
    mov eax, [rbx + Widget.y]; add eax, 3; mov [rip + g_kitty_y], eax
    mov eax, [rbx + Widget.w]; sub eax, 2; mov [rip + g_kitty_w], eax
    mov eax, [rbx + Widget.h]; sub eax, 4; mov [rip + g_kitty_h], eax
    lea rdi, [rip + g_kitty_path]
    lea rsi, [rbx + PreviewPane.target_path]
    mov edx, PATH_MAX
    call str_copy
    mov dword ptr [rip + g_kitty_pending], 1
    mov eax, 1
    pop r12; pop rbx; ret
.Liptr_hb:
    mov rdi, rbx; mov rsi, r12
    call png_draw_halfblock
    pop r12; pop rbx; ret
.Liptr_no:
    xor eax, eax; ret

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
