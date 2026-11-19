# Frozen reference oracle: src/ui/preview_pane_render.s (before C23 migration to src/ui/preview_pane{,_render}.c).
# PreviewPane Widget (Inherits from Widget) — preview pane render (split from preview_pane.s)

.intel_syntax noprefix
.include "classes.inc"

.section .rodata
str_space:         .asciz " "

.section .text
.global PreviewPane_render

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
    call PreviewPane_render__draw_box
    # Title pill
    call PreviewPane_render__title_pill
    # Divider y + 2
    call PreviewPane_render__divider
    # Directory preview?
    cmp dword ptr [rbx + PreviewPane.is_dir], 0
    je .Lppr_chk_empty
    call PreviewPane_render__draw_text
    jmp .Lppr_done

.Lppr_chk_empty:
    cmp dword ptr [rbx + PreviewPane.pending], 0
    jne .Lppr_done                    # head bytes still on their way
    cmp qword ptr [rbx + PreviewPane.buf_len], 0
    jne .Lppr_chk_bin
    call PreviewPane_render__draw_text_2
    jmp .Lppr_done

.Lppr_chk_bin:
    mov rdi, rbx; mov rsi, r12; mov rdx, r13; call pv_mode_dispatch   # Image / Hex / Text (Alt+V)
    test eax, eax; jz .Lppr_done
    cmp eax, 2; je .Lppr_text_mode

    # Binary hex preview
    call PreviewPane_render__binary_hex_preview
    # Show 8-byte hex rows starting at scroll * 8
    call PreviewPane_render__show_byte_hex_rows
.Lppr_hex_row:
    cmp r15d, [rsp + 292]
    jge .Lppr_done
    movsxd rax, r14d
    cmp rax, [rbx + PreviewPane.buf_len]
    jae .Lppr_done

    # Format "0000: XX XX XX XX XX XX XX XX  |........|"
    call PreviewPane_render__format
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
    call PreviewPane_render__u64_hex
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
    call PreviewPane_render__draw_text_3
    add r14d, 8
    inc r15d
    jmp .Lppr_hex_row

.Lppr_text_mode:
    # Skip `scroll` lines in buffer
    call PreviewPane_render__skip_scroll_lines_buffer
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
    call PreviewPane_render__draw_line_number_muted
    # Copy single line up to '\n' or 255 bytes (expanding tabs to 2 spaces)
    call PreviewPane_render__copy_single_line_up
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

# PreviewPane_render step: draw_box (runs on the caller's frame)
PreviewPane_render__draw_box:
    lea rsp, [rsp - 8]
    mov rdi, r12; mov esi, [r13 + Theme.border_inactive]; mov edx, [r13 + Theme.surface]; xor ecx, ecx
    call ScreenBuffer_set_pen

    mov rdi, r12
    mov esi, [rbx + Widget.x]
    mov edx, [rbx + Widget.y]
    mov ecx, [rbx + Widget.w]
    mov r8d, [rbx + Widget.h]
    mov r9d, 1
    call ScreenBuffer_draw_box

.LPreviewPane_render__draw_box_ret:
    lea rsp, [rsp + 8]
    ret

# PreviewPane_render step: Title pill (runs on the caller's frame)
PreviewPane_render__title_pill:
    lea rsp, [rsp - 8]
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
    lea rdi, [rsp + 16]
    mov edx, 256
    call str_copy
    mov rdi, [rbx + PreviewPane.file_size]
    lea rsi, [rsp + 256 + 16]
    call format_size
    lea rdi, [rsp + 16]
    lea rsi, [rsp + 256 + 16]
    mov edx, 256
    call str_cat
    call i18n_get
    mov rsi, [rax + LangStrings.pv_perm_lbl]
    lea rdi, [rsp + 16]
    mov edx, 256
    call str_cat
    mov edi, [rbx + PreviewPane.file_mode]
    lea rsi, [rsp + 256 + 16]
    call format_perms
    lea rdi, [rsp + 16]
    lea rsi, [rsp + 256 + 16]
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
    lea rcx, [rsp + 16]
    mov r8d, [rbx + Widget.w]
    sub r8d, 4
    call ScreenBuffer_draw_text

.LPreviewPane_render__title_pill_ret:
    lea rsp, [rsp + 8]
    ret

# PreviewPane_render step: Divider (runs on the caller's frame)
PreviewPane_render__divider:
    lea rsp, [rsp - 8]
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

.LPreviewPane_render__divider_ret:
    lea rsp, [rsp + 8]
    ret

# PreviewPane_render step: draw_text (runs on the caller's frame)
PreviewPane_render__draw_text:
    lea rsp, [rsp - 8]
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
.LPreviewPane_render__draw_text_ret:
    lea rsp, [rsp + 8]
    ret

