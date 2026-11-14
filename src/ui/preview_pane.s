# PreviewPane Widget (Inherits from Widget)
# Displays live file content preview (text with line numbers, or hex dump for binary) or directory metadata.

.intel_syntax noprefix
.include "classes.inc"

.section .rodata
str_PreviewPane:   .asciz "PreviewPane"
str_space:         .asciz " "

.global PreviewPane_vtbl
PreviewPane_vtbl:
    WIDGET_VTBL_SLOTS str_PreviewPane, Widget_vtbl, PreviewPane._size, PreviewPane_dtor, Widget_layout, PreviewPane_render, Widget_on_key, PreviewPane_on_mouse, Widget_on_focus, Widget_hit_test

.section .text
.global PreviewPane_new
.global PreviewPane_dtor
.global PreviewPane_load
.global PreviewPane_accept
.global PreviewPane_read_sync
.global PreviewPane_render
.global PreviewPane_on_mouse

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

    mov edi, PREVIEW_BUF_SIZE + 1
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

# void PreviewPane_read_sync(PreviewPane *this) -- fallback: read target_path head now
PreviewPane_read_sync:
    push rbx
    mov rbx, rdi
    lea rdi, [rbx + PreviewPane.target_path]
    mov rsi, [rbx + PreviewPane.buf]
    mov edx, PREVIEW_BUF_SIZE
    lea rcx, [rbx + PreviewPane.buf_len]
    call fs_read_file_head
    mov rdi, rbx
    mov rsi, [rbx + PreviewPane.buf_len]
    pop rbx
    jmp PreviewPane_accept

# void PreviewPane_accept(PreviewPane *this, size_t len) -- analyse head bytes in this->buf
PreviewPane_accept:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov [rbx + PreviewPane.buf_len], rsi
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

# void PreviewPane_render(PreviewPane *this, ScreenBuffer *scr, Theme *theme)
PreviewPane_render:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 320
    # [rsp+0..255] = line render buf
    # [rsp+256..287] = aux buf
    mov rbx, rdi              # this
    mov r12, rsi              # scr
    mov r13, rdx              # theme

    cmp dword ptr [rbx + Widget.w], 10; jl .Lppr_done
    cmp dword ptr [rbx + Widget.h], 6; jl .Lppr_done
    mov rdi, r12; mov esi, [r13 + Theme.border_inactive]; mov edx, [r13 + Theme.surface]; xor ecx, ecx
    call ScreenBuffer_set_pen

    mov rdi, r12
    mov esi, [rbx + Widget.x]
    mov edx, [rbx + Widget.y]
    mov ecx, [rbx + Widget.w]
    mov r8d, [rbx + Widget.h]
    mov r9d, 1
    call ScreenBuffer_draw_box

    # Title pill
    mov rdi, r12
    mov esi, [r13 + Theme.accent_fg]
    mov edx, [r13 + Theme.accent]
    mov ecx, ATTR_BOLD
    call ScreenBuffer_set_pen

    call i18n_get
    mov rcx, [rax + LangStrings.pv_title]
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 2
    mov edx, [rbx + Widget.y]
    mov r8d, [rbx + Widget.w]
    sub r8d, 4
    call ScreenBuffer_draw_text

    # Metadata bar at y + 1
    call i18n_get
    mov rsi, [rax + LangStrings.pv_sz_lbl]
    mov rdi, rsp
    mov edx, 256
    call str_copy
    mov rdi, [rbx + PreviewPane.file_size]
    lea rsi, [rsp + 256]
    call format_size
    mov rdi, rsp
    lea rsi, [rsp + 256]
    mov edx, 256
    call str_cat
    call i18n_get
    mov rsi, [rax + LangStrings.pv_perm_lbl]
    mov rdi, rsp
    mov edx, 256
    call str_cat
    mov edi, [rbx + PreviewPane.file_mode]
    lea rsi, [rsp + 256]
    call format_perms
    mov rdi, rsp
    lea rsi, [rsp + 256]
    mov edx, 256
    call str_cat

    mov rdi, r12
    mov esi, [r13 + Theme.muted]
    mov edx, [r13 + Theme.surface]
    xor ecx, ecx
    call ScreenBuffer_set_pen

    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 2
    mov edx, [rbx + Widget.y]
    inc edx
    mov rcx, rsp
    mov r8d, [rbx + Widget.w]
    sub r8d, 4
    call ScreenBuffer_draw_text

    # Divider y + 2
    mov rdi, r12
    mov esi, [r13 + Theme.border_inactive]
    mov edx, [r13 + Theme.surface]
    xor ecx, ecx
    call ScreenBuffer_set_pen

    mov rdi, r12
    mov esi, [rbx + Widget.x]
    mov edx, [rbx + Widget.y]
    add edx, 2
    mov ecx, CH_BOX_LT
    call ScreenBuffer_set_cell_pen

    mov rdi, r12
    mov esi, [rbx + Widget.x]
    inc esi
    mov edx, [rbx + Widget.y]
    add edx, 2
    mov ecx, [rbx + Widget.w]
    sub ecx, 2
    mov r8d, CH_BOX_H
    call ScreenBuffer_draw_hline

    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, [rbx + Widget.w]
    dec esi
    mov edx, [rbx + Widget.y]
    add edx, 2
    mov ecx, CH_BOX_RT
    call ScreenBuffer_set_cell_pen

    # Directory preview?
    cmp dword ptr [rbx + PreviewPane.is_dir], 0
    je .Lppr_chk_empty
    mov rdi, r12
    mov esi, [r13 + Theme.dir_fg]
    mov edx, [r13 + Theme.surface]
    mov ecx, ATTR_BOLD
    call ScreenBuffer_set_pen

    call i18n_get
    mov rcx, [rax + LangStrings.pv_dir_msg]
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 2
    mov edx, [rbx + Widget.y]
    add edx, 4
    mov r8d, [rbx + Widget.w]
    sub r8d, 4
    call ScreenBuffer_draw_text
    jmp .Lppr_done

