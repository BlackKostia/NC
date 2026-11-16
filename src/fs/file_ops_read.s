# Filesystem Operations: mkdir, touch, rename, copy, move, delete (recursive), file read — file ops read (split from file_ops.s)

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"
.equ CFR_CHUNK,     4194304
.equ COPY_BUF_SIZE, 262144
.equ DENTS_CAP,     32752       # 32 KiB slab block minus its 16-byte header

.section .text
.global fs_read_file_alloc

# int fs_read_file_alloc(const char *path, size_t max_bytes, void **out_buf, size_t *out_len)
fs_read_file_alloc:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 64
    call fs_read_file_alloc__path
    call fs_read_file_alloc__part2
    call fs_read_file_alloc__cap_read
    add rsp, 64
    pop r15
    pop r14
    pop r13
    pop r12; pop rbx; ret

# fs_read_file_alloc step: path (runs on the caller's frame)
fs_read_file_alloc__path:
    lea rsp, [rsp - 8]
    mov r12, rdi              # path
    mov r13, rsi              # max_bytes
    mov r14, rdx              # out_buf
    mov r15, rcx              # out_len
    mov qword ptr [r14], 0
    mov qword ptr [r15], 0

.Lfs_read_file_alloc__path_ret:
    lea rsp, [rsp + 8]
    ret

# fs_read_file_alloc step (runs on the caller's frame)
fs_read_file_alloc__part2:
    lea rsp, [rsp - 8]
    mov edi, AT_FDCWD
    mov rsi, r12
    mov edx, O_RDONLY | O_NONBLOCK | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
.Lfs_read_file_alloc__part2_ret:
    lea rsp, [rsp + 8]
    ret

# fs_read_file_alloc step: cap to read (runs on the caller's frame)
fs_read_file_alloc__cap_read:
    lea rsp, [rsp - 8]
    js .Lrfa_done
    mov ebx, eax              # fd

    mov edi, ebx
    lea rsi, [rsp + 16]
    call os_fstat
    test rax, rax
    js .Lrfa_close_err
    mov eax, [rsp + FileStat.mode + 16]
    and eax, S_IFMT
    cmp eax, S_IFREG
    je .Lrfa_isreg
    mov rax, -EINVAL
    jmp .Lrfa_close_err
.Lrfa_isreg:

    mov rax, [rsp + FileStat.size + 16]
    test rax, rax
    jns .Lrfa_nonneg
    xor eax, eax
.Lrfa_nonneg:
    cmp rax, r13
    jbe .Lrfa_size_ok
    mov rax, r13
.Lrfa_size_ok:
    mov r13, rax              # cap to read
    lea rdi, [rax + 1]
    call mem_alloc
    test rax, rax
    jz .Lrfa_close_nomem
    mov [r14], rax            # *out_buf

    xor ecx, ecx
.Lrfa_loop:
    cmp rcx, r13
    jae .Lrfa_ok
    push rcx
    mov edi, ebx
    mov rsi, [r14]
    add rsi, rcx
    mov rdx, r13
    sub rdx, rcx
    call sys_read_retry
    pop rcx
    test rax, rax
    jz .Lrfa_ok
    jns .Lrfa_adv
    push rax
    mov rdi, [r14]
    call mem_free
    mov qword ptr [r14], 0
    mov qword ptr [r15], 0
    pop rax
    jmp .Lrfa_close_err
.Lrfa_adv:
    add rcx, rax
    jmp .Lrfa_loop

.Lrfa_ok:
    mov rax, [r14]
    mov byte ptr [rax + rcx], 0
    mov [r15], rcx
    mov edi, ebx
    OS_CLOSE
    xor eax, eax
    jmp .Lrfa_done

.Lrfa_close_nomem:
    mov rax, -ENOMEM
.Lrfa_close_err:
    push rax
    mov edi, ebx
    OS_CLOSE
    pop rax
.Lrfa_done:
.Lfs_read_file_alloc__cap_read_ret:
    lea rsp, [rsp + 8]
    ret
