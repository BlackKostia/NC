# src/core/hash.s - IEEE 802.3 CRC32 and FIPS 180-4 SHA-256 file hashing
.intel_syntax noprefix

.include "pal.inc"

.struct 0
ShaCtx.state: .space 32       # 8 x uint32
ShaCtx.total: .space 8        # total bytes
ShaCtx.buflen:.space 4
ShaCtx.pad:   .space 4
ShaCtx.buf:   .space 64
ShaCtx._size:

.section .rodata
.align 4
sha256_iv:
    .long 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
    .long 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19

sha256_k:
    .long 0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5
    .long 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174
    .long 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da
    .long 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967
    .long 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85
    .long 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070
    .long 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3
    .long 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2

hex_digits: .ascii "0123456789abcdef"

.section .text
.global hash_file

.extern mem_alloc
.extern mem_free
.extern sys_read_retry

# uint32_t crc32_update(uint32_t crc, const uint8_t *buf, size_t len)
crc32_update:
    mov eax, edi
    test rdx, rdx
    jz .Lcu_done
.Lcu_byte:
    movzx ecx, byte ptr [rsi]
    xor eax, ecx
    mov r8d, 8
.Lcu_bit:
    mov ecx, eax
    shr eax, 1
    and ecx, 1
    jz .Lcu_next
    xor eax, 0xedb88320
.Lcu_next:
    dec r8d
    jnz .Lcu_bit
    inc rsi
    dec rdx
    jnz .Lcu_byte
.Lcu_done:
    ret

# void sha256_init(ShaCtx *ctx)
sha256_init:
    lea rsi, [rip + sha256_iv]
    xor ecx, ecx
.Lsi_loop:
    mov eax, [rsi + rcx*4]
    mov [rdi + ShaCtx.state + rcx*4], eax
    inc ecx
    cmp ecx, 8
    jb .Lsi_loop
    mov qword ptr [rdi + ShaCtx.total], 0
    mov dword ptr [rdi + ShaCtx.buflen], 0
    ret

# void sha256_expand_w(uint32_t w[64], const uint8_t *block)
sha256_expand_w:
    xor ecx, ecx
.Lsew_load:
    mov eax, [rsi + rcx*4]
    bswap eax
    mov [rdi + rcx*4], eax
    inc ecx
    cmp ecx, 16
    jb .Lsew_load
.Lsew_ext:
    mov eax, [rdi + rcx*4 - 60]
    mov edx, eax
    ror eax, 7
    ror edx, 18
    xor eax, edx
    mov edx, [rdi + rcx*4 - 60]
    shr edx, 3
    xor eax, edx              # s0

    mov r8d, [rdi + rcx*4 - 8]
    mov r9d, r8d
    ror r8d, 17
    ror r9d, 19
    xor r8d, r9d
    mov r9d, [rdi + rcx*4 - 8]
    shr r9d, 10
    xor r8d, r9d              # s1

    add eax, [rdi + rcx*4 - 64]
    add eax, [rdi + rcx*4 - 28]
    add eax, r8d
    mov [rdi + rcx*4], eax
    inc ecx
    cmp ecx, 64
    jb .Lsew_ext
    ret

# void sha256_transform(ShaCtx *ctx, const uint8_t *block)
sha256_transform:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 296              # [rsp+0..255]=w[64], [rsp+256..287]=a..h, [rsp+288]=ctx
    mov [rsp + 288], rdi
    mov rdi, rsp
    call sha256_expand_w

    mov rdi, [rsp + 288]
    xor ecx, ecx
.Lst_cp:
    mov eax, [rdi + ShaCtx.state + rcx*4]
    mov [rsp + 256 + rcx*4], eax
    inc ecx
    cmp ecx, 8
    jb .Lst_cp

    xor r12d, r12d            # i = 0..63
    lea r13, [rip + sha256_k]
.Lst_round:
    # S1 = ror(e,6)^ror(e,11)^ror(e,25)
    mov eax, [rsp + 256 + 16] # e
    mov edx, eax
    ror eax, 6
    ror edx, 11
    xor eax, edx
    mov edx, [rsp + 256 + 16]
    ror edx, 25
    xor eax, edx
    # ch = (e & f) ^ ((~e) & g)
    mov ebx, [rsp + 256 + 16]
    mov ecx, ebx
    and ecx, [rsp + 256 + 20] # e & f
    not ebx
    and ebx, [rsp + 256 + 24] # ~e & g
    xor ebx, ecx
    # temp1 = h + S1 + ch + k[i] + w[i]
    add eax, [rsp + 256 + 28] # + h
    add eax, ebx
    add eax, [r13 + r12*4]
    add eax, [rsp + r12*4]
    mov r14d, eax             # temp1

    # S0 = ror(a,2)^ror(a,13)^ror(a,22)
    mov eax, [rsp + 256 + 0]  # a
    mov edx, eax
    ror eax, 2
    ror edx, 13
    xor eax, edx
    mov edx, [rsp + 256 + 0]
    ror edx, 22
    xor eax, edx
    # maj = (a&b)^(a&c)^(b&c)
    mov ebx, [rsp + 256 + 0]
    mov ecx, [rsp + 256 + 4]
    mov edx, [rsp + 256 + 8]
    mov r8d, ebx
    and r8d, ecx
    and ebx, edx
    and ecx, edx
    xor r8d, ebx
    xor r8d, ecx
    add eax, r8d
    mov r15d, eax             # temp2

    # Shift h=g, g=f, f=e, e=d+temp1, d=c, c=b, b=a, a=temp1+temp2
    mov eax, [rsp + 256 + 24]; mov [rsp + 256 + 28], eax
    mov eax, [rsp + 256 + 20]; mov [rsp + 256 + 24], eax
    mov eax, [rsp + 256 + 16]; mov [rsp + 256 + 20], eax
    mov eax, [rsp + 256 + 12]; add eax, r14d; mov [rsp + 256 + 16], eax
    mov eax, [rsp + 256 + 8];  mov [rsp + 256 + 12], eax
    mov eax, [rsp + 256 + 4];  mov [rsp + 256 + 8], eax
    mov eax, [rsp + 256 + 0];  mov [rsp + 256 + 4], eax
    lea eax, [r14d + r15d];    mov [rsp + 256 + 0], eax

    inc r12d
    cmp r12d, 64
    jb .Lst_round

    mov rdi, [rsp + 288]
    xor ecx, ecx
