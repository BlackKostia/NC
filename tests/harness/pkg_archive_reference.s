# Frozen reference oracle: the hand-written asm that src/fs/pkg_archive.c replaced (tests/test_c_pkg_archive.py diffs against it)
# src/fs/pkg_archive.s - Archive & manifest helpers for Duop Package Manager
.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.equ ARC_MAX_FILE,    4194304
.equ ARC_MAX_ENTRIES, 1024
.equ AENT_SIZE,       288
.equ ACTX_SIZE,       32 + PATH_MAX * 3
.equ SHA_CTX_SZ,      112

.section .rodata
pka_k_name: .asciz "name"
pka_k_ver:  .asciz "version"
pka_k_kind: .asciz "kind"
pka_k_desc: .asciz "description"

.section .text
.global pkg_mkdir_p
.global pkg_write_file
.global pkg_parse_manifest
.global pkg_load_archive
.global pkg_load_archive_sha
.global pkg_free_archive
.global pkg_extract_entry_to
.global pkg_ensure_exec

.extern arc_is_archive
.extern arc_parse_tar
.extern arc_parse_zip
.extern arc_ungzip
.extern fs_read_file_head
.extern inflate_raw
.extern mem_alloc
.extern mem_free
.extern mem_zero
.extern os_statat
.extern sha256_final_hex
.extern sha256_init
.extern sha256_update
.extern str_copy
.extern str_cmp
.extern sys_write_all

# void pkg_mkdir_p(const char *path)
pkg_mkdir_p:
    push rbx; push r12; sub rsp, PATH_MAX + 8
    mov rbx, rdi
    mov rdi, rsp; mov rsi, rbx; mov edx, PATH_MAX; call str_copy
    lea r12, [rsp + 1]                # skip leading '/'
.Lpm_loop:
    mov al, [r12]
    test al, al; jz .Lpm_last
    cmp al, '/'; jne .Lpm_next
    mov byte ptr [r12], 0
    mov edi, AT_FDCWD; mov rsi, rsp; mov edx, 0755; OS_MKDIRAT
    mov byte ptr [r12], '/'
.Lpm_next:
    inc r12; jmp .Lpm_loop
.Lpm_last:
    mov edi, AT_FDCWD; mov rsi, rsp; mov edx, 0755; OS_MKDIRAT
    add rsp, PATH_MAX + 8; pop r12; pop rbx; ret

# int pkg_write_file(const char *path, const void *buf, uint64_t len) -> 0 ok, -1 err
pkg_write_file:
    push rbx; push r12; push r13
    mov r12, rsi; mov r13, rdx
    mov rsi, rdi; mov edi, AT_FDCWD
    mov edx, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC; mov r10d, 0644; OS_OPENAT
    test rax, rax; js .Lpwf_err
    mov ebx, eax
    mov edi, ebx; mov rsi, r12; mov rdx, r13; call sys_write_all
    push rax
    mov edi, ebx; OS_CLOSE
    pop rax
    test rax, rax; js .Lpwf_err
    xor eax, eax; pop r13; pop r12; pop rbx; ret
.Lpwf_err:
    mov eax, -1; pop r13; pop r12; pop rbx; ret

# int pkg_ensure_exec(const char *path) -> 0 ok (S_ISREG + 0755), -1 err/symlink
pkg_ensure_exec:
    push rbx; sub rsp, FileStat._size + 8
    mov rbx, rdi
    mov edi, AT_FDCWD; mov rsi, rbx; mov rdx, rsp; xor ecx, ecx
    call os_statat
    test rax, rax; js 1f
    mov eax, [rsp + FileStat.mode]
    mov ecx, eax; and ecx, S_IFMT; cmp ecx, S_IFREG; jne 1f
    test eax, 0111; jnz 2f
    mov edi, AT_FDCWD; mov rsi, rbx; mov edx, 0755; xor r10d, r10d; OS_FCHMODAT
    test rax, rax; js 1f
2:  xor eax, eax; add rsp, FileStat._size + 8; pop rbx; ret
1:  mov eax, -1; add rsp, FileStat._size + 8; pop rbx; ret

# void pka_copy_val(const char *p, const char *end, char *dst, int cap)
pka_copy_val:
.Lcv_skip:
    cmp rdi, rsi; jae .Lcv_done
    mov al, [rdi]
    cmp al, ' '; je .Lcv_adv
    cmp al, '\t'; je .Lcv_adv
    cmp al, '='; je .Lcv_adv
    cmp al, '"'; je .Lcv_adv
    jmp .Lcv_trim
