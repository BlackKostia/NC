# ViewerDialog (Inherits from Dialog): built-in Text / Hex file viewer for files of ANY size — viewer dialog render (split from viewer_dialog.s)

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"
.equ VW_LINE_MAX, 248

.section .rodata

vw_hex: .ascii "0123456789abcdef"

.section .text
.global ViewerDialog_render

# void ViewerDialog_render(ViewerDialog *this, ScreenBuffer *scr, Theme *theme)
ViewerDialog_render:
    cmp dword ptr [rdi + ViewerDialog.img_mode], 0
    jne ViewerDialog_render_image
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    sub rsp, 344                      # [8..263]=line, [264..295]=num, [296]=rows, [300]=row,
                                      # [304]=numw, [312]=line_no, [320]=cursor off
    call ViewerDialog_render__draw_text
    mov eax, [rbx + Widget.h]
    sub eax, 5
    mov [rbx + ViewerDialog.vis_rows], eax
    cmp eax, 1
    jl .Lvr_done
    mov [rsp + 296], eax
    cmp qword ptr [rbx + ViewerDialog.data], 0
    je .Lvr_done
    cmp dword ptr [rbx + ViewerDialog.hex_mode], 0
    jne .Lvr_hex

    # ---- Text mode: number column width from the last visible line number ----
    call ViewerDialog_render__text_mode_number_column
    call ViewerDialog_render__part3
.Lvr_tloop:
    mov eax, [rsp + 300]
    cmp eax, [rsp + 296]
    jge .Lvr_done
    mov r14, [rsp + 320]
    cmp r14, [rbx + ViewerDialog.data_len]
    jae .Lvr_done

    # line number
    call ViewerDialog_render__line_number
    # line end via SIMD newline search
    call ViewerDialog_render__line_end_via_simd
    # copy (tabs -> 2 spaces, CR dropped, capped)
    call ViewerDialog_render__copy
    mov byte ptr [rsp + 8 + rdx], 0
    mov eax, [r13 + Theme.dialog_bg]
    push rax
    push r13
    call ViewerDialog_render__part7
    call syntax_draw_line
    add rsp, 16
    inc dword ptr [rsp + 300]
    inc qword ptr [rsp + 312]
    jmp .Lvr_tloop

    # ---- Hex mode: "OFFSET: XX XX ... |ascii|" ----
.Lvr_hex:
    mov rax, [rbx + ViewerDialog.hex_row]
    shl rax, 4
    mov [rsp + 320], rax
    mov dword ptr [rsp + 300], 0
.Lvr_hloop:
    mov eax, [rsp + 300]
    cmp eax, [rsp + 296]
    jge .Lvr_done
    mov r14, [rsp + 320]
    cmp r14, [rbx + ViewerDialog.data_len]
    jae .Lvr_done
    call ViewerDialog_render__offset_digits
    call ViewerDialog_render__draw_text_2
    jmp .Lvr_hloop

.Lvr_done:
    add rsp, 344
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# ViewerDialog_render step: draw_text (runs on the caller's frame)
ViewerDialog_render__draw_text:
    lea rsp, [rsp - 8]
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx

    call i18n_get
    mov rcx, [rax + LangStrings.dlg_btn_hex]
    mov r8,  [rax + LangStrings.dlg_btn_close]
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call Dialog_draw_frame

    mov rdi, r12
    mov esi, [r13 + Theme.dir_fg]
    mov edx, [r13 + Theme.dialog_bg]
    mov ecx, ATTR_BOLD
    call ScreenBuffer_set_pen
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 2
    mov edx, [rbx + Widget.y]
    inc edx
    lea rcx, [rbx + ViewerDialog.path]
    mov r8d, [rbx + Widget.w]
    sub r8d, 4
    call ScreenBuffer_draw_text

    mov rdi, r12
    mov esi, [r13 + Theme.muted]
    mov edx, [r13 + Theme.dialog_bg]
    xor ecx, ecx
    call ScreenBuffer_set_pen
    call i18n_get
    mov rcx, [rax + LangStrings.dlg_vw_hint]
    movsx r8d, word ptr [rbx + Dialog.btns + HitZone.x1]
    mov eax, [rbx + Widget.x]
    add eax, 3
    sub r8d, eax
    cmp r8d, 0
    jle .Lvr_skip_hint
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 2
    mov edx, [rbx + Widget.y]
    add edx, [rbx + Widget.h]
    sub edx, 2
    call ScreenBuffer_draw_text
