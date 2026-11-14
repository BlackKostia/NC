# src/ui/elf_inspect.s - ELF64 header & section inspector for PreviewPane
.intel_syntax noprefix

.include "classes.inc"

.section .rodata
elf_hdr_x64:   .asciz "ELF64 x86-64"
elf_hdr_a64:   .asciz "ELF64 AArch64"
elf_hdr_oth:   .asciz "ELF64"
elf_t_rel:     .asciz " ET_REL"
elf_t_exec:    .asciz " ET_EXEC"
elf_t_dyn:     .asciz " ET_DYN"
elf_entry_lbl: .asciz "Entry: 0x"
elf_ph_lbl:    .asciz "Phdrs: "
elf_sh_lbl:    .asciz "  Shdrs: "
elf_sec_lbl:   .asciz "Sections:"

.section .text
.global elf_preview_try_render

.extern ScreenBuffer_set_pen
.extern ScreenBuffer_draw_text
.extern fs_read_file_alloc
.extern mem_free
.extern str_copy
.extern str_cat
.extern u64_to_hex
.extern u64_to_dec

# void elf_draw_sections(pv, scr, theme, buf, buf_len, int y)
elf_draw_sections:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, 32
    mov rbx, rdi; mov r12, rsi; mov r13, rdx; mov r14, rcx; mov r15, r8
    mov [rsp], r9d            # y
    mov r8, [r14 + 40]        # e_shoff
    movzx r9d, word ptr [r14 + 60]  # e_shnum
    movzx r10d, word ptr [r14 + 62] # e_shstrndx
    test r8, r8; jz .Leds_done
    cmp r10d, r9d; jae .Leds_done
    mov rax, r9; imul rax, 64; add rax, r8
    cmp rax, r15; ja .Leds_done
    mov rax, r10; imul rax, 64; add rax, r8; add rax, r14
    mov r11, [rax + 24]       # shstrtab sh_offset
    mov rcx, [rax + 32]
    add rcx, r11; cmp rcx, r15; ja .Leds_done

    mov [rsp + 8], r8
    mov [rsp + 16], r9d
    mov [rsp + 24], r11
    mov rdi, r12; mov esi, [r13 + Theme.muted]; mov edx, [r13 + Theme.surface]; xor ecx, ecx
    call ScreenBuffer_set_pen
    mov rdi, r12; mov esi, [rbx + Widget.x]; add esi, 2
    mov edx, [rsp]; lea rcx, [rip + elf_sec_lbl]; mov r8d, [rbx + Widget.w]; sub r8d, 4
    call ScreenBuffer_draw_text
    inc dword ptr [rsp]

    xor ecx, ecx
.Leds_sloop:
    cmp ecx, [rsp + 16]; jge .Leds_done
    mov eax, [rsp]; sub eax, [rbx + Widget.y]
    cmp eax, [rbx + Widget.h]; jge .Leds_done
    mov r8, [rsp + 8]
    mov r11, [rsp + 24]
    imul rax, rcx, 64; add rax, r8; add rax, r14
    mov edx, [rax]; add rdx, r11
    cmp rdx, r15; jae .Leds_snext
    lea rax, [r14 + rdx]
    cmp byte ptr [rax], 0; je .Leds_snext
    push rcx; sub rsp, 8
    mov rdi, r12; mov esi, [rbx + Widget.x]; add esi, 3
    mov edx, [rsp + 16]; mov rcx, rax; mov r8d, [rbx + Widget.w]; sub r8d, 5
    call ScreenBuffer_draw_text
    add rsp, 8; pop rcx
    inc dword ptr [rsp]
.Leds_snext:
    inc ecx; jmp .Leds_sloop
.Leds_done:
    add rsp, 32; pop r15; pop r14; pop r13; pop r12; pop rbx; ret

# int elf_preview_try_render(PreviewPane *pv, ScreenBuffer *scr, Theme *theme) -> 1 if rendered, 0 else
elf_preview_try_render:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, 320
    mov rbx, rdi; mov r12, rsi; mov r13, rdx
    mov r14, [rbx + PreviewPane.buf]
    mov r15, [rbx + PreviewPane.buf_len]
    cmp r15, 64; jb .Lept_no
    cmp dword ptr [r14], 0x464c457f; jne .Lept_no
    cmp byte ptr [r14 + 4], 2; jne .Lept_no

    mov qword ptr [rsp + 288], 0
    mov [rsp + 296], r15
    mov rax, [r14 + 40]
    movzx ecx, word ptr [r14 + 60]; imul rcx, 64; add rax, rcx
    cmp rax, r15; jbe .Lept_draw
    lea rdi, [rbx + PreviewPane.target_path]
    mov esi, 2097152
    lea rdx, [rsp + 288]; lea rcx, [rsp + 296]
    call fs_read_file_alloc
    test rax, rax; js .Lept_draw
    mov rax, [rsp + 288]; test rax, rax; jz .Lept_draw
    mov r14, rax; mov r15, [rsp + 296]

