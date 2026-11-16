# src/fs/trash_info.s - freedesktop.org Trash specification 1.0 ".trashinfo" writer
#
#   [Trash Info]\nPath=<percent-encoded absolute path>\nDeletionDate=YYYY-MM-DDThh:mm:ss\n
#
# Path= is escaped byte-wise (everything except A-Z a-z 0-9 - . _ ~ and "/" becomes %XX), so no
# file name can add keys or lines. DeletionDate is the real UTC time of the deletion (other tools
# purge the trash by it) and the file is written atomically (temp file + fsync + rename).

.intel_syntax noprefix
.include "pal.inc"
.include "config.inc"

.equ TI_BUF,    3 * PATH_MAX + 96              # header + fully escaped path + date line
.equ TI_SCRATCH, PATH_MAX + TI_BUF             # 32-byte date scratch behind the content buffer
.equ TI_FRAME,  TI_SCRATCH + 48                # [0..PATH_MAX) temp path, content buffer, date scratch

.section .rodata
ti_head:      .asciz "[Trash Info]\nPath="
ti_date_key:  .asciz "\nDeletionDate="
ti_hex:       .asciz "0123456789ABCDEF"

.section .text
.global tu_write_info

.extern str_copy
.extern str_len
.extern os_time_sec
.extern format_datetime_raw
.extern tmp_open_atomic
.extern tmp_commit_atomic
.extern sys_write_all

# size_t ti_pct_encode(char *dst, const char *src) -> bytes written (NUL added, not counted)
ti_pct_encode:
    xor eax, eax
    lea r9, [rip + ti_hex]
.Ltpe_loop:
    movzx ecx, byte ptr [rsi]
    test ecx, ecx; jz .Ltpe_done
    inc rsi
    cmp ecx, '/'; je .Ltpe_plain
    cmp ecx, '-'; je .Ltpe_plain
    cmp ecx, '.'; je .Ltpe_plain
    cmp ecx, '_'; je .Ltpe_plain
    cmp ecx, '~'; je .Ltpe_plain
    lea edx, [rcx - '0']; cmp edx, 9; jbe .Ltpe_plain
    lea edx, [rcx - 'A']; cmp edx, 25; jbe .Ltpe_plain
    lea edx, [rcx - 'a']; cmp edx, 25; jbe .Ltpe_plain
    mov byte ptr [rdi + rax], '%'
    mov edx, ecx
    shr edx, 4
    mov dl, [r9 + rdx]
    mov [rdi + rax + 1], dl
    and ecx, 15
    mov dl, [r9 + rcx]
    mov [rdi + rax + 2], dl
    add rax, 3
    jmp .Ltpe_loop
.Ltpe_plain:
    mov [rdi + rax], cl
    inc rax
    jmp .Ltpe_loop
.Ltpe_done:
    mov byte ptr [rdi + rax], 0
    ret

# void ti_date(int64_t epoch, char *out32) -- "YYYY-MM-DDThh:mm:ss" (UTC) + NUL
ti_date:
    push rbx; push r12
    sub rsp, 8
    mov rbx, rsi
    mov r12, rdi
    call format_datetime_raw                          # "YYYY-MM-DD hh:mm"
    mov byte ptr [rbx + 10], 'T'
    mov rax, r12
    xor edx, edx
    mov ecx, 60
    div rcx                                           # edx = seconds
    mov eax, edx
    xor edx, edx
    mov ecx, 10
    div ecx
    add al, '0'
    add dl, '0'
    mov byte ptr [rbx + 16], ':'
    mov [rbx + 17], al
    mov [rbx + 18], dl
    mov byte ptr [rbx + 19], 0
    add rsp, 8
    pop r12; pop rbx
    ret

# size_t ti_build(char *buf, const char *orig) -> content length, or 0 when the path is too long
ti_build:
    push rbx; push r12; push r13
    mov rbx, rdi
    mov r12, rsi
    mov rdi, r12
    call str_len
    cmp rax, PATH_MAX - 1; jae .Ltb_fail              # path-checked: nothing is truncated below
    mov rdi, rbx; lea rsi, [rip + ti_head]; mov edx, TI_BUF   # path-checked
    call str_copy
    mov r13, rax
    lea rdi, [rbx + r13]; mov rsi, r12
    call ti_pct_encode
    add r13, rax
    lea rdi, [rbx + r13]; lea rsi, [rip + ti_date_key]; mov edx, 64   # path-checked
    call str_copy
    add r13, rax
    call os_time_sec
    mov rdi, rax
    lea rsi, [rbx + TI_BUF]                           # date scratch right behind the content buffer
    call ti_date
    lea rdi, [rbx + r13]; lea rsi, [rbx + TI_BUF]; mov edx, 32   # path-checked
    call str_copy
    add r13, rax
    mov byte ptr [rbx + r13], 10
    inc r13
    mov rax, r13
    jmp .Ltb_ret
.Ltb_fail:
    xor eax, eax
.Ltb_ret:
    pop r13; pop r12; pop rbx
    ret

# int tu_write_info(const char *info_path, const char *orig_path) -> 0, or -errno
tu_write_info:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, TI_FRAME
    mov r13, rdi                                      # info path (final name)
    lea rbx, [rsp + PATH_MAX]                         # content buffer
    mov rdi, rbx
    call ti_build
    test rax, rax; jz .Ltwi_long
    mov r14, rax
    mov rdi, r13; mov rsi, rsp; mov edx, 0600
    call tmp_open_atomic
    test rax, rax; js .Ltwi_ret
    mov r15d, eax
    mov edi, r15d; mov rsi, rbx; mov rdx, r14
    call sys_write_all
    xor ecx, ecx
    test rax, rax; jns .Ltwi_commit
    mov rcx, rax
.Ltwi_commit:
    mov edi, r15d; mov rsi, rsp; mov rdx, r13
    call tmp_commit_atomic
    jmp .Ltwi_ret
.Ltwi_long:
    mov rax, -ENAMETOOLONG
.Ltwi_ret:
    add rsp, TI_FRAME
    pop r15; pop r14; pop r13; pop r12; pop rbx
    ret