.Lvr_skip_hint:

.LViewerDialog_render__draw_text_ret:
    lea rsp, [rsp + 8]
    ret

# ViewerDialog_render step: Text mode number column width from the last visible line number (runs on the caller's frame)
ViewerDialog_render__text_mode_number_column:
    lea rsp, [rsp - 8]
    mov rdi, [rbx + ViewerDialog.top_line]
    movsxd rax, dword ptr [rsp + 296 + 16]
    add rdi, rax
    lea rsi, [rsp + 264 + 16]
    call u64_to_dec
    cmp eax, 5
    jge .Lvr_numw
    mov eax, 5
.Lvr_numw:
.LViewerDialog_render__text_mode_number_column_ret:
    lea rsp, [rsp + 8]
    ret

# ViewerDialog_render step (runs on the caller's frame)
ViewerDialog_render__part3:
    lea rsp, [rsp - 8]
    inc eax
    mov [rsp + 304 + 16], eax
    mov rax, [rbx + ViewerDialog.top_line]
    mov [rsp + 312 + 16], rax
    mov rax, [rbx + ViewerDialog.top_off]
    mov [rsp + 320 + 16], rax
    mov dword ptr [rsp + 300 + 16], 0
.LViewerDialog_render__part3_ret:
    lea rsp, [rsp + 8]
    ret

# ViewerDialog_render step: line number (runs on the caller's frame)
ViewerDialog_render__line_number:
    lea rsp, [rsp - 8]
    mov rdi, [rsp + 312 + 16]
    inc rdi
    lea rsi, [rsp + 264 + 16]
    call u64_to_dec
    mov rdi, r12
    mov esi, [r13 + Theme.muted]
    mov edx, [r13 + Theme.dialog_bg]
    xor ecx, ecx
    call ScreenBuffer_set_pen
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 2
    mov edx, [rbx + Widget.y]
    add edx, 2
    add edx, [rsp + 300 + 16]
    lea rcx, [rsp + 264 + 16]
    mov r8d, [rsp + 304 + 16]
    call ScreenBuffer_draw_text_pad

.LViewerDialog_render__line_number_ret:
    lea rsp, [rsp + 8]
    ret

# ViewerDialog_render step: line end via SIMD newline search (runs on the caller's frame)
ViewerDialog_render__line_end_via_simd:
    lea rsp, [rsp - 8]
    mov rdi, [rbx + ViewerDialog.data]
    add rdi, r14
    mov rsi, [rbx + ViewerDialog.data_len]
    sub rsi, r14
    mov edx, 10
    call os_mem_find_byte
    mov r15, rax                      # line length
    lea rax, [r14 + r15 + 1]
    mov [rsp + 320 + 16], rax  # next line offset

.LViewerDialog_render__line_end_via_simd_ret:
    lea rsp, [rsp + 8]
    ret

# ViewerDialog_render step: copy (runs on the caller's frame)
ViewerDialog_render__copy:
    lea rsp, [rsp - 8]
    mov rbp, [rbx + ViewerDialog.data]
    add rbp, r14
    xor ecx, ecx                      # src index
    xor edx, edx                      # dst index
.Lvr_copy:
    cmp rcx, r15
    jae .Lvr_copied
    cmp edx, VW_LINE_MAX
    jae .Lvr_copied
    mov al, [rbp + rcx]
    inc rcx
    cmp al, 13
    je .Lvr_copy
    cmp al, 9
    jne .Lvr_ch
    mov byte ptr [rsp + 8 + rdx + 16], ' '
    mov byte ptr [rsp + 9 + rdx + 16], ' '
    add edx, 2
    jmp .Lvr_copy
.Lvr_ch:
    test al, al
    jnz .Lvr_put
    mov al, '.'
.Lvr_put:
    mov [rsp + 8 + rdx + 16], al
    inc edx
    jmp .Lvr_copy
