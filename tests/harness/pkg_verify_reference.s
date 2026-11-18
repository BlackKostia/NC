# Frozen reference oracle: the hand-written asm that src/fs/pkg_verify.c replaced (tests/test_c_pkg_verify.py diffs against it)
# src/fs/pkg_verify.s - Package file-hash recording & verification for Duop
.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .rodata
pkv_sha_file:    .asciz "sha256"
pkv_hashes_file: .asciz "hashes.sha256"
pkv_manifest_nm: .asciz "manifest.ini"

.section .text
.global pkg_hashes_append
.global pkg_hashes_write
.global pkg_verify

.extern fs_read_file_head
.extern hash_file
.extern mem_alloc
.extern mem_free
.extern path_basename
.extern path_join
.extern pkg_get_root
.extern pkg_write_file
.extern pkm_safe_name
.extern str_casecmp
.extern str_cmp
.extern str_len

# void pkg_hashes_append(const char *file_path, char *buf, uint64_t *len_ptr)
pkg_hashes_append:
    push rbx; push r12; push r13; push r14
    sub rsp, 88
    mov rbx, rdi; mov r12, rsi; mov r13, rdx
    mov rdi, rbx; lea rsi, [rsp]; lea rdx, [rsp + 8]; call hash_file
    test eax, eax; js .Lpha_ret
    mov rdi, rbx; call str_len; mov r14, rax
    mov rax, [r13]
    lea rcx, [rax + r14 + 66]
    cmp rcx, 8192; jae .Lpha_ret
    lea rdi, [r12 + rax]
    xor ecx, ecx
.Lpha_hex:
    mov dl, [rsp + 8 + rcx]; mov [rdi + rcx], dl
    inc rcx; cmp rcx, 64; jl .Lpha_hex
    mov byte ptr [rdi + 64], ' '
    xor ecx, ecx
.Lpha_path:
    cmp rcx, r14; jge .Lpha_nl
    mov dl, [rbx + rcx]; mov [rdi + 65 + rcx], dl
    inc rcx; jmp .Lpha_path
.Lpha_nl:
    mov byte ptr [rdi + 65 + r14], '\n'
    lea rax, [rax + r14 + 66]
    mov [r13], rax
.Lpha_ret:
    add rsp, 88; pop r14; pop r13; pop r12; pop rbx; ret

# void pkg_hashes_write(const char *pkg_dir, const char *buf, uint64_t len)
pkg_hashes_write:
    push rbx; push r12; sub rsp, PATH_MAX + 8
    mov rbx, rsi; mov r12, rdx
    mov rsi, rdi; mov rdi, rsp; lea rdx, [rip + pkv_hashes_file]; mov ecx, PATH_MAX; call path_join
    mov rdi, rsp; mov rsi, rbx; mov rdx, r12; call pkg_write_file
    add rsp, PATH_MAX + 8; pop r12; pop rbx; ret

# Helper: int pkv_is_hex64(const char *s) -> 1 valid 64 hex digits, 0 else
pkv_is_hex64:
    xor ecx, ecx
.Lpih_loop:
    movzx eax, byte ptr [rdi + rcx]
    cmp eax, '0'; jb .Lpih_no
    cmp eax, '9'; jbe .Lpih_ok
    or eax, 0x20
    cmp eax, 'a'; jb .Lpih_no
    cmp eax, 'f'; ja .Lpih_no
.Lpih_ok:
    inc ecx; cmp ecx, 64; jl .Lpih_loop
    mov eax, 1; ret
.Lpih_no:
    xor eax, eax; ret

# Helper: int pkv_check_hashes_buf(char *buf, uint64_t len) -> 0 ok, -1 err
pkv_check_hashes_buf:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, 88
    mov r12, rdi; lea r13, [r12 + rsi]; xor r15d, r15d
.Lpcb_line:
    cmp r12, r13; jae .Lpcb_ok
    mov r14, r12