.Lppr_chk_empty:
    cmp dword ptr [rbx + PreviewPane.pending], 0
    jne .Lppr_done                    # head bytes still on their way
    cmp qword ptr [rbx + PreviewPane.buf_len], 0
    jne .Lppr_chk_bin
    mov rdi, r12
    mov esi, [r13 + Theme.muted]
    mov edx, [r13 + Theme.surface]
    xor ecx, ecx
    call ScreenBuffer_set_pen

    call i18n_get
    mov rcx, [rax + LangStrings.pv_empty]
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 2
    mov edx, [rbx + Widget.y]
    add edx, 4
    mov r8d, [rbx + Widget.w]
    sub r8d, 4
    call ScreenBuffer_draw_text
    jmp .Lppr_done

.Lppr_chk_bin:
    mov rdi, rbx; mov rsi, r12; mov rdx, r13; call img_preview_try_render; test eax, eax; jnz .Lppr_done
    mov rdi, rbx; mov rsi, r12; mov rdx, r13; call elf_preview_try_render; test eax, eax; jnz .Lppr_done
    cmp dword ptr [rbx + PreviewPane.is_binary], 0
    je .Lppr_text_mode

    # Binary hex preview
    mov rdi, r12
    mov esi, [r13 + Theme.warn_fg]
    mov edx, [r13 + Theme.surface]
    mov ecx, ATTR_BOLD
    call ScreenBuffer_set_pen

    call i18n_get
    mov rcx, [rax + LangStrings.pv_bin_hdr]
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 2
    mov edx, [rbx + Widget.y]
    add edx, 3
    mov r8d, [rbx + Widget.w]
    sub r8d, 4
    call ScreenBuffer_draw_text

    # Show 8-byte hex rows starting at scroll * 8
    mov r14d, [rbx + PreviewPane.scroll]
    shl r14d, 3               # byte offset
    mov r15d, 0               # visible row
    mov eax, [rbx + Widget.h]
    sub eax, 5
    mov [rsp + 292], eax      # max rows
.Lppr_hex_row:
    cmp r15d, [rsp + 292]
    jge .Lppr_done
    movsxd rax, r14d
    cmp rax, [rbx + PreviewPane.buf_len]
    jae .Lppr_done

    # Format "0000: XX XX XX XX XX XX XX XX  |........|"
    mov edi, r14d
    mov rsi, rsp
    mov edx, 4
    call u64_to_hex
    mov byte ptr [rsp + 4], ':'
    mov byte ptr [rsp + 5], ' '
    mov byte ptr [rsp + 6], 0

    xor ecx, ecx
    mov r8, [rbx + PreviewPane.buf]
.Lppr_hx_bytes:
    cmp ecx, 8
    jge .Lppr_hx_ascii
    lea eax, [r14d + ecx]
    movsxd rdx, eax
    cmp rdx, [rbx + PreviewPane.buf_len]
    jae .Lppr_hx_pad
    movzx edi, byte ptr [r8 + rdx]
    push rcx
    push r8
    lea rsi, [rsp + 256 + 16]
    mov edx, 2
    call u64_to_hex
    mov rdi, rsp
    add rdi, 16
    lea rsi, [rsp + 256 + 16]
    mov edx, 256
    call str_cat
    mov rdi, rsp
    add rdi, 16
    lea rsi, [rip + str_space]
    mov edx, 256
    call str_cat
    pop r8
    pop rcx
    jmp .Lppr_hx_bnext
.Lppr_hx_pad:
    push rcx
    push r8
    mov rdi, rsp
    add rdi, 16
    lea rsi, [rip + str_space]
    mov edx, 256
    call str_cat
    pop r8
    pop rcx
.Lppr_hx_bnext:
    inc ecx
    jmp .Lppr_hx_bytes

