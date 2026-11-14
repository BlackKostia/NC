# src/fs/pkg_registry.s - Package Registry (update, list, find, upgrade)
.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.equ PKGR_SIZE,   512
.equ PKGR_VER,    64
.equ PKGR_KIND,   96
.equ PKGR_SHA,    112
.equ PKGR_URL,    192
.equ PKGR_DESC,   384
.equ PKG_ENTRY_SZ, 296

.section .rodata
pkr_env_reg:  .asciz "DUOP_PKG_REGISTRY="
pkr_reg_file: .asciz "registry.tsv"
pkr_http:     .asciz "http://"
pkr_https:    .asciz "https://"

.section .text
.global pkg_registry_update
.global pkg_registry_list
.global pkg_registry_find
.global pkg_registry_upgrade
.global pkg_semver_cmp

.extern cfg_getenv
.extern fs_read_file_head
.extern mem_alloc
.extern mem_free
.extern mem_zero
.extern path_join
.extern pkg_fetch_url
.extern pkg_get_root
.extern pkg_install_archive
.extern pkg_list
.extern pkg_mkdir_p
.extern pkg_write_file
.extern str_cmp
.extern str_starts_with

pkr_copy_field:
    # rdi=cur_ptr, rsi=line_end, rdx=dst, ecx=cap -> returns rax=next_ptr after '\t' or line_end
    dec ecx; xor r8d, r8d
.Lpcf_l:
    cmp rdi, rsi; jae .Lpcf_eol
    mov al, [rdi]
    cmp al, 9; je .Lpcf_tab
    cmp al, 13; je .Lpcf_adv
    cmp r8d, ecx; jge .Lpcf_adv
    mov [rdx + r8], al; inc r8d
.Lpcf_adv:
    inc rdi; jmp .Lpcf_l
.Lpcf_tab:
    inc rdi
.Lpcf_eol:
    mov byte ptr [rdx + r8], 0
    mov rax, rdi; ret

pkr_parse_line:
    # rdi=line, rsi=line_end, rdx=PkgRegEntry*
    push rbx; push r12; push r13
    mov rbx, rdi; mov r12, rsi; mov r13, rdx
    mov rdi, r13; mov esi, PKGR_SIZE; call mem_zero
    mov rdi, rbx; mov rsi, r12; mov rdx, r13; mov ecx, 64; call pkr_copy_field
    mov rdi, rax; mov rsi, r12; lea rdx, [r13 + PKGR_VER]; mov ecx, 32; call pkr_copy_field
    mov rdi, rax; mov rsi, r12; lea rdx, [r13 + PKGR_KIND]; mov ecx, 16; call pkr_copy_field
    mov rdi, rax; mov rsi, r12; lea rdx, [r13 + PKGR_SHA]; mov ecx, 80; call pkr_copy_field
    mov rdi, rax; mov rsi, r12; lea rdx, [r13 + PKGR_URL]; mov ecx, 192; call pkr_copy_field
    mov rdi, rax; mov rsi, r12; lea rdx, [r13 + PKGR_DESC]; mov ecx, 128; call pkr_copy_field
    pop r13; pop r12; pop rbx; ret

# int pkg_registry_update(char **envp) -> 0 ok, -1 err
pkg_registry_update:
    push rbx; push r12; push r13
    sub rsp, PATH_MAX * 2 + 16
    mov rbx, rdi
    lea rsi, [rip + pkr_env_reg]; call cfg_getenv
    test rax, rax; jz .Lpru_err
    mov r12, rax
    mov rdi, rbx; mov rsi, rsp; mov edx, PATH_MAX; call pkg_get_root
    mov rdi, rsp; call pkg_mkdir_p
    lea rdi, [rsp + PATH_MAX]; mov rsi, rsp; lea rdx, [rip + pkr_reg_file]; mov ecx, PATH_MAX; call path_join
    mov rdi, r12; lea rsi, [rip + pkr_http]; call str_starts_with; test eax, eax; jnz .Lpru_url
    mov rdi, r12; lea rsi, [rip + pkr_https]; call str_starts_with; test eax, eax; jnz .Lpru_url
    mov edi, 65536; call mem_alloc; test rax, rax; jz .Lpru_err
    mov r13, rax
    mov rdi, r12; mov rsi, r13; mov edx, 65536; lea rcx, [rsp + PATH_MAX * 2]; call fs_read_file_head
    test rax, rax; js .Lpru_free_err
    lea rdi, [rsp + PATH_MAX]; mov rsi, r13; mov rdx, [rsp + PATH_MAX * 2]; call pkg_write_file
    push rax; mov rdi, r13; call mem_free; pop rax
    jmp .Lpru_ret
