# Frozen reference oracle: compute_cols as it was in src/ui/file_pane.s (tests/test_c_file_pane_layout.py links it next to file_pane_layout_reference.s)
.intel_syntax noprefix
.include "classes.inc"

.section .text
.global compute_cols

# Helper: compute adaptive column layout into r8d=name_w, r9d=size_w, r10d=extra_w, r11d=extra_is_date(1)/perm(0)
compute_cols:
    mov eax, [rdi + Widget.w]
    sub eax, 2                # inner width
    cmp eax, 1
    jge .Lcc_ok
    mov eax, 1
.Lcc_ok:
    xor r9d, r9d              # size_w
    xor r10d, r10d            # extra_w
    xor r11d, r11d            # extra_is_date

    cmp dword ptr [rdi + Widget.w], 54
    jl .Lcc_chk_med
    mov r9d, 9
    mov r10d, 17              # 1 space + 16 date
    mov r11d, 1
    jmp .Lcc_name
.Lcc_chk_med:
    cmp dword ptr [rdi + Widget.w], 40
    jl .Lcc_chk_sm
    mov r9d, 9
    mov r10d, 11              # 1 space + 10 perms
    jmp .Lcc_name
.Lcc_chk_sm:
    cmp dword ptr [rdi + Widget.w], 28
    jl .Lcc_name
    mov r9d, 9
.Lcc_name:
    mov r8d, eax
    sub r8d, r9d
    sub r8d, r10d
    cmp r8d, 6
    jge .Lcc_ret
    mov r8d, eax
    xor r9d, r9d
    xor r10d, r10d
.Lcc_ret:
    ret