.Lpcb_nl:
    cmp r14, r13; jae .Lpcb_err
    cmp byte ptr [r14], '\n'; je .Lpcb_got
    inc r14; jmp .Lpcb_nl
.Lpcb_got:
    mov byte ptr [r14], 0
    mov rax, r14; sub rax, r12
    cmp rax, 66; jl .Lpcb_err
    mov rdi, r12; call pkv_is_hex64; test eax, eax; jz .Lpcb_err
    cmp byte ptr [r12 + 64], ' '; jne .Lpcb_err
    mov byte ptr [r12 + 64], 0
    lea rdi, [r12 + 65]; call path_basename
    mov rdi, rax; lea rsi, [rip + pkv_manifest_nm]; call str_cmp
    test eax, eax; jnz .Lpcb_hash
    mov r15d, 1
.Lpcb_hash:
    lea rdi, [r12 + 65]; lea rsi, [rsp]; lea rdx, [rsp + 8]; call hash_file
    test eax, eax; js .Lpcb_err
    mov rdi, r12; lea rsi, [rsp + 8]; call str_casecmp
    test eax, eax; jnz .Lpcb_err
    lea r12, [r14 + 1]; jmp .Lpcb_line
.Lpcb_ok:
    test r15d, r15d; jz .Lpcb_err
    xor eax, eax; jmp .Lpcb_ret
.Lpcb_err:
    mov eax, -1
.Lpcb_ret:
    add rsp, 88; pop r15; pop r14; pop r13; pop r12; pop rbx; ret

# int pkg_verify(char **envp, const char *name) -> 0 ok, -1 err
pkg_verify:
    push rbx; push r12; push r13; sub rsp, PATH_MAX * 2 + 80
    mov rbx, rdi; mov r12, rsi
    mov rdi, r12; call pkm_safe_name; test eax, eax; jz .Lpv_err
    mov rdi, rbx; mov rsi, rsp; mov edx, PATH_MAX; call pkg_get_root
    lea rdi, [rsp + PATH_MAX]; mov rsi, rsp; mov rdx, r12; mov ecx, PATH_MAX; call path_join
    test rax, rax; js .Lpv_err
    mov rdi, rsp; lea rsi, [rsp + PATH_MAX]; lea rdx, [rip + pkv_sha_file]; mov ecx, PATH_MAX; call path_join
    test rax, rax; js .Lpv_err
    mov rdi, rsp; lea rsi, [rsp + PATH_MAX * 2]; mov edx, 72; lea rcx, [rsp + PATH_MAX * 2 + 72]
    call fs_read_file_head
    test rax, rax; js .Lpv_err
    cmp qword ptr [rsp + PATH_MAX * 2 + 72], 64; jl .Lpv_err
    lea rdi, [rsp + PATH_MAX * 2]; call pkv_is_hex64; test eax, eax; jz .Lpv_err
    mov rdi, rsp; lea rsi, [rsp + PATH_MAX]; lea rdx, [rip + pkv_hashes_file]; mov ecx, PATH_MAX; call path_join
    test rax, rax; js .Lpv_err
    mov edi, 8192; call mem_alloc; test rax, rax; jz .Lpv_err
    mov r13, rax
    mov rdi, rsp; mov rsi, r13; mov edx, 8192; lea rcx, [rsp + PATH_MAX * 2 + 72]
    call fs_read_file_head
    test rax, rax; js .Lpv_free_err
    mov rsi, [rsp + PATH_MAX * 2 + 72]
    test rsi, rsi; jz .Lpv_free_err
    mov rdi, r13; call pkv_check_hashes_buf
    push rax; mov rdi, r13; call mem_free; pop rax
    jmp .Lpv_ret
.Lpv_free_err:
    mov rdi, r13; call mem_free
.Lpv_err:
    mov eax, -1
.Lpv_ret:
    add rsp, PATH_MAX * 2 + 80; pop r13; pop r12; pop rbx; ret