.Lpru_url:
    mov rdi, rbx; mov rsi, r12; lea rdx, [rsp + PATH_MAX]; call pkg_fetch_url
    jmp .Lpru_ret
.Lpru_free_err:
    mov rdi, r13; call mem_free
.Lpru_err:
    mov eax, -1
.Lpru_ret:
    add rsp, PATH_MAX * 2 + 16; pop r13; pop r12; pop rbx; ret

# int pkg_registry_list(char **envp, PkgRegEntry *out, int max) -> count
pkg_registry_list:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, PATH_MAX * 2 + 16
    mov rbx, rdi; mov r12, rsi; mov r13d, edx; xor r14d, r14d
    mov rdi, rbx; mov rsi, rsp; mov edx, PATH_MAX; call pkg_get_root
    lea rdi, [rsp + PATH_MAX]; mov rsi, rsp; lea rdx, [rip + pkr_reg_file]; mov ecx, PATH_MAX; call path_join
    mov edi, 65536; call mem_alloc; test rax, rax; jz .Lprl_ret
    mov r15, rax
    lea rdi, [rsp + PATH_MAX]; mov rsi, r15; mov edx, 65536; lea rcx, [rsp + PATH_MAX * 2]
    call fs_read_file_head; test rax, rax; js .Lprl_free
    mov rbx, r15; mov rax, [rsp + PATH_MAX * 2]; lea r8, [r15 + rax]
.Lprl_line:
    cmp rbx, r8; jae .Lprl_free
    cmp r14d, r13d; jge .Lprl_free
    mov r9, rbx
.Lprl_eol:
    cmp r9, r8; jae .Lprl_got
    cmp byte ptr [r9], 10; je .Lprl_got
    inc r9; jmp .Lprl_eol
.Lprl_got:
    cmp r9, rbx; je .Lprl_next
    cmp byte ptr [rbx], '#'; je .Lprl_next
    push r8; push r9
    imul rdx, r14, PKGR_SIZE; add rdx, r12
    mov rdi, rbx; mov rsi, r9; call pkr_parse_line
    pop r9; pop r8
    imul rax, r14, PKGR_SIZE; cmp byte ptr [r12 + rax], 0; je .Lprl_next
    inc r14d
.Lprl_next:
    lea rbx, [r9 + 1]; jmp .Lprl_line
.Lprl_free:
    mov rdi, r15; call mem_free
.Lprl_ret:
    mov eax, r14d
    add rsp, PATH_MAX * 2 + 16; pop r15; pop r14; pop r13; pop r12; pop rbx; ret

# int pkg_registry_find(char **envp, const char *name, PkgRegEntry *out) -> 0 ok, -1 err
pkg_registry_find:
    push rbx; push r12; push r13; push r14
    mov rbx, rdi; mov r12, rsi; mov r13, rdx
    mov edi, 64 * PKGR_SIZE; call mem_alloc; test rax, rax; jz .Lprf_err
    mov r14, rax
    mov rdi, rbx; mov rsi, r14; mov edx, 64; call pkg_registry_list
    mov ebx, eax; xor ecx, ecx
