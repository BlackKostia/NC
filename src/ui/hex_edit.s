# src/ui/hex_edit.s - In-place Hex editor (E to edit, 0-9a-f nibbles, Ctrl+Z undo, Ctrl+S save)
.intel_syntax noprefix

.include "classes.inc"

# HexEditCtx:
#   [0]  active (4)
#   [4]  nibble (4)
#   [8]  dirty (4)
#   [12] undo_cnt (4)
#   [16] cursor (8)
#   [24] undo_ring[64] -> 64 * 16 = 1024 bytes ([0]=off(8), [8]=old_byte(1))
.equ HEX_UNDO_MAX, 64
.equ HEX_CTX_SIZE, 1048

.section .text
.global hex_edit_free
.global hex_edit_on_key

.extern mem_alloc
.extern mem_free
.extern mem_zero
.extern mem_copy
.extern os_munmap
.extern fs_write_file

# void hex_edit_free(ViewerDialog *vd)
hex_edit_free:
    mov rcx, [rdi + ViewerDialog.hex_edit_ctx]
    test rcx, rcx
    jz .Lhef_ret
    push rdi
    mov rdi, rcx
    call mem_free
    pop rdi
    mov qword ptr [rdi + ViewerDialog.hex_edit_ctx], 0
.Lhef_ret:
    ret

# int hex_edit_ensure_writable(ViewerDialog *vd) -> HexEditCtx* or 0
hex_edit_ensure_writable:
    push rbx; push r12
    mov rbx, rdi
    mov r12, [rbx + ViewerDialog.hex_edit_ctx]
    test r12, r12; jnz .Lhew_buf
    mov edi, HEX_CTX_SIZE; call mem_alloc
    test rax, rax; jz .Lhew_err
    mov r12, rax
    mov rdi, r12; mov esi, HEX_CTX_SIZE; call mem_zero
    mov [rbx + ViewerDialog.hex_edit_ctx], r12
.Lhew_buf:
    cmp qword ptr [rbx + ViewerDialog.map_len], 0
    je .Lhew_ok
    mov rdi, [rbx + ViewerDialog.data_len]
    test rdi, rdi; jz .Lhew_ok
    call mem_alloc
    test rax, rax; jz .Lhew_err
    push rax
    mov rdi, rax; mov rsi, [rbx + ViewerDialog.data]; mov rdx, [rbx + ViewerDialog.data_len]
    call mem_copy
    mov rdi, [rbx + ViewerDialog.data]; mov rsi, [rbx + ViewerDialog.map_len]
    call os_munmap
    pop rax
    mov [rbx + ViewerDialog.data], rax
    mov qword ptr [rbx + ViewerDialog.map_len], 0
.Lhew_ok:
    mov rax, r12; pop r12; pop rbx; ret
.Lhew_err:
    xor eax, eax; pop r12; pop rbx; ret

# int hex_parse_nibble(int ch) -> 0..15 or -1
hex_parse_nibble:
    cmp eax, '0'; jb .Lhpn_no
    cmp eax, '9'; jbe .Lhpn_09
    cmp eax, 'a'; jb .Lhpn_up
    cmp eax, 'f'; jbe .Lhpn_af
.Lhpn_up:
    cmp eax, 'A'; jb .Lhpn_no
    cmp eax, 'F'; ja .Lhpn_no
    sub eax, 'A' - 10; ret
.Lhpn_09:
    sub eax, '0'; ret
.Lhpn_af:
    sub eax, 'a' - 10; ret
.Lhpn_no:
    mov eax, -1; ret

# int hex_edit_on_key(ViewerDialog *vd, Event *ev) -> 1 if handled, 0 else
hex_edit_on_key:
    cmp dword ptr [rdi + ViewerDialog.hex_mode], 0
    je .Lheok_no
    push rbx; push r12; push r13
    mov rbx, rdi
    mov eax, [rsi + Event.key]
    mov edx, [rsi + Event.mods]
    mov r12, [rbx + ViewerDialog.hex_edit_ctx]

    # 'e'/'E' toggles hex edit mode
    test edx, MOD_CTRL | MOD_ALT
    jnz .Lheok_chk_active
    cmp eax, 'e'; je .Lheok_tog
    cmp eax, 'E'; jne .Lheok_chk_active
