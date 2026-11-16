# src/core/tmpfile.s - Safe PID/UID-scoped private temporary directory & exclusive temp files
.intel_syntax noprefix

.include "pal.inc"
.include "config.inc"

.section .rodata
tmp_dir_pfx:    .asciz "/tmp/duop-"
tmp_dot_sfx:    .asciz ".tmp"

.section .bss
.align 8
g_tmp_dir:      .space 128
g_tmp_dir_ok:   .space 4
g_tmp_seq:      .space 4

.section .text
.global tmp_ensure_dir
.global tmp_open_unique
.global tmp_make_path
.global tmp_open_atomic
.global tmp_commit_atomic

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
    xor ecx, ecx                      # OS_STAT_NOFOLLOW
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
    mov [rsp], rax
    xor ecx, ecx; test r12, r12; jz 1f; mov rdi, r12; call str_len; mov rcx, rax
1:  mov [rsp + 8], rcx
    xor edx, edx; test r13, r13; jz 2f; mov rdi, r13; call str_len; mov rdx, rax
2:  mov rax, [rsp]
    add rax, [rsp + 8]
    add rax, rdx
    add rax, 11
    mov ecx, r15d
    cmp rax, rcx
    ja .Ltou_err
    mov rax, [rsp]
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

# int tmp_open_atomic(const char *final_path, char *tmp_buf, int mode)
tmp_open_atomic:
    push rbx; push r12; push r13; push r14; sub rsp, 8
    mov rbx, rdi; mov r12, rsi; mov r13d, edx
    call str_len
    cmp rax, PATH_MAX - 14
    jae .Ltoa_too_long
    xor r14d, r14d
.Ltoa_try:
    mov rdi, r12; mov rsi, rbx; mov edx, PATH_MAX; call str_copy
    mov rdi, r12; lea rsi, [rip + tmp_dot_sfx]; mov edx, PATH_MAX; call str_cat
    mov rdi, r12; call str_len
    lea rdi, [r12 + rax]
    mov byte ptr [rdi], '.'; inc rdi
    mov eax, 1; lock xadd [rip + g_tmp_seq], eax; inc eax
    mov esi, eax; mov edx, 8; call tmp_append_hex
    mov edi, AT_FDCWD; mov rsi, r12
    mov edx, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
    mov r10d, r13d
    OS_OPENAT
    test rax, rax; jns .Ltoa_ret
    cmp rax, -17                      # -EEXIST
    jne .Ltoa_ret
    inc r14d; cmp r14d, 16; jl .Ltoa_try
    jmp .Ltoa_ret
.Ltoa_too_long:
    mov rax, -ENAMETOOLONG
.Ltoa_ret:
    add rsp, 8; pop r14; pop r13; pop r12; pop rbx
    ret

# void tmp_fsync_parent_dir(const char *final_path)
tmp_fsync_parent_dir:
    push rbx; push r12; sub rsp, PATH_MAX + 8
    mov r12, rdi
    call str_len
    mov rcx, rax
.Ltfpd_scan:
    test rcx, rcx; jz .Ltfpd_dot
    dec rcx
    cmp byte ptr [r12 + rcx], '/'; je .Ltfpd_slash
    jmp .Ltfpd_scan
.Ltfpd_dot:
    mov word ptr [rsp], '.'; jmp .Ltfpd_open
.Ltfpd_slash:
    test rcx, rcx; jnz .Ltfpd_copy
    mov word ptr [rsp], '/'; jmp .Ltfpd_open
.Ltfpd_copy:
    cmp rcx, PATH_MAX - 1; jae .Ltfpd_done
    mov rdx, rcx
.Ltfpd_cp:
    dec rdx
    mov al, [r12 + rdx]; mov [rsp + rdx], al
    test rdx, rdx; jnz .Ltfpd_cp
    mov byte ptr [rsp + rcx], 0
.Ltfpd_open:
    mov edi, AT_FDCWD; mov rsi, rsp
    mov edx, O_RDONLY | O_DIRECTORY | O_CLOEXEC; xor r10d, r10d
    OS_OPENAT
    test rax, rax; js .Ltfpd_done
    mov ebx, eax
.Ltfpd_sync:
    mov edi, ebx; OS_FSYNC
    cmp rax, -EINTR; je .Ltfpd_sync
    test rax, rax
    mov edi, ebx; OS_CLOSE            # fault-checked: best-effort dir durability sync
.Ltfpd_done:
    add rsp, PATH_MAX + 8; pop r12; pop rbx
    ret

# int tmp_commit_atomic(int fd, const char *tmp_buf, const char *final_path, int64_t write_rc)
tmp_commit_atomic:
    push rbx; push r12; push r13; push r14
    mov ebx, edi; mov r12, rsi; mov r13, rdx; mov r14, rcx
    test r14, r14
    js .Ltca_close_fail
.Ltca_fsync:
    mov edi, ebx; OS_FSYNC
    cmp rax, -EINTR; je .Ltca_fsync
    test rax, rax; jns .Ltca_close
    cmp rax, -EINVAL; je .Ltca_close
    mov r14, rax
    jmp .Ltca_close_fail
.Ltca_close:
    mov edi, ebx; OS_CLOSE
    test rax, rax; jns .Ltca_rename
    mov r14, rax
    jmp .Ltca_unlink
.Ltca_rename:
    mov edi, AT_FDCWD; mov rsi, r12; mov edx, AT_FDCWD; mov r10, r13
    OS_RENAMEAT               # atomic-replace
    test rax, rax; jns .Ltca_ok
    mov r14, rax
    jmp .Ltca_unlink
.Ltca_close_fail:
    mov edi, ebx; OS_CLOSE    # fault-checked: cleanup after prior error
.Ltca_unlink:
    mov edi, AT_FDCWD; mov rsi, r12; xor edx, edx; OS_UNLINKAT # fault-checked: best-effort cleanup
    mov rax, r14
    jmp .Ltca_ret
.Ltca_ok:
    mov rdi, r13
    call tmp_fsync_parent_dir
    xor eax, eax
.Ltca_ret:
    pop r14; pop r13; pop r12; pop rbx
    ret