.Lcv_adv:
    inc rdi; jmp .Lcv_skip
.Lcv_trim:
    cmp rsi, rdi; jbe .Lcv_done
    mov al, [rsi - 1]
    cmp al, ' '; je .Lcv_dec
    cmp al, '\t'; je .Lcv_dec
    cmp al, '\r'; je .Lcv_dec
    cmp al, '"'; je .Lcv_dec
    jmp .Lcv_cp
.Lcv_dec:
    dec rsi; jmp .Lcv_trim
.Lcv_cp:
    dec ecx; xor r8d, r8d
.Lcv_loop:
    cmp rdi, rsi; jae .Lcv_done
    cmp r8d, ecx; jge .Lcv_done
    mov al, [rdi]; mov [rdx + r8], al
    inc rdi; inc r8d; jmp .Lcv_loop
.Lcv_done:
    mov byte ptr [rdx + r8], 0; ret

# void pkg_parse_manifest(const char *buf, int len, PkgEntry *out)
pkg_parse_manifest:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, 72
    mov r12, rdi; movsxd rax, esi; lea r13, [r12 + rax]; mov r14, rdx
    mov rdi, r14; mov esi, 296; call mem_zero
.Lpmf_line:
    cmp r12, r13; jae .Lpmf_done
    mov r15, r12
.Lpmf_eol:
    cmp r15, r13; jae .Lpmf_got
    cmp byte ptr [r15], '\n'; je .Lpmf_got
    inc r15; jmp .Lpmf_eol
.Lpmf_got:
    mov rbx, r12
.Lpmf_eq:
    cmp rbx, r15; jae .Lpmf_next
    cmp byte ptr [rbx], '='; je .Lpmf_key
    inc rbx; jmp .Lpmf_eq
.Lpmf_key:
    mov rdi, r12; mov rsi, rbx; mov rdx, rsp; mov ecx, 64; call pka_copy_val
    mov rdi, rsp; lea rsi, [rip + pka_k_name]; call str_cmp
    test eax, eax; jz .Lpmf_name
    mov rdi, rsp; lea rsi, [rip + pka_k_ver]; call str_cmp
    test eax, eax; jz .Lpmf_ver
    mov rdi, rsp; lea rsi, [rip + pka_k_kind]; call str_cmp
    test eax, eax; jz .Lpmf_kind
    mov rdi, rsp; lea rsi, [rip + pka_k_desc]; call str_cmp
    test eax, eax; jz .Lpmf_desc
    jmp .Lpmf_next
.Lpmf_name:
    lea rdi, [rbx + 1]; mov rsi, r15; mov rdx, r14; mov ecx, 64; call pka_copy_val; jmp .Lpmf_next
.Lpmf_ver:
    lea rdi, [rbx + 1]; mov rsi, r15; lea rdx, [r14 + 64]; mov ecx, 32; call pka_copy_val; jmp .Lpmf_next
.Lpmf_kind:
    lea rdi, [rbx + 1]; mov rsi, r15; lea rdx, [r14 + 96]; mov ecx, 16; call pka_copy_val; jmp .Lpmf_next
.Lpmf_desc:
    lea rdi, [rbx + 1]; mov rsi, r15; lea rdx, [r14 + 112]; mov ecx, 112; call pka_copy_val
.Lpmf_next:
    lea r12, [r15 + 1]; jmp .Lpmf_line
.Lpmf_done:
    add rsp, 72; pop r15; pop r14; pop r13; pop r12; pop rbx; ret

# ArcCtx *pkg_load_archive(const char *path)
pkg_load_archive:
    xor esi, esi
# ArcCtx *pkg_load_archive_sha(const char *path, char *out_sha_hex65)
pkg_load_archive_sha:
    push rbx; push r12; push r13; push r14; sub rsp, SHA_CTX_SZ + 16
    mov rbx, rdi; mov r14, rsi; call arc_is_archive
    test eax, eax; jz .Lpla_err
    mov r12d, eax
    mov edi, ACTX_SIZE; call mem_alloc; test rax, rax; jz .Lpla_err
    mov r13, rax
    mov rdi, r13; mov esi, ACTX_SIZE; call mem_zero
    mov [r13], r12d
    mov edi, ARC_MAX_ENTRIES * AENT_SIZE; call mem_alloc; mov [r13 + 24], rax
    mov edi, ARC_MAX_FILE; call mem_alloc; mov [r13 + 8], rax
    test rax, rax; jz .Lpla_free
    mov rdi, rbx; mov rsi, rax; mov edx, ARC_MAX_FILE; lea rcx, [r13 + 16]
    call fs_read_file_head; test rax, rax; js .Lpla_free
    test r14, r14; jz .Lpla_ungz
    lea rdi, [rsp + 16]; call sha256_init
    lea rdi, [rsp + 16]; mov rsi, [r13 + 8]; mov rdx, [r13 + 16]; call sha256_update
    lea rdi, [rsp + 16]; mov rsi, r14; call sha256_final_hex