.Lheok_tog:
    mov rdi, rbx; call hex_edit_ensure_writable
    test rax, rax; jz .Lheok_ret0
    xor dword ptr [rax], 1
    mov rcx, [rbx + ViewerDialog.hex_row]; shl rcx, 4
    mov [rax + 16], rcx
    mov dword ptr [rax + 4], 0
    jmp .Lheok_redraw

.Lheok_chk_active:
    test r12, r12; jz .Lheok_ret0
    cmp dword ptr [r12], 0; je .Lheok_ret0

    # Ctrl+Z undo
    test edx, MOD_CTRL; jz .Lheok_chk_nav
    cmp eax, 'z'; jne .Lheok_chk_save
    mov ecx, [r12 + 12]; test ecx, ecx; jz .Lheok_redraw
    dec ecx; mov [r12 + 12], ecx
    mov eax, ecx; and eax, 63; imul rax, 16
    mov r8, [r12 + 24 + rax]      # offset
    mov cl, [r12 + 24 + rax + 8]  # old byte
    mov r9, [rbx + ViewerDialog.data]
    mov [r9 + r8], cl
    mov [r12 + 16], r8
    mov dword ptr [r12 + 4], 0
    jmp .Lheok_redraw

.Lheok_chk_save:
    cmp eax, 's'; jne .Lheok_ret0
    lea rdi, [rbx + ViewerDialog.path]
    mov rsi, [rbx + ViewerDialog.data]
    mov rdx, [rbx + ViewerDialog.data_len]
    call fs_write_file
    test eax, eax; jnz .Lheok_redraw
    mov dword ptr [r12 + 8], 0
    jmp .Lheok_redraw

.Lheok_chk_nav:
    cmp eax, KEY_LEFT; jne .Lheok_rt
    cmp qword ptr [r12 + 16], 0; je .Lheok_redraw
    dec qword ptr [r12 + 16]; mov dword ptr [r12 + 4], 0
    jmp .Lheok_redraw
.Lheok_rt:
    cmp eax, KEY_RIGHT; jne .Lheok_nib
    mov rcx, [r12 + 16]; inc rcx
    cmp rcx, [rbx + ViewerDialog.data_len]; jae .Lheok_redraw
    mov [r12 + 16], rcx; mov dword ptr [r12 + 4], 0
    jmp .Lheok_redraw

.Lheok_nib:
    call hex_parse_nibble
    test eax, eax; js .Lheok_ret0
    mov r13d, eax             # nibble 0..15
    mov r8, [r12 + 16]        # cursor
    cmp r8, [rbx + ViewerDialog.data_len]; jae .Lheok_redraw
    mov r9, [rbx + ViewerDialog.data]
    movzx edx, byte ptr [r9 + r8]
    cmp dword ptr [r12 + 4], 0
    jne .Lheok_low
    # High nibble: push undo entry first
    mov ecx, [r12 + 12]
    mov eax, ecx; and eax, 63; imul rax, 16
    mov [r12 + 24 + rax], r8
    mov [r12 + 24 + rax + 8], dl
    inc dword ptr [r12 + 12]
    and edx, 0x0f; shl r13d, 4; or edx, r13d
    mov [r9 + r8], dl
    mov dword ptr [r12 + 4], 1
    mov dword ptr [r12 + 8], 1
    jmp .Lheok_redraw
.Lheok_low:
    and edx, 0xf0; or edx, r13d
    mov [r9 + r8], dl
    mov dword ptr [r12 + 4], 0
    mov dword ptr [r12 + 8], 1
    inc r8
    cmp r8, [rbx + ViewerDialog.data_len]; jae .Lheok_redraw
    mov [r12 + 16], r8
.Lheok_redraw:
    mov rax, [rbx + Dialog.app]
    mov dword ptr [rax + App.need_redraw], 1
    mov eax, 1; pop r13; pop r12; pop rbx; ret
.Lheok_ret0:
    xor eax, eax; pop r13; pop r12; pop rbx; ret
.Lheok_no:
    xor eax, eax; ret
