# Core String, Formatting, and Path Utilities — string format (split from string.s)

.intel_syntax noprefix
.include "pal.inc"
.include "config.inc"

.section .bss

.align 16
g_dt_cache: .space 64 * 32         # format_datetime minute cache

.section .rodata
size_units:
    .ascii "BKMGTPE"

.section .text
.global format_size
.global format_perms
.global format_datetime

# size_t format_size(int64_t bytes, char *buf)
# Formats human-readable size (e.g. "512 B", "4.2 K", "128 M") into buf (>= 16 bytes)
format_size:
    push rbx
    push r12
    mov rbx, rsi              # buf
    mov rax, rdi
    test rax, rax
    jns .Lfs_nonneg
    xor eax, eax
.Lfs_nonneg:
    cmp rax, 1024
    jae .Lfs_scaled

    # < 1024 bytes: "<N> B"
    mov rdi, rax
    mov rsi, rbx
    call u64_to_dec
    mov byte ptr [rbx + rax], ' '
    mov byte ptr [rbx + rax + 1], 'B'
    mov byte ptr [rbx + rax + 2], 0
    add rax, 2
    pop r12
    pop rbx
    ret

.Lfs_scaled:
    # Scale by 1024 keeping remainder for 1 decimal digit
    xor r12d, r12d            # unit index: 0=B, 1=K, 2=M, 3=G, 4=T, 5=P, 6=E
    xor edx, edx
.Lfs_loop:
    cmp rax, 1024
    jb .Lfs_got_unit
    cmp r12d, 6
    jae .Lfs_got_unit
    mov rcx, 1024
    xor edx, edx
    div rcx                   # rax = quotient, rdx = remainder (0..1023)
    inc r12d
    jmp .Lfs_loop

.Lfs_got_unit:
    # rdx has remainder; compute tenth = (rdx * 10) / 1024
    imul rdx, rdx, 10
    shr rdx, 10               # 0..9
    push rdx
    push rax
    mov rdi, rax
    mov rsi, rbx
    call u64_to_dec           # rax = digits written
    pop rcx                   # quotient
    pop rdx                   # tenth digit
    cmp rcx, 100
    jae .Lfs_no_dec           # >= 100: skip decimal (e.g. "512 K")
    mov byte ptr [rbx + rax], '.'
    add dl, '0'
    mov byte ptr [rbx + rax + 1], dl
    add rax, 2
.Lfs_no_dec:
    mov byte ptr [rbx + rax], ' '
    lea rcx, [rip + size_units]
    mov cl, byte ptr [rcx + r12]
    mov byte ptr [rbx + rax + 1], cl
    mov byte ptr [rbx + rax + 2], 0
    add rax, 2
    pop r12
    pop rbx
    ret

# void format_perms(uint32_t mode, char *buf)
# Writes 10 chars + NUL (e.g. "drwxr-xr-x")
format_perms:
    mov eax, edi
    and eax, S_IFMT
    mov cl, '-'
    cmp eax, S_IFDIR
    je .Lfp_is_dir
    cmp eax, S_IFLNK
    je .Lfp_is_lnk
    jmp .Lfp_type_ok
.Lfp_is_dir:
    mov cl, 'd'
    jmp .Lfp_type_ok
.Lfp_is_lnk:
    mov cl, 'l'
.Lfp_type_ok:
    mov byte ptr [rsi], cl

    # 9 permission bits from bit 8 down to bit 0
    # Pattern: r, w, x repeated 3 times
    mov ecx, 8
    mov r8d, 1                # write index
.Lfp_loop:
    mov eax, edi
    bt eax, ecx
    jnc .Lfp_dash
    # Select 'r', 'w', or 'x' based on (8 - ecx) % 3
    mov eax, 8
    sub eax, ecx
    xor edx, edx
    mov r9d, 3
    div r9d                   # edx = 0(r), 1(w), 2(x)
    mov al, 'r'
    cmp edx, 0
    je .Lfp_put
    mov al, 'w'
    cmp edx, 1
    je .Lfp_put
    mov al, 'x'
    jmp .Lfp_put
.Lfp_dash:
    mov al, '-'
.Lfp_put:
    mov byte ptr [rsi + r8], al
    inc r8d
    dec ecx
    jns .Lfp_loop
    mov byte ptr [rsi + 10], 0
    ret

# void format_datetime(int64_t epoch_sec, char *buf)
# Formats UTC timestamp as "YYYY-MM-DD HH:MM" (16 chars + NUL, buf >= 20 bytes).
# Fronted by a 64-slot direct-mapped cache keyed by the minute (files of one directory share
# few distinct minutes), so redrawing a pane skips the calendar divisions per visible row.
format_datetime:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov rax, rdi
    mov rcx, 60
    cqo
    idiv rcx
    test rdx, rdx
    jns .Lfdc_min
    dec rax                           # floor for pre-1970 timestamps
.Lfdc_min:
    mov r13, rax                      # minute key
    mov rcx, rax
    shr rcx, 7
    xor rcx, rax
    and ecx, 63
    shl rcx, 5
    lea rdx, [rip + g_dt_cache]
    add rdx, rcx                      # slot: [0] key+1, [8..24] text
    lea rax, [r13 + 1]
    cmp [rdx], rax
    jne .Lfdc_miss
    mov rax, [rdx + 8]
    mov [r12], rax
    mov rax, [rdx + 16]
    mov [r12 + 8], rax
    mov byte ptr [r12 + 16], 0
    pop r13
    pop r12
    pop rbx
    ret
.Lfdc_miss:
    push rdx
    sub rsp, 8
    mov rdi, rbx
    mov rsi, r12
    call format_datetime_raw
    add rsp, 8
    pop rdx
    lea rax, [r13 + 1]
    mov [rdx], rax
    mov rax, [r12]
    mov [rdx + 8], rax
    mov rax, [r12 + 8]
    mov [rdx + 16], rax
    pop r13
    pop r12
    pop rbx
    ret
