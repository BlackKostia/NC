# src/core/hash.s - IEEE 802.3 CRC32 and FIPS 180-4 SHA-256 file hashing — hash file (split from hash.s)

.intel_syntax noprefix
.include "pal.inc"
.struct 0
ShaCtx.state: .space 32       # 8 x uint32
ShaCtx.total: .space 8        # total bytes
ShaCtx.buflen:.space 4
ShaCtx.pad:   .space 4
ShaCtx.buf:   .space 64
ShaCtx._size:

.extern mem_alloc
.extern mem_free
.extern sys_read_retry

.section .text
.global hash_file

# int hash_file(const char *path, uint32_t *out_crc32, char *out_sha_hex65)
hash_file:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, ShaCtx._size + 16
    call hash_file__out_crc32
    js .Lhf_err
    call hash_file__buf
.Lhf_ret:
    add rsp, ShaCtx._size + 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.Lhf_err:
    jmp .Lhf_ret

# hash_file step: out_crc32 (runs on the caller's frame)
hash_file__out_crc32:
    lea rsp, [rsp - 8]
    mov r12, rsi              # out_crc32
    mov r13, rdx              # out_sha_hex65

    mov rsi, rdi
    mov edi, AT_FDCWD
    mov edx, O_RDONLY | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
.Lhash_file__out_crc32_ret:
    lea rsp, [rsp + 8]
    ret

# hash_file step: buf (runs on the caller's frame)
hash_file__buf:
    lea rsp, [rsp - 8]
    mov ebx, eax              # fd

    mov edi, 16384
    call mem_alloc
    test rax, rax
    jz .Lhf_close_err
    mov r14, rax              # buf

    lea rdi, [rsp + 16]
    call sha256_init
    mov r15d, 0xFFFFFFFF      # crc = ~0

.Lhf_loop:
    mov edi, ebx
    mov rsi, r14
    mov edx, 16384
    call sys_read_retry
    test rax, rax
    js .Lhf_read_err
    jz .Lhf_done
    push rax
    mov edi, r15d
    mov rsi, r14
    mov rdx, rax
    call crc32_update
    mov r15d, eax
    pop rdx
    lea rdi, [rsp + 16]
    mov rsi, r14
    call sha256_update
    jmp .Lhf_loop

.Lhf_done:
    not r15d
    mov [r12], r15d
    lea rdi, [rsp + 16]
    mov rsi, r13
    call sha256_final_hex
    mov rdi, r14
    call mem_free
    mov edi, ebx
    OS_CLOSE
    xor eax, eax
    jmp .Lhash_file__buf_ret

.Lhf_read_err:
    mov rdi, r14
    call mem_free
.Lhf_close_err:
    mov edi, ebx
    OS_CLOSE
    mov eax, -1
.Lhash_file__buf_ret:
    lea rsp, [rsp + 8]
    ret
