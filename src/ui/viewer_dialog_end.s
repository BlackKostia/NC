# ViewerDialog (Inherits from Dialog): built-in Text / Hex file viewer for files of ANY size — viewer dialog end (split from viewer_dialog.s)

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"
.equ VW_LINE_MAX, 248

.section .text
.global vw_end

# Internal: void vw_end(ViewerDialog *this) -- last page; counts lines once (SIMD)
vw_end:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov rcx, [rbx + ViewerDialog.data_len]
    cmp dword ptr [rbx + ViewerDialog.hex_mode], 0
    je .Lve_text
    call vw_end__part1
    mov [rbx + ViewerDialog.hex_row], rcx
    jmp .Lve_done
.Lve_text:
    call vw_end__start_last_line
.Lve_done:
    mov rax, [rbx + Dialog.app]
    mov dword ptr [rax + App.need_redraw], 1
    add rsp, 8
    pop r12
    pop rbx
    ret

# vw_end step (runs on the caller's frame)
vw_end__part1:
    lea rsp, [rsp - 8]
    add rcx, 15
    shr rcx, 4
    movsxd rax, dword ptr [rbx + ViewerDialog.vis_rows]
    sub rcx, rax
    jns .Lve_hset
    xor ecx, ecx
.Lve_hset:
.Lvw_end__part1_ret:
    lea rsp, [rsp + 8]
    ret

# vw_end step: Start of the last line (runs on the caller's frame)
vw_end__start_last_line:
    lea rsp, [rsp - 8]
    mov rdi, [rbx + ViewerDialog.data]
    test rdi, rdi
    jz .Lvw_end__start_last_line_ret
    test rcx, rcx
    jz .Lvw_end__start_last_line_ret
    cmp qword ptr [rbx + ViewerDialog.total_lines], 0
    jge .Lve_have_total
    mov rsi, rcx
    mov edx, 10
    call os_mem_count_byte
    mov rcx, [rbx + ViewerDialog.data_len]
    mov rdx, [rbx + ViewerDialog.data]
    cmp byte ptr [rdx + rcx - 1], 10
    je .Lve_store_total
    inc rax                           # unterminated last line
.Lve_store_total:
    mov [rbx + ViewerDialog.total_lines], rax
.Lve_have_total:
    # Start of the last line
    mov rdx, [rbx + ViewerDialog.data]
    mov rcx, [rbx + ViewerDialog.data_len]
    lea rax, [rcx - 1]
    cmp byte ptr [rdx + rax], 10
    jne .Lve_back
    dec rax                           # ignore the final terminator
.Lve_back:
    test rax, rax
    js .Lve_first
    cmp byte ptr [rdx + rax], 10
    je .Lve_found
    dec rax
    jmp .Lve_back
.Lve_found:
    inc rax
    jmp .Lve_set
.Lve_first:
    xor eax, eax
.Lve_set:
    mov [rbx + ViewerDialog.top_off], rax
    mov rax, [rbx + ViewerDialog.total_lines]
    dec rax
    jns .Lve_line
    xor eax, eax
.Lve_line:
    mov [rbx + ViewerDialog.top_line], rax
    movsxd r12, dword ptr [rbx + ViewerDialog.vis_rows]
    dec r12
.Lve_up:
    test r12, r12
    jle .Lvw_end__start_last_line_ret
    mov rdi, rbx
    call vw_line_up
    test eax, eax
    jz .Lvw_end__start_last_line_ret
    dec r12
    jmp .Lve_up
.Lvw_end__start_last_line_ret:
    lea rsp, [rsp + 8]
    ret
