# Frozen reference oracle: the hand-written asm that src/fs/file_ops_overwrite.c replaced (tests/test_c_fops_overwrite.py diffs against it)
# src/fs/file_ops_overwrite.s - crash-safe "Overwrite": write a sibling temp file, then rename it over the target
#
# Opening the existing target with O_TRUNC destroys the old content before the new copy exists: a read
# error, ENOSPC, a cancel or a power cut half-way would leave neither version. Here the data goes to a
# hidden temp file in the same directory; only when it is complete (the caller fsyncs it) does rename(2)
# swap it in atomically, so the target is always the complete old file or the complete new file.

.intel_syntax noprefix
.include "pal.inc"
.include "config.inc"

.section .rodata
fo_ovw_pfx: .asciz ".duop-ovw."
fo_ovw_hex: .asciz "0123456789abcdef"

.section .bss
.align 4
g_fo_ovw_seq: .space 4

.section .text
.global fo_open_overwrite
.global fo_overwrite_open
.global fo_overwrite_commit

.extern str_copy

# void fo_ovw_name(char *out, uint32_t pid, uint32_t seq) -- ".duop-ovw.<pid hex>.<seq hex>", NUL ended
fo_ovw_name:
    push rbx; push r12; push r13
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    lea rsi, [rip + fo_ovw_pfx]
    mov edx, 32                                       # path-checked: the template is 10 bytes
    call str_copy
    lea rdi, [rbx + rax]
    mov esi, r12d
    call fo_ovw_hex8
    mov byte ptr [rdi], '.'
    inc rdi
    mov esi, r13d
    call fo_ovw_hex8
    mov byte ptr [rdi], 0
    pop r13; pop r12; pop rbx
    ret

# void fo_ovw_hex8(char *dst, uint32_t v) -- 8 hex digits; on return rdi = dst + 8 (esi, ecx, eax, r8 clobbered)
fo_ovw_hex8:
    lea r8, [rip + fo_ovw_hex]
    mov ecx, 8
.Lfh8_loop:
    rol esi, 4
    mov eax, esi
    and eax, 15
    mov al, [r8 + rax]
    mov [rdi], al
    inc rdi
    dec ecx
    jnz .Lfh8_loop
    ret

# int fo_overwrite_open(int dfd, const char *name, uint32_t mode, char *out_tmp)
# Creates an exclusive temp file in the directory of `name` (a plain name relative to dfd, or a path;
# same directory = same filesystem). out_tmp (PATH_MAX bytes) receives the temp name/path.
# Returns the open fd, or -errno.
fo_overwrite_open:
    push rbx; push rbp; push r12; push r13; push r14; push r15
    sub rsp, 8
    mov ebx, edi
    mov r12d, edx
    mov r13, rcx
    xor ecx, ecx                                      # ecx = length of the directory prefix (up to the last '/')
    xor eax, eax
.Lfoo_scan:
    movzx edx, byte ptr [rsi + rax]
    test edx, edx; jz .Lfoo_scanned
    inc eax
    cmp edx, '/'; jne .Lfoo_scan
    mov ecx, eax
    jmp .Lfoo_scan
.Lfoo_scanned:
    cmp ecx, PATH_MAX - 48; ja .Lfoo_long             # path-checked: prefix + temp name must fit
    xor eax, eax
.Lfoo_copy:
    cmp eax, ecx; jae .Lfoo_prefixed
    mov dl, [rsi + rax]
    mov [r13 + rax], dl
    inc eax
    jmp .Lfoo_copy
.Lfoo_prefixed:
    mov r15d, ecx
    OS_GETPID
    mov r14d, eax
    xor ebp, ebp
.Lfoo_try:
    mov eax, 1
    lock xadd [rip + g_fo_ovw_seq], eax
    inc eax
    lea rdi, [r13 + r15]
    mov esi, r14d
    mov edx, eax
    call fo_ovw_name
    mov edi, ebx
    mov rsi, r13
    mov edx, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
    mov r10d, r12d
    OS_OPENAT
    cmp rax, -EEXIST
    jne .Lfoo_ret
    inc ebp
    cmp ebp, 8
    jb .Lfoo_try
    jmp .Lfoo_ret
.Lfoo_long:
    mov rax, -ENAMETOOLONG
.Lfoo_ret:
    add rsp, 8
    pop r15; pop r14; pop r13; pop r12; pop rbp; pop rbx
    ret

# int fo_overwrite_commit(int dfd, const char *tmp, const char *name) -> 0, or -errno
# Atomically replaces `name` with the finished temp file.
fo_overwrite_commit:
    mov r10, rdx
    mov edx, edi
    OS_RENAMEAT               # atomic-replace: the temp file is complete and fsynced
    test rax, rax
    ret

# int fo_open_overwrite(int dfd, const char *name, uint32_t dst_mode, uint32_t new_mode, char *out_tmp)
# Opens the target of an "Overwrite" for writing. An existing regular file is replaced through a temp
# file (edx = 1, out_tmp = its name: fo_overwrite_commit it once it is complete and fsynced). Anything
# else -- and a directory the user cannot write into -- is opened in place with O_TRUNC (edx = 0).
# Returns the fd or -errno (no fallback on ENOSPC: truncating would destroy the old file for nothing).
fo_open_overwrite:
    push rbx; push r12; push r13; push r14
    sub rsp, 8
    mov ebx, edi
    mov r12, rsi
    mov r13d, ecx
    mov r14, r8
    and edx, S_IFMT
    cmp edx, S_IFREG
    jne .Lfoov_inplace
    mov edi, ebx
    mov rsi, r12
    mov edx, r13d
    mov rcx, r14
    call fo_overwrite_open
    cmp rax, -EACCES
    je .Lfoov_inplace
    cmp rax, -1                       # -EPERM
    je .Lfoov_inplace
    xor edx, edx
    test rax, rax
    js .Lfoov_ret
    mov edx, 1
    jmp .Lfoov_ret
.Lfoov_inplace:
    mov edi, ebx
    mov rsi, r12
    mov edx, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC
    OS_OPENAT
    xor edx, edx
    test rax, rax
.Lfoov_ret:
    add rsp, 8
    pop r14; pop r13; pop r12; pop rbx
    ret