.Lvr_copied:
.LViewerDialog_render__copy_ret:
    lea rsp, [rsp + 8]
    ret

# ViewerDialog_render step (runs on the caller's frame)
ViewerDialog_render__part7:
    lea rsp, [rsp - 8]
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 3
    add esi, [rsp + 304 + 16 + 16]
    mov edx, [rbx + Widget.y]
    add edx, 2
    add edx, [rsp + 300 + 16 + 16]
    lea rcx, [rsp + 8 + 16 + 16]
    mov r8d, [rbx + Widget.w]
    sub r8d, 5
    sub r8d, [rsp + 304 + 16 + 16]
    lea r9, [rbx + ViewerDialog.path]
.LViewerDialog_render__part7_ret:
    lea rsp, [rsp + 8]
    ret

# ViewerDialog_render step: offset digits (runs on the caller's frame)
ViewerDialog_render__offset_digits:
    lea rsp, [rsp - 8]
    mov rdi, r14
    lea rsi, [rsp + 8 + 16]
    mov edx, 8
    call u64_to_hex
    mov r15d, eax                     # offset digits
    mov byte ptr [rsp + 8 + r15 + 16], ':'
    mov byte ptr [rsp + 9 + r15 + 16], ' '
    lea r9d, [r15d + 2]               # hex write pos
    lea r10d, [r15d + 2 + 49]         # ascii write pos
    mov byte ptr [rsp + 8 + r10 - 1 + 16], '|'
    mov rbp, [rbx + ViewerDialog.data]
    xor ecx, ecx
.Lvr_hb:
    cmp ecx, 16
    jge .Lvr_hend
    lea rax, [r14 + rcx]
    cmp rax, [rbx + ViewerDialog.data_len]
    jae .Lvr_hpad
    movzx edi, byte ptr [rbp + rax]
    mov eax, edi
    shr eax, 4
    lea rdx, [rip + vw_hex]
    mov al, [rdx + rax]
    mov [rsp + 8 + r9 + 16], al
    mov eax, edi
    and eax, 15
    mov al, [rdx + rax]
    mov [rsp + 9 + r9 + 16], al
    mov byte ptr [rsp + 10 + r9 + 16], ' '
    cmp dil, 0x20
    jb .Lvr_dot
    cmp dil, 0x7E
    jbe .Lvr_asc
.Lvr_dot:
    mov dil, '.'
.Lvr_asc:
    mov [rsp + 8 + r10 + 16], dil
    jmp .Lvr_hnext
.Lvr_hpad:
    mov byte ptr [rsp + 8 + r9 + 16], ' '
    mov byte ptr [rsp + 9 + r9 + 16], ' '
    mov byte ptr [rsp + 10 + r9 + 16], ' '
    mov byte ptr [rsp + 8 + r10 + 16], ' '
.Lvr_hnext:
    add r9d, 3
    inc r10d
    inc ecx
    jmp .Lvr_hb
.Lvr_hend:
    mov byte ptr [rsp + 8 + r9 + 16], ' '
    mov byte ptr [rsp + 8 + r10 + 16], '|'
    mov byte ptr [rsp + 9 + r10 + 16], 0
    mov rdi, r12
    mov esi, [r13 + Theme.text]
    mov edx, [r13 + Theme.dialog_bg]
    xor ecx, ecx
    call ScreenBuffer_set_pen
    mov rdi, r12
    mov esi, [rbx + Widget.x]
    add esi, 2
.LViewerDialog_render__offset_digits_ret:
    lea rsp, [rsp + 8]
    ret

# ViewerDialog_render step: draw_text (runs on the caller's frame)
ViewerDialog_render__draw_text_2:
    lea rsp, [rsp - 8]
    mov edx, [rbx + Widget.y]
    add edx, 2
    add edx, [rsp + 300 + 16]
    lea rcx, [rsp + 8 + 16]
    mov r8d, [rbx + Widget.w]
    sub r8d, 4
    call ScreenBuffer_draw_text
    add qword ptr [rsp + 320 + 16], 16
    inc dword ptr [rsp + 300 + 16]
.LViewerDialog_render__draw_text_2_ret:
    lea rsp, [rsp + 8]
    ret