.Lept_draw:
    mov eax, [rbx + Widget.y]; add eax, 3; mov [rsp + 304], eax
    mov rdi, r12; mov esi, [r13 + Theme.accent]; mov edx, [r13 + Theme.surface]; mov ecx, ATTR_BOLD
    call ScreenBuffer_set_pen
    movzx eax, word ptr [r14 + 18]
    lea rsi, [rip + elf_hdr_x64]; cmp eax, 62; je .Lept_m
    lea rsi, [rip + elf_hdr_a64]; cmp eax, 183; je .Lept_m
    lea rsi, [rip + elf_hdr_oth]
.Lept_m:
    mov rdi, rsp; mov edx, 256; call str_copy
    movzx eax, word ptr [r14 + 16]
    lea rsi, [rip + elf_t_rel];  cmp eax, 1; je .Lept_t
    lea rsi, [rip + elf_t_exec]; cmp eax, 2; je .Lept_t
    lea rsi, [rip + elf_t_dyn];  cmp eax, 3; je .Lept_t
    jmp .Lept_l1
.Lept_t:
    mov rdi, rsp; mov edx, 256; call str_cat
.Lept_l1:
    mov rdi, r12; mov esi, [rbx + Widget.x]; add esi, 2
    mov edx, [rsp + 304]; mov rcx, rsp; mov r8d, [rbx + Widget.w]; sub r8d, 4
    call ScreenBuffer_draw_text; inc dword ptr [rsp + 304]

    mov rdi, r12; mov esi, [r13 + Theme.text]; mov edx, [r13 + Theme.surface]; xor ecx, ecx
    call ScreenBuffer_set_pen
    mov rdi, rsp; lea rsi, [rip + elf_entry_lbl]; mov edx, 256; call str_copy
    mov rdi, [r14 + 24]; lea rsi, [rsp + 256]; mov edx, 16; call u64_to_hex
    mov rdi, rsp; lea rsi, [rsp + 256]; mov edx, 256; call str_cat
    mov rdi, r12; mov esi, [rbx + Widget.x]; add esi, 2
    mov edx, [rsp + 304]; mov rcx, rsp; mov r8d, [rbx + Widget.w]; sub r8d, 4
    call ScreenBuffer_draw_text; inc dword ptr [rsp + 304]

    mov rdi, rsp; lea rsi, [rip + elf_ph_lbl]; mov edx, 256; call str_copy
    movzx edi, word ptr [r14 + 56]; lea rsi, [rsp + 256]; call u64_to_dec
    mov rdi, rsp; lea rsi, [rsp + 256]; mov edx, 256; call str_cat
    mov rdi, rsp; lea rsi, [rip + elf_sh_lbl]; mov edx, 256; call str_cat
    movzx edi, word ptr [r14 + 60]; lea rsi, [rsp + 256]; call u64_to_dec
    mov rdi, rsp; lea rsi, [rsp + 256]; mov edx, 256; call str_cat
    mov rdi, r12; mov esi, [rbx + Widget.x]; add esi, 2
    mov edx, [rsp + 304]; mov rcx, rsp; mov r8d, [rbx + Widget.w]; sub r8d, 4
    call ScreenBuffer_draw_text; inc dword ptr [rsp + 304]

    mov rdi, rbx; mov rsi, r12; mov rdx, r13; mov rcx, r14; mov r8, r15; mov r9d, [rsp + 304]
    call elf_draw_sections

    mov rdi, [rsp + 288]; test rdi, rdi; jz .Lept_ret1
    call mem_free
.Lept_ret1:
    mov eax, 1; add rsp, 320; pop r15; pop r14; pop r13; pop r12; pop rbx; ret
.Lept_no:
    xor eax, eax; add rsp, 320; pop r15; pop r14; pop r13; pop r12; pop rbx; ret