# PreviewPane_render step: draw_text (runs on the caller's frame)
PreviewPane_render__draw_text_2:
    lea rsp, [rsp - 8]
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
.LPreviewPane_render__draw_text_2_ret:
    lea rsp, [rsp + 8]
    ret

# PreviewPane_render step: Binary hex preview (runs on the caller's frame)
PreviewPane_render__binary_hex_preview:
    lea rsp, [rsp - 8]
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

.LPreviewPane_render__binary_hex_preview_ret:
    lea rsp, [rsp + 8]
    ret

# PreviewPane_render step: Show byte hex rows starting at scroll (runs on the caller's frame)
PreviewPane_render__show_byte_hex_rows:
    lea rsp, [rsp - 8]
    mov r14d, [rbx + PreviewPane.scroll]
    shl r14d, 3               # byte offset
    mov r15d, 0               # visible row
    mov eax, [rbx + Widget.h]
    sub eax, 5
    mov [rsp + 292 + 16], eax  # max rows
.LPreviewPane_render__show_byte_hex_rows_ret:
    lea rsp, [rsp + 8]
    ret

# PreviewPane_render step: Format (runs on the caller's frame)
PreviewPane_render__format:
    lea rsp, [rsp - 8]
    mov edi, r14d
    lea rsi, [rsp + 16]
    mov edx, 4
    call u64_to_hex
    mov byte ptr [rsp + 4 + 16], ':'
    mov byte ptr [rsp + 5 + 16], ' '
    mov byte ptr [rsp + 6 + 16], 0

.LPreviewPane_render__format_ret:
    lea rsp, [rsp + 8]
    ret

# PreviewPane_render step: u64_to_hex (runs on the caller's frame)
PreviewPane_render__u64_hex:
    lea rsp, [rsp - 8]
    lea rsi, [rsp + 256 + 16 + 16]
    mov edx, 2
    call u64_to_hex
    lea rdi, [rsp + 16]
    add rdi, 16
    lea rsi, [rsp + 256 + 16 + 16]
    mov edx, 256
    call str_cat
    lea rdi, [rsp + 16]
    add rdi, 16
    lea rsi, [rip + str_space]
    mov edx, 256
    call str_cat
.LPreviewPane_render__u64_hex_ret:
    lea rsp, [rsp + 8]
    ret

# PreviewPane_render step: draw_text (runs on the caller's frame)
PreviewPane_render__draw_text_3:
    lea rsp, [rsp - 8]
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
    lea rcx, [rsp + 16]
    mov r8d, [rbx + Widget.w]
    sub r8d, 4
    call ScreenBuffer_draw_text

.LPreviewPane_render__draw_text_3_ret:
    lea rsp, [rsp + 8]
    ret

# PreviewPane_render step: Skip scroll lines in buffer (runs on the caller's frame)
PreviewPane_render__skip_scroll_lines_buffer:
    lea rsp, [rsp - 8]
    mov r14, [rbx + PreviewPane.buf]
    mov r15, r14
    add r15, [rbx + PreviewPane.buf_len]
    mov ecx, [rbx + PreviewPane.scroll]
    mov dword ptr [rsp + 296 + 16], 1  # current 1-based line number

.LPreviewPane_render__skip_scroll_lines_buffer_ret:
    lea rsp, [rsp + 8]
    ret

# PreviewPane_render step: Draw line number in muted fg (runs on the caller's frame)
PreviewPane_render__draw_line_number_muted:
    lea rsp, [rsp - 8]
    mov edi, [rsp + 296 + 8 + 16]
    lea rsi, [rsp + 256 + 8 + 16]
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
    add edx, [rsp + 16]
    lea rcx, [rsp + 256 + 8 + 16]
    mov r8d, 5
    call ScreenBuffer_draw_text_pad

.LPreviewPane_render__draw_line_number_muted_ret:
    lea rsp, [rsp + 8]
    ret

# PreviewPane_render step: Copy single line up to or bytes (runs on the caller's frame)
PreviewPane_render__copy_single_line_up:
    lea rsp, [rsp - 8]
    mov rdi, r14; mov rsi, r15; lea rdx, [rsp + 8 + 16]
    call pv_copy_line_strip_ansi
    mov r14, rax
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
    add edx, [rsp + 16]
    lea rcx, [rsp + 8 + 16]
    mov r8d, [rbx + Widget.w]
    sub r8d, 9
    call ScreenBuffer_draw_text

.LPreviewPane_render__copy_single_line_up_ret:
    lea rsp, [rsp + 8]
    ret