.Lpla_ungz:
    cmp dword ptr [r13], 2; jne .Lpla_parse
    mov rdi, [r13 + 8]; mov rsi, [r13 + 16]; mov rdx, rsp; call arc_ungzip
    test rax, rax; jz .Lpla_free
    push rax; mov rdi, [r13 + 8]; call mem_free; pop rax
    mov [r13 + 8], rax; mov rax, [rsp]; mov [r13 + 16], rax
.Lpla_parse:
    mov rdi, r13
    cmp dword ptr [r13], 3; je .Lpla_zip
    call arc_parse_tar; jmp .Lpla_ok
.Lpla_zip:
    call arc_parse_zip
.Lpla_ok:
    mov rax, r13; add rsp, SHA_CTX_SZ + 16; pop r14; pop r13; pop r12; pop rbx; ret
.Lpla_free:
    mov rdi, r13; call pkg_free_archive
.Lpla_err:
    xor eax, eax; add rsp, SHA_CTX_SZ + 16; pop r14; pop r13; pop r12; pop rbx; ret

# void pkg_free_archive(ArcCtx *ctx)
pkg_free_archive:
    test rdi, rdi; jz .Lpfa_ret
    push rbx; mov rbx, rdi
    mov rdi, [rbx + 8]; test rdi, rdi; jz .Lpfa_e
    call mem_free
.Lpfa_e:
    mov rdi, [rbx + 24]; test rdi, rdi; jz .Lpfa_c
    call mem_free
.Lpfa_c:
    mov rdi, rbx; call mem_free
    pop rbx
.Lpfa_ret:
    ret

# int pkg_extract_entry_to(ArcCtx *ctx, ArcEntry *ent, const char *dest_path) -> 0 ok, -1 err
pkg_extract_entry_to:
    push rbx; push r12; push r13; push r14; push r15
    mov rbx, rdi; mov r12, rsi; mov r13, rdx
    mov r14, [rbx + 8]; mov rdx, [r12 + 256]; mov rcx, [rbx + 16]
    cmp rdx, rcx; ja .Lpe_err
    add r14, rdx; sub rcx, rdx                # r14=ptr, rcx=avail
    cmp dword ptr [rbx], 3; jne .Lpe_not_zip
    cmp rcx, 30; jb .Lpe_err
    movzx eax, word ptr [r14 + 26]; movzx edx, word ptr [r14 + 28]
    lea rax, [rax + rdx + 30]
    cmp rcx, rax; jb .Lpe_err
    add r14, rax; sub rcx, rax
    mov r15, [r12 + 272]                    # comp_size
    cmp r15, rcx; jbe .Lpe_cs_ok
    mov r15, rcx
    jmp .Lpe_cs_ok
.Lpe_not_zip:
    mov r15, rcx
.Lpe_cs_ok:
    mov eax, [r12 + 280]
    cmp eax, 8; je .Lpe_deflate
    test eax, eax; jnz .Lpe_err
    mov rdx, [r12 + 264]
    cmp rdx, r15; jbe 1f; mov rdx, r15
1:  cmp rdx, rcx; jbe 2f; mov rdx, rcx
2:  mov rdi, r13; mov rsi, r14; call pkg_write_file
    jmp .Lpe_ret
.Lpe_deflate:
    mov rdi, [r12 + 264]
    cmp rdi, ARC_MAX_UNCOMP; ja .Lpe_err
    test rdi, rdi; jnz .Lpe_alloc; mov edi, 1
.Lpe_alloc:
    call mem_alloc; test rax, rax; jz .Lpe_err
    mov rcx, [r12 + 264]
    push r14; mov r14, rax
    mov rdi, [rsp]; mov rsi, r15; mov rdx, r14; call inflate_raw
    add rsp, 8
    test rax, rax; js .Lpe_free_err
    mov rdi, r13; mov rsi, r14; mov rdx, rax; call pkg_write_file
    push rax; mov rdi, r14; call mem_free; pop rax; jmp .Lpe_ret
.Lpe_free_err:
    mov rdi, r14; call mem_free
.Lpe_err:
    mov eax, -1
.Lpe_ret:
    pop r15; pop r14; pop r13; pop r12; pop rbx; ret
