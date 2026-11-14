# src/core/tmpfile.s - Safe PID/UID-scoped private temporary directory & exclusive temp files
.intel_syntax noprefix

.include "pal.inc"

.section .rodata
tmp_dir_pfx:    .asciz "/tmp/duop-"

.section .bss
.align 8
g_tmp_dir:      .space 128
g_tmp_dir_ok:   .space 4
g_tmp_seq:      .space 4

.section .text
.global tmp_ensure_dir
.global tmp_open_unique
.global tmp_make_path

.extern os_statat
.extern str_copy
.extern str_len

# Internal: char *tmp_append_u32_hex(char *dst, uint32_t v, int digits)
tmp_append_hex:
    mov ecx, edx
.Ltah_loop:
    test ecx, ecx; jz .Ltah_done
    dec ecx
    mov eax, esi
    shl cl, 2
    shr eax, cl
    shr cl, 2
    and eax, 0xF
    cmp al, 10; jb .Ltah_dig
    add al, 'a' - 10; jmp .Ltah_st
.Ltah_dig:
    add al, '0'
.Ltah_st:
    mov [rdi], al; inc rdi; jmp .Ltah_loop
.Ltah_done:
    mov byte ptr [rdi], 0
    mov rax, rdi
    ret

# Internal: char *tmp_append_u32_dec(char *dst, uint32_t v)
tmp_append_dec:
    mov eax, esi
    lea r8, [rsp - 16]
    xor ecx, ecx
    mov r9d, 10
.Ltad_div:
    xor edx, edx; div r9d
    add dl, '0'
    mov [r8 + rcx], dl; inc ecx
    test eax, eax; jnz .Ltad_div
.Ltad_rev:
    dec ecx
    mov al, [r8 + rcx]
    mov [rdi], al; inc rdi
    test ecx, ecx; jnz .Ltad_rev
    mov byte ptr [rdi], 0
    mov rax, rdi
    ret

# int tmp_ensure_dir(char *out_dir, int cap) -> 0 ok, -1 err
# Creates/validates a private 0700 directory /tmp/duop-<uid>-<pid>[-n].
tmp_ensure_dir:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, FileStat._size + 16
    mov r14, rdi; mov r15d, esi
    cmp dword ptr [rip + g_tmp_dir_ok], 1
    je .Lted_copy

    OS_GETUID; mov r12d, eax
    OS_GETPID; mov r13d, eax
    xor ebx, ebx                      # retry suffix index
.Lted_try:
    lea rdi, [rip + g_tmp_dir]
    lea rsi, [rip + tmp_dir_pfx]; mov edx, 128; call str_copy
    lea rdi, [rip + g_tmp_dir]; call str_len
    lea rdi, [rip + g_tmp_dir]; add rdi, rax
    mov esi, r12d; call tmp_append_dec
    mov byte ptr [rax], '-'; inc rax
    mov rdi, rax; mov esi, r13d; call tmp_append_dec
    test ebx, ebx; jz .Lted_mkdir
    mov byte ptr [rax], '-'; inc rax
    mov rdi, rax; mov esi, ebx; call tmp_append_dec
.Lted_mkdir:
    mov edi, AT_FDCWD
    lea rsi, [rip + g_tmp_dir]
    mov edx, 0700
    OS_MKDIRAT
    test eax, eax; jz .Lted_ok
    cmp eax, -17                      # -EEXIST
    jne .Lted_next
    # Verify existing path is a real directory (not symlink), owned by uid, mode 0700
    mov edi, AT_FDCWD
    lea rsi, [rip + g_tmp_dir]
    mov rdx, rsp
    mov ecx, 1                        # AT_SYMLINK_NOFOLLOW
    call os_statat
    test eax, eax; js .Lted_next
    mov eax, [rsp + FileStat.mode]
    and eax, 0170000
    cmp eax, S_IFDIR; jne .Lted_next
    cmp dword ptr [rsp + FileStat.uid], r12d; jne .Lted_next
    mov eax, [rsp + FileStat.mode]
    and eax, 0777
    cmp eax, 0700; je .Lted_ok
.Lted_next:
    inc ebx; cmp ebx, 16; jl .Lted_try
    mov eax, -1; jmp .Lted_ret
.Lted_ok:
    mov dword ptr [rip + g_tmp_dir_ok], 1
.Lted_copy:
    test r14, r14; jz .Lted_zero
    mov rdi, r14; lea rsi, [rip + g_tmp_dir]; mov edx, r15d; call str_copy
.Lted_zero:
    xor eax, eax
.Lted_ret:
    add rsp, FileStat._size + 16
    pop r15; pop r14; pop r13; pop r12; pop rbx
    ret

# int tmp_open_unique(const char *prefix, const char *suffix, char *out_path, int cap) -> fd >= 0 or -1
tmp_open_unique:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, 16
    mov r12, rdi; mov r13, rsi; mov r14, rdx; mov r15d, ecx
    cmp r15d, 64; jl .Ltou_err
    mov rdi, r14; mov esi, r15d; call tmp_ensure_dir
    test eax, eax; js .Ltou_err
    xor ebx, ebx
.Ltou_try:
    mov rdi, r14; lea rsi, [rip + g_tmp_dir]; mov edx, r15d; call str_copy
    mov rdi, r14; call str_len
    lea rcx, [r14 + rax]
    mov byte ptr [rcx], '/'; inc rcx
    mov rsi, r12
.Ltou_pfx:
    test rsi, rsi; jz .Ltou_seq
    mov al, [rsi]; test al, al; jz .Ltou_seq
    mov [rcx], al; inc rcx; inc rsi; jmp .Ltou_pfx
.Ltou_seq:
    mov byte ptr [rcx], '_'; inc rcx
    mov eax, 1; lock xadd [rip + g_tmp_seq], eax; inc eax
    mov rdi, rcx; mov esi, eax; mov edx, 8; call tmp_append_hex
    mov rcx, rax
    mov rsi, r13
.Ltou_sfx:
    test rsi, rsi; jz .Ltou_open
    mov al, [rsi]; test al, al; jz .Ltou_open
    mov [rcx], al; inc rcx; inc rsi; jmp .Ltou_sfx
.Ltou_open:
    mov byte ptr [rcx], 0
    mov edi, AT_FDCWD
    mov rsi, r14
    mov edx, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
    mov r10d, 0600
    OS_OPENAT
    test rax, rax; jns .Ltou_ret
    cmp rax, -17                      # -EEXIST
    jne .Ltou_err
    inc ebx; cmp ebx, 16; jl .Ltou_try
.Ltou_err:
    mov rax, -1
.Ltou_ret:
    add rsp, 16
    pop r15; pop r14; pop r13; pop r12; pop rbx
    ret

# int tmp_make_path(const char *prefix, const char *suffix, char *out_path, int cap) -> 0 ok, -1 err
tmp_make_path:
    sub rsp, 8
    call tmp_open_unique
    test rax, rax; js .Ltmp_err
    mov edi, eax; OS_CLOSE
    xor eax, eax
    add rsp, 8; ret
.Ltmp_err:
    mov eax, -1
    add rsp, 8; ret