.Lst_add:
    mov eax, [rsp + 256 + rcx*4]
    add [rdi + ShaCtx.state + rcx*4], eax
    inc ecx
    cmp ecx, 8
    jb .Lst_add

    add rsp, 296
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

# void sha256_update(ShaCtx *ctx, const uint8_t *buf, size_t len)
sha256_update:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    add [rbx + ShaCtx.total], r13
.Lsu_loop:
    test r13, r13
    jz .Lsu_done
    mov ecx, [rbx + ShaCtx.buflen]
    mov al, [r12]
    mov [rbx + ShaCtx.buf + rcx], al
    inc ecx
    mov [rbx + ShaCtx.buflen], ecx
    inc r12
    dec r13
    cmp ecx, 64
    jb .Lsu_loop
    mov rdi, rbx
    lea rsi, [rbx + ShaCtx.buf]
    call sha256_transform
    mov dword ptr [rbx + ShaCtx.buflen], 0
    jmp .Lsu_loop
.Lsu_done:
    pop r13
    pop r12
    pop rbx
    ret

# void sha256_final_hex(ShaCtx *ctx, char *out_hex65)
sha256_final_hex:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi

    mov rax, [rbx + ShaCtx.total]
    shl rax, 3                # bit length
    bswap rax
    push rax

    mov ecx, [rbx + ShaCtx.buflen]
    mov byte ptr [rbx + ShaCtx.buf + rcx], 0x80
    inc ecx
    cmp ecx, 56
    jbe .Lsf_pad
.Lsf_pad_hi:
    cmp ecx, 64
    jae .Lsf_tr1
    mov byte ptr [rbx + ShaCtx.buf + rcx], 0
    inc ecx
    jmp .Lsf_pad_hi
.Lsf_tr1:
    mov rdi, rbx
    lea rsi, [rbx + ShaCtx.buf]
    call sha256_transform
    xor ecx, ecx
.Lsf_pad:
    cmp ecx, 56
    jae .Lsf_len
    mov byte ptr [rbx + ShaCtx.buf + rcx], 0
    inc ecx
    jmp .Lsf_pad
.Lsf_len:
    pop rax
    mov [rbx + ShaCtx.buf + 56], rax
    mov rdi, rbx
    lea rsi, [rbx + ShaCtx.buf]
    call sha256_transform

    lea r8, [rip + hex_digits]
    xor ecx, ecx
.Lsf_hex:
    mov eax, [rbx + ShaCtx.state + rcx*4]
    bswap eax
    mov edx, 4
.Lsf_byte:
    mov r9d, eax
    and r9d, 0x0F
    mov r10d, eax
    shr r10d, 4
    and r10d, 0x0F
    mov r11b, [r8 + r10]
    mov [r12], r11b
    mov r11b, [r8 + r9]
    mov [r12 + 1], r11b
    add r12, 2
    shr eax, 8
    dec edx
    jnz .Lsf_byte
    inc ecx
    cmp ecx, 8
    jb .Lsf_hex
    mov byte ptr [r12], 0

    add rsp, 8
    pop r12
    pop rbx
    ret

# int hash_file(const char *path, uint32_t *out_crc32, char *out_sha_hex65)
hash_file:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, ShaCtx._size + 16
    mov r12, rsi              # out_crc32
    mov r13, rdx              # out_sha_hex65

    mov rsi, rdi
    mov edi, AT_FDCWD
    mov edx, O_RDONLY | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
    js .Lhf_err
    mov ebx, eax              # fd

    mov edi, 16384
    call mem_alloc
    test rax, rax
    jz .Lhf_close_err
    mov r14, rax              # buf

    mov rdi, rsp
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
    mov rdi, rsp
    mov rsi, r14
    call sha256_update
    jmp .Lhf_loop

.Lhf_done:
    not r15d
    mov [r12], r15d
    mov rdi, rsp
    mov rsi, r13
    call sha256_final_hex
    mov rdi, r14
    call mem_free
    mov edi, ebx
    OS_CLOSE
    xor eax, eax
    jmp .Lhf_ret

.Lhf_read_err:
    mov rdi, r14
    call mem_free
.Lhf_close_err:
    mov edi, ebx
    OS_CLOSE
    mov eax, -1
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