.Lppr_hx_ascii:
    mov rdi, r12
    mov esi, [r13 + Theme.text]
    mov edx, [r13 + Theme.surface]
    xor ecx, ecx
    call ScreenBuffer_set_pen

    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 2
    mov edx, [rbx + Widget.y]
    add edx, 4
    add edx, r15d
    mov rcx, rsp
    mov r8d, [rbx + Widget.w]
    sub r8d, 4
    call ScreenBuffer_draw_text

    add r14d, 8
    inc r15d
    jmp .Lppr_hex_row

.Lppr_text_mode:
    # Skip `scroll` lines in buffer
    mov r14, [rbx + PreviewPane.buf]
    mov r15, r14
    add r15, [rbx + PreviewPane.buf_len]
    mov ecx, [rbx + PreviewPane.scroll]
    mov dword ptr [rsp + 296], 1  # current 1-based line number

.Lppr_skip_lines:
    test ecx, ecx
    jle .Lppr_draw_lines
    cmp r14, r15
    jae .Lppr_done
    mov al, byte ptr [r14]
    inc r14
    cmp al, '\n'
    jne .Lppr_skip_lines
    dec ecx
    inc dword ptr [rsp + 296]
    jmp .Lppr_skip_lines

.Lppr_draw_lines:
    mov eax, [rbx + Widget.h]
    sub eax, 4
    mov [rsp + 292], eax      # max visible lines
    xor ecx, ecx              # row offset r = 0
.Lppr_line_loop:
    cmp ecx, [rsp + 292]
    jge .Lppr_done
    cmp r14, r15
    jae .Lppr_done
    push rcx

    # Draw line number in muted fg
    mov edi, [rsp + 296 + 8]
    lea rsi, [rsp + 256 + 8]
    call u64_to_dec
    mov rdi, r12
    mov esi, [r13 + Theme.muted]
    mov edx, [r13 + Theme.surface]
    xor ecx, ecx
    call ScreenBuffer_set_pen

    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 2
    mov edx, [rbx + Widget.y]
    add edx, 3
    add edx, [rsp]
    lea rcx, [rsp + 256 + 8]
    mov r8d, 5
    call ScreenBuffer_draw_text_pad

    # Copy single line up to '\n' or 255 bytes (expanding tabs to 2 spaces)
    xor edx, edx
.Lppr_copy_line:
    cmp r14, r15
    jae .Lppr_line_ready
    mov al, byte ptr [r14]
    inc r14
    cmp al, '\n'
    je .Lppr_line_ready
    cmp al, '\r'
    je .Lppr_copy_line
    cmp edx, 250
    jae .Lppr_copy_line       # consume rest of long line until '\n'
    cmp al, '\t'
    jne .Lppr_store_ch
    mov byte ptr [rsp + 8 + rdx], ' '
    mov byte ptr [rsp + 9 + rdx], ' '
    add edx, 2
    jmp .Lppr_copy_line
.Lppr_store_ch:
    mov byte ptr [rsp + 8 + rdx], al
    inc edx
    jmp .Lppr_copy_line

.Lppr_line_ready:
    mov byte ptr [rsp + 8 + rdx], 0
    mov rdi, r12
    mov esi, [r13 + Theme.text]
    mov edx, [r13 + Theme.surface]
    xor ecx, ecx
    call ScreenBuffer_set_pen

    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 7
    mov edx, [rbx + Widget.y]
    add edx, 3
    add edx, [rsp]
    lea rcx, [rsp + 8]
    mov r8d, [rbx + Widget.w]
    sub r8d, 9
    call ScreenBuffer_draw_text

    pop rcx
    inc ecx
    inc dword ptr [rsp + 296]
    jmp .Lppr_line_loop

.Lppr_done:
    add rsp, 320
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# int PreviewPane_on_mouse(PreviewPane *this, Event *evt)
PreviewPane_on_mouse:
    cmp dword ptr [rsi + Event.mouse_kind], MACT_WHEEL
    jne .Lppm_ret0
    mov eax, [rdi + PreviewPane.scroll]
    cmp dword ptr [rsi + Event.mouse_btn], MOUSE_WHEEL_UP
    jne .Lppm_dn
    sub eax, 3
    jns .Lppm_apply
    xor eax, eax
    jmp .Lppm_apply
.Lppm_dn:
    add eax, 3
    mov ecx, [rdi + PreviewPane.total_lines]
    cmp dword ptr [rdi + PreviewPane.is_binary], 0
    je .Lppm_chk_max
    mov rcx, [rdi + PreviewPane.buf_len]
    shr rcx, 3
.Lppm_chk_max:
    dec ecx
    jns .Lppm_max_nonneg
    xor ecx, ecx
.Lppm_max_nonneg:
    cmp eax, ecx
    jle .Lppm_apply
    mov eax, ecx
.Lppm_apply:
    mov [rdi + PreviewPane.scroll], eax
    mov rax, [rdi + PreviewPane.app]
    mov dword ptr [rax + App.need_redraw], 1
    mov eax, 1
    ret
.Lppm_ret0:
    xor eax, eax
    ret
