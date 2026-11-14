# PreviewPane Widget (Inherits from Widget)
# Displays live file content preview (text with line numbers, or hex dump for binary) or directory metadata.

.intel_syntax noprefix
.include "classes.inc"

.section .rodata
str_PreviewPane:   .asciz "PreviewPane"

PreviewPane_vtbl:
    WIDGET_VTBL_SLOTS str_PreviewPane, Widget_vtbl, PreviewPane._size, PreviewPane_dtor, Widget_layout, PreviewPane_render, Widget_on_key, PreviewPane_on_mouse, Widget_on_focus, Widget_hit_test

.section .text
.global PreviewPane_new
.global PreviewPane_dtor
.global PreviewPane_load
.global PreviewPane_read_sync
.global PreviewPane_accept
.global PreviewPane_vtbl

# PreviewPane *PreviewPane_new(App *app)
PreviewPane_new:
    push rbx
    push r12
    mov r12, rdi

    NEW_OBJ PreviewPane_vtbl, PreviewPane._size
    test rax, rax
    jz .Lppn_fail
    mov rbx, rax

    mov rdi, rbx
    mov rsi, r12
    mov edx, 103
    call Widget_init
    mov [rbx + PreviewPane.app], r12

    mov edi, PV_BUF_TOTAL             # head bytes + NUL, then the image thumbnail
    call mem_alloc
    test rax, rax
    jz .Lppn_fail_free
    mov [rbx + PreviewPane.buf], rax
    mov rax, rbx
    pop r12
    pop rbx
    ret

.Lppn_fail_free:
    mov rdi, rbx
    call mem_free
.Lppn_fail:
    xor eax, eax
    pop r12
    pop rbx
    ret

# void PreviewPane_dtor(PreviewPane *this)
PreviewPane_dtor:
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + PreviewPane.buf]
    call mem_free
    mov qword ptr [rbx + PreviewPane.buf], 0
    pop rbx
    ret

# int PreviewPane_load(PreviewPane *this, const char *full_path, const FileEntry *entry)
# Directories / empty selection are shown immediately (returns 0). For files the pane enters
# the pending state and returns 1: the caller supplies the head bytes in this->buf (async
# reader) followed by PreviewPane_accept, or calls PreviewPane_read_sync.
PreviewPane_load:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi              # full_path
    mov r13, rdx              # entry

    mov dword ptr [rbx + PreviewPane.scroll], 0
    mov qword ptr [rbx + PreviewPane.buf_len], 0
    mov dword ptr [rbx + PreviewPane.total_lines], 0
    mov dword ptr [rbx + PreviewPane.is_binary], 0
    mov dword ptr [rbx + PreviewPane.is_dir], 0
    mov dword ptr [rbx + PreviewPane.pending], 0
    mov dword ptr [rbx + PreviewPane.thumb_len], 0
    mov dword ptr [rbx + PreviewPane.view_mode], PV_MODE_AUTO

    test r13, r13
    jz .Lppl_ldone
    test r12, r12
    jz .Lppl_ldone

    lea rdi, [rbx + PreviewPane.target_path]
    mov rsi, r12
    mov edx, PATH_MAX
    call str_copy

    mov rax, [r13 + FileEntry.size]
    mov [rbx + PreviewPane.file_size], rax
    mov eax, [r13 + FileEntry.mode]
    mov [rbx + PreviewPane.file_mode], eax

    test dword ptr [r13 + FileEntry.flags], (FE_IS_DIR | FE_LINK_DIR)
    jz .Lppl_read_file
    mov dword ptr [rbx + PreviewPane.is_dir], 1
    jmp .Lppl_ldone

.Lppl_read_file:
    mov dword ptr [rbx + PreviewPane.pending], 1
    mov eax, 1
    jmp .Lppl_lret
.Lppl_ldone:
    xor eax, eax
.Lppl_lret:
    pop r13
    pop r12
    pop rbx
    ret

# void PreviewPane_read_sync(PreviewPane *this) -- fallback: read the head (+ thumbnail) now
PreviewPane_read_sync:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    lea rdi, [rbx + PreviewPane.target_path]
    mov rsi, [rbx + PreviewPane.buf]
    mov edx, PREVIEW_BUF_SIZE
    lea rcx, [rbx + PreviewPane.buf_len]
    call fs_read_file_head
    mov rdi, rbx
    call PreviewPane_thumb_dims
    movzx ecx, ax
    shr eax, 16
    mov r8d, eax
    lea rdi, [rbx + PreviewPane.target_path]
    mov rsi, [rbx + PreviewPane.buf]
    mov rdx, [rbx + PreviewPane.buf_len]
    lea r9, [rsi + rdx]               # same layout as an async reply: thumbnail after the head
    call pv_make_thumb
    mov rdi, rbx
    mov rsi, [rbx + PreviewPane.buf_len]
    mov rdx, rax
    add rsp, 8
    pop r12
    pop rbx
    jmp PreviewPane_accept

# void PreviewPane_accept(PreviewPane *this, size_t len, size_t tlen)
# this->buf holds len head bytes followed by tlen thumbnail bytes (tlen = 0: not an image).
PreviewPane_accept:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov [rbx + PreviewPane.buf_len], rsi
    xor r12d, r12d
    cmp rdx, IMG_THUMB_CAP
    ja 1f
    cmp rdx, IMG_THUMB_HDR
    jb 1f
    mov r12, rdx
    mov rdi, [rbx + PreviewPane.buf]
    lea rsi, [rdi + rsi]
    add rdi, PV_THUMB_OFF
    call mem_move                     # park the thumbnail at its fixed, aligned slot
1:  mov [rbx + PreviewPane.thumb_len], r12d
    mov dword ptr [rbx + PreviewPane.pending], 0
    mov dword ptr [rbx + PreviewPane.total_lines], 0
    mov dword ptr [rbx + PreviewPane.is_binary], 0
    mov rcx, [rbx + PreviewPane.buf_len]
    mov r8, [rbx + PreviewPane.buf]
    mov byte ptr [r8 + rcx], 0

    # Detect binary in first min(512, buf_len) bytes and count lines
    xor r9d, r9d              # i = 0
    mov r10d, 1               # line count
.Lppl_scan:
    cmp r9, rcx
    jae .Lppl_lines_ok
    movzx eax, byte ptr [r8 + r9]
    test eax, eax
    jnz .Lppl_not_nul
    cmp r9, 512
    jae .Lppl_not_nul
    mov dword ptr [rbx + PreviewPane.is_binary], 1
.Lppl_not_nul:
    cmp eax, '\n'
    jne .Lppl_next_b
    inc r10d
.Lppl_next_b:
    inc r9
    jmp .Lppl_scan

.Lppl_lines_ok:
    cmp rcx, 0
    jne .Lppl_set_lines
    xor r10d, r10d
.Lppl_set_lines:
    mov [rbx + PreviewPane.total_lines], r10d
    xor eax, eax

.Lppl_done:
    pop r13
    pop r12
    pop rbx
    ret