.Lprf_l:
    cmp ecx, ebx; jge .Lprf_nf
    imul rsi, rcx, PKGR_SIZE; add rsi, r14
    push rcx; push rsi; mov rdi, rsi; mov rsi, r12; call str_cmp; pop rsi; pop rcx
    test eax, eax; jnz .Lprf_n
    mov rdi, r13; mov ecx, PKGR_SIZE / 8; rep movsq
    mov rdi, r14; call mem_free; xor eax, eax; pop r14; pop r13; pop r12; pop rbx; ret
.Lprf_n:
    inc ecx; jmp .Lprf_l
.Lprf_nf:
    mov rdi, r14; call mem_free
.Lprf_err:
    mov eax, -1; pop r14; pop r13; pop r12; pop rbx; ret

# int pkg_registry_upgrade(char **envp) -> 0 ok, -1 err
pkg_registry_upgrade:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, PKGR_SIZE + 8
    mov rbx, rdi
    mov edi, 32 * PKG_ENTRY_SZ; call mem_alloc; test rax, rax; jz .Lpru_g_err
    mov r12, rax
    mov rdi, rbx; mov rsi, r12; mov edx, 32; call pkg_list
    mov r13d, eax; xor r14d, r14d; xor r15d, r15d
.Lpru_g_l:
    cmp r14d, r13d; jge .Lpru_g_done
    imul rsi, r14, PKG_ENTRY_SZ; add rsi, r12
    mov rdi, rbx; mov rdx, rsp; push rsi; call pkg_registry_find; pop rsi
    test eax, eax; jnz .Lpru_g_n
    lea rdi, [rsi + 64]; lea rsi, [rsp + PKGR_VER]; call pkg_semver_cmp
    cmp eax, 0; jge .Lpru_g_n
    mov rdi, rbx; lea rsi, [rsp + PKGR_URL]; lea rdx, [rsp + PKGR_SHA]
    call pkg_install_archive
    test eax, eax; jz .Lpru_g_n
    mov r15d, -1
.Lpru_g_n:
    inc r14d; jmp .Lpru_g_l
.Lpru_g_done:
    mov rdi, r12; call mem_free; mov eax, r15d
    add rsp, PKGR_SIZE + 8; pop r15; pop r14; pop r13; pop r12; pop rbx; ret
.Lpru_g_err:
    mov eax, -1; add rsp, PKGR_SIZE + 8; pop r15; pop r14; pop r13; pop r12; pop rbx; ret

# Helper: (eax=num, rdx=next_ptr) pkr_parse_ver_part(const char *p)
pkr_parse_ver_part:
    xor eax, eax
    test rdi, rdi; jz .Lpvp_ret
    mov cl, [rdi]
    cmp cl, 'v'; je .Lpvp_skip
    cmp cl, 'V'; jne .Lpvp_loop
.Lpvp_skip:
    inc rdi
.Lpvp_loop:
    movzx ecx, byte ptr [rdi]
    cmp cl, '0'; jb .Lpvp_end
    cmp cl, '9'; ja .Lpvp_end
    imul eax, eax, 10
    sub cl, '0'
    add eax, ecx
    inc rdi
    jmp .Lpvp_loop
.Lpvp_end:
    cmp byte ptr [rdi], '.'; jne .Lpvp_ret
    inc rdi
.Lpvp_ret:
    mov rdx, rdi
    ret

# int pkg_semver_cmp(const char *a, const char *b) -> -1 (a<b), 0 (a==b), 1 (a>b)
pkg_semver_cmp:
    push rbx; push r12; push r13
    mov rbx, rdi; mov r12, rsi
    mov r13d, 3
.Lpsc_loop:
    mov rdi, rbx; call pkr_parse_ver_part
    mov rbx, rdx; push rax
    mov rdi, r12; call pkr_parse_ver_part
    mov r12, rdx; pop rcx
    cmp ecx, eax; jl .Lpsc_lt; jg .Lpsc_gt
    dec r13d; jnz .Lpsc_loop
    xor eax, eax; jmp .Lpsc_done
.Lpsc_lt:
    mov eax, -1; jmp .Lpsc_done
.Lpsc_gt:
    mov eax, 1
.Lpsc_done:
    pop r13; pop r12; pop rbx; ret
